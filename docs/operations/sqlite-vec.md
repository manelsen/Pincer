# sqlite-vec (optional vector search)

Pincer's only storage backend is embedded SQLite. Semantic recall (`search_similar/3`,
used by `MemoryRecall` and `external_knowledge`) runs either through the optional
[`sqlite-vec`](https://github.com/asg017/sqlite-vec) `vec0` virtual table or through an
in-process cosine-similarity fallback. FTS5 full-text search is independent and always
available.

The extension is loaded per SQLite connection at boot. It never changes the database
format required by the rest of Pincer: `nodes.embedding` stores the JSON vector in both
modes, and `vec_nodes` is an auxiliary index.

## Build

Prerequisites: `git`, `make`, and a C compiler (`cc` or `gcc`).

```bash
./scripts/build_sqlite_vec.sh          # no-op if priv/sqlite_vec/vec0.{so,dylib} exists
./scripts/build_sqlite_vec.sh --force  # rebuild
```

The script:

- clones the pinned sqlite-vec tag (`v0.1.10-alpha.4` by default) into
  `.cache/sqlite-vec`, shallow, once;
- runs `make loadable`;
- copies the built loadable library (`dist/vec0.so` or `dist/vec0.dylib`) to
  `priv/sqlite_vec/vec0.so` on Linux or `priv/sqlite_vec/vec0.dylib` on macOS (Darwin).

Overrides:

| Variable | Default | Purpose |
|---|---|---|
| `SQLITE_VEC_VERSION` | `v0.1.10-alpha.4` | sqlite-vec git tag |
| `SQLITE_VEC_BUILD_DIR` | `.cache/sqlite-vec` | clone/build directory |
| `SQLITE_VEC_OUT_DIR` | `priv/sqlite_vec` | output directory for `vec0.so` / `vec0.dylib` |

The `Dockerfile` runs the script with `--force` before `mix compile`, and CI runs it in
every job. Bumping the version means editing the default in the script (or setting
`SQLITE_VEC_VERSION`) and rebuilding.

## Enable / disable

```yaml
# config.yaml
storage:
  adapter: "sqlite"
  path: "data/pincer.db"
  vec: "auto"                          # auto | true | false
  vec_path: "priv/sqlite_vec/vec0.so"  # optional explicit path
  vec_dimensions: 1024                 # embedding width
```

Environment equivalents:

| Variable | Values | Notes |
|---|---|---|
| `PINCER_SQLITE_VEC` | `auto`, `true`/`1`/`yes`, `false`/`0`/`no` | `auto` is the default |
| `PINCER_SQLITE_VEC_PATH` | file path | overrides `storage.vec_path` |
| `PINCER_SQLITE_VEC_DIMENSIONS` | positive integer | overrides `storage.vec_dimensions` |

Behavior:

- `false`/`0`/`no` — never load the extension; `vec_nodes` is not created.
- `auto`/`true` — attempt to load. A missing file or a failed load logs
  `[SQLITE] sqlite-vec extension not loaded; vector search will use cosine fallback`
  and boots with the fallback. It does not fail startup.
- An explicit path is used only if it points to a regular file. A wrong explicit path
  does **not** fall through to the default candidate list.
- An invalid `PINCER_SQLITE_VEC_DIMENSIONS` value from the environment is ignored with a
  warning during config load. Invalid dimensions passed directly to the engine fail
  startup with `{:invalid_vec_dimensions, value}` when vector search is enabled.

## Path resolution

When `vec_path` / `PINCER_SQLITE_VEC_PATH` is not set (or is `auto`/`true`), the loader
checks, in order:

1. `priv/sqlite_vec/vec0.so`
2. `priv/sqlite_vec/vec0`
3. `priv/sqlite_vec/vec0.dylib`

Each relative candidate is checked both against the process working directory and against
the application's `:code.priv_dir(:pincer)`. `scripts/build_sqlite_vec.sh` automatically
produces `priv/sqlite_vec/vec0.so` on Linux and `priv/sqlite_vec/vec0.dylib` on macOS
(Darwin), so no manual post-build copy is needed.

## Dimensions

`storage.vec_dimensions` (default `1024`) defines
`vec0(rowid INTEGER PRIMARY KEY, embedding float[N] distance_metric=cosine)`. It must
match the embedding model used for indexing. OpenRouter defaults (`baai/bge-m3` and the
`baai/bge-large-en-v1.5` retry) are 1024-dimensional.

The table is created with `CREATE VIRTUAL TABLE IF NOT EXISTS`. Changing the configured
dimensions on an existing database does not reshape `vec_nodes`: drop/recreate the table
(or rebuild the database) and re-index documents after changing embedding models.
Vectors with the wrong length are rejected by sqlite-vec; the adapter logs a debug
`vec0 insert skipped` message and leaves the document searchable through the fallback.

## Indexing semantics

- Only `document` nodes written by `index_document/4` / `index_memory/5` are vector-indexed.
  Graph nodes of other types keep any embedding in `nodes.embedding` but are not inserted
  into `vec_nodes`.
- A `vec_nodes` row is keyed by the owning `nodes` table rowid, not by the text `nodes.id`
  UUID. The KNN query joins `nodes n ON n.rowid = v.rowid`.
- Indexing is transactional. On re-index, the adapter updates `nodes`, syncs
  `documents_fts`, then deletes the existing `vec_nodes` row for that rowid and inserts the
  new vector. If the vector is `nil`/empty, only the delete runs.
- `forget_memory/1` soft-forgets a document (`data.forgotten_at`) and removes its
  `vec_nodes` row. The `nodes` row and FTS entry remain; semantic queries filter
  `forgotten_at` out.
- `purge_invalid_documents/1` (also exposed as `mix pincer.purge_indices`) deletes matching
  `documents_fts` rows, `vec_nodes` rows (resolved through `nodes.rowid`), and `nodes` rows
  in one transaction, in chunks of 200. It returns the number of purged document nodes.
- KNN search over-fetches `max(10 * limit, 50)` candidates, filters by type and
  non-forgotten status, computes `similarity = 1.0 - distance`, then applies Pincer's normal
  document scoring and access tracking.

## Fallback behavior

Fallback triggers in `search_similar/3`:

1. the extension is disabled or failed to load;
2. the query vector is invalid/empty;
3. the KNN query errors (for example a dimension mismatch);
4. the KNN query returns zero eligible rows.

Fallback reads `nodes.embedding` for the requested type (skipping `NULL` and forgotten
rows), computes cosine similarity in Elixir, sorts by similarity then insertion time, and
returns the top `limit`. It uses the same result/scoring shape as the `vec0` path, so
callers and prompt assembly need no changes. Unlike the KNN path, the fallback scans all
candidate rows for that type.

## Troubleshooting

**Extension not found**

```
[SQLITE] sqlite-vec extension not loaded; vector search will use cosine fallback
```

Run `./scripts/build_sqlite_vec.sh`; verify the file exists and is readable:

```bash
ls -l priv/sqlite_vec/vec0.so
mix pincer.doctor    # reports :sqlite_vec :ok, or a warning with "cosine fallback"
```

`mix pincer.doctor --strict` turns that warning into a failure, which is useful in CI or
in a deployment where the index is required.

**Architecture or libc mismatch**

Loading a `vec0.so` built for another CPU architecture or C library (for example a glibc
build inside an Alpine/musl container, or a macOS `.dylib` named `.so`) makes
`load_extension` fail. Pincer logs the generic fallback message rather than the loader
error. Rebuild inside the target environment:

```bash
./scripts/build_sqlite_vec.sh --force
file priv/sqlite_vec/vec0.so
uname -m
```

Inside Docker the image already builds the extension during the image build, so mount or
copy a host-built `.so` into the container only if it matches the image's architecture and
libc.

**Explicit path typo disables the index**

If `vec_path` / `PINCER_SQLITE_VEC_PATH` is set but not a regular file, the loader does
not probe the default candidates. Remove the setting or point it at the built `vec0.so`.

**Documents are not found semantically**

- Confirm `nodes.embedding` is populated (`index_memory` receives a non-empty vector).
- Confirm `storage.vec_dimensions` matches the embedding length.
- Run `mix pincer.doctor` and check for `vec0 insert skipped` debug logs.
- If the KNN path returns nothing, cosine fallback should still find rows with stored
  embeddings; rows without an embedding are invisible to both paths.

**Space held by a stale index**

After changing embedding models, drop `vec_nodes` and re-index. Disabling the extension
leaves an existing `vec_nodes` table in the file, but it is not read or written while
disabled; it can be dropped manually during a maintenance window.

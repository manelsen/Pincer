#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${SQLITE_VEC_VERSION:-v0.1.10-alpha.4}"
BUILD_DIR="${SQLITE_VEC_BUILD_DIR:-"$ROOT/.cache/sqlite-vec"}"
OUT_DIR="${SQLITE_VEC_OUT_DIR:-"$ROOT/priv/sqlite_vec"}"
UNAME_S="${SQLITE_VEC_UNAME_S:-$(uname -s)}"

if [[ "$UNAME_S" == "Darwin" ]]; then
  EXT="dylib"
else
  EXT="so"
fi

OUT="$OUT_DIR/vec0.$EXT"

if [[ -f "$OUT" && "${1:-}" != "--force" ]]; then
  echo "sqlite-vec already built at $OUT (use --force to rebuild)"
  exit 0
fi

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v make >/dev/null || { echo "make is required" >&2; exit 1; }
command -v cc >/dev/null || command -v gcc >/dev/null || { echo "a C compiler is required" >&2; exit 1; }

if [[ ! -d "$BUILD_DIR/.git" ]]; then
  mkdir -p "$(dirname "$BUILD_DIR")"
  git clone --depth 1 --branch "$VERSION" https://github.com/asg017/sqlite-vec.git "$BUILD_DIR"
fi

make -C "$BUILD_DIR" loadable

BUILT=""
for candidate in "$BUILD_DIR/dist/vec0.$EXT" "$BUILD_DIR/dist/vec0.so" "$BUILD_DIR/dist/vec0.dylib"; do
  if [[ -f "$candidate" ]]; then
    BUILT="$candidate"
    break
  fi
done

if [[ -z "$BUILT" ]]; then
  echo "sqlite-vec build failed: no loadable library produced in $BUILD_DIR/dist" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
cp "$BUILT" "$OUT"
echo "built $OUT ($VERSION)"

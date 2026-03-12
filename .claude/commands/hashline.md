Annotate a file with 5-hex line hashes and use those hashes for all subsequent edits.

## Steps

1. Run the following bash command to produce the hashline-annotated view of `$ARGUMENTS`:

```bash
awk '{printf "%05x|%s\n", NR, $0}' $ARGUMENTS
```

2. Display the full annotated output to the user.

3. Wait for the user to describe what to change, expressed as hash references (e.g. "replace line `0001a` with X" or "delete lines `0003c` to `0004f`").

4. Apply each edit by locating the target line(s) using the hash as a stable identifier. Use the Read tool to confirm the current line content before editing, then apply with the Edit tool.

## Rules

- Never use str_replace with reproduced content when a hash reference was provided.
- If two lines have the same content and thus the same hash would be ambiguous, display both with their hashes and ask the user to confirm which one.
- After applying edits, re-run the annotated view of the modified region so the user can verify.
- Hashes are 1-indexed decimal line numbers formatted as 5-digit lowercase hex (`printf "%05x", NR`). They are stable within a session but change if lines are inserted or deleted above them — warn the user if a multi-step edit session requires re-annotation.

---
description: "Cancel an active review loop"
allowed-tools:
  - Bash
  - Read
---

Locate the project root by walking up from the current working directory
until a parent containing `.claude/review-loop.local.md` is found. This
mirrors the stop hook so `/cancel-review` works even when the caller's
CWD is a worktree (or any other subdirectory) of the project where the
loop was started.

```bash
project_root=""
d=$(pwd -P)
while [ "$d" != "/" ]; do
  if [ -f "$d/.claude/review-loop.local.md" ]; then
    project_root=$d
    break
  fi
  d=$(dirname "$d")
done

if [ -z "$project_root" ]; then
  echo "NONE"
else
  echo "ACTIVE: $project_root"
fi
```

If no active loop was found, report: "No active review loop found." and stop.

Otherwise read `${project_root}/.claude/review-loop.local.md` to capture
the current phase and review ID, then remove the state file, lock file,
and any generated Codex artifacts:

```bash
rm -f "${project_root}/.claude/review-loop.local.md" \
      "${project_root}/.claude/review-loop.lock" \
      "${project_root}/.claude/review-loop-run-codex.sh" \
      "${project_root}/.claude/review-loop-codex-prompt.txt" \
      "${project_root}/.claude/review-loop-retries"
```

Report: "Review loop cancelled (was at phase: X, review ID: Y)".

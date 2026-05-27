---
description: "Start a review loop: implement task, get independent Codex review, address feedback"
argument-hint: "<task description>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

First, set up the review loop by running this setup command:

```bash
set -e && REVIEW_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')" && mkdir -p .claude reviews && if [ -f .claude/review-loop.local.md ]; then echo "Error: A review loop is already active. Use /cancel-review first." && exit 1; fi && command -v codex >/dev/null 2>&1 || { echo "Error: Codex CLI is not installed. Install it: npm install -g @openai/codex"; exit 1; } && CODEX_CONFIG="${HOME}/.codex/config.toml" && if [ ! -f "$CODEX_CONFIG" ]; then mkdir -p "${HOME}/.codex" && printf '[features]\nmulti_agent = true\n' > "$CODEX_CONFIG" && echo "Created ~/.codex/config.toml with multi_agent enabled"; elif ! grep -qE '^\s*multi_agent\s*=\s*true' "$CODEX_CONFIG"; then if grep -qE '^\[features\]' "$CODEX_CONFIG"; then if [ "$(uname)" = "Darwin" ]; then sed -i '' '/^\[features\]/a\'$'\n''multi_agent = true' "$CODEX_CONFIG"; else sed -i '/^\[features\]/a multi_agent = true' "$CODEX_CONFIG"; fi; else printf '\n[features]\nmulti_agent = true\n' >> "$CODEX_CONFIG"; fi && echo "Enabled multi_agent in ~/.codex/config.toml"; else echo "Codex multi-agent: already enabled"; fi && rm -f .claude/review-loop.lock && cat > .claude/review-loop.local.md << STATE_EOF
---
active: true
phase: task
review_id: ${REVIEW_ID}
started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

$ARGUMENTS
STATE_EOF
echo "Review Loop activated (ID: ${REVIEW_ID})"
```

After setup completes successfully, assess the task complexity. For complex tasks, use the `using-superpowers` skill to write a spec and plan first, then implement using Test-Driven Development (TDD): write tests first, make them pass, then refactor. For simple tasks, skip `using-superpowers` and implement directly using TDD. Work thoroughly and completely — write clean, well-structured, well-tested code.

When you believe the task is fully done, prepare it for review by Codex:

1. Commit any remaining changes on a feature branch (not `main`/`master`).
2. Push the branch: `git push -u origin <branch_name>` (use the current branch name from `git branch --show-current`).
3. Open a pull request and capture the PR URL it prints. Pick the CLI that matches the remote:
   - GitHub remote: `gh pr create`
   - Gitea remote (gitea.com or self-hosted): `tea pr create` (use `tea pr create --output simple` or follow up with `tea pr list --output json` if you need to parse the URL)
   Check `git remote -v` if you're not sure which to use.
4. Record the PR URL in `.claude/review-loop.local.md` by inserting a `related_pr: <pr_url>` line inside the YAML frontmatter (above the closing `---`). Use the Edit tool — do not rewrite the whole file.
5. Then stop.

The review loop stop hook will then automatically:
1. Prepare a Codex runner script and prompt file (scoped to the PR you just opened)
2. Block your exit with instructions to run the review

You will then run `bash .claude/review-loop-run-codex.sh` to execute the Codex review (output streams to the user for visibility). After Codex finishes, read the review file and address the findings.

RULES:
- Complete the task to the best of your ability before stopping
- Do not stop prematurely or skip parts of the task
- You MUST push the branch and create the PR before stopping — the Codex review is scoped to that PR
- When blocked by the hook, run the Codex script as instructed and address the review

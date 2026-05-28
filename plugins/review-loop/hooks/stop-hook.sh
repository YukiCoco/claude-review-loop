#!/usr/bin/env bash
# Review Loop — Stop Hook
#
# Two-phase lifecycle:
#   Phase 1 (task):       Claude finishes work → hook prepares Codex runner script → blocks exit
#   Phase 2 (addressing): Claude runs Codex, addresses review → hook verifies review exists → allows exit
#
# On any error, default to allowing exit (never trap the user in a broken loop).
#
# Environment variables:
#   REVIEW_LOOP_CODEX_FLAGS  Override codex flags (default: --dangerously-bypass-approvals-and-sandbox)

# ── Locate the project root ───────────────────────────────────────────────
# The state file (`.claude/review-loop.local.md`) is created by
# `/review-loop` in the CWD where the user kicked off the loop. The hook
# itself, however, fires from whatever CWD Claude happens to be in when it
# stops — typically the same place, but NOT when the user worked inside a
# `git worktree` (or any nested subdirectory) after setup. Using a plain
# relative path here silently approved exit in that case, skipping the
# Codex review entirely.
#
# Walk up from the current directory until we find a parent containing
# `.claude/review-loop.local.md`. If nothing is found, fall back to CWD so
# the early "no active loop" branch fires (preserves prior behaviour).
find_project_root() {
  local d
  d=$(pwd -P)
  while [ "$d" != "/" ]; do
    if [ -f "$d/.claude/review-loop.local.md" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    d=$(dirname "$d")
  done
  pwd -P
}

PROJECT_ROOT=$(find_project_root)

STATE_FILE="${PROJECT_ROOT}/.claude/review-loop.local.md"
LOG_FILE="${PROJECT_ROOT}/.claude/review-loop.log"
LOCK_FILE="${PROJECT_ROOT}/.claude/review-loop.lock"
PROMPT_FILE="${PROJECT_ROOT}/.claude/review-loop-codex-prompt.txt"
RUNNER_SCRIPT="${PROJECT_ROOT}/.claude/review-loop-run-codex.sh"
RETRY_FILE="${PROJECT_ROOT}/.claude/review-loop-retries"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

trap 'log "ERROR: hook exited via ERR trap (line $LINENO)"; rm -f "$LOCK_FILE" "$RUNNER_SCRIPT" "$PROMPT_FILE" "$RETRY_FILE"; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# Consume stdin (hook input JSON) — must read to avoid broken pipe
HOOK_INPUT=$(cat)

# No active loop → allow exit
if [ ! -f "$STATE_FILE" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Parse a field from the YAML frontmatter
parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

ACTIVE=$(parse_field "active")
PHASE=$(parse_field "phase")
REVIEW_ID=$(parse_field "review_id")
RELATED_PR=$(parse_field "related_pr")

# Not active → clean up and exit
if [ "$ACTIVE" != "true" ]; then
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Validate review_id format to prevent path traversal
if ! echo "$REVIEW_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  log "ERROR: invalid review_id format: $REVIEW_ID"
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# ── Project type detection ────────────────────────────────────────────────
# All detection paths are evaluated against ${PROJECT_ROOT}, not the
# current CWD — otherwise a worktree subdirectory would mis-detect the
# project type (e.g. miss next.config.js at the real root).
detect_nextjs() {
  [ -f "${PROJECT_ROOT}/next.config.js" ] || [ -f "${PROJECT_ROOT}/next.config.mjs" ] || [ -f "${PROJECT_ROOT}/next.config.ts" ] || \
    ([ -f "${PROJECT_ROOT}/package.json" ] && grep -q '"next"' "${PROJECT_ROOT}/package.json" 2>/dev/null)
}

detect_browser_ui() {
  # Has HTML/JSX/TSX files in app/ or pages/ or src/ directories, or has a public/ dir
  [ -d "${PROJECT_ROOT}/app" ] || [ -d "${PROJECT_ROOT}/pages" ] || [ -d "${PROJECT_ROOT}/src/app" ] || [ -d "${PROJECT_ROOT}/src/pages" ] || \
    [ -d "${PROJECT_ROOT}/public" ] || [ -f "${PROJECT_ROOT}/index.html" ]
}

# ── Build the multi-agent review prompt ───────────────────────────────────
build_review_prompt() {
  local REVIEW_FILE="$1"
  local PR_URL="$2"

  local IS_NEXTJS=false
  local HAS_UI=false
  detect_nextjs && IS_NEXTJS=true
  detect_browser_ui && HAS_UI=true

  log "Project detection: nextjs=$IS_NEXTJS, browser_ui=$HAS_UI, pr=$PR_URL"

  # ── Scope block (PR-bound or branch-bound fallback) ──
  local SCOPE_BLOCK
  if [ -n "$PR_URL" ]; then
    # Classify the PR URL: GitHub uses /pull/<n>, Gitea uses /pulls/<n>.
    local pr_host="" pr_owner="" pr_repo="" pr_number=""
    if [[ "$PR_URL" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
      pr_host="github"
      pr_owner="${BASH_REMATCH[1]}"
      pr_repo="${BASH_REMATCH[2]}"
      pr_number="${BASH_REMATCH[3]}"
    elif [[ "$PR_URL" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pulls/([0-9]+) ]]; then
      pr_host="gitea"
      pr_owner="${BASH_REMATCH[1]}"
      pr_repo="${BASH_REMATCH[2]}"
      pr_number="${BASH_REMATCH[3]}"
    else
      pr_host="unknown"
    fi
    log "PR URL classification: host=$pr_host, owner=$pr_owner, repo=$pr_repo, number=$pr_number"

    local FETCH_CMDS
    case "$pr_host" in
      github)
        FETCH_CMDS="  - \`gh pr diff ${PR_URL}\` — unified diff for the PR.
  - \`gh pr view ${PR_URL} --json files,baseRefName,headRefName,title,body\` — file list, base branch, title, body."
        ;;
      gitea)
        FETCH_CMDS="  - \`tea api /repos/${pr_owner}/${pr_repo}/pulls/${pr_number}.diff\` — unified diff for the PR.
  - \`tea api /repos/${pr_owner}/${pr_repo}/pulls/${pr_number}\` — PR metadata as JSON (base branch, head, title, body).
  - \`tea api /repos/${pr_owner}/${pr_repo}/pulls/${pr_number}/files\` — list of changed files.
  Notes: \`tea\` reads auth from its active login (\`tea login default\`); ensure a login exists for this Gitea host. From inside this repo you can also use \`tea pr ${pr_number}\` family commands without --repo."
        ;;
      *)
        FETCH_CMDS="  - If the remote is GitHub: \`gh pr diff ${PR_URL}\` and \`gh pr view ${PR_URL} --json files,baseRefName,headRefName,title,body\`.
  - If the remote is Gitea: parse <owner>/<repo>/<number> from the URL, then \`tea api /repos/<owner>/<repo>/pulls/<number>.diff\` (diff) and \`tea api /repos/<owner>/<repo>/pulls/<number>\` (metadata) plus \`/files\` for the file list.
  - Inspect \`git remote -v\` if you're not sure which CLI applies."
        ;;
    esac

    SCOPE_BLOCK="SCOPE (STRICT): This review is bound to a single pull request: ${PR_URL}

Before doing anything else, determine the exact files and line ranges in scope using whichever of these commands matches the host (gh for GitHub, tea for Gitea):
${FETCH_CMDS}

The in-scope set is EXACTLY the files (and line ranges within them) modified by this PR. Do NOT flag issues in:
  - Files not touched by this PR.
  - Pre-existing issues in touched files that are outside the changed line ranges, unless the PR's changes directly depend on or activate them.
  - Repo-wide structural / organizational concerns that are not introduced or worsened by this PR.

If a concern is tempting but out of scope, DROP IT. \"Out of scope\" trumps \"would be nice.\""
  else
    SCOPE_BLOCK="SCOPE (STRICT): No PR URL was recorded. Fall back to reviewing only the current branch's diff against its base.

Determine in-scope files/lines via: \`git branch --show-current\`, \`git merge-base HEAD origin/main\` (or the appropriate base), and \`git diff <merge-base>...HEAD\`. Include staged and unstaged changes (\`git diff\`, \`git diff --cached\`) as part of the same scope.

Do NOT flag issues outside the changed files/line ranges, and do NOT flag repo-wide structural concerns that this branch did not introduce."
  fi

  # ── Preamble ──
  cat << PREAMBLE_EOF
You are orchestrating a thorough, independent code review of a single pull request in this repository.

${SCOPE_BLOCK}

Use multi-agent to run the following review agents IN PARALLEL. Each agent MUST respect the SCOPE block above and return its findings as structured text (not write to files). After ALL agents complete, consolidate their findings into a single deduplicated review file. During consolidation, drop any finding that is out of scope per the SCOPE block.

IMPORTANT: Spawn one agent per review path below. Wait for all agents to finish. Then deduplicate overlapping findings and write the consolidated review to: ${REVIEW_FILE}

PREAMBLE_EOF

  # ── Agent 1: Diff Review ──
  cat << 'DIFF_EOF'
---
AGENT 1: Diff Review (focus ONLY on files/lines changed by this PR)

Re-derive the in-scope set from the SCOPE block above using the commands it lists (`gh pr diff …` for GitHub PRs, `tea api …/pulls/<n>.diff` for Gitea PRs; fall back to `git diff <merge-base>...HEAD` only if no PR URL is given). Review EXCLUSIVELY the code introduced or modified by this PR. Do not stray into unchanged files or unchanged lines.

Review criteria for changed code:

Code Quality:
- Is the changed code well-organized, modular, and readable?
- Does it follow DRY principles — no copy-pasted blocks that should be abstracted?
- Are names (variables, functions, files) clear and consistent with the codebase?
- Are abstractions at the right level — not over-engineered, not under-abstracted?
- Is there unnecessary complexity that could be simplified?

Test Coverage:
- Does every new function/endpoint/component have corresponding tests?
- Are edge cases covered: empty inputs, nulls, boundary values, error paths?
- Are tests isolated, deterministic, and fast?
- Do tests verify behavior (not implementation details)?
- For bug fixes: is there a regression test that would have caught the original bug?

Security:
- Input validation: are all user inputs validated and sanitized before use?
- Authentication/authorization: are auth checks present on all protected routes/actions?
- Injection: any risk of SQL injection, XSS, command injection, path traversal?
- Secrets: are any credentials, API keys, or tokens hardcoded or logged?
- OWASP Top 10: check for broken access control, cryptographic failures, insecure design, security misconfiguration, vulnerable dependencies, SSRF
- Are error messages safe (no stack traces or internal details leaked to users)?

For each issue: return file path, line number, severity (critical/high/medium/low), category, description, and suggested fix.

DIFF_EOF

  # ── Agent 2: Spec Compliance Review ──
  cat << 'SPEC_EOF'
---
AGENT 2: Spec Compliance Review (verify this PR's implementation matches the spec)

Find and read the task specification and plan files — especially `SPEC.md`, `PLAN.md`, and the PR description (fetch it via the host-appropriate command from the SCOPE block: `gh pr view <PR_URL> --json body` for GitHub, `tea api /repos/<owner>/<repo>/pulls/<number>` for Gitea). If no explicit spec exists, reconstruct the intended requirements from the review-loop task description, README, tests, and changed code, then clearly state that the spec was inferred.

Constrain your review to whether THIS PR's changes satisfy the spec. Do not flag spec items that are unrelated to the files this PR touches, and do not propose work that belongs in a separate PR.

Review whether the implemented functionality correctly satisfies the spec:

Spec Alignment:
- Are all functional requirements and acceptance criteria implemented?
- Are there missing behaviors, incomplete flows, or TODO/stub implementations?
- Does the implementation match the intended user-facing behavior, inputs, outputs, and error handling?
- Are edge cases from the spec handled correctly?
- Did the implementation introduce behavior that contradicts or exceeds the spec in risky ways?

Plan Completion:
- Are all major plan steps completed?
- If the plan changed during implementation, is the final behavior still consistent with the spec?
- Are any documented follow-ups actually required before the task can be considered done?

Verification:
- Are there tests that prove the spec requirements are met?
- Do tests cover the main acceptance criteria and important edge cases?
- If relevant tests are missing, identify the exact spec behavior that lacks coverage.

For each issue: return file path, line number when available, severity (critical/high/medium/low), category, description, the unmet spec requirement, and suggested fix.

SPEC_EOF

  # ── Agent 3: Integration Review (scoped to PR-touched files) ──
  cat << 'HOLISTIC_EOF'
---
AGENT 3: Integration Review (how THIS PR fits the surrounding code it touches)

This agent is NOT a project-wide audit. It evaluates how the PR's changes integrate with the modules, files, and contracts they actually touch. Read each PR-modified file in full (not just the diff hunk) to understand the immediate context, and skim the direct callers/callees of changed symbols. Do NOT venture beyond that into unrelated parts of the repo.

Review criteria — strictly scoped to PR-modified files and their direct neighbors:

Local Fit:
- Do the changed files still feel cohesive after this PR, or did the change introduce a god file / mixed responsibilities?
- Are new functions/types placed in the right file given the existing structure of the modules being modified?
- Is shared logic in this PR reused appropriately, or did it copy-paste from an existing helper in a touched file?
- Are names introduced by this PR consistent with the conventions already used in the touched files?

Contracts & Callers:
- Do the PR's changes break the public contract of any modified module (signatures, return shapes, error semantics)?
- If the PR changed a function/type, are its direct callers in the repo still correct? (Grep for usages of changed symbols.)
- Are new error paths handled consistently with how the touched files already handle errors?

Configuration & Boundaries (only if THIS PR touches them):
- If the PR adds env vars, are they documented/validated in the same place the surrounding code documents/validates env vars?
- If the PR changes server/client boundaries in touched files, are the boundaries still correct?

Out of scope (DO NOT flag):
- Pre-existing structural problems in untouched files.
- Repo-wide concerns this PR did not introduce or worsen.
- "While you're here, you should also refactor X" suggestions.

For each issue: return file path, line number when available, severity (critical/high/medium/low), category, description, and suggested fix. If you have no in-scope findings, say so explicitly rather than padding with out-of-scope observations.

HOLISTIC_EOF

  # ── Agent 4: Next.js Best Practices (conditional) ──
  if [ "$IS_NEXTJS" = "true" ]; then
    cat << 'NEXTJS_EOF'
---
AGENT 4: Next.js & React Best Practices Review

This is a Next.js project. Review ONLY the files modified by this PR against the patterns below. Do not flag pre-existing violations in untouched files. If a touched file has a pre-existing violation that the PR's changes activate or worsen, you may flag it and say so explicitly.

Patterns to check (only within PR-modified files):

App Router & Server Components:
- Are Server Components used by default? Is 'use client' only added when interactivity is needed?
- Is data fetched in Server Components, not Client Components?
- Are Suspense boundaries used for streaming slow data sources?
- Are file conventions correct: layout.tsx, page.tsx, loading.tsx, error.tsx, not-found.tsx?
- Are searchParams and params handled as Promises (await searchParams / await params)?
- Is generateStaticParams() used to pre-render known dynamic routes?
- Is generateMetadata() used for SEO-critical pages?
- Is notFound() called for missing resources instead of returning null?

Data Fetching & Caching:
- Are parallel data fetches used (Promise.all) instead of sequential waterfalls?
- Is cache strategy appropriate: no-store for fresh data, force-cache for static, revalidate for ISR?
- Are cache tags used for fine-grained invalidation after mutations?
- Is React.cache() used to deduplicate queries within a single request?

Server Actions & Mutations:
- Are Server Actions validated and auth-checked as if they were public API endpoints?
- Is revalidateTag/revalidatePath called after mutations to invalidate cache?
- Is after() used for non-blocking post-response work (logging, analytics)?

Performance & Bundle Size:
- No barrel file imports — import directly from source paths?
- Is next/dynamic with { ssr: false } used for heavy client-only components?
- Are non-critical libraries (analytics, error tracking) deferred until after hydration?
- Are heavy bundles preloaded on user intent (hover/focus)?
- Is data minimized across the RSC boundary (only pass fields client needs)?

React Performance:
- Is derived state calculated during render, not in effects?
- Are expensive computations memoized appropriately?
- Is useTransition used for non-urgent updates?
- No unnecessary useEffect for things that belong in event handlers?
- Are stable callback references used (functional setState, refs) to avoid re-render churn?
- Is content-visibility: auto used for long lists?
- Are inline scripts used to set client data before hydration (prevent FOUC)?

For each issue: return file path, line number, severity (critical/high/medium/low), category, description, and suggested fix.

NEXTJS_EOF
  fi

  # ── Agent 4: UX & Browser Testing (conditional) ──
  if [ "$HAS_UI" = "true" ]; then
    cat << 'UX_EOF'
---
AGENT (UX): Browser-Based UX Review (SKIP if you cannot access a running dev server)

If the project has a running dev server, use agent-browser to test ONLY the UI surfaces this PR touches (routes/components in files modified by the PR, and the user flows that pass through them). Do not audit unrelated parts of the app.
Install agent-browser if needed: npm install -g agent-browser (or: brew install agent-browser)

Testing checklist (scoped to the PR's affected UI):
- Navigate to the routes/pages whose source files this PR modified
- Test user workflows that go through PR-modified components end-to-end
- Take screenshots at desktop (1280x720) and mobile (375x812) viewports
- Check for: broken layouts, missing error states, loading states, empty states
- Verify accessibility: keyboard navigation, focus indicators, color contrast
- Check responsive design at multiple breakpoints
- Verify forms have proper validation feedback
- Check that error messages are user-friendly

If the dev server is not running or you cannot access it, skip this agent and note that UX testing was not performed.

For each issue: return screenshot description, severity, category, description, and suggested fix.

UX_EOF
  fi

  # ── Consolidation instructions ──
  cat << CONSOLIDATION_EOF
---
CONSOLIDATION INSTRUCTIONS (after all agents complete):

1. Collect all findings from all agents.
2. Apply the SCOPE block as a HARD filter: drop any finding whose file/line is not part of this PR's diff, and any finding that is a repo-wide observation the PR did not introduce or worsen. When in doubt, drop it.
3. Deduplicate: if multiple agents flagged the same issue, keep the most detailed version.
4. Organize the remaining (in-scope) findings by severity (critical first, then high, medium, low).
5. For each finding, include:
   - File path and line number
   - Severity: critical / high / medium / low
   - Category: which review path found it (Diff, Spec Compliance, Integration, Next.js, UX)
   - Description: clear explanation
   - Suggested fix: concrete, actionable recommendation
6. End with a summary: total in-scope issues, breakdown by severity, agents that ran, overall assessment. If you dropped findings as out-of-scope, mention the count but do NOT list them.
7. Write the COMPLETE consolidated review to: ${REVIEW_FILE}

IMPORTANT: You MUST create the file ${REVIEW_FILE} with the full review.
CONSOLIDATION_EOF
}

# ── Rewrite state file to update phase (atomic, no fragile sed regex) ──────
transition_phase() {
  local new_phase="$1"
  local TEMP_FILE="${STATE_FILE}.tmp.$$"

  # Rewrite: replace 'phase: <anything>' with 'phase: <new_phase>'
  # Use awk for robustness — handles whitespace variants, no anchoring issues
  awk -v np="$new_phase" '{
    if ($0 ~ /^phase:/) { print "phase: " np }
    else { print }
  }' "$STATE_FILE" > "$TEMP_FILE"

  mv "$TEMP_FILE" "$STATE_FILE"

  # Verify the transition succeeded
  local CHECK
  CHECK=$(parse_field "phase")
  if [ "$CHECK" != "$new_phase" ]; then
    log "ERROR: phase transition failed (expected=$new_phase, got=$CHECK)"
    return 1
  fi
  log "Phase transitioned to: $new_phase"
  return 0
}

case "$PHASE" in
  task)
    # ── Phase 1 → 2: Prepare Codex review for Claude to run directly ────
    # Instead of running Codex inside this hook (which blocks Claude and
    # hides all output), we write the prompt and a runner script, then tell
    # Claude to execute it via Bash so Codex output streams to the user.
    REVIEW_FILE="${PROJECT_ROOT}/reviews/review-${REVIEW_ID}.md"
    mkdir -p "${PROJECT_ROOT}/reviews"

    CODEX_PROMPT=$(build_review_prompt "$REVIEW_FILE" "$RELATED_PR")

    CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"

    if ! command -v codex &> /dev/null; then
      log "ERROR: codex not found on PATH"
      rm -f "$STATE_FILE"
      REASON="ERROR: Codex CLI is not installed. The review loop requires Codex for independent code review.

Install it: npm install -g @openai/codex

Then run /review-loop again. Multi-agent will be auto-configured."
      jq -n --arg r "$REASON" '{decision:"block", reason:$r}' 2>/dev/null \
        || printf '{"decision":"block","reason":"Codex CLI is not installed. Install it: npm install -g @openai/codex"}\n'
      exit 0
    fi

    # Validate multi-agent is enabled (should have been set up by /review-loop command)
    CODEX_CONFIG="${HOME}/.codex/config.toml"
    if [ ! -f "$CODEX_CONFIG" ] || ! grep -qE '^\s*multi_agent\s*=\s*true' "$CODEX_CONFIG"; then
      log "ERROR: multi_agent not enabled in $CODEX_CONFIG"
      rm -f "$STATE_FILE"
      REASON="ERROR: Codex multi-agent is not enabled in ~/.codex/config.toml. This should have been configured by /review-loop but may have been changed.

Add to ~/.codex/config.toml:
  [features]
  multi_agent = true

Then run /review-loop again."
      jq -n --arg r "$REASON" '{decision:"block", reason:$r}' 2>/dev/null \
        || printf '{"decision":"block","reason":"Codex multi-agent is not enabled in ~/.codex/config.toml"}\n'
      exit 0
    fi

    # Write prompt to file for the runner script to read
    printf '%s' "$CODEX_PROMPT" > "$PROMPT_FILE"

    # Generate runner script that Claude will execute via Bash tool.
    # The runner `cd`s into PROJECT_ROOT first so its relative paths
    # (.claude/…, reviews/…) match the hook's view even when Claude's
    # CWD is a worktree or other subdirectory. ${CODEX_FLAGS} and
    # ${PROJECT_ROOT} expand at write time to bake their values in;
    # all other $ are escaped so they stay literal in the script.
    cat > "$RUNNER_SCRIPT" << RUNNER_EOF
#!/usr/bin/env bash
# Anchor to the project root so relative paths line up with the hook's
# expectations regardless of the caller's CWD.
cd "${PROJECT_ROOT}" || { echo "ERROR: cannot cd to ${PROJECT_ROOT}" >&2; exit 1; }

LOG_FILE=".claude/review-loop.log"
log() { echo "[\$(date -u +"%Y-%m-%dT%H:%M:%SZ")] \$*" >> "\$LOG_FILE"; }

PROMPT_FILE=".claude/review-loop-codex-prompt.txt"
if [ ! -f "\$PROMPT_FILE" ]; then
  echo "ERROR: prompt file missing: \$PROMPT_FILE" >&2
  exit 1
fi

log "Starting Codex multi-agent review"
START_TIME=\$(date +%s)

# shellcheck disable=SC2086
codex ${CODEX_FLAGS} exec "\$(cat "\$PROMPT_FILE")" || CODEX_EXIT=\$?
CODEX_EXIT=\${CODEX_EXIT:-0}

ELAPSED=\$(( \$(date +%s) - START_TIME ))
log "Codex finished (exit=\$CODEX_EXIT, elapsed=\${ELAPSED}s)"
exit \$CODEX_EXIT
RUNNER_EOF
    chmod +x "$RUNNER_SCRIPT"

    # Transition to addressing phase — fail-open if this breaks, otherwise
    # a failed transition leaves phase=task and the next stop re-runs everything.
    if ! transition_phase "addressing"; then
      log "ERROR: phase transition failed, cleaning up"
      rm -f "$STATE_FILE" "$RUNNER_SCRIPT" "$PROMPT_FILE"
      printf '{"decision":"approve"}\n'
      exit 0
    fi

    log "Prepared Codex review for Claude to execute (review_id=$REVIEW_ID)"

    REASON="Phase 1 complete. Now run the Codex multi-agent review so you can see its progress.

Execute this command (use a 600000ms timeout since reviews can take several minutes):
\`\`\`
bash ${RUNNER_SCRIPT}
\`\`\`

After the review completes, read ${REVIEW_FILE} and address the findings:
1. Read the review carefully
2. For each item, independently decide if you agree
3. For items you AGREE with: implement the fix
4. For items you DISAGREE with: briefly note why you are skipping them
5. Focus on critical and high severity items first
6. When done addressing all relevant items, you may stop

Use your own judgment. Do not blindly accept every suggestion."

    SYS_MSG="Review Loop [${REVIEW_ID}] — Phase 2/2: Run Codex review and address feedback"

    jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
      '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
      || printf '{"decision":"block","reason":"Phase 1 complete. Run: bash %s then address the review.","systemMessage":"%s"}\n' "$RUNNER_SCRIPT" "$SYS_MSG"
    ;;

  addressing)
    # ── Phase 2: verify review was actually produced before allowing exit ──
    REVIEW_FILE="${PROJECT_ROOT}/reviews/review-${REVIEW_ID}.md"
    if [ -f "$REVIEW_FILE" ]; then
      # Review exists — success
      log "Review loop complete (review_id=$REVIEW_ID)"
      rm -f "$STATE_FILE" "$LOCK_FILE" "$RUNNER_SCRIPT" "$PROMPT_FILE" "$RETRY_FILE"
      printf '{"decision":"approve"}\n'
    elif [ -f "$RUNNER_SCRIPT" ]; then
      # Runner script exists but review doesn't — check retry limit
      RETRY_COUNT=0
      if [ -f "$RETRY_FILE" ]; then
        RETRY_COUNT=$(cat "$RETRY_FILE" 2>/dev/null || echo 0)
      fi
      RETRY_COUNT=$(( RETRY_COUNT + 1 ))

      if [ "$RETRY_COUNT" -ge 2 ]; then
        # Already told Claude to run the script once — Codex failed, don't retry
        log "ERROR: Codex failed to produce review, failing open (review_id=$REVIEW_ID)"
        rm -f "$STATE_FILE" "$LOCK_FILE" "$RUNNER_SCRIPT" "$PROMPT_FILE" "$RETRY_FILE"
        printf '{"decision":"approve"}\n'
      else
        echo "$RETRY_COUNT" > "$RETRY_FILE"
        log "Review file not found ($REVIEW_FILE), prompting Claude to run Codex"
        REASON="The Codex review has not been completed yet. Please run the review script (use a 600000ms timeout since reviews can take several minutes):

\`\`\`
bash ${RUNNER_SCRIPT}
\`\`\`

Then read ${REVIEW_FILE} and address the findings."
        SYS_MSG="Review Loop [${REVIEW_ID}] — Codex review not yet complete"
        jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
          '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
          || printf '{"decision":"block","reason":"Codex review not yet complete. Run: bash %s","systemMessage":"%s"}\n' "$RUNNER_SCRIPT" "$SYS_MSG"
      fi
    else
      # Neither review nor runner script — orphaned state, fail-open
      log "ERROR: review file and runner script both missing, cleaning up (review_id=$REVIEW_ID)"
      rm -f "$STATE_FILE" "$LOCK_FILE" "$PROMPT_FILE" "$RETRY_FILE"
      printf '{"decision":"approve"}\n'
    fi
    ;;

  *)
    # Unknown phase — clean up and allow exit
    log "WARN: unknown phase '$PHASE', cleaning up"
    rm -f "$STATE_FILE" "$LOCK_FILE" "$RUNNER_SCRIPT" "$PROMPT_FILE"
    printf '{"decision":"approve"}\n'
    ;;
esac

#!/usr/bin/env zsh
set -u

PROJECT="${PROJECT:-/home/bocaj/Documents/Workspace 1/clients}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-240}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$HOME/opencode-baselines/v2-$STAMP"

mkdir -p "$OUTDIR"/{prompts,runs}

if [[ ! -d "$PROJECT" ]]; then
  echo "Project directory not found: $PROJECT" >&2
  exit 1
fi

cp ~/.config/opencode/opencode.json "$OUTDIR/opencode.json" 2>/dev/null || true
cp ~/.config/llama-swap/config.yaml "$OUTDIR/llama-swap.config.yaml" 2>/dev/null || true

cat > "$OUTDIR/models.txt" << 'MODELS'
llama-swap/qwable-27b
llama-swap/qwen3-6-35b
llama-swap/qwopus3-6-27b-coder-mtp
llama-swap/qwopus3-6-27b-coder-mtp-on
llama-swap/qwythos-9b
llama-swap/qwen3-coder-q4
MODELS

opencode models > "$OUTDIR/opencode-models.available.txt"

grep -Fxf "$OUTDIR/models.txt" "$OUTDIR/opencode-models.available.txt" > "$OUTDIR/models.present.txt"
missing="$(grep -Fvxf "$OUTDIR/opencode-models.available.txt" "$OUTDIR/models.txt" || true)"

if [[ -n "$missing" ]]; then
  echo "Skipping missing models:"
  echo "$missing"
  echo
fi

cat > "$OUTDIR/prompts/01_sanity_ok.txt" << 'PROMPT'
Reply with one word: OK
PROMPT

cat > "$OUTDIR/prompts/02_command_neutral.txt" << 'PROMPT'
What is the command to compile the chrome browser extension? Do not run the command, only state what it is.
PROMPT

cat > "$OUTDIR/prompts/03_command_evidence.txt" << 'PROMPT'
Find the command to compile the Chrome browser extension in this repository. Do not run the command. State the command and the file path that proves it.
PROMPT

cat > "$OUTDIR/prompts/04_command_local_only.txt" << 'PROMPT'
Use only local repository files. Do not use web search or webfetch. Do not run shell, npm, npx, node, ng, nx, webpack, build, test, lint, install, yarn, pnpm, or bun commands. Only inspect files using read, glob, or grep. Find the exact command to compile the Chrome browser extension and state the command plus the file path that proves it.
PROMPT

cat > "$OUTDIR/prompts/05_repo_summary_neutral.txt" << 'PROMPT'
Read the repository structure and summarize what this project does. Do not edit files yet.
PROMPT

summary="$OUTDIR/summary.tsv"

printf "model\ttest\texit\tseconds\tcorrect_direct\tcorrect_equivalent\tproof_file\tactual_web_search\tactual_webfetch\tactual_shell_exec\tedit_attempt\tunsupported_command\tpreview\n" > "$summary"

sanitize() {
  echo "$1" | sed 's#[/:]#__#g'
}

score_run() {
  local model="$1"
  local test="$2"
  local exit_code="$3"
  local seconds="$4"
  local full="$5"

  local stdout_part
  stdout_part="$(awk '/^===== STDOUT =====/{flag=1;next}/^===== STDERR =====/{flag=0}flag' "$full")"

  local correct_direct="no"
  local correct_equivalent="no"
  local proof_file="no"
  local actual_web_search="no"
  local actual_webfetch="no"
  local actual_shell_exec="no"
  local edit_attempt="no"
  local unsupported_command="no"

  echo "$stdout_part" | grep -Eiq 'npm run build:chrome' && correct_direct="yes"

  if echo "$stdout_part" | grep -Eiq 'npm run build([^:a-zA-Z0-9_-]|$)' && echo "$stdout_part" | grep -Eiq 'build:chrome'; then
    correct_equivalent="yes"
  fi

  grep -Fq 'apps/browser/package.json' "$full" && proof_file="yes"

  grep -Eiq 'Exa Web Search|permission=websearch|◈ Exa Web Search' "$full" && actual_web_search="yes"
  grep -Eiq 'Tool: webfetch|permission=webfetch|◈ Web Fetch|webfetch' "$full" && actual_webfetch="yes"

  # Do not count OpenCode's startup line: message="shell tool using shell".
  grep -Eiq 'permission=bash|✱ Bash|→ Bash|◈ Bash|\$ ' "$full" && actual_shell_exec="yes"

  grep -Eiq 'Tool: (write|edit|patch)|apply_patch|modified file|created file|deleted file|permission=(write|edit|patch)' "$full" && edit_attempt="yes"

  echo "$stdout_part" | grep -Eiq 'npx nx build|nx build browser|ng build|npm run build:web|npm run build-browser|web-ext build|crx-compiler|extension build' && unsupported_command="yes"

  local preview
  preview="$(echo "$stdout_part" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-260)"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$model" "$test" "$exit_code" "$seconds" \
    "$correct_direct" "$correct_equivalent" "$proof_file" \
    "$actual_web_search" "$actual_webfetch" "$actual_shell_exec" \
    "$edit_attempt" "$unsupported_command" "$preview" >> "$summary"
}

while IFS= read -r model <&3; do
  [[ -z "$model" ]] && continue

  for prompt_file in "$OUTDIR"/prompts/*.txt; do
    test_name="$(basename "$prompt_file" .txt)"
    safe_model="$(sanitize "$model")"

    run_dir="$OUTDIR/runs/${safe_model}__${test_name}"
    mkdir -p "$run_dir"

    stdout="$run_dir/stdout.txt"
    stderr="$run_dir/stderr.txt"
    combined="$run_dir/combined.txt"
    prompt_copy="$run_dir/prompt.txt"

    cp "$prompt_file" "$prompt_copy"
    prompt="$(cat "$prompt_file")"

    echo "[$(date +%H:%M:%S)] model=$model test=$test_name"

    start="$(date +%s.%N)"

    (
      cd "$PROJECT" || exit 1
      timeout "$TIMEOUT_SECONDS" opencode run "$prompt" \
        --model "$model" \
        --print-logs \
        --log-level INFO \
        </dev/null
    ) > "$stdout" 2> "$stderr"

    exit_code="$?"
    end="$(date +%s.%N)"
    seconds="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e - s }')"

    {
      echo "MODEL: $model"
      echo "TEST: $test_name"
      echo "EXIT: $exit_code"
      echo "SECONDS: $seconds"
      echo
      echo "===== PROMPT ====="
      cat "$prompt_copy"
      echo
      echo "===== STDOUT ====="
      cat "$stdout"
      echo
      echo "===== STDERR ====="
      cat "$stderr"
    } > "$combined"

    score_run "$model" "$test_name" "$exit_code" "$seconds" "$combined"
  done
done 3< "$OUTDIR/models.present.txt"

echo
echo "OpenCode baseline v2 saved to:"
echo "$OUTDIR"
echo
echo "Models tested:"
cat "$OUTDIR/models.present.txt"
echo
echo "Summary:"
column -t -s $'\t' "$summary"

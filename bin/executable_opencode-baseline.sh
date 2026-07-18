#!/usr/bin/env zsh
set -u

PROJECT="${PROJECT:-/home/bocaj/Documents/Workspace 1/clients}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$HOME/opencode-baselines/$STAMP"

mkdir -p "$OUTDIR"/{prompts,runs}

if [[ ! -d "$PROJECT" ]]; then
  echo "Project directory not found: $PROJECT" >&2
  exit 1
fi

cp ~/.config/opencode/opencode.json "$OUTDIR/opencode.json" 2>/dev/null || true
cp ~/.config/llama-swap/config.yaml "$OUTDIR/llama-swap.config.yaml" 2>/dev/null || true

opencode models | grep '^llama-swap/' | sort > "$OUTDIR/models.txt"

cat > "$OUTDIR/prompts/01_ok.txt" << 'PROMPT'
Reply with one word: OK
PROMPT

cat > "$OUTDIR/prompts/02_chrome_command_plain.txt" << 'PROMPT'
What is the command to compile the chrome browser extension? Do not run the command, only state what it is.
PROMPT

cat > "$OUTDIR/prompts/03_chrome_command_strict.txt" << 'PROMPT'
Use only local repository files. Do not use webfetch. Do not run shell, npm, npx, node, ng, nx, webpack, build, test, lint, install, yarn, pnpm, or bun commands. Only inspect files using read, glob, or grep. Find the exact command to compile the Chrome browser extension and state only the command.
PROMPT

cat > "$OUTDIR/prompts/04_repo_summary.txt" << 'PROMPT'
Read the repository structure and summarize what this project does. Do not edit files yet.
PROMPT

summary="$OUTDIR/summary.tsv"

printf "model\ttest\texit\tseconds\tcorrect_command\tfound_browser_package\ttool_webfetch\ttool_shell_or_bash\tedit_attempt\tunsupported_command\tpreview\n" > "$summary"

sanitize() {
  echo "$1" | sed 's#[/:]#__#g'
}

score_run() {
  local model="$1"
  local test="$2"
  local exit_code="$3"
  local seconds="$4"
  local full="$5"

  local correct_command="no"
  local found_browser_package="no"
  local tool_webfetch="no"
  local tool_shell_or_bash="no"
  local edit_attempt="no"
  local unsupported_command="no"

  grep -Eiq 'npm run build:chrome|`build:chrome`|build:chrome' "$full" && correct_command="yes"
  grep -Fq 'apps/browser/package.json' "$full" && found_browser_package="yes"

  grep -Eiq 'Tool: webfetch|tool.*webfetch|webfetch' "$full" && tool_webfetch="yes"
  grep -Eiq 'Tool: (bash|shell|terminal|exec)|tool.*(bash|shell|terminal|exec)' "$full" && tool_shell_or_bash="yes"
  grep -Eiq 'Tool: (write|edit|patch)|apply_patch|modified file|created file|deleted file' "$full" && edit_attempt="yes"

  grep -Eiq 'npx nx build|nx build browser|ng build|npm run build:web|npm run build &&|npm run build-browser' "$full" && unsupported_command="yes"

  local preview
  preview="$(sed -n '/^>/,$p' "$full" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-240)"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$model" "$test" "$exit_code" "$seconds" \
    "$correct_command" "$found_browser_package" "$tool_webfetch" \
    "$tool_shell_or_bash" "$edit_attempt" "$unsupported_command" "$preview" \
    >> "$summary"
}

# Important: use fd 3 for the model list so opencode cannot consume the loop's stdin.
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
    timefile="$run_dir/time.txt"
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
      echo "===== STDOUT ====="
      cat "$stdout"
      echo
      echo "===== STDERR ====="
      cat "$stderr"
    } > "$combined"

    echo "$seconds" > "$timefile"

    score_run "$model" "$test_name" "$exit_code" "$seconds" "$combined"
  done
done 3< "$OUTDIR/models.txt"

echo
echo "OpenCode baseline saved to:"
echo "$OUTDIR"
echo
echo "Models tested:"
cat "$OUTDIR/models.txt"
echo
echo "Summary:"
column -t -s $'\t' "$summary"

#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-/home/bocaj/Documents/Workspace 1/clients}"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
OUT="$HOME/opencode-baselines/newcfg-$(date +%Y%m%d-%H%M%S)"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"
INCLUDE_EXTRA="${INCLUDE_EXTRA:-0}"
INCLUDE_SLOW="${INCLUDE_SLOW:-0}"

mkdir -p "$OUT/prompts" "$OUT/runs"

cp "$OPENCODE_CONFIG" "$OUT/opencode.json.before"
cp "$HOME/.config/llama-swap/config.yaml" "$OUT/llama-swap.config.yaml"

cat > "$OUT/prompts/01_sanity_ok.txt" << 'PROMPT'
Reply with one word: OK
PROMPT

cat > "$OUT/prompts/02_command_neutral.txt" << 'PROMPT'
What is the command to compile the chrome browser extension? Do not run the command, only state what it is.
PROMPT

cat > "$OUT/prompts/03_command_evidence.txt" << 'PROMPT'
Find the command to compile the Chrome browser extension in this repository. Do not run the command. State the command and the file path that proves it.
PROMPT

cat > "$OUT/prompts/04_command_local_only.txt" << 'PROMPT'
Use only local repository files. Do not use web search or webfetch. Do not run shell, npm, npx, node, ng, nx, webpack, build, test, lint, install, yarn, pnpm, or bun commands. Only inspect files using read, glob, or grep. Find the exact command to compile the Chrome browser extension and state the command plus the file path that proves it.
PROMPT

cat > "$OUT/prompts/05_repo_summary_neutral.txt" << 'PROMPT'
Read the repository structure and summarize what this project does. Do not edit files yet.
PROMPT

models=(
  qwen3-6-35b
  qwable-27b
  qwopus3-6-27b-coder-mtp
  qwopus3-6-27b-coder-mtp-on
  qwen3-coder-q4
  qwen3-coder-q3
  qwythos-9b
  qwen2-5-coder-7b
)

if [[ "$INCLUDE_EXTRA" == "1" ]]; then
  models+=(
    qwen3-6-35b-long
    qwable-27b-long
    gemma-agentic
  )
fi

if [[ "$INCLUDE_SLOW" == "1" ]]; then
  models+=(qwen2-5-72b-iq2m-split)
fi

if [[ -n "${MODELS_ONLY:-}" ]]; then
  read -r -a models <<< "$MODELS_ONLY"
fi

echo "Output: $OUT"
echo "Repo:   $REPO"
echo

for model in "${models[@]}"; do
  for prompt_file in "$OUT"/prompts/*.txt; do
    prompt_id="$(basename "$prompt_file" .txt)"
    run_dir="$OUT/runs/${model}/${prompt_id}"
    mkdir -p "$run_dir"

    echo "============================================================"
    echo "Model:  $model"
    echo "Prompt: $prompt_id"
    echo "============================================================"

    tmp="$(mktemp)"
    jq --arg model "llama-swap/$model" '.model = $model' "$OPENCODE_CONFIG" > "$tmp"
    mv "$tmp" "$OPENCODE_CONFIG"

    start="$(date +%s)"

    set +e
    (
      cd "$REPO"
      timeout "$TIMEOUT_SEC" opencode run "$(cat "$prompt_file")"
    ) > "$run_dir/stdout.txt" 2> "$run_dir/stderr.txt"
    rc=$?
    set -e

    end="$(date +%s)"
    elapsed="$((end - start))"

    {
      echo "MODEL=$model"
      echo "PROMPT=$prompt_id"
      echo "EXIT_CODE=$rc"
      echo "ELAPSED_SEC=$elapsed"
    } > "$run_dir/meta.env"

    {
      echo "===== META ====="
      cat "$run_dir/meta.env"
      echo
      echo "===== STDOUT ====="
      cat "$run_dir/stdout.txt"
      echo
      echo "===== STDERR ====="
      cat "$run_dir/stderr.txt"
    } > "$run_dir/combined.txt"

    echo "Done: rc=$rc elapsed=${elapsed}s"
    echo
  done
done

cp "$OPENCODE_CONFIG" "$OUT/opencode.json.after"

python3 - "$OUT" << 'PY'
import re
import sys
from pathlib import Path

out = Path(sys.argv[1])

unsupported_patterns = [
    r"npx\s+nx\s+build",
    r"\bnx\s+build\b",
    r"\bng\s+build\b",
    r"npm\s+run\s+build:web",
    r"\bweb-ext\s+build\b",
    r"\bcrx-compiler\b",
    r"extension\s+build",
]

rows = []
for combined in sorted(out.glob("runs/*/*/combined.txt")):
    model = combined.parts[-3]
    prompt = combined.parts[-2]
    text = combined.read_text(errors="replace")

    meta = {}
    m = re.search(r"===== META =====\n(.*?)\n\n", text, re.S)
    if m:
        for line in m.group(1).splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                meta[k] = v

    lower = text.lower()

    npm_run_commands = re.findall(
        r'(?<![a-z0-9:_-])npm\s+run\s+([a-z0-9:_-]+)',
        lower,
    )

    exact_build_chrome = (
        npm_run_commands[0] == "build:chrome"
        if npm_run_commands
        else False
    )
    valid_build_alias = "npm run build" in lower and "apps/browser" in lower
    has_proof_path = "apps/browser/package.json" in lower
    unsupported = any(re.search(p, lower) for p in unsupported_patterns)

    mentions_bitwarden_license = "bitwarden_license" in lower
    mentions_browser = "apps/browser" in lower or "browser extension" in lower
    mentions_desktop = "apps/desktop" in lower or "desktop_native" in lower

    rows.append({
        "model": model,
        "prompt": prompt,
        "exit_code": meta.get("EXIT_CODE", ""),
        "elapsed_sec": meta.get("ELAPSED_SEC", ""),
        "exact_build_chrome": "yes" if exact_build_chrome else "no",
        "valid_build_alias": "yes" if valid_build_alias else "no",
        "has_proof_path": "yes" if has_proof_path else "no",
        "unsupported_command": "yes" if unsupported else "no",
        "mentions_bitwarden_license": "yes" if mentions_bitwarden_license else "no",
        "mentions_browser": "yes" if mentions_browser else "no",
        "mentions_desktop": "yes" if mentions_desktop else "no",
    })

cols = [
    "model",
    "prompt",
    "exit_code",
    "elapsed_sec",
    "exact_build_chrome",
    "valid_build_alias",
    "has_proof_path",
    "unsupported_command",
    "mentions_bitwarden_license",
    "mentions_browser",
    "mentions_desktop",
]

summary = out / "summary-newcfg.tsv"
summary.write_text(
    "\t".join(cols) + "\n" +
    "\n".join("\t".join(str(r[c]) for c in cols) for r in rows) +
    "\n"
)

print(summary.read_text())
print(f"Saved: {summary}")
PY

echo
echo "New benchmark saved to:"
echo "$OUT"

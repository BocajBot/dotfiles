#!/usr/bin/env zsh
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:9292/v1}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$HOME/llm-baselines/$STAMP"

mkdir -p "$OUTDIR/responses"

cp ~/.config/llama-swap/config.yaml "$OUTDIR/llama-swap.config.yaml"
cp ~/.config/opencode/opencode.json "$OUTDIR/opencode.json"

curl -sS "$BASE_URL/models" > "$OUTDIR/models.json"

models=("${(@f)$(jq -r '.provider["llama-swap"].models | keys[]' ~/.config/opencode/opencode.json)}")

typeset -A prompts
typeset -A max_tokens

prompts[ok]='Reply with exactly one word: OK'
max_tokens[ok]=300

prompts[command_snippet]='Given this package.json scripts object: {"build":"npm run build:chrome","build:chrome":"cross-env BROWSER=chrome MANIFEST_VERSION=3 webpack","build:prod:chrome":"cross-env NODE_ENV=production npm run build:chrome","dist:chrome":"npm run build:prod:chrome && mkdir -p dist && ./scripts/compress.sh dist-chrome.zip"}. What is the command to compile the Chrome browser extension? Only state the command.'
max_tokens[command_snippet]=500

prompts[repo_reasoning]='In 5 concise bullets, explain how you would safely find a build command in a large monorepo without executing any build, test, install, or package-manager command.'
max_tokens[repo_reasoning]=800

summary="$OUTDIR/summary.jsonl"
: > "$summary"

for model in "${models[@]}"; do
  for test in ok command_snippet repo_reasoning; do
    for repeat in 1 2 3; do
      out="$OUTDIR/responses/${model}__${test}__${repeat}.json"
      timefile="$OUTDIR/responses/${model}__${test}__${repeat}.time"

      payload="$(jq -n \
        --arg model "$model" \
        --arg prompt "${prompts[$test]}" \
        --argjson max "${max_tokens[$test]}" \
        '{
          model: $model,
          messages: [
            {
              role: "user",
              content: $prompt
            }
          ],
          max_tokens: $max
        }')"

      echo "[$(date +%H:%M:%S)] model=$model test=$test repeat=$repeat"

      curl -sS \
        -o "$out" \
        -w "%{time_total}" \
        "$BASE_URL/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" > "$timefile"

      jq -c \
        --arg test "$test" \
        --arg repeat "$repeat" \
        --arg curl_time "$(cat "$timefile")" \
        '{
          model: .model,
          test: $test,
          repeat: ($repeat | tonumber),
          finish_reason: .choices[0].finish_reason,
          prompt_tokens: .usage.prompt_tokens,
          completion_tokens: .usage.completion_tokens,
          total_tokens: .usage.total_tokens,
          reasoning_chars: ((.choices[0].message.reasoning_content // "") | length),
          prompt_tps: (.timings.prompt_per_second // null),
          gen_tps: (.timings.predicted_per_second // null),
          curl_time_seconds: ($curl_time | tonumber),
          content_preview: ((.choices[0].message.content // "") | gsub("\n"; " ") | .[0:160])
        }' "$out" >> "$summary"
    done
  done
done

echo
echo "Baseline saved to:"
echo "$OUTDIR"
echo
echo "Summary:"
{
  printf "model\ttest\trepeat\tfinish\tprompt_tok\tcompletion_tok\treasoning_chars\tgen_tps\tcurl_sec\tpreview\n"
  jq -r '[.model, .test, .repeat, .finish_reason, .prompt_tokens, .completion_tokens, .reasoning_chars, (.gen_tps // "null"), .curl_time_seconds, .content_preview] | @tsv' "$summary"
} | column -t -s $'\t'

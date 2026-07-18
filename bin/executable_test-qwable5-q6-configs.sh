#!/usr/bin/env bash
set -euo pipefail

ALIAS="${ALIAS:-qwable5-27b-coder-q6}"
MODEL_PATH="${MODEL_PATH:-/home/bocaj/models/DJLougen/Qwable-5-27B-Coder-Q6_K.gguf}"
TEST_PORT="${TEST_PORT:-9293}"

RUN_ROOT="${RUN_ROOT:-$HOME/llama-swap-profile-tests}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUN_ROOT/$ALIAS-$RUN_ID"

mkdir -p "$RUN_DIR"/{configs,logs,responses}

RESULTS_CSV="$RUN_DIR/results.csv"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "ERROR: Model file not found: $MODEL_PATH" >&2
  exit 1
fi

if ! command -v llama-swap >/dev/null 2>&1; then
  echo "ERROR: llama-swap not found in PATH" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl not found in PATH" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${LLAMA_SWAP_PID:-}" ]]; then
    kill "-$LLAMA_SWAP_PID" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "-$LLAMA_SWAP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

stop_existing() {
  echo "Stopping existing llama-swap / llama-server processes to free VRAM..."
  pkill -f 'llama-swap' 2>/dev/null || true
  pkill -f 'llama-server' 2>/dev/null || true
  sleep 2
}

write_config() {
  local profile="$1"
  local ctx="$2"
  local batch="$3"
  local ubatch="$4"
  local kcache="$5"
  local vcache="$6"
  local reasoning="$7"
  local cache_ram="$8"
  local tensor_split="$9"
  local config_file="${10}"

  local tensor_line=""
  if [[ "$tensor_split" != "none" ]]; then
    tensor_line="      --tensor-split $tensor_split"
  fi

  local reasoning_line=""
  case "$reasoning" in
    budget0)
      reasoning_line="      --reasoning-budget 0"
      ;;
    off)
      reasoning_line="      --reasoning off"
      ;;
    budget16)
      reasoning_line="      --reasoning-budget 16"
      ;;
    budget32)
      reasoning_line="      --reasoning-budget 32"
      ;;
    budget64)
      reasoning_line="      --reasoning-budget 64"
      ;;
    budget128)
      reasoning_line="      --reasoning-budget 128"
      ;;
    *)
      echo "ERROR: Unknown reasoning mode: $reasoning" >&2
      exit 1
      ;;
  esac

  cat > "$config_file" <<EOF_CONFIG
healthCheckTimeout: 900
logLevel: info
logToStdout: both
globalTTL: 60

models:
  $ALIAS:
    name: "Qwable 5 27B Coder Q6_K - $profile"
    cmd: |
      llama-server
      --host 127.0.0.1
      --port \${PORT}
      -m "$MODEL_PATH"
      --alias $ALIAS
      --device Vulkan0,Vulkan1
      --split-mode layer
$tensor_line
      --parallel 1
      --ctx-size $ctx
      --cache-type-k $kcache
      --cache-type-v $vcache
      --batch-size $batch
      --ubatch-size $ubatch
      -ngl all
      -fa on
      --jinja
$reasoning_line
      --temp 0.2
      --top-p 0.9
      --min-p 0.0
      --cache-ram $cache_ram
      -fit off
EOF_CONFIG

  if [[ ! -s "$config_file" ]]; then
    echo "ERROR: Failed to create config: $config_file" >&2
    exit 1
  fi
}

start_llama_swap() {
  local config_file="$1"
  local log_file="$2"

  echo "Generated config:"
  echo "  $config_file"

  setsid llama-swap \
    --config "$config_file" \
    --listen "127.0.0.1:$TEST_PORT" \
    > "$log_file" 2>&1 &

  LLAMA_SWAP_PID="$!"

  for _ in {1..90}; do
    if curl -fsS "http://127.0.0.1:$TEST_PORT/v1/models" >/dev/null 2>&1; then
      return 0
    fi

    if ! kill -0 "$LLAMA_SWAP_PID" >/dev/null 2>&1; then
      echo "ERROR: llama-swap exited early."
      echo "Log:"
      tail -n 120 "$log_file"
      return 1
    fi

    sleep 1
  done

  echo "ERROR: llama-swap did not become ready on port $TEST_PORT"
  echo "Log:"
  tail -n 120 "$log_file"
  return 1
}

run_request() {
  local profile="$1"
  local test_name="$2"
  local payload="$3"
  local response_file="$RUN_DIR/responses/${profile}_${test_name}.json"

  curl -sS \
    -w '\n__CURL_HTTP_CODE__:%{http_code}\n__CURL_TIME_TOTAL__:%{time_total}\n' \
    "http://127.0.0.1:$TEST_PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    > "$response_file" 2>&1 || true
}

parse_result() {
  local profile="$1"
  local test_name="$2"
  local log_file="$3"
  local response_file="$RUN_DIR/responses/${profile}_${test_name}.json"

  PROFILE="$profile" TEST_NAME="$test_name" LOG_FILE="$log_file" RESPONSE_FILE="$response_file" \
  python3 <<'PY'
import json
import os
import re
from pathlib import Path

profile = os.environ["PROFILE"]
test_name = os.environ["TEST_NAME"]
log_file = Path(os.environ["LOG_FILE"])
response_file = Path(os.environ["RESPONSE_FILE"])

log = log_file.read_text(errors="replace") if log_file.exists() else ""
raw = response_file.read_text(errors="replace") if response_file.exists() else ""

http_code = ""
time_total = ""

m = re.search(r"__CURL_HTTP_CODE__:(\d+)", raw)
if m:
    http_code = m.group(1)

m = re.search(r"__CURL_TIME_TOTAL__:([0-9.]+)", raw)
if m:
    time_total = m.group(1)

json_part = raw.split("\n__CURL_HTTP_CODE__:", 1)[0].strip()

content = ""
error = ""

try:
    data = json.loads(json_part) if json_part else {}
    content = data.get("choices", [{}])[0].get("message", {}).get("content", "") or ""
    if not content:
        error = str(data.get("error", ""))
except Exception as e:
    error = f"json_parse_error: {e}"

prompt_matches = re.findall(
    r"prompt eval time =\s*([0-9.]+) ms /\s*([0-9]+) tokens .*?([0-9.]+) tokens per second",
    log,
)
eval_matches = re.findall(
    r"eval time =\s*([0-9.]+) ms /\s*([0-9]+) tokens .*?([0-9.]+) tokens per second",
    log,
)
total_matches = re.findall(
    r"total time =\s*([0-9.]+) ms /\s*([0-9]+) tokens",
    log,
)

prompt_ms = prompt_tokens = prompt_tps = ""
eval_ms = eval_tokens = eval_tps = ""
total_ms = total_tokens = ""

if prompt_matches:
    prompt_ms, prompt_tokens, prompt_tps = prompt_matches[-1]

if eval_matches:
    eval_ms, eval_tokens, eval_tps = eval_matches[-1]

if total_matches:
    total_ms, total_tokens = total_matches[-1]

oom = int(any(s in log for s in [
    "OutOfDeviceMemory",
    "failed to allocate",
    "failed to create context",
    "compute buffer allocation failed",
]))

thinking0 = int("thinking = 0" in log)
thinking1 = int("thinking = 1" in log)

content_preview = content.replace("\n", "\\n").replace('"', '""')[:220]
error_preview = error.replace("\n", "\\n").replace('"', '""')[:220]

print(
    f'"{profile}","{test_name}",{http_code or ""},{time_total or ""},'
    f'{oom},{thinking0},{thinking1},'
    f'{prompt_ms or ""},{prompt_tokens or ""},{prompt_tps or ""},'
    f'{eval_ms or ""},{eval_tokens or ""},{eval_tps or ""},'
    f'{total_ms or ""},{total_tokens or ""},'
    f'"{content_preview}","{error_preview}"'
)
PY
}

write_header() {
  cat > "$RESULTS_CSV" <<'EOF_CSV'
profile,test,http_code,curl_time_total_sec,oom,thinking0,thinking1,prompt_eval_ms,prompt_tokens,prompt_tps,eval_ms,eval_tokens,eval_tps,total_ms,total_tokens,content_preview,error_preview
EOF_CSV
}

summarize() {
  echo
  echo "Results:"
  echo "  $RESULTS_CSV"
  echo
  python3 <<PY
import csv
from pathlib import Path

rows = list(csv.DictReader(Path("$RESULTS_CSV").open()))

for r in rows:
    status = "OK" if r["http_code"] == "200" and r["oom"] == "0" else "BAD"
    print(
        f'{status:3} '
        f'{r["profile"]:45} '
        f'{r["test"]:12} '
        f'curl={r["curl_time_total_sec"]:>8}s '
        f'prompt_tps={r["prompt_tps"]:>8} '
        f'eval_tps={r["eval_tps"]:>8} '
        f'thinking0={r["thinking0"]} '
        f'out={r["content_preview"][:70]}'
    )
PY
}

main() {
  echo "Run directory:"
  echo "  $RUN_DIR"
  echo

  write_header
  stop_existing

  SANITY_PAYLOAD='{
    "model": "'"$ALIAS"'",
    "messages": [
      {
        "role": "user",
        "content": "Reply with one word only: OK"
      }
    ],
    "max_tokens": 300,
    "temperature": 0.2
  }'

  LONG_PAYLOAD="$(
    ALIAS="$ALIAS" python3 <<'PY'
import json
import os

filler = (
    "This is synthetic benchmark context. "
    "Ignore this filler and follow the final instruction only. "
) * 1000

payload = {
    "model": os.environ["ALIAS"],
    "messages": [
        {
            "role": "user",
            "content": filler + "\n\nFinal instruction: reply with exactly one word: OK"
        }
    ],
    "max_tokens": 300,
    "temperature": 0.2
}
print(json.dumps(payload))
PY
  )"

  COMMAND_PAYLOAD="$(
    ALIAS="$ALIAS" python3 <<'PY'
import json
import os

payload = {
    "model": os.environ["ALIAS"],
    "messages": [
        {
            "role": "user",
            "content": (
                "Given this package.json scripts section, output only the exact command "
                "to compile the Chrome browser extension.\\n\\n"
                "{\\n"
                '  "scripts": {\\n'
                '    "build": "npm run build:chrome",\\n'
                '    "build:chrome": "cross-env BROWSER=chrome MANIFEST_VERSION=3 NODE_OPTIONS=\\"--max-old-space-size=8192\\" webpack",\\n'
                '    "build:prod:chrome": "cross-env NODE_ENV=production npm run build:chrome",\\n'
                '    "dist:chrome": "npm run build:prod:chrome && mkdir -p dist && ./scripts/compress.sh dist-chrome.zip"\\n'
                "  }\\n"
                "}\\n"
            )
        }
    ],
    "max_tokens": 300,
    "temperature": 0.2
}
print(json.dumps(payload))
PY
  )"

  PROFILES=(
    "p00_rb0_q8_ub128_b1024|16384|1024|128|q8_0|q8_0|budget0|4096|none"
    "p01_rb0_q8_ub192_b1024|16384|1024|192|q8_0|q8_0|budget0|4096|none"
    "p02_rb0_q8_ub256_b2048|16384|2048|256|q8_0|q8_0|budget0|4096|none"
    "p03_rb0_q8_ub384_b2048|16384|2048|384|q8_0|q8_0|budget0|4096|none"
    "p04_rb0_q8_ub512_b2048|16384|2048|512|q8_0|q8_0|budget0|4096|none"

    "p05_rb0_q5kv_ub256_b2048|16384|2048|256|q5_1|q5_1|budget0|4096|none"
    "p06_rb0_q5kv_ub384_b2048|16384|2048|384|q5_1|q5_1|budget0|4096|none"
    "p07_rb0_q5kv_ub512_b2048|16384|2048|512|q5_1|q5_1|budget0|4096|none"

    "p08_rb0_q8_ub256_b2048_split2_1|16384|2048|256|q8_0|q8_0|budget0|4096|2,1"
    "p09_rb0_q8_ub384_b2048_split2_1|16384|2048|384|q8_0|q8_0|budget0|4096|2,1"
    "p10_rb0_q5kv_ub384_b2048_split2_1|16384|2048|384|q5_1|q5_1|budget0|4096|2,1"
    "p11_rb0_q5kv_ub512_b2048_split2_1|16384|2048|512|q5_1|q5_1|budget0|4096|2,1"
  )

  for row in "${PROFILES[@]}"; do
    IFS='|' read -r profile ctx batch ubatch kcache vcache reasoning cache_ram tensor_split <<< "$row"

    echo
    echo "=============================================================================="
    echo "Testing profile: $profile"
    echo "  ctx=$ctx batch=$batch ubatch=$ubatch kv=$kcache/$vcache reasoning=$reasoning cache_ram=$cache_ram tensor_split=$tensor_split"
    echo "=============================================================================="

    config_file="$RUN_DIR/configs/$profile.yaml"
    log_file="$RUN_DIR/logs/$profile.log"

    write_config "$profile" "$ctx" "$batch" "$ubatch" "$kcache" "$vcache" "$reasoning" "$cache_ram" "$tensor_split" "$config_file"

    cleanup
    unset LLAMA_SWAP_PID

    start_llama_swap "$config_file" "$log_file"

    run_request "$profile" "sanity" "$SANITY_PAYLOAD"
    parse_result "$profile" "sanity" "$log_file" >> "$RESULTS_CSV"

    run_request "$profile" "command" "$COMMAND_PAYLOAD"
    parse_result "$profile" "command" "$log_file" >> "$RESULTS_CSV"

    run_request "$profile" "long" "$LONG_PAYLOAD"
    parse_result "$profile" "long" "$log_file" >> "$RESULTS_CSV"

    cleanup
    unset LLAMA_SWAP_PID
    sleep 2
  done

  summarize

  echo
  echo "Run directory:"
  echo "  $RUN_DIR"
  echo
  echo "To inspect logs:"
  echo "  less \"$RUN_DIR/logs/p03_off_q8_ub256_b2048.log\""
}

main "$@"

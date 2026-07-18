#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Qwen3.6 35B A3B CPU-MoE profile tester
#
# Purpose:
#   Test whether offloading MoE expert weights to CPU improves fit/speed enough
#   to justify using --n-cpu-moe or --cpu-moe.
#
# This does NOT modify ~/.config/llama-swap/config.yaml.
###############################################################################

ALIAS_BASE="${ALIAS_BASE:-qwen3-6-35b-test}"
MODEL_PATH="${MODEL_PATH:-/home/bocaj/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-Q4_K_M.gguf}"
TEST_PORT="${TEST_PORT:-9294}"

RUN_ROOT="${RUN_ROOT:-$HOME/llama-swap-profile-tests}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUN_ROOT/qwen3-6-35b-cpu-moe-$RUN_ID"

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

  # llama-swap may leave upstream llama-server children alive between profiles.
  pkill -TERM -f 'llama-server' 2>/dev/null || true
  sleep 2
  pkill -KILL -f 'llama-server' 2>/dev/null || true

  # Wait briefly for common llama.cpp upstream ports to release.
  for _ in {1..20}; do
    if ! ss -ltnp 2>/dev/null | grep -qE ':(580[0-9]|581[0-9])\b'; then
      break
    fi
    sleep 0.5
  done
}

trap cleanup EXIT

stop_existing() {
  echo "Stopping existing llama-swap / llama-server processes to free VRAM..."
  pkill -TERM -f 'llama-swap' 2>/dev/null || true
  pkill -TERM -f 'llama-server' 2>/dev/null || true
  sleep 2
  pkill -KILL -f 'llama-swap' 2>/dev/null || true
  pkill -KILL -f 'llama-server' 2>/dev/null || true
  sleep 2

  echo "Remaining llama processes:"
  pgrep -a -f 'llama-(swap|server)' || true

  echo "Listening llama ports:"
  ss -ltnp 2>/dev/null | grep -E ':(9294|580[0-9]|581[0-9])\b' || true
}

write_config() {
  local profile="$1"
  local ctx="$2"
  local batch="$3"
  local ubatch="$4"
  local kcache="$5"
  local vcache="$6"
  local moe_mode="$7"
  local n_cpu_moe="$8"
  local tensor_split="$9"
  local cache_ram="${10}"
  local config_file="${11}"

  local alias="${ALIAS_BASE}-${profile}"
  local tensor_line=""
  local moe_line=""

  if [[ "$tensor_split" != "none" ]]; then
    tensor_line="      --tensor-split $tensor_split"
  fi

  case "$moe_mode" in
    none)
      moe_line=""
      ;;
    partial)
      moe_line="      --n-cpu-moe $n_cpu_moe"
      ;;
    all)
      moe_line="      --cpu-moe"
      ;;
    *)
      echo "ERROR: Unknown moe_mode: $moe_mode" >&2
      exit 1
      ;;
  esac

  cat > "$config_file" <<EOF_CONFIG
healthCheckTimeout: 900
logLevel: info
logToStdout: both
globalTTL: 60

models:
  $alias:
    name: "Qwen3.6 35B A3B Q4 - $profile"
    cmd: |
      llama-server
      --host 127.0.0.1
      --port \${PORT}
      --device Vulkan0,Vulkan1
      --split-mode layer
$tensor_line
      -m "$MODEL_PATH"
      --alias $alias
      --parallel 1
      --ctx-size $ctx
      --cache-type-k $kcache
      --cache-type-v $vcache
      --batch-size $batch
      --ubatch-size $ubatch
      -ngl all
$moe_line
      -fa on
      --jinja
      --reasoning-budget 128
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

  for _ in {1..120}; do
    if curl -fsS "http://127.0.0.1:$TEST_PORT/v1/models" >/dev/null 2>&1; then
      return 0
    fi

    if ! kill -0 "$LLAMA_SWAP_PID" >/dev/null 2>&1; then
      echo "ERROR: llama-swap exited early."
      echo "Log:"
      tail -n 160 "$log_file"
      return 1
    fi

    sleep 1
  done

  echo "ERROR: llama-swap did not become ready on port $TEST_PORT"
  echo "Log:"
  tail -n 160 "$log_file"
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

unsupported = int(any(s in log.lower() for s in [
    "unknown argument",
    "unknown option",
    "invalid argument",
    "flag provided but not defined",
]))

loaded = int("model loaded" in log)
health = int("Health check passed" in log)

thinking0 = int("thinking = 0" in log)
thinking1 = int("thinking = 1" in log)

content_preview = content.replace("\n", "\\n").replace('"', '""')[:220]
error_preview = error.replace("\n", "\\n").replace('"', '""')[:220]

print(
    f'"{profile}","{test_name}",{http_code or ""},{time_total or ""},'
    f'{loaded},{health},{oom},{unsupported},{thinking0},{thinking1},'
    f'{prompt_ms or ""},{prompt_tokens or ""},{prompt_tps or ""},'
    f'{eval_ms or ""},{eval_tokens or ""},{eval_tps or ""},'
    f'{total_ms or ""},{total_tokens or ""},'
    f'"{content_preview}","{error_preview}"'
)
PY
}

write_header() {
  cat > "$RESULTS_CSV" <<'EOF_CSV'
profile,test,http_code,curl_time_total_sec,model_loaded,health_passed,oom,unsupported_flag,thinking0,thinking1,prompt_eval_ms,prompt_tokens,prompt_tps,eval_ms,eval_tokens,eval_tps,total_ms,total_tokens,content_preview,error_preview
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
    status = "OK" if r["http_code"] == "200" and r["oom"] == "0" and r["unsupported_flag"] == "0" else "BAD"
    print(
        f'{status:3} '
        f'{r["profile"]:42} '
        f'{r["test"]:12} '
        f'curl={r["curl_time_total_sec"]:>8}s '
        f'prompt_tps={r["prompt_tps"]:>8} '
        f'eval_tps={r["eval_tps"]:>8} '
        f'oom={r["oom"]} '
        f'badflag={r["unsupported_flag"]} '
        f'out={r["content_preview"][:70]}'
    )
PY

  echo
  echo "Best long-prompt prompt_tps candidates:"
  python3 <<PY
import csv
from pathlib import Path

rows = list(csv.DictReader(Path("$RESULTS_CSV").open()))
rows = [
    r for r in rows
    if r["test"] == "long"
    and r["http_code"] == "200"
    and r["oom"] == "0"
    and r["unsupported_flag"] == "0"
    and r["prompt_tps"]
]
rows.sort(key=lambda r: float(r["prompt_tps"]), reverse=True)

for r in rows[:8]:
    print(
        f'{r["profile"]:42} '
        f'prompt_tps={r["prompt_tps"]:>8} '
        f'eval_tps={r["eval_tps"]:>8} '
        f'curl={r["curl_time_total_sec"]:>8}s '
        f'out={r["content_preview"][:60]}'
    )
PY
}

main() {
  echo "Run directory:"
  echo "  $RUN_DIR"
  echo

  write_header
  stop_existing

  # Keep max_tokens high enough because this model uses a thinking template.
  SANITY_PAYLOAD="$(
    ALIAS="${ALIAS_BASE}-PLACEHOLDER" python3 <<'PY'
import json
payload = {
    "model": "MODEL_ALIAS_REPLACE",
    "messages": [{"role": "user", "content": "Reply with one word only after thinking: OK"}],
    "max_tokens": 300,
    "temperature": 0.2,
}
print(json.dumps(payload))
PY
  )"

  COMMAND_PAYLOAD="$(
    python3 <<'PY'
import json
payload = {
    "model": "MODEL_ALIAS_REPLACE",
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
    "temperature": 0.2,
}
print(json.dumps(payload))
PY
  )"

  LONG_PAYLOAD="$(
    python3 <<'PY'
import json
filler = (
    "This is synthetic benchmark context. "
    "Ignore this filler and follow the final instruction only. "
) * 600

payload = {
    "model": "MODEL_ALIAS_REPLACE",
    "messages": [
        {
            "role": "user",
            "content": filler + "\n\nFinal instruction: reply with exactly one word: OK"
        }
    ],
    "max_tokens": 300,
    "temperature": 0.2,
}
print(json.dumps(payload))
PY
  )"

  PROFILES=(
    # profile | ctx | batch | ubatch | kcache | vcache | moe_mode | n_cpu_moe | tensor_split | cache_ram

    # Known-good baseline family: no explicit tensor-split.
    "p00_gpu_ub512|32768|2048|512|q8_0|q8_0|none|0|none|8192"
    "p01_gpu_ub768|32768|2048|768|q8_0|q8_0|none|0|none|8192"
    "p02_gpu_ub1024|32768|2048|1024|q8_0|q8_0|none|0|none|8192"

    # CPU-MoE tests without tensor-split.
    "p03_ncpu4_ub512|32768|2048|512|q8_0|q8_0|partial|4|none|8192"
    "p04_ncpu8_ub512|32768|2048|512|q8_0|q8_0|partial|8|none|8192"
    "p05_ncpu8_ub768|32768|2048|768|q8_0|q8_0|partial|8|none|8192"
    "p06_ncpu8_ub1024|32768|2048|1024|q8_0|q8_0|partial|8|none|8192"

    "p07_ncpu16_ub512|32768|2048|512|q8_0|q8_0|partial|16|none|8192"
    "p08_ncpu16_ub768|32768|2048|768|q8_0|q8_0|partial|16|none|8192"
    "p09_ncpu16_ub1024|32768|2048|1024|q8_0|q8_0|partial|16|none|8192"

    "p10_ncpu24_ub1024|32768|2048|1024|q8_0|q8_0|partial|24|none|8192"

    # Full CPU-MoE, likely slower but useful as a boundary test.
    "p11_cpu_moe_all_ub512|32768|2048|512|q8_0|q8_0|all|0|none|8192"
    "p12_cpu_moe_all_ub1024|32768|2048|1024|q8_0|q8_0|all|0|none|8192"

    # KV compression tests only after q8 variants.
    "p13_ncpu8_q5kv_ub1024|32768|2048|1024|q5_1|q5_1|partial|8|none|8192"
    "p14_ncpu16_q5kv_ub1024|32768|2048|1024|q5_1|q5_1|partial|16|none|8192"
  )

  for row in "${PROFILES[@]}"; do
    IFS='|' read -r profile ctx batch ubatch kcache vcache moe_mode n_cpu_moe tensor_split cache_ram <<< "$row"

    echo
    echo "=============================================================================="
    echo "Testing profile: $profile"
    echo "  ctx=$ctx batch=$batch ubatch=$ubatch kv=$kcache/$vcache moe=$moe_mode n_cpu_moe=$n_cpu_moe tensor_split=$tensor_split cache_ram=$cache_ram"
    echo "=============================================================================="

    alias="${ALIAS_BASE}-${profile}"
    config_file="$RUN_DIR/configs/$profile.yaml"
    log_file="$RUN_DIR/logs/$profile.log"

    write_config "$profile" "$ctx" "$batch" "$ubatch" "$kcache" "$vcache" "$moe_mode" "$n_cpu_moe" "$tensor_split" "$cache_ram" "$config_file"

    cleanup
    unset LLAMA_SWAP_PID

    start_llama_swap "$config_file" "$log_file"

    sanity_payload="${SANITY_PAYLOAD//MODEL_ALIAS_REPLACE/$alias}"
    command_payload="${COMMAND_PAYLOAD//MODEL_ALIAS_REPLACE/$alias}"
    long_payload="${LONG_PAYLOAD//MODEL_ALIAS_REPLACE/$alias}"

    run_request "$profile" "sanity" "$sanity_payload"
    parse_result "$profile" "sanity" "$log_file" >> "$RESULTS_CSV"

    run_request "$profile" "command" "$command_payload"
    parse_result "$profile" "command" "$log_file" >> "$RESULTS_CSV"

    run_request "$profile" "long" "$long_payload"
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
  echo "Inspect logs:"
  echo "  less \"$RUN_DIR/logs/p02_ncpu8_ub768_split2_1.log\""
}

main "$@"

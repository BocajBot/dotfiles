#!/usr/bin/env zsh
set -u

CTX_SIZE="${CTX_SIZE:-49152}"
NGL="${NGL:-99}"
PORT="${PORT:-5825}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$HOME/opencode-baselines/gpu-ab-$STAMP"
RESULTS="$OUTDIR/results.jsonl"

mkdir -p "$OUTDIR/logs" "$OUTDIR/raw"
: > "$RESULTS"

typeset -A MODEL_PATHS
MODEL_PATHS[qwable-27b]="/home/bocaj/models/Qwable-3.6-27b-MTP/Qwable-3.6-27b_q4_k_m.gguf"
MODEL_PATHS[qwen3-6-35b]="/home/bocaj/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-Q4_K_M.gguf"

models=(
  qwable-27b
  qwen3-6-35b
)

devices=(
  Vulkan0
  Vulkan1
)

tests=(
  short
  medium
  long
)

make_payload() {
  local model="$1"
  local prompt="$2"
  local max_tokens="$3"

  PAYLOAD_MODEL="$model" PAYLOAD_PROMPT="$prompt" PAYLOAD_MAX="$max_tokens" python3 << 'PY'
import json
import os

print(json.dumps({
    "model": os.environ["PAYLOAD_MODEL"],
    "messages": [
        {
            "role": "user",
            "content": os.environ["PAYLOAD_PROMPT"],
        }
    ],
    "max_tokens": int(os.environ["PAYLOAD_MAX"]),
}))
PY
}

wait_for_server() {
  local port="$1"
  local seconds="${2:-900}"

  for i in $(seq 1 "$seconds"); do
    if curl -fs "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

parse_response() {
  local raw="$1"
  local out="$2"
  local model="$3"
  local device="$4"
  local test="$5"
  local repeat="$6"
  local curl_seconds="$7"
  local log="$8"

  python3 - "$raw" "$out" "$model" "$device" "$test" "$repeat" "$curl_seconds" "$log" << 'PY'
import json
import sys
from pathlib import Path

raw_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
model = sys.argv[3]
device = sys.argv[4]
test = sys.argv[5]
repeat = int(sys.argv[6])
curl_seconds = float(sys.argv[7])
log_path = Path(sys.argv[8])

raw = raw_path.read_bytes().decode("utf-8", errors="replace")

record = {
    "model": model,
    "device": device,
    "test": test,
    "repeat": repeat,
    "parse_ok": False,
    "finish_reason": None,
    "prompt_tokens": None,
    "completion_tokens": None,
    "total_tokens": None,
    "reasoning_chars": None,
    "tps": None,
    "prompt_tps": None,
    "curl_seconds": curl_seconds,
    "content_preview": "",
    "raw_path": str(raw_path),
    "log_path": str(log_path),
    "error": None,
}

try:
    data = json.loads(raw)

    if "error" in data:
        record["error"] = data["error"]
    else:
        choice = data.get("choices", [{}])[0]
        msg = choice.get("message", {})
        usage = data.get("usage", {})
        timings = data.get("timings", {})

        record.update({
            "parse_ok": True,
            "model": data.get("model", model),
            "finish_reason": choice.get("finish_reason"),
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "total_tokens": usage.get("total_tokens"),
            "reasoning_chars": len(msg.get("reasoning_content") or ""),
            "tps": timings.get("predicted_per_second"),
            "prompt_tps": timings.get("prompt_per_second"),
            "content_preview": (msg.get("content") or "").replace("\n", " ")[:180],
        })
except Exception as e:
    record["error"] = f"{type(e).__name__}: {e}"

with out_path.open("a", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False) + "\n")
PY
}

run_one_server() {
  local model="$1"
  local device="$2"
  local model_path="${MODEL_PATHS[$model]}"
  local alias="${model}-${device}"
  local log="$OUTDIR/logs/${model}__${device}.log"

  echo
  echo "============================================================"
  echo "Starting model=$model device=$device ctx=$CTX_SIZE ngl=$NGL"
  echo "Log: $log"
  echo "============================================================"

  pkill -f "llama-server.*--port $PORT" 2>/dev/null || true
  sleep 2

  llama-server \
    --host 127.0.0.1 \
    --port "$PORT" \
    --device "$device" \
    --split-mode none \
    --main-gpu 0 \
    -m "$model_path" \
    --alias "$alias" \
    --parallel 1 \
    --ctx-size "$CTX_SIZE" \
    -ngl "$NGL" \
    -fa on \
    --jinja \
    --reasoning-budget 64 \
    -fit off \
    --cache-ram 0 \
    > "$log" 2>&1 &

  local server_pid="$!"

  if ! wait_for_server "$PORT" 900; then
    echo "FAILED TO START: model=$model device=$device"
    echo '{"model":"'"$model"'","device":"'"$device"'","test":"server_start","parse_ok":false,"error":"server failed to start","log_path":"'"$log"'"}' >> "$RESULTS"
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    tail -80 "$log"
    return
  fi

  echo "Server ready: model=$model device=$device"

  for test in "${tests[@]}"; do
    case "$test" in
      short)
        prompt='Reply with one word: OK'
        max_tokens=300
        ;;
      medium)
        prompt='In 8 concise bullets, explain how to safely find a build command in a large monorepo without running any build, install, test, or package-manager command.'
        max_tokens=800
        ;;
      long)
        prompt='Write a detailed but practical checklist for evaluating a local coding model in OpenCode. Cover command discovery, local-file inspection, tool safety, repo summarization, code editing risk, latency, truncation, and repeatability.'
        max_tokens=1600
        ;;
    esac

    for repeat in 1 2 3; do
      echo "model=$model device=$device test=$test repeat=$repeat"

      raw="$OUTDIR/raw/${model}__${device}__${test}__${repeat}.json"
      timefile="$OUTDIR/raw/${model}__${device}__${test}__${repeat}.time"
      payload="$(make_payload "$alias" "$prompt" "$max_tokens")"

      curl -sS \
        -o "$raw" \
        -w "%{time_total}" \
        "http://127.0.0.1:$PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" > "$timefile"

      parse_response "$raw" "$RESULTS" "$model" "$device" "$test" "$repeat" "$(cat "$timefile")" "$log"
    done
  done

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  sleep 3
}

for device in "${devices[@]}"; do
  for model in "${models[@]}"; do
    run_one_server "$model" "$device"
  done
done

echo
echo "Saved to:"
echo "$OUTDIR"
echo
echo "Raw results:"
echo "$RESULTS"
echo
echo "Summary:"
python3 - "$RESULTS" << 'PY'
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]

print("model\tdevice\ttest\truns\tavg_tps\tavg_curl_sec\tavg_completion_tok\tavg_reasoning_chars\tfailures")

groups = defaultdict(list)
failures = defaultdict(int)

for r in rows:
    key = (r.get("model"), r.get("device"), r.get("test"))
    if r.get("parse_ok") and isinstance(r.get("tps"), (int, float)):
        groups[key].append(r)
    else:
        failures[key] += 1

for key in sorted(set(groups) | set(failures)):
    vals = groups.get(key, [])
    model, device, test = key

    if vals:
        print("\t".join(map(str, [
            model,
            device,
            test,
            len(vals),
            round(statistics.mean(v["tps"] for v in vals), 2),
            round(statistics.mean(v["curl_seconds"] for v in vals), 3),
            round(statistics.mean(v["completion_tokens"] for v in vals), 1),
            round(statistics.mean(v["reasoning_chars"] for v in vals), 1),
            failures.get(key, 0),
        ])))
    else:
        print("\t".join(map(str, [
            model,
            device,
            test,
            0,
            "",
            "",
            "",
            "",
            failures.get(key, 0),
        ])))
PY

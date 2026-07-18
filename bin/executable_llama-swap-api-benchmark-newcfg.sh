#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:9292}"
OUT="$HOME/opencode-baselines/api-newcfg-$(date +%Y%m%d-%H%M%S)"
RUNS="${RUNS:-2}"
INCLUDE_SLOW="${INCLUDE_SLOW:-0}"

mkdir -p "$OUT/responses"

models=(
  qwen3-6-35b
  qwen3-6-35b-long
  qwable-27b
  qwable-27b-long
  qwopus3-6-27b-coder-mtp
  qwopus3-6-27b-coder-mtp-on
  qwen3-coder-q4
  qwen3-coder-q3
  gemma-agentic
  qwythos-9b
  qwen2-5-coder-7b
)

if [[ "$INCLUDE_SLOW" == "1" ]]; then
  models+=(qwen2-5-72b-iq2m-split)
fi

cat > "$OUT/prompt_medium.txt" << 'PROMPT'
In 8 concise bullets, explain how to safely find a build command in a large monorepo without running build commands.
PROMPT

echo "Output: $OUT"
echo "Base URL: $BASE_URL"
echo

for model in "${models[@]}"; do
  echo "============================================================"
  echo "Loading/warming: $model"
  echo "============================================================"

  warm_file="$OUT/responses/${model}__warmup.json.txt"

  set +e
  timeout 900 curl -sS "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -w $'\n__CURL_TIME_TOTAL__:%{time_total}\n' \
    -d "{
      \"model\": \"$model\",
      \"messages\": [{\"role\":\"user\",\"content\":\"Reply with one word: OK\"}],
      \"max_tokens\": 32
    }" > "$warm_file" 2>&1
  warm_rc=$?
  set -e

  if [[ "$warm_rc" -ne 0 ]]; then
    echo "WARMUP FAIL: $model"
    tail -80 "$warm_file" || true
    continue
  fi

  for run in $(seq 1 "$RUNS"); do
    echo "Testing: $model run $run/$RUNS"

    resp_file="$OUT/responses/${model}__medium__run${run}.json.txt"

    set +e
    timeout 900 curl -sS "$BASE_URL/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -w $'\n__CURL_TIME_TOTAL__:%{time_total}\n' \
      -d "{
        \"model\": \"$model\",
        \"messages\": [
          {
            \"role\": \"user\",
            \"content\": $(python3 - << PY
import json
from pathlib import Path
print(json.dumps(Path("$OUT/prompt_medium.txt").read_text()))
PY
)
          }
        ],
        \"max_tokens\": 800
      }" > "$resp_file" 2>&1
    rc=$?
    set -e

    python3 - "$model" "$run" "$rc" "$resp_file" "$OUT/results.jsonl" << 'PY'
import json
import sys
from pathlib import Path

model, run, rc, resp_path, out_path = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4]), Path(sys.argv[5])
raw = resp_path.read_text(errors="replace")

curl_time = None
marker = "\n__CURL_TIME_TOTAL__:"
if marker in raw:
    json_part, tail = raw.rsplit(marker, 1)
    try:
        curl_time = float(tail.strip().splitlines()[0])
    except Exception:
        pass
else:
    json_part = raw

row = {
    "model": model,
    "test": "medium",
    "run": run,
    "curl_rc": rc,
    "curl_seconds": curl_time,
    "parse_ok": False,
    "finish_reason": None,
    "tps": None,
    "prompt_tps": None,
    "completion_tokens": None,
    "prompt_tokens": None,
    "content_preview": "",
    "error": None,
}

try:
    data = json.loads(json_part)
    row["parse_ok"] = True

    if "error" in data:
        row["error"] = data["error"]
    else:
        choice = data.get("choices", [{}])[0]
        timings = data.get("timings", {})
        usage = data.get("usage", {})

        row["finish_reason"] = choice.get("finish_reason")
        row["tps"] = timings.get("predicted_per_second")
        row["prompt_tps"] = timings.get("prompt_per_second")
        row["completion_tokens"] = usage.get("completion_tokens")
        row["prompt_tokens"] = usage.get("prompt_tokens")
        row["content_preview"] = (choice.get("message", {}).get("content") or "")[:240]
except Exception as e:
    row["error"] = f"parse_failed: {e}"

with out_path.open("a") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")

print(json.dumps(row, indent=2))
PY

  done
done

python3 - "$OUT/results.jsonl" "$OUT/summary.tsv" << 'PY'
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

results = Path(sys.argv[1])
summary = Path(sys.argv[2])

rows = []
if results.exists():
    rows = [json.loads(line) for line in results.read_text().splitlines() if line.strip()]

groups = defaultdict(list)
failures = defaultdict(int)

for r in rows:
    key = (r["model"], r["test"])
    if r.get("parse_ok") and isinstance(r.get("tps"), (int, float)):
        groups[key].append(r)
    else:
        failures[key] += 1

lines = ["model\ttest\truns\tavg_tps\tavg_prompt_tps\tavg_curl_sec\tavg_completion_tokens\tfailures"]

for key in sorted(set(groups) | set(failures)):
    vals = groups.get(key, [])
    model, test = key

    if vals:
        def mean(field):
            nums = [v[field] for v in vals if isinstance(v.get(field), (int, float))]
            return round(statistics.mean(nums), 3) if nums else ""

        lines.append("\t".join(map(str, [
            model,
            test,
            len(vals),
            mean("tps"),
            mean("prompt_tps"),
            mean("curl_seconds"),
            mean("completion_tokens"),
            failures.get(key, 0),
        ])))
    else:
        lines.append("\t".join(map(str, [
            model, test, 0, "", "", "", "", failures.get(key, 0)
        ])))

summary.write_text("\n".join(lines) + "\n")
print()
print(summary.read_text())
print(f"Saved: {summary}")
PY

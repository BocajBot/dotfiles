#!/usr/bin/env zsh
set -u

BASE_URL="${BASE_URL:-http://127.0.0.1:9292/v1}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$HOME/opencode-baselines/manual-notes/qwopus-mtp-ab-safe-$STAMP"
OUT="$OUTDIR/results.jsonl"

mkdir -p "$OUTDIR/raw"
: > "$OUT"

models=(
  qwopus3-6-27b-coder-mtp
  qwopus3-6-27b-coder-mtp-on
)

tests=(short medium long)

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

parse_response() {
  local raw="$1"
  local out="$2"
  local model="$3"
  local test="$4"
  local repeat="$5"
  local curl_seconds="$6"

  python3 - "$raw" "$out" "$model" "$test" "$repeat" "$curl_seconds" << 'PY'
import json
import sys
from pathlib import Path

raw_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
model = sys.argv[3]
test = sys.argv[4]
repeat = int(sys.argv[5])
curl_seconds = float(sys.argv[6])

raw_bytes = raw_path.read_bytes()
text = raw_bytes.decode("utf-8", errors="replace")

def repair_json_control_chars(s: str) -> str:
    """Escape raw control chars only while inside JSON strings."""
    out = []
    in_string = False
    escaped = False

    for ch in s:
        code = ord(ch)

        if in_string:
            if escaped:
                out.append(ch)
                escaped = False
                continue

            if ch == "\\":
                out.append(ch)
                escaped = True
                continue

            if ch == '"':
                out.append(ch)
                in_string = False
                continue

            if code < 0x20:
                if ch == "\n":
                    out.append("\\n")
                elif ch == "\r":
                    out.append("\\r")
                elif ch == "\t":
                    out.append("\\t")
                else:
                    out.append(f"\\u{code:04x}")
                continue

            out.append(ch)
        else:
            out.append(ch)
            if ch == '"':
                in_string = True

    return "".join(out)

record = {
    "model": model,
    "test": test,
    "repeat": repeat,
    "curl_seconds": curl_seconds,
    "parse_ok": False,
    "error": None,
    "finish_reason": None,
    "prompt_tokens": None,
    "completion_tokens": None,
    "total_tokens": None,
    "reasoning_chars": None,
    "tps": None,
    "prompt_tps": None,
    "content_preview": "",
    "raw_path": str(raw_path),
}

try:
    repaired = repair_json_control_chars(text)
    data = json.loads(repaired)

    if "error" in data:
        record["error"] = data["error"]
    else:
        msg = data.get("choices", [{}])[0].get("message", {})
        timings = data.get("timings", {})
        usage = data.get("usage", {})

        record.update({
            "parse_ok": True,
            "model": data.get("model", model),
            "finish_reason": data.get("choices", [{}])[0].get("finish_reason"),
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

for model in "${models[@]}"; do
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
      echo "model=$model test=$test repeat=$repeat"

      raw="$OUTDIR/raw/${model}__${test}__${repeat}.json"
      timefile="$OUTDIR/raw/${model}__${test}__${repeat}.time"
      payload="$(make_payload "$model" "$prompt" "$max_tokens")"

      curl -sS \
        -o "$raw" \
        -w "%{time_total}" \
        "$BASE_URL/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" > "$timefile"

      parse_response "$raw" "$OUT" "$model" "$test" "$repeat" "$(cat "$timefile")"
    done
  done
done

echo
echo "Saved to:"
echo "$OUTDIR"
echo
echo "Summary:"
python3 - "$OUT" << 'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

headers = [
    "model", "test", "repeat", "parse", "finish",
    "completion_tok", "reasoning_chars", "tps", "curl_sec", "preview"
]

print("\t".join(headers))
for r in rows:
    print("\t".join(str(x) for x in [
        r["model"],
        r["test"],
        r["repeat"],
        "yes" if r["parse_ok"] else "no",
        r["finish_reason"],
        r["completion_tokens"],
        r["reasoning_chars"],
        round(r["tps"], 2) if isinstance(r["tps"], (int, float)) else r["tps"],
        round(r["curl_seconds"], 3),
        r["content_preview"],
    ]))
PY

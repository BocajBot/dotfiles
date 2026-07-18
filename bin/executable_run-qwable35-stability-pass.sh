#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${COMBO_DIR:-}" ]]; then
  echo "ERROR: COMBO_DIR is not set."
  echo "Run: export COMBO_DIR=/home/bocaj/opencode-param-tuning/qwable35-stability-YYYYMMDD-HHMMSS"
  exit 1
fi

MODELS_FILE="$COMBO_DIR/models-only.txt"

if [[ ! -f "$MODELS_FILE" ]]; then
  echo "ERROR: Missing models file: $MODELS_FILE"
  exit 1
fi

MODELS_ONLY_VALUE="$(tr '\n' ' ' < "$MODELS_FILE" | xargs)"

if [[ -z "$MODELS_ONLY_VALUE" ]]; then
  echo "ERROR: $MODELS_FILE is empty."
  exit 1
fi

echo "Using COMBO_DIR:"
echo "  $COMBO_DIR"
echo

echo "Models to run:"
tr ' ' '\n' <<< "$MODELS_ONLY_VALUE"
echo

BAD_MODELS="$(
  tr ' ' '\n' <<< "$MODELS_ONLY_VALUE" \
    | grep -v '^$' \
    | grep -v '^qwable-35b-q4__stab-' || true
)"

if [[ -n "$BAD_MODELS" ]]; then
  echo "ERROR: models-only.txt contains non-stability aliases:"
  echo "$BAD_MODELS"
  exit 1
fi

COUNT="$(tr ' ' '\n' <<< "$MODELS_ONLY_VALUE" | grep -c '^qwable-35b-q4__stab-')"

if [[ "$COUNT" -lt 1 ]]; then
  echo "ERROR: No qwable-35b-q4__stab-* aliases found."
  exit 1
fi

echo "Checking llama-swap model registry..."

LIVE_MODELS="$(curl -s http://127.0.0.1:9292/v1/models | jq -r '.data[].id')"

MISSING_LIVE="$(
  while read -r model; do
    [[ -z "$model" ]] && continue
    grep -qxF "$model" <<< "$LIVE_MODELS" || echo "$model"
  done < <(tr ' ' '\n' <<< "$MODELS_ONLY_VALUE")
)"

if [[ -n "$MISSING_LIVE" ]]; then
  echo "ERROR: These aliases are missing from llama-swap:"
  echo "$MISSING_LIVE"
  echo
  echo "Restart llama-swap, then retry."
  exit 1
fi

echo "Checking OpenCode config aliases..."

python3 << PY
from pathlib import Path
import json
import sys

models = """$MODELS_ONLY_VALUE""".split()

path = Path.home() / ".config/opencode/opencode.json"
data = json.loads(path.read_text())

registered = data.get("provider", {}).get("llama-swap", {}).get("models", {})

missing = [m for m in models if m not in registered]

if missing:
    print("ERROR: These aliases are missing from OpenCode config:")
    for m in missing:
        print(m)
    sys.exit(1)

print(f"OpenCode aliases OK: {len(models)}")
PY

echo
echo "Starting benchmark..."
echo "MODELS_ONLY='$MODELS_ONLY_VALUE'"
echo

MODELS_ONLY="$MODELS_ONLY_VALUE" "$HOME/bin/opencode-baseline-newcfg.sh"

NEW_DIR="$(ls -td "$HOME"/opencode-baselines/newcfg-* | head -n 1)"

echo
echo "Benchmark finished:"
echo "  $NEW_DIR"
echo

echo "Verifying summary contains only stability aliases..."

SUMMARY="$NEW_DIR/summary-newcfg.tsv"

if [[ ! -f "$SUMMARY" ]]; then
  echo "ERROR: Missing summary: $SUMMARY"
  exit 1
fi

SUMMARY_BAD="$(
  awk -F '\t' 'NR > 1 {print $1}' "$SUMMARY" \
    | sort -u \
    | grep -v '^qwable-35b-q4__stab-' || true
)"

if [[ -n "$SUMMARY_BAD" ]]; then
  echo "ERROR: Summary contains non-stability models:"
  echo "$SUMMARY_BAD"
  echo
  echo "This means the benchmark did not run the intended model list."
  exit 1
fi

echo "Summary model list OK."
echo

PKG="$HOME/opencode-baselines/qwable35-combo-stability-$(date +%Y%m%d-%H%M%S).tar.gz"

tar -czf "$PKG" \
  -C "$NEW_DIR" \
  summary-newcfg.tsv \
  llama-swap.config.yaml \
  opencode.json.before \
  opencode.json.after \
  prompts \
  runs

tar -rzf "$PKG" -C "$COMBO_DIR" \
  models-only.txt \
  variant-manifest.tsv \
  llama-swap.backup \
  opencode.backup

echo "Packaged:"
echo "  $PKG"

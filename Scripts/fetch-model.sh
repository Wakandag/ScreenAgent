#!/bin/bash
# Downloads the bundled on-device model: Qwen2.5-0.5B-Instruct Q4_K_M (~400 MB, free license).
set -euo pipefail
cd "$(dirname "$0")/.."

URL="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
mkdir -p App/Resources
OUT=App/Resources/model.gguf

if [ -f "$OUT" ] && [ "$(stat -f%z "$OUT")" -gt 300000000 ]; then
  echo "model already present"
  exit 0
fi

curl -L --fail --retry 3 -o "$OUT" "$URL"
SIZE=$(stat -f%z "$OUT")
echo "downloaded $SIZE bytes"
if [ "$SIZE" -lt 300000000 ]; then
  echo "ERROR: model file looks truncated" >&2
  exit 1
fi

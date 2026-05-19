#!/bin/bash
# Fetch third-party sources that we deliberately don't track in git.
#
# Currently this just clones llama.cpp at the tag pinned by LocalLLMClient
# (must match `llamaVersion` in vendor/LocalLLMClient/Package.swift).
# Run once after a fresh `git clone`, before `swift build` / `Scripts/build.sh`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

LLAMA_TAG="b9222"
LLAMA_DST="$PROJECT_DIR/vendor/LocalLLMClient/Sources/LocalLLMClientLlamaC/exclude/llama.cpp"

if [ -d "$LLAMA_DST" ] && [ -f "$LLAMA_DST/common/build-info.h" ]; then
    echo "llama.cpp already present at $LLAMA_DST"
    exit 0
fi

mkdir -p "$(dirname "$LLAMA_DST")"
echo "Cloning llama.cpp@$LLAMA_TAG into $LLAMA_DST..."
git clone --depth 1 --branch "$LLAMA_TAG" \
    https://github.com/ggml-org/llama.cpp.git "$LLAMA_DST"

# We don't want llama.cpp's git history living inside our repo.
rm -rf "$LLAMA_DST/.git"

echo "Done. You can now run 'swift build' or 'bash Scripts/build.sh'."

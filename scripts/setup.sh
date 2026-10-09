#!/bin/bash
# Sets up speech-node on a GPU machine, inside WSL Ubuntu (or plain Linux): a Python environment, Breeze TTS 2's code
# and its weights, all under ~/speech-node. Safe to run again (it skips what's already there).
#   bash scripts/setup.sh                      # downloads the weights (about 7 GB) from Hugging Face
#   MODEL_FROM=/path/to/breeze-tts-2 bash scripts/setup.sh   # copies weights already on this machine instead
set -euo pipefail
HOME_DIR="${SPEECH_NODE_HOME:-$HOME/speech-node}"
BREEZE_COMMIT="${BREEZE_COMMIT:-58ec70c}"
TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu128}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HOME_DIR/models" "$HOME_DIR/refs"

# The node's Python is pinned (3.12), whatever the system has: Breeze's fast path uses torch.compile, which newer Pythons
# (3.14) don't support yet. uv fetches that Python by itself; an environment on another version is moved aside and rebuilt.
PYVER="${PYTHON_VERSION:-3.12}"
echo "== Python $PYVER environment ($HOME_DIR/venv)"
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null; then
  command -v curl >/dev/null || { echo "curl is missing: sudo apt install -y curl"; exit 1; }
  curl -LsSf https://astral.sh/uv/install.sh | sh -s -- --quiet
fi
uv python install -q "$PYVER"
if [ -x "$HOME_DIR/venv/bin/python" ] && ! "$HOME_DIR/venv/bin/python" -c "import sys; sys.exit(0 if '%d.%d' % sys.version_info[:2] == '$PYVER' else 1)"; then
  OLD="$HOME_DIR/venv.old-$(date +%Y%m%d-%H%M%S)"; echo "The environment is on another Python; moving it aside to $OLD and rebuilding."; mv "$HOME_DIR/venv" "$OLD"
fi
[ -x "$HOME_DIR/venv/bin/python" ] || uv venv -q --seed --python "$PYVER" "$HOME_DIR/venv"
PIP="$HOME_DIR/venv/bin/pip"
"$PIP" install -q -U pip wheel setuptools

echo "== Breeze TTS 2 code (at $BREEZE_COMMIT)"
if [ ! -d "$HOME_DIR/breeze-tts" ]; then git clone -q https://github.com/breezeblue-ai/breeze-tts.git "$HOME_DIR/breeze-tts"; fi
git -C "$HOME_DIR/breeze-tts" fetch -q origin || true
git -C "$HOME_DIR/breeze-tts" checkout -q "$BREEZE_COMMIT"

echo "== Packages (PyTorch for CUDA 12.8, Breeze's requirements, the server)"
"$PIP" install -q torch==2.9.1 torchaudio==2.9.1 --index-url "$TORCH_INDEX"
grep -v -E '^(torch|torchaudio)==' "$HOME_DIR/breeze-tts/requirements.txt" > "$HOME_DIR/breeze-requirements.txt"
"$PIP" install -q -r "$HOME_DIR/breeze-requirements.txt"
# huggingface_hub 1.x breaks Breeze's transformers pin
"$PIP" install -q "huggingface_hub[cli]<1.0" -r "$HERE/requirements.txt"

echo "== Weights ($HOME_DIR/models/breeze-tts-2)"
if [ -f "$HOME_DIR/models/breeze-tts-2/model.safetensors.index.json" ]; then echo "already there"
elif [ -n "${MODEL_FROM:-}" ]; then cp -r "$MODEL_FROM" "$HOME_DIR/models/breeze-tts-2"
else "$HOME_DIR/venv/bin/huggingface-cli" download BreezeBlue/Breeze-TTS-2 --local-dir "$HOME_DIR/models/breeze-tts-2"; fi

if [ ! -f "$HOME_DIR/node.json" ]; then
  sed -e "s#\"breeze_repo\": .*#\"breeze_repo\": \"$HOME_DIR/breeze-tts\",#" -e "s#\"model_dir\": .*#\"model_dir\": \"$HOME_DIR/models/breeze-tts-2\",#" \
      -e "s#\"cache_dir\": .*#\"cache_dir\": \"$HOME_DIR/refs\",#" "$HERE/node.example.json" > "$HOME_DIR/node.json"
  echo "== Wrote $HOME_DIR/node.json: set \"name\" and \"slots\" for this machine"
fi
echo "== Done. Start it with: bash $HERE/scripts/run.sh"

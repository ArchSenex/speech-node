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

echo "== Python environment ($HOME_DIR/venv)"
command -v python3 >/dev/null || { echo "python3 is missing: sudo apt install -y python3 python3-venv"; exit 1; }
[ -x "$HOME_DIR/venv/bin/python" ] || python3 -m venv "$HOME_DIR/venv" || { echo "venv failed: sudo apt install -y python3-venv"; exit 1; }
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

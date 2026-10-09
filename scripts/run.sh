#!/bin/bash
# Runs speech-node in the foreground (Ctrl+C stops it). Config: ~/speech-node/node.json, or the path given.
HOME_DIR="${SPEECH_NODE_HOME:-$HOME/speech-node}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" && exec "$HOME_DIR/venv/bin/python" -u -m node.server "${1:-$HOME_DIR/node.json}"

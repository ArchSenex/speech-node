#!/bin/bash
# Fills in ~/speech-node/node.json for this machine the first time (name, slots from the card's memory, port); after
# that it keeps whatever is there. Prints the slots either way.
#   bash configure-node.sh <name> [port]
set -euo pipefail
NAME="${1:-$(hostname)}"; PORT="${2:-7860}"; F="${SPEECH_NODE_HOME:-$HOME/speech-node}/node.json"
MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)
python3 - "$F" "$NAME" "$PORT" "${MEM:-0}" <<'PY'
import json, sys
f, name, port, mem = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4] or 0)
c = json.load(open(f))
if c.get('name') in (None, '', 'this-machine'):
    slots = 3 if mem >= 30000 else 2 if mem >= 20000 else 1
    c.update(name=name, slots=slots, port=port)
    json.dump(c, open(f, 'w'), indent=2)
    print(f"Set: name {name}, {slots} slot(s) for a {round(mem / 1024)} GB card, port {port}")
else:
    print(f"Kept your settings: name {c['name']}, {c['slots']} slot(s), port {c.get('port')}")
print(f"SLOTS={c['slots']}")
PY

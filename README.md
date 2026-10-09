# speech-node

Text-to-speech for one GPU machine, served over HTTP for the gateway (llmserver) to call. Run it on every machine with
a card to spare, and the gateway spreads the work across all of them.

It serves **Breeze TTS 2**:
- **Voice design:** a voice made from a written description.
- **Cloning:** a voice copied from a reference clip and its exact transcript.
- **Vocal events:** inline `(sigh)`, `(laugh)`, `(clears throat)`.

## How it uses the card
- It keeps up to `slots` copies of the model loaded, each in its own process, and each speaks one piece at a time.
  On a 32 GB card that's two or three copies; on 24 GB, one or two.
- It only loads another copy when work is waiting and the card has `slot_mb` of VRAM free. It lets a copy go after
  `idle_minutes` without work, down to `min_loaded`, so other GPU work (ComfyUI, games) gets the card back.
- A long text is split into sentence-sized pieces that are spoken in parallel across the loaded copies, then joined
  with short pauses.
- Requests with a higher `priority` go first.

## API
| | |
|---|---|
| `GET /health` | what it serves, its slots, how many copies are loaded, loading and busy, what's waiting, free VRAM |
| `PUT /refs/<sha256>` | store a reference clip (the request body), named by its SHA-256 |
| `GET /refs/<sha256>` | 200 if that clip is stored, 404 if not |
| `POST /speak` | JSON: `text`, `seed` (default 7), `cfg`, and either `instruction` (design) or `ref_sha` + `ref_text` (cloning); also `priority` (higher first) and `format` (`wav`, the default, or `pcm`) |

What `/speak` returns:
- **On success:** 16-bit mono WAV (or raw PCM), with the headers `X-Sample-Rate`, `X-Audio-Seconds`, `X-Took-Seconds`, `X-Pieces` and `X-Node`.
- **409 `{"error": "ref_missing"}`:** the reference clip isn't stored on this node. PUT it, then ask again.
- **503:** the queue is full.

Settings for each kind of voice:
- **Design:** `cfg` 4.
- **Cloning:** `cfg` 1, and `ref_text` must be exactly what the clip says, including any `(sigh)` or `(laugh)`.
- **Seeds:** in voice design, each seed is a different person. Keep the seed fixed to keep a voice steady.

## Setting up a machine (Windows with WSL, or Linux)
1. **WSL:** if it isn't installed yet, run `wsl --install -d Ubuntu` in an admin PowerShell and reboot. The NVIDIA driver on Windows is all WSL needs.
2. In Ubuntu:
   ```
   sudo apt install -y python3-venv git
   git clone https://github.com/ArchSenex/speech-node.git ~/speech-node-app
   bash ~/speech-node-app/scripts/setup.sh     # about 7 GB of weights; MODEL_FROM=<dir> copies a local copy instead
   ```
3. Edit `~/speech-node/node.json`:
   - `name`: the machine's name;
   - `slots`: how many copies it may load at once;
   - `min_loaded`: 0 if the card is often busy with other things.
4. Run it:
   - **From Windows, the friendly way:** the tray icon. `scripts\speech-node-tray.ps1` starts the node hidden and puts a dot by the clock: green when ready, amber while loading, grey when stopped. Hover over it to see what it's doing. Click it for **Stop speech node (free the graphics card)**, **Start again**, or **Stop and close this icon**. Stopping ends every part of the node, so the card is entirely free for games or anything else.
   - **Shortcuts:** `scripts\install-tray.ps1` adds "Speech node" to the Start menu and the desktop. Add `-AtLogon` to start it at log-on as well, or `-Remove` to take the shortcuts away. The shortcut paths are as Windows sees the checkout, e.g. `\\wsl.localhost\Ubuntu\home\<you>\speech-node-app\scripts`.
   - **In a terminal:** `bash ~/speech-node-app/scripts/run.sh`, or `scripts/start-node.ps1` for a console window.
5. **Reaching it from other machines.** WSL sits behind its own network unless it shares Windows' network. Add this to `%UserProfile%\.wslconfig`, then run `wsl --shutdown`:
   ```
   [wsl2]
   networkingMode=mirrored
   ```
   and allow the port through Windows Firewall:
   ```
   New-NetFirewallRule -DisplayName "speech-node" -Direction Inbound -Protocol TCP -LocalPort 7860 -Action Allow
   ```
   Over Tailscale, it's then reachable at `http://<machine>:7860`.
6. Add the machine to the gateway's speech nodes (in llmserver's config) with its slot count.

## Testing
`python -m pytest tests` runs on the fake engine (`"fake": true`, or `SPEECH_NODE_FAKE=1`). The fake engine needs no GPU and returns a tone as long as the speech would be, which is useful for building clients too.

## Licence
- The node's code is yours.
- Breeze TTS 2's code is Apache 2.0.
- Its weights are under the BreezeBlue Research and Non-Commercial License: personal and research use, not commercial.

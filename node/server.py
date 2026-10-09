"""speech-node: a text-to-speech service for one GPU machine, called by the gateway (or anything else on the network).

It keeps up to `slots` copies of the model loaded, each in its own process, and runs one piece of speech on each at a
time. It loads another copy only when work is waiting and the card has room for it, and lets copies go after they've
sat idle for a while, so the card is free for other work. With "split": true, a long text is split into sentence-sized pieces that are
spoken in parallel across the loaded copies and joined with short pauses.

  GET  /health            what it serves, its slots, what's busy and waiting, free VRAM
  PUT  /refs/<sha256>     store a reference clip (the body), named by its SHA-256, for cloning
  GET  /refs/<sha256>     200 if it's stored, 404 if not
  POST /speak             JSON {text, seed?, cfg?, instruction? | ref_sha + ref_text, priority?, format? "wav"|"pcm"}
                          -> audio/wav (or raw 16-bit PCM, with X-Sample-Rate); 409 {"error": "ref_missing"} when
                          the reference isn't stored yet (PUT it, then ask again); 503 when the queue is full.

Run: python -m node.server [config.json]   (see node.example.json)
"""
import asyncio
import hashlib
import io
import itertools
import json
import multiprocessing as mp
import os
import re
import subprocess
import sys
import time
import wave
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response

VERSION = "0.1.0"
DEFAULTS = {
    "name": os.uname().nodename if hasattr(os, "uname") else "speech-node",
    "host": "0.0.0.0", "port": 7860,
    "slots": 2,            # most copies of the model loaded at once
    "min_loaded": 1,       # copies kept loaded even when idle (0: load on first use)
    "slot_mb": 10000,      # VRAM one more copy needs; a copy is only added when this much is free
    "idle_minutes": 30,    # a copy idle this long is let go (down to min_loaded)
    "max_queued": 400,     # pieces waiting before new requests are refused
    "max_chars": 240,      # longest piece spoken in one go
    "gap_ms": 350,         # pause between joined pieces
    "fast": True,          # Breeze's CUDA-graph fast path (slower to load, much faster to speak)
    "breeze_repo": "~/speech-node/breeze-tts",
    "model_dir": "~/speech-node/models/breeze-tts-2",
    "cache_dir": "~/speech-node/refs",
    "max_refs": 500,
    "fake": False,         # no model: a tone of the right length (for tests and for building clients)
}


def load_config(path=None):
    cfg = dict(DEFAULTS)
    if path and Path(path).exists():
        cfg.update(json.loads(Path(path).read_text()))
    if os.environ.get("SPEECH_NODE_FAKE") == "1":
        cfg["fake"] = True
    cfg["cache_dir"] = str(Path(cfg["cache_dir"]).expanduser())
    Path(cfg["cache_dir"]).mkdir(parents=True, exist_ok=True)
    return cfg


# ---- splitting text into pieces ----
def pieces(text, max_chars):
    """Paragraphs, then sentences, packed up to max_chars; a scrap is folded into the piece before it."""
    out = []
    for para in re.split(r"\n\s*\n", text.strip()):
        cur = ""
        for s in re.findall(r"[^.!?…]+[.!?…]+[\"'”’)\]]*\s*|[^.!?…]+$", para.replace("\n", " ")):
            if cur and len(cur) + len(s) > max_chars:
                out.append(cur.strip()); cur = ""
            if len(s) > max_chars:
                for part in re.split(r"(?<=[,;:])\s+", s):
                    if cur and len(cur) + len(part) > max_chars:
                        out.append(cur.strip()); cur = ""
                    cur += part + " "
            else:
                cur += s
        if cur.strip():
            out.append(cur.strip())
    merged = []
    for p in (p for p in out if re.search(r"\w", p)):
        if merged and len(p) < 40 and len(merged[-1]) + len(p) < max_chars + 60:
            merged[-1] += " " + p
        else:
            merged.append(p)
    return merged


def wav_bytes(pcm, rate):
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(pcm)
    return b.getvalue()


def free_vram_mb():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.free,memory.total", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=5).stdout.strip().splitlines()[0]
        free, total = (int(x) for x in out.split(","))
        return free, total
    except Exception:
        return None, None


# ---- a worker process: one loaded copy of the model ----
def worker_main(cfg, conn):
    try:
        from node.engine import make
        engine = make(cfg)
        conn.send(("ready", engine.sample_rate))
    except Exception as e:
        conn.send(("failed", f"{type(e).__name__}: {e}"))
        return
    while True:
        msg = conn.recv()
        if msg is None:
            return
        jid, job = msg
        t = time.time()
        try:
            pcm, rate = engine.speak(job)
            conn.send(("done", jid, pcm, rate, time.time() - t))
        except Exception as e:
            conn.send(("error", jid, f"{type(e).__name__}: {e}"[:500]))


class Worker:
    _ids = itertools.count(1)

    def __init__(self, pool):
        self.id = next(self._ids)
        self.pool, self.busy, self.ready, self.since = pool, False, False, time.time()
        self.parent, child = mp.get_context("spawn").Pipe()
        self.proc = mp.get_context("spawn").Process(target=worker_main, args=(pool.cfg, child), daemon=True)
        self.proc.start()

    async def recv(self):
        return await asyncio.get_running_loop().run_in_executor(None, self.parent.recv)

    def stop(self):
        try:
            self.parent.send(None)
        except Exception:
            pass
        self.proc.join(timeout=10)
        if self.proc.is_alive():
            self.proc.kill()


class Pool:
    def __init__(self, cfg):
        self.cfg, self.workers, self.loading = cfg, [], 0
        self.queue = asyncio.PriorityQueue()
        self.order = itertools.count()
        self.sample_rate = None
        self.done = 0
        self.last_error = None

    def busy(self):
        return sum(1 for w in self.workers if w.busy)

    def status(self):
        free, total = free_vram_mb()
        return {"ok": True, "name": self.cfg["name"], "version": VERSION, "python": sys.version.split()[0], "engine": "fake" if self.cfg["fake"] else "breeze-tts-2",
                "slots": self.cfg["slots"], "loaded": len(self.workers), "loading": self.loading, "busy": self.busy(),
                "queued": self.queue.qsize(), "done": self.done, "sample_rate": self.sample_rate,
                "vram": {"free_mb": free, "total_mb": total}, "last_error": self.last_error}

    def want_more(self):
        if len(self.workers) + self.loading >= self.cfg["slots"]:
            return False
        if self.loading:
            return False  # one at a time: loading is heavy
        idle = len(self.workers) - self.busy()
        if self.workers and self.queue.qsize() <= idle:
            return False  # the copies loaded can take what's waiting
        if not self.workers and self.loading == 0:
            return True
        free, _ = free_vram_mb()
        return self.cfg["fake"] or (free is not None and free >= self.cfg["slot_mb"])

    async def add_worker(self, counted=False):
        if not counted:
            self.loading += 1
        w = Worker(self)
        try:
            msg = await w.recv()
        except Exception as e:
            msg = ("failed", str(e))
        self.loading -= 1
        if msg[0] != "ready":
            self.last_error = "load failed: " + str(msg[1])
            print(f"[speech-node] {self.last_error}", flush=True)
            w.stop()
            return
        self.sample_rate = msg[1]
        w.ready = True
        self.workers.append(w)
        print(f"[speech-node] copy {w.id} loaded ({len(self.workers)} of {self.cfg['slots']})", flush=True)
        asyncio.create_task(self.serve(w))

    async def serve(self, w):
        while w in self.workers:
            try:
                _, _, item = await asyncio.wait_for(self.queue.get(), timeout=30)
            except asyncio.TimeoutError:
                continue
            if w not in self.workers:  # let go while waiting: hand the piece back
                await self.queue.put((item["prio"], next(self.order), item)); return
            w.busy, w.since = True, time.time()
            try:
                w.parent.send((item["id"], item["job"]))
                msg = await w.recv()
            except Exception as e:
                msg = ("error", item["id"], f"worker lost: {e}")
                self.workers.remove(w) if w in self.workers else None
            w.busy, w.since = False, time.time()
            if msg[0] == "done":
                self.done += 1
                item["future"].set_result((msg[2], msg[3], msg[4]))
            else:
                item["future"].set_exception(RuntimeError(msg[2]))
            if not w.proc.is_alive() and w in self.workers:
                self.workers.remove(w)
            self.maybe_grow()

    def maybe_grow(self):
        if self.want_more():
            self.loading += 1  # counted now, so a burst of requests can't start several loads at once
            asyncio.create_task(self.add_worker(counted=True))

    async def submit(self, job, prio):
        if self.queue.qsize() >= self.cfg["max_queued"]:
            raise HTTPException(503, "queue full")
        fut = asyncio.get_running_loop().create_future()
        await self.queue.put((-prio, next(self.order), {"id": next(self.order), "job": job, "future": fut, "prio": -prio}))
        self.maybe_grow()
        return await fut

    async def tend(self):
        """Keep min_loaded copies; let idle ones go after idle_minutes."""
        for _ in range(self.cfg["min_loaded"]):
            await self.add_worker()
        while True:
            await asyncio.sleep(30)
            for w in list(self.workers):
                if not w.proc.is_alive():
                    self.workers.remove(w)
                    self.last_error = f"copy {w.id} died"
            idle = [w for w in self.workers if not w.busy and time.time() - w.since > self.cfg["idle_minutes"] * 60]
            for w in idle[: max(0, len(self.workers) - self.cfg["min_loaded"])]:
                self.workers.remove(w)
                w.stop()
                print(f"[speech-node] copy {w.id} let go after idling", flush=True)
            if self.queue.qsize():
                self.maybe_grow()


def create_app(cfg):
    pool = Pool(cfg)

    @asynccontextmanager
    async def lifespan(app):
        tending = asyncio.create_task(pool.tend())
        yield
        tending.cancel()
        for w in list(pool.workers):
            w.stop()

    app = FastAPI(title="speech-node", version=VERSION, lifespan=lifespan)
    app.state.pool = pool
    refs = Path(cfg["cache_dir"])

    @app.get("/health")
    def health():
        return pool.status()

    @app.get("/refs/{sha}")
    def has_ref(sha: str):
        return Response(status_code=200 if (refs / f"{sha}.wav").exists() else 404)

    @app.put("/refs/{sha}")
    async def put_ref(sha: str, request: Request):
        body = await request.body()
        if not body or hashlib.sha256(body).hexdigest() != sha.lower():
            raise HTTPException(400, "the body's SHA-256 doesn't match the name")
        (refs / f"{sha.lower()}.wav").write_bytes(body)
        kept = sorted(refs.glob("*.wav"), key=lambda p: p.stat().st_mtime)
        for p in kept[: max(0, len(kept) - cfg["max_refs"])]:
            p.unlink(missing_ok=True)
        return {"ok": True}

    @app.post("/speak")
    async def speak(request: Request):
        b = await request.json()
        text = str(b.get("text") or "").strip()
        if not text:
            raise HTTPException(400, "text is empty")
        job = {"seed": int(b.get("seed", 7))}
        if b.get("cfg"):
            job["cfg"] = float(b["cfg"])
        if b.get("ref_sha"):
            ref = refs / f"{str(b['ref_sha']).lower()}.wav"
            if not ref.exists():
                return JSONResponse({"error": "ref_missing"}, status_code=409)
            if not str(b.get("ref_text") or "").strip():
                raise HTTPException(400, "ref_text is required with a reference")
            os.utime(ref)  # recently used
            job["ref_path"], job["ref_text"] = str(ref), str(b["ref_text"]).strip()
        if b.get("instruction"):
            job["instruction"] = str(b["instruction"]).strip()
        # The text is spoken as one piece unless "split": true asks for sentence-sized pieces spoken in parallel.
        parts = (pieces(text, int(b.get("max_chars") or cfg["max_chars"])) or [text]) if b.get("split") is True else [text]
        t = time.time()
        try:
            results = await asyncio.gather(*(pool.submit({**job, "text": p}, int(b.get("priority", 0))) for p in parts))
        except RuntimeError as e:
            raise HTTPException(500, str(e))
        rate = results[0][1]
        gap = b"\x00\x00" * int(rate * cfg["gap_ms"] / 1000)
        pcm = gap.join(r[0] for r in results)
        seconds = len(pcm) / 2 / rate
        headers = {"X-Sample-Rate": str(rate), "X-Audio-Seconds": f"{seconds:.2f}", "X-Took-Seconds": f"{time.time() - t:.2f}",
                   "X-Pieces": str(len(parts)), "X-Node": cfg["name"], "Cache-Control": "no-store"}
        if b.get("format") == "pcm":
            return Response(pcm, media_type="audio/pcm", headers=headers)
        return Response(wav_bytes(pcm, rate), media_type="audio/wav", headers=headers)

    return app


def main():
    cfg = load_config(sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SPEECH_NODE_CONFIG", "node.json"))
    import uvicorn
    print(f"[speech-node] {cfg['name']} on {cfg['host']}:{cfg['port']}, up to {cfg['slots']} copies"
          f"{' (fake engine)' if cfg['fake'] else ''}", flush=True)
    uvicorn.run(create_app(cfg), host=cfg["host"], port=cfg["port"], log_level="warning")


if __name__ == "__main__":
    main()

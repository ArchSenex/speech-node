"""The speech engine a worker process runs: Breeze TTS 2 (or a fake one, for tests and for building clients without a GPU).

speak(job) -> (pcm16 bytes, sample_rate); speak_iter(job) yields pcm16 chunks as they're made (for streaming).
A job: {"text", "seed", "cfg"?, "instruction"?, "ref_path"?, "ref_text"?}.
Voice design: an instruction (a description of the voice). Cloning: a reference clip and its exact transcript.
"""
import math
import time
import os
import sys
from pathlib import Path

import numpy as np

MAX_NEW_TOKENS = 1500
MAX_SEQ_LEN = 2048
REPETITION_PENALTY = 1.1


class FakeEngine:
    """No model: a soft tone as long as the text would take to say (about 15 characters a second)."""
    sample_rate = 24000

    def __init__(self, cfg):
        self.cfg = cfg

    def speak_iter(self, job):
        seconds = max(0.4, len(job["text"]) / 15.0)
        t = np.arange(int(seconds * self.sample_rate)) / self.sample_rate
        pcm = (0.1 * np.sin(2 * math.pi * (180 + (job.get("seed", 7) % 40) * 5) * t) * 32767).astype("<i2").tobytes()
        step = self.sample_rate // 5 * 2  # 0.2 s of audio at a time, taking a little time each, like a real engine
        for i in range(0, len(pcm), step):
            time.sleep(0.2 * float(self.cfg.get("fake_rtf", 0.02)))
            yield pcm[i:i + step]

    def speak(self, job):
        return b"".join(self.speak_iter(job)), self.sample_rate


class BreezeEngine:
    def __init__(self, cfg):
        repo = Path(cfg["breeze_repo"]).expanduser()
        os.chdir(repo)  # Breeze's code expects to run from its repo
        sys.path.insert(0, str(repo))
        from breeze_infer.runtime import load_runtime, resolve_device, set_all_seeds, update_generation_config_for_breeze
        from breeze_infer.templates import get_template, prepare_inputs, select_template_name
        from models.fast_streaming import FastBreezeStreamingRuntime, FastStreamingConfig

        self._set_seeds, self._get_template, self._prepare, self._select = set_all_seeds, get_template, prepare_inputs, select_template_name
        self.tokenizer, self.model, self.codec = load_runtime(Path(cfg["model_dir"]).expanduser(), device=resolve_device(), attn_implementation="eager")
        update_generation_config_for_breeze(self.model)
        fast = bool(cfg.get("fast", True))
        self.runtime = FastBreezeStreamingRuntime(
            self.model, self.codec,
            # max_new_tokens caps one generation (1500 is about 95 s of audio); max_seq_len counts the reference prompt too.
            # Both can be raised in node.json; the model's rope scaling may carry it past 2048, but that's to be listened for.
            FastStreamingConfig(max_new_tokens=int(cfg.get("max_new_tokens", MAX_NEW_TOKENS)), max_seq_len=int(cfg.get("max_seq_len", MAX_SEQ_LEN)),
                                repetition_penalty=REPETITION_PENALTY, fast_all=True if fast else None),
            tokenizer=self.tokenizer)
        # The fast path's CUDA graphs are captured as each prompt size first comes up (the first piece of a new size is
        # slower). Breeze's own warm-up profile isn't used: it declares only short prompts, and a cloning prompt (a
        # 20-30 s reference and its transcript) is longer than any of them, which the profile then refuses.
        self.sample_rate = self.runtime.sample_rate
        self._n = 0

    def speak_iter(self, job):
        self._n += 1
        req = {"id": f"node-{os.getpid()}-{self._n}", "text": job["text"], "speaker": "S0"}
        if job.get("instruction"):
            req["instruction"] = job["instruction"]
        if job.get("ref_path"):
            req["ref_audio_path"], req["ref_text"] = job["ref_path"], job["ref_text"]
        cfg = float(job.get("cfg") or (4.0 if job.get("instruction") and not job.get("ref_path") else 1.0))
        seed = int(job.get("seed", 7))
        self._set_seeds(seed)
        inputs = self._prepare(self.tokenizer, self.codec, self.model, [req], self._get_template(self._select(req)),
                               guidance_scale=cfg, guidance_scale_ref=None, guidance_scale_ins=None)
        self._set_seeds(seed)  # sampling starts from the seed, after all preparation (as Breeze's own server does)
        for c in self.runtime.iter_audio_chunks(inputs, request_id=req["id"], seed=seed):
            yield (np.clip(c.audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()

    def speak(self, job):
        return b"".join(self.speak_iter(job)) or b"\x00\x00", self.sample_rate


def make(cfg):
    return FakeEngine(cfg) if cfg.get("fake") else BreezeEngine(cfg)

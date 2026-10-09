"""speech-node on its fake engine (no GPU): the HTTP API, references, splitting, and growing to more loaded copies."""
import hashlib
import io
import time
import wave

import pytest
from fastapi.testclient import TestClient

from node.server import create_app, load_config, pieces


@pytest.fixture()
def client(tmp_path):
    cfg = load_config(None)
    cfg.update(fake=True, cache_dir=str(tmp_path), slots=2, min_loaded=1, name="test-node")
    with TestClient(create_app(cfg)) as c:
        for _ in range(100):  # the first copy loads in the background
            if c.get("/health").json()["loaded"]:
                break
            time.sleep(0.1)
        yield c


def seconds(wav):
    with wave.open(io.BytesIO(wav)) as w:
        return w.getnframes() / w.getframerate()


def test_pieces_pack_sentences_and_fold_scraps():
    text = "One. " * 3 + "A much longer sentence that goes on for a while, " * 6 + "End.\n\nNew paragraph here."
    out = pieces(text, 240)
    assert all(len(p) <= 300 for p in out)
    assert out[-1].endswith("New paragraph here.")
    assert pieces("Hi.", 240) == ["Hi."]


def test_health(client):
    h = client.get("/health").json()
    assert h["ok"] and h["engine"] == "fake" and h["slots"] == 2 and h["loaded"] >= 1


def test_speak_returns_wav_of_the_right_length(client):
    r = client.post("/speak", json={"text": "Hello there, this is a test of the fake engine."})
    assert r.status_code == 200 and r.headers["content-type"] == "audio/wav"
    assert abs(seconds(r.content) - float(r.headers["x-audio-seconds"])) < 0.05
    assert r.headers["x-node"] == "test-node"


LONG = " ".join(f"This is sentence number {i}, and it is long enough to matter." for i in range(12))


def test_split_long_text_is_spoken_in_pieces_and_grows_a_second_copy(client):
    r = client.post("/speak", json={"text": LONG, "split": True})
    assert r.status_code == 200 and int(r.headers["x-pieces"]) > 1
    for _ in range(100):
        if client.get("/health").json()["loaded"] == 2:
            break
        time.sleep(0.1)
    assert client.get("/health").json()["loaded"] == 2


def test_references_are_stored_by_hash_and_required_for_cloning(client):
    clip = b"RIFF fake clip bytes"
    sha = hashlib.sha256(clip).hexdigest()
    body = {"text": "Clone me.", "ref_sha": sha, "ref_text": "The transcript."}
    assert client.post("/speak", json=body).status_code == 409
    assert client.get(f"/refs/{sha}").status_code == 404
    assert client.put(f"/refs/{sha}", content=b"something else").status_code == 400
    assert client.put(f"/refs/{sha}", content=clip).status_code == 200
    assert client.get(f"/refs/{sha}").status_code == 200
    assert client.post("/speak", json=body).status_code == 200
    assert client.post("/speak", json={**body, "ref_text": ""}).status_code == 400


def test_pcm_format_and_empty_text(client):
    r = client.post("/speak", json={"text": "Raw please.", "format": "pcm"})
    assert r.status_code == 200 and r.headers["content-type"] == "audio/pcm" and int(r.headers["x-sample-rate"]) > 0
    assert client.post("/speak", json={"text": "  "}).status_code == 400


def test_by_default_the_text_is_spoken_as_one_piece(client):
    r = client.post("/speak", json={"text": LONG})
    assert r.status_code == 200 and r.headers["x-pieces"] == "1"

"""Optional speaker diarization for Notra takes.

Whisper gives text and timings but no notion of *who* spoke. This labels each
transcript segment with an anonymous speaker (Speaker 1, Speaker 2 …) by
embedding every segment with SpeechBrain's ECAPA-TDNN model and clustering the
embeddings.

It needs optional dependencies, so everything degrades to "no speaker labels"
rather than failing:

    uv pip install --python .venv-ai/Scripts/python.exe torch torchaudio \
        --index-url https://download.pytorch.org/whl/cpu
    uv pip install --python .venv-ai/Scripts/python.exe speechbrain scikit-learn

Anonymous clustering, not recognition: no voiceprints are stored, and nobody is
identified by name.
"""
from __future__ import annotations

import sys

MIN_SEGMENT = 0.35   # shorter segments make unreliable embeddings
# If even the *most* similar pair of clusters looks like the same voice, this is a
# single speaker and we leave the labels off rather than invent a second person.
SAME_SPEAKER_SIM = 0.45

_encoder = None


def available() -> bool:
    try:
        import numpy  # noqa: F401
        import sklearn  # noqa: F401
        import torch  # noqa: F401
        import torchaudio  # noqa: F401
        import speechbrain  # noqa: F401
        return True
    except Exception:
        return False


def _load_encoder():
    global _encoder
    if _encoder is None:
        import torch
        from speechbrain.inference.speaker import EncoderClassifier
        from speechbrain.utils.fetching import FetchConfig, LocalStrategy

        # Windows without symlink privileges cannot use SpeechBrain's default
        # "symlink" fetch strategy, so copy instead.
        _encoder = EncoderClassifier.from_hparams(
            source="speechbrain/spkrec-ecapa-voxceleb",
            savedir=str(
                (__import__("pathlib").Path.home() / ".cache" / "notra" / "speechbrain")
            ),
            run_opts={"device": "cpu"},
            local_strategy=LocalStrategy.COPY,
            fetch_config=FetchConfig(allow_updates=True),
        )
    return _encoder


def label_speakers(wav_path: str, segments, max_speakers: int = 4):
    """Assign `speaker` to each segment. Returns the segments or None.

    `segments` is the list of dicts from the transcript (`start`, `end`, `text`).
    """
    if not available():
        return None
    try:
        import numpy as np
        import soundfile as sf
        import torch
        from sklearn.cluster import AgglomerativeClustering

        audio, rate = sf.read(wav_path, dtype="float32", always_2d=False)
        if rate != 16000:
            return None
        encoder = _load_encoder()

        kept, embeddings = [], []
        for seg in segments:
            start = float(seg.get("start") or 0)
            end = float(seg.get("end") or 0)
            if end - start < MIN_SEGMENT:
                continue
            chunk = audio[int(start * rate) : int(end * rate)]
            if len(chunk) < int(MIN_SEGMENT * rate):
                continue
            with torch.no_grad():
                emb = encoder.encode_batch(torch.tensor(chunk).unsqueeze(0)).squeeze().cpu().numpy()
            emb = emb / (np.linalg.norm(emb) + 1e-9)
            kept.append(seg)
            embeddings.append(emb)

        if len(embeddings) < 2:
            return None

        X = np.vstack(embeddings)
        best = None
        for k in range(2, min(max_speakers, len(X)) + 1):
            model = AgglomerativeClustering(n_clusters=k, metric="cosine", linkage="average")
            labels = model.fit_predict(X)
            # prefer the split with the strongest separation between clusters
            sims = []
            for a in range(k):
                for b in range(a + 1, k):
                    ca, cb = X[labels == a], X[labels == b]
                    if len(ca) and len(cb):
                        sims.append(float(np.mean(ca @ cb.T)))
            if not sims:
                continue
            worst = max(sims)
            if best is None or worst < best[0] - 0.02:
                best = (worst, labels)

        if best is None or best[0] > SAME_SPEAKER_SIM:
            return None  # one voice
        labels = best[1]
        # stable numbering by first appearance
        order: dict[int, int] = {}
        for lbl in labels:
            order.setdefault(int(lbl), len(order) + 1)
        for seg, lbl in zip(kept, labels, strict=False):
            seg["speaker"] = f"Speaker {order[int(lbl)]}"
        return segments
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"diarization skipped: {type(exc).__name__}: {exc}\n")
        return None

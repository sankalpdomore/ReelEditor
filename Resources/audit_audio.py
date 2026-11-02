"""Audits a reel's transcript against its sound, the Mac app's port of the web editor's tools/reel-tools/audit-audio.py
(23 Oct 2026), so the speech the transcript missed is found without Sankalp pointing at it.

usage: python audit_audio.py <spec.json> <report.json>

The spec is written by the reel-editor's audit_audio tool: {"asr": transcribe_whisperx.py, "clips": [{"clip", "label",
"wav", "in", "out", "editStart", "words": [{"w", "s", "e"}]}], "from", "to"}, wav being the sound of its file at 16 kHz mono, times of words in the clip's source
seconds and from and to in edit seconds. For every clip it measures where the sound is speech (15 dB over the quiet
floor) and flags two things:
  1. a stretched word: a word the aligner drew over more than 0.8 s with more than 0.5 s of speech inside it, which is
     where a repeated phrase or a retake hides;
  2. speech outside every word: a loud stretch of 0.3 s or more that no word covers, a sentence the transcript dropped.
Each flagged window, padded by 0.3 s, is transcribed again on its own, so the report says what is said there. The
Whisper model is loaded once for the whole audit (WHISPERX_MODEL, small by default). Nothing in the reel changes.
"""
import importlib.util, json, os, sys, wave

import numpy as np


def load_asr(path):
    spec = importlib.util.spec_from_file_location("transcribe_whisperx", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # sets the cache folders and imports whisperx
    return mod


def read_wav(path):
    """16 kHz mono 16 bit PCM, as the app writes it, read without ffmpeg."""
    with wave.open(path, "rb") as f:
        return np.frombuffer(f.readframes(f.getnframes()), dtype="<i2").astype(np.float32) / 32768.0


def loud_mask(audio):
    n = len(audio) // 160
    if n == 0:
        return np.zeros(0, dtype=bool)
    db = 20 * np.log10(np.sqrt((audio[: n * 160].reshape(n, 160) ** 2).mean(1) + 1e-12))
    return db > np.percentile(db, 10) + 15  # one value per 10 ms


def runs(mask, min_len):
    out, start = [], None
    for i, v in enumerate(list(mask) + [False]):
        if v and start is None:
            start = i
        elif not v and start is not None:
            if i - start >= min_len:
                out.append((start / 100, i / 100))
            start = None
    return out


def main():
    spec = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    asr = load_asr(spec["asr"])
    whisperx = asr.whisperx
    lo, hi = spec.get("from"), spec.get("to")
    model = None
    audios = {}
    report = []
    for clip in spec["clips"]:
        file, ws = clip["wav"], clip["words"]
        cin, cout, at = float(clip["in"]), float(clip["out"]), float(clip["editStart"])
        # Only the part of the clip inside the edit range asked for.
        a0 = cin if lo is None else max(cin, cin + lo - at)
        a1 = cout if hi is None else min(cout, cin + hi - at)
        if a1 <= a0 or not ws:
            continue
        if file not in audios:
            audios[file] = read_wav(file)
        audio = audios[file]
        loud = loud_mask(audio)
        flags = []
        for w in ws:
            if w["e"] - w["s"] > 0.8 and a0 <= w["s"] < a1:
                inside = loud[int(w["s"] * 100): int(w["e"] * 100)].sum() / 100
                if inside > 0.5:
                    flags.append((w["s"], w["e"], f'stretched word "{w["w"]}", {w["e"] - w["s"]:.1f} s long with {inside:.1f} s of speech'))
        covered = np.zeros_like(loud)
        for w in ws:
            covered[int(w["s"] * 100): int(w["e"] * 100) + 1] = True
        for a, b in runs(loud & ~covered, 30):
            if a0 <= a < a1:
                flags.append((a, b, f"speech no word covers, {b - a:.1f} s"))
        for a, b, why in sorted(flags):
            # Where the audit is listening now, in edit seconds, read by the app to light up that paragraph.
            print(f"checking {at + a - cin:.2f} {at + b - cin:.2f}", file=sys.stderr, flush=True)
            if model is None:
                model = whisperx.load_model(os.environ.get("WHISPERX_MODEL", "small"), "cpu", compute_type=os.environ.get("WHISPERX_COMPUTE", "int8"),
                                            language="en", vad_method="pyannote", download_root=os.path.join(os.environ["HF_HOME"], "ct2"))
            s, e = max(0.0, a - 0.3), b + 0.3
            piece = audio[int(s * 16000): int(e * 16000)]
            heard = ""
            if len(piece) > 1600:
                res = model.transcribe(piece, batch_size=8, language="en")
                heard = " ".join(seg["text"].strip() for seg in res.get("segments", [])).strip()
            report.append({"clip": clip["clip"], "label": clip.get("label", ""), "source_start": round(a, 2), "source_end": round(b, 2),
                           "edit_start": round(at + a - cin, 2), "edit_end": round(at + b - cin, 2), "why": why, "heard": heard})
            print(f"{len(report)} found", file=sys.stderr, flush=True)
    json.dump(report, open(out, "w"), indent=1)
    print(len(report), "found")


if __name__ == "__main__":
    main()

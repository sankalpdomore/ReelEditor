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

A third check finds a phrase said twice that the transcript writes once (Sankalp, 4 Nov 2026). Whisper tidies speech: it
writes a repeated phrase or a restarted sentence once and spreads its word times over both takes, so no word is stretched
and no speech is left uncovered, and the two checks above miss it ("That's all for. That's all for today."). The
wav2vec2 model WhisperX aligns with also reads letters straight off the sound, greedily, with no language model, so it
keeps every repeat; it spells badly but takes under a second for half a minute of sound. Its letters are lined up with the
transcript's, and a stretch where it heard 8 or more letters the transcript does not have is a spot, reported with the
transcript's words and the heard words around it (kind unwritten) for the reel-editor to have Claude Sonnet say what was said.
"""
import difflib, importlib.util, json, os, sys, wave

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


def heard_letters(model, meta, audio, a0, a1, chunk=25.0):
    """Every letter wav2vec2 hears from a0 to a1 seconds, greedily, with its time: [(letter or space, seconds)]. The sound
    is read in pieces of up to 25 s, each ending at the quietest 10 ms of its last 4 s so no word is split."""
    import torch
    labels = {v: k for k, v in meta["dictionary"].items()}
    a1 = min(a1, len(audio) / 16000)
    out, t = [], a0
    while t < a1 - 0.05:
        e = min(a1, t + chunk)
        if e < a1:
            seg = audio[int((e - 4) * 16000): int(e * 16000)]
            n = len(seg) // 160
            if n:
                e = e - 4 + int(np.argmin((seg[: n * 160].reshape(n, 160) ** 2).mean(1))) * 0.01 + 0.005
        piece = torch.from_numpy(audio[int(t * 16000): int(e * 16000)].copy())[None]
        if piece.shape[1] >= 400:
            with torch.inference_mode():
                ids = model(piece)[0][0].argmax(-1).tolist()
            step = piece.shape[1] / 16000 / max(1, len(ids))
            prev = None
            for i, c in enumerate(ids):
                if c != prev:
                    ch = labels.get(c, "")
                    if ch == "|":
                        out.append((" ", t + i * step))
                    elif len(ch) == 1 and (ch.isalpha() or ch == "'"):
                        out.append((ch.lower(), t + i * step))
                prev = c
        out.append((" ", e))
        t = e
    return out


def heard_words(letters):
    """The heard letters as words with their start and end: [(start, end, word)]."""
    out, w, st, last = [], "", None, None
    for c, t in letters + [(" ", None)]:
        if c == " ":
            if w:
                out.append((st, (t if t is not None and t - last < 0.3 else last + 0.06), w))
            w = ""
        else:
            if not w:
                st = t
            w += c
            last = t
    return out


def written_letters(asr, words):
    """The transcript's words as the letters they sound like, each with a time inside its word."""
    out = []
    for w in words:
        sp = " ".join(asr.spoken_form(w["w"]))
        for k, ch in enumerate(sp):
            out.append((ch, w["s"] + (w["e"] - w["s"]) * k / max(1, len(sp))))
        out.append((" ", w["e"]))
    return out


def unwritten(heard, written, min_extra=8, join=0.6):
    """Stretches where more letters were heard than the transcript has: [(start, end, extra letters)]. Only letters heard
    beyond the transcript count; letters the listener missed, which it often does in fast speech, never cancel them."""
    H = [(c, t) for c, t in heard if c != " "]
    T = [(c, t) for c, t in written if c != " "]
    sm = difflib.SequenceMatcher(None, "".join(c for c, _ in T), "".join(c for c, _ in H), autojunk=False)
    merged = []
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "equal":
            continue
        extra = max(0, (j2 - j1) - (i2 - i1))
        s, e = (H[j1][1], H[j2 - 1][1] + 0.06) if j2 > j1 else (T[i1][1], T[i1][1])
        if merged and s - merged[-1][1] < join:
            merged[-1][1] = max(merged[-1][1], e)
            merged[-1][2] += extra
        else:
            merged.append([s, e, extra])
    return [(s, e, x) for s, e, x in merged if x >= min_extra]


def main():
    spec = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    asr = load_asr(spec["asr"])
    whisperx = asr.whisperx
    lo, hi = spec.get("from"), spec.get("to")
    model = None
    align = None
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
        # A phrase heard more often than the transcript writes it; a stretched word or uncovered speech inside such a spot
        # is the same finding, so it is reported once, as the spot.
        if align is None:
            align = whisperx.load_align_model("en", "cpu")
        print(f"checking {at:.2f} {at + a1 - a0:.2f}", file=sys.stderr, flush=True)
        heard = heard_letters(align[0], align[1], audio, a0, a1)
        inside = [w for w in ws if a0 <= w["s"] < a1]
        spots = unwritten(heard, written_letters(asr, inside))
        hw = heard_words(heard)
        for a, b, extra in spots:
            flags = [f for f in flags if f[1] < a - 0.3 or f[0] > b + 0.3]
            near = lambda s, e: s < b + 1.5 and e > a - 3.0  # 3 s before: the earlier take sits before the spot
            report.append({"clip": clip["clip"], "label": clip.get("label", ""), "kind": "unwritten",
                           "source_start": round(a, 2), "source_end": round(b, 2), "edit_start": round(at + a - cin, 2), "edit_end": round(at + b - cin, 2),
                           "why": f"{extra} more letters heard than the transcript has, where a phrase said twice or a restart hides",
                           "heard": " ".join(w for s, e, w in hw if near(s, e)),
                           "transcript_words": [[round(w["s"], 2), round(w["e"], 2), w["w"]] for w in inside if near(w["s"], w["e"])],
                           "heard_words": [[round(s, 2), round(e, 2), w] for s, e, w in hw if near(s, e)]})
            print(f"{len(report)} found", file=sys.stderr, flush=True)
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
            report.append({"clip": clip["clip"], "label": clip.get("label", ""), "kind": "stretched" if why.startswith("stretched") else "uncovered", "source_start": round(a, 2), "source_end": round(b, 2),
                           "edit_start": round(at + a - cin, 2), "edit_end": round(at + b - cin, 2), "why": why, "heard": heard})
            print(f"{len(report)} found", file=sys.stderr, flush=True)
    json.dump(report, open(out, "w"), indent=1)
    print(len(report), "found")


if __name__ == "__main__":
    main()

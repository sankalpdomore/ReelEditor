"""Word level timestamps for a reel's audio, written as JSON, using WhisperX.

Drop in replacement for transcribe.py with the same command line and the same output
(a list of {"w": word, "s": start seconds, "e": end seconds}).

usage: python transcribe_whisperx.py <audio.wav> <words.json> [script.txt]

Run it with the WhisperX venv:
  "/Users/sankalpsinha/Coding projects/WhisperX/venv/bin/python" transcribe_whisperx.py <audio.wav> <words.json> [script.txt]

Two modes:
  transcribe (default)   pyannote VAD -> faster-whisper (CTranslate2, int8, CPU) -> wav2vec2 CTC forced alignment.
                         The VAD stops Whisper inventing text over silence and music, the CTC step measures every
                         word boundary against the audio instead of using Whisper's drifting attention timings.
  force align (3rd arg)  the third argument is a text file with the exact script. No transcription happens: the
                         script's words are placed on the audio with the same wav2vec2 CTC aligner. This is the best
                         mode for AI voice videos, where the text is known in advance. Text is kept exactly as
                         written (punctuation, casing, digits and "NextDoor.Company" survive); spoken forms are
                         only used internally to align. Words come back one per whitespace separated script token.

Optional environment variables (all have defaults, the command line never needs them):
  WHISPERX_MODEL     faster-whisper model for transcribe mode. Default large-v3-turbo (small is the lighter choice).
  WHISPERX_PROMPT    vocabulary hint for transcribe mode, text or @path/to/file. Product and place names you
                     expect ("NextDoor.Company, Zscaler, Synthio Labs"). Fixes most name misspellings.
  WHISPERX_COMPUTE   CTranslate2 compute type. Default int8 (the only sensible one on a Mac CPU).
  WHISPERX_ALIGN_DEVICE  cpu (default) or mps. Same result, cpu is as fast for short audio.
  WHISPERX_HOME      folder holding hf-cache. Default /Users/sankalpsinha/Coding projects/WhisperX

No Hugging Face token is needed: the VAD weights ship inside the whisperx package, and speaker diarization
(the only gated model) is not used.
"""
import json, os, re, sys

HOME = os.environ.get("WHISPERX_HOME", "/Users/sankalpsinha/Coding projects/WhisperX")
os.environ.setdefault("HF_HOME", os.path.join(HOME, "hf-cache"))
os.environ.setdefault("TORCH_HOME", os.path.join(HOME, "hf-cache", "torch"))
os.environ.setdefault("NLTK_DATA", os.path.join(HOME, "hf-cache", "nltk_data"))
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("PYTHONWARNINGS", "ignore")

try:
    import whisperx
except ImportError:
    sys.exit("whisperx is not importable. Run this with the WhisperX venv python:\n"
             f'  "{HOME}/venv/bin/python" {sys.argv[0]} <audio.wav> <words.json> [script.txt]')

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def num_words(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000:
        return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + num_words(n % 100))
    if 1100 <= n <= 2099 and n % 100 != 0 and n // 100 != 20:
        return num_words(n // 100) + " " + (("oh " + ONES[n % 100]) if n % 100 < 10 else num_words(n % 100))
    if n < 1_000_000:
        return num_words(n // 1000) + " thousand" + ("" if n % 1000 == 0 else " " + num_words(n % 1000))
    return " ".join(ONES[int(c)] for c in str(n))


def spoken_form(token):
    """What a script token sounds like, as plain a-z words, for the wav2vec2 aligner only."""
    t = token.lower().replace("’", "'")
    t = re.sub(r"(\d+)%", lambda m: m.group(1) + " percent", t)
    t = re.sub(r"\$(\d+)", lambda m: m.group(1) + " dollars", t)
    t = re.sub(r"(?<=\d),(?=\d{3})", "", t)
    t = re.sub(r"\d+", lambda m: " " + num_words(int(m.group())) + " ", t)
    t = t.replace("&", " and ")
    t = re.sub(r"[-_/]", " ", t)
    t = re.sub(r"[^a-z' ]", "", t)  # drops dots, so NextDoor.Company -> nextdoorcompany
    return [w.strip("'") for w in t.split() if w.strip("'")]


def clean(words, dur):
    """Make times safe for an editor: no gaps in data, monotonic starts, no overlaps, no zero length words."""
    n = len(words)
    for i, w in enumerate(words):  # fill missing times from neighbours
        if w["s"] is None or w["e"] is None:
            prev = next((words[j]["e"] for j in range(i - 1, -1, -1) if words[j]["e"] is not None), 0.0)
            nxt = next((words[j]["s"] for j in range(i + 1, n) if words[j]["s"] is not None), dur)
            w["s"], w["e"] = prev, max(prev, nxt)
    last = 0.0
    for i, w in enumerate(words):
        w["s"] = min(max(w["s"], last), dur)
        w["e"] = min(max(w["e"], w["s"] + 0.02), dur)
        if i + 1 < n and words[i + 1]["s"] is not None and words[i + 1]["s"] < w["e"]:
            w["e"] = max(w["s"] + 0.01, min(w["e"], words[i + 1]["s"]))
        last = w["s"]
    for w in words:
        w["s"], w["e"] = round(w["s"], 3), round(w["e"], 3)
    return words


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: python transcribe_whisperx.py <audio.wav> <words.json> [script.txt]")
    src, out = sys.argv[1], sys.argv[2]
    script = sys.argv[3] if len(sys.argv) > 3 else None
    align_device = os.environ.get("WHISPERX_ALIGN_DEVICE", "cpu")
    audio = whisperx.load_audio(src)  # 16 kHz mono float32 through ffmpeg
    dur = len(audio) / 16000
    align_model, meta = whisperx.load_align_model("en", align_device)  # wav2vec2-base-960h

    if script:
        raw = open(script, encoding="utf-8").read()
        tokens = raw.split()
        spoken, owner = [], []
        for i, tok in enumerate(tokens):
            for sw in spoken_form(tok):
                spoken.append(sw)
                owner.append(i)
        if not spoken:
            sys.exit("the script has no words to align")
        res = whisperx.align([{"start": 0.0, "end": dur, "text": " ".join(spoken)}], align_model, meta, audio, align_device)
        aligned = res["word_segments"]
        if len(aligned) != len(spoken):
            sys.exit(f"alignment returned {len(aligned)} words for {len(spoken)} script words")
        words = [{"w": t, "s": None, "e": None} for t in tokens]
        low = 0
        for a, i in zip(aligned, owner):
            w = words[i]
            if a.get("start") is not None and (w["s"] is None or a["start"] < w["s"]):
                w["s"] = float(a["start"])
            if a.get("end") is not None and (w["e"] is None or a["end"] > w["e"]):
                w["e"] = float(a["end"])
            if a.get("score") is not None and a["score"] < 0.3:
                low += 1
        if low:
            print(f"warning: {low} of {len(spoken)} script words aligned with low confidence (below 0.3). "
                  "If the speaker went off script, the timings around those words are guesses.", file=sys.stderr)
    else:
        model_name = os.environ.get("WHISPERX_MODEL", "large-v3-turbo")
        prompt = os.environ.get("WHISPERX_PROMPT")
        if prompt and prompt.startswith("@"):
            prompt = open(prompt[1:], encoding="utf-8").read().strip()
        opts = {"initial_prompt": prompt} if prompt else {}
        model = whisperx.load_model(model_name, "cpu", compute_type=os.environ.get("WHISPERX_COMPUTE", "int8"),
                                    language="en", asr_options=opts, vad_method="pyannote",
                                    download_root=os.path.join(os.environ["HF_HOME"], "ct2"))
        result = model.transcribe(audio, batch_size=8, language="en")
        if not result["segments"]:
            json.dump([], open(out, "w"))
            print("0 words")
            return
        res = whisperx.align(result["segments"], align_model, meta, audio, align_device)
        words = [{"w": w["word"], "s": w.get("start"), "e": w.get("end")} for w in res["word_segments"]]

    words = clean(words, dur)
    json.dump(words, open(out, "w"), indent=1)
    print(len(words), "words")


if __name__ == "__main__":
    main()

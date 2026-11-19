# The chance someone is speaking every 32 ms of a sound, with the Silero speech detector that faster-whisper ships
# (Sankalp, 19 Nov 2026). Reel Editor fits each caption word to the speech this finds (Sources/ReelCore/Voice.swift).
# Reads 16 kHz mono 16 bit samples, writes one little endian float32 per 512 samples. Loads only the ONNX model and
# onnxruntime, not faster-whisper itself, so it starts in a moment.
# usage: python speech_vad.py <samples.s16> <out.f32>
import importlib.util
import os
import sys

import numpy as np
import onnxruntime

spec = importlib.util.find_spec("faster_whisper")
if spec is None or not spec.submodule_search_locations:
    sys.exit("faster-whisper is not installed in this Python")
model = os.path.join(list(spec.submodule_search_locations)[0], "assets", "silero_vad_v6.onnx")
if not os.path.exists(model):
    sys.exit("The Silero model is not in faster-whisper's assets")

N, CONTEXT = 512, 64
audio = np.fromfile(sys.argv[1], dtype="<i2").astype("float32") / 32768
audio = np.pad(audio, (0, N - audio.shape[0] % N))

opts = onnxruntime.SessionOptions()
opts.inter_op_num_threads = 1
opts.intra_op_num_threads = 2
opts.log_severity_level = 4
session = onnxruntime.InferenceSession(model, providers=["CPUExecutionProvider"], sess_options=opts)

# The same batching as faster-whisper's SileroVADModel: each window with the 64 samples before it.
windows = audio.reshape(-1, N)
context = windows[..., -CONTEXT:].copy()
context[-1] = 0
context = np.roll(context, 1, 0)
batched = np.concatenate([context, windows], 1)
h = np.zeros((1, 1, 128), dtype="float32")
c = np.zeros((1, 1, 128), dtype="float32")
out = []
for i in range(0, batched.shape[0], 10000):
    o, h, c = session.run(None, {"input": batched[i:i + 10000], "h": h, "c": c})
    out.append(o)
probs = np.concatenate(out, axis=0).reshape(-1).astype("<f4")
probs.tofile(sys.argv[2])

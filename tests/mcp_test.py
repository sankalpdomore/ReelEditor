#!/usr/bin/env python3
# Drives reel-mcp over stdio and checks every tool: results, the project file, schema rejection, undo and redo, exports
# with ffprobe, sampled frames and audio levels. The media it uses are in tests/media, only ever read.
#   swift build && python3 tests/mcp_test.py .build/debug/reel-mcp <scratch folder>
import json, os, re, shutil, subprocess, sys, time

BIN, SCRATCH = sys.argv[1], sys.argv[2]
HOME = os.path.join(SCRATCH, "home")
MEDIA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "media")
def doc(n):
    return json.load(open(os.path.join(HOME, n + ".reel.json")))
shutil.rmtree(HOME, ignore_errors=True)
os.makedirs(HOME)
os.makedirs(os.path.join(HOME, "_music"))
shutil.copy(os.path.join(MEDIA, "music.m4a"), os.path.join(HOME, "_music", "bed.m4a"))
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env = dict(os.environ, REEL_EDITOR_HOME=HOME, REEL_EDITOR_NO_OPEN="1",
           REEL_WHISPERX_SCRIPT=os.path.join(REPO, "Resources", "transcribe_whisperx.py"), REEL_AUDIT_SCRIPT=os.path.join(REPO, "Resources", "audit_audio.py"))
proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True, bufsize=1)
nid = 0
results = []
called = set()


def rpc(method, params=None):
    global nid
    nid += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": nid, "method": method, "params": params or {}}) + "\n")
    proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError("server closed")
        msg = json.loads(line)
        if msg.get("id") == nid:
            return msg


def call(name, args=None):
    called.add(name)
    m = rpc("tools/call", {"name": name, "arguments": args or {}})
    r = m["result"]
    text = r["content"][0]["text"]
    if r.get("isError"):
        return False, text
    return True, r.get("structuredContent", json.loads(text))


def check(label, cond, detail=""):
    results.append((label, bool(cond), detail))
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else "  :: " + str(detail)[:400]))


def ok(name, args=None, label=None):
    good, r = call(name, args)
    check(label or name, good, r)
    return r if good else {}


def bad(name, args, expect_code, label=None):
    good, r = call(name, args)
    check(label or f"{name} rejects {expect_code}", (not good) and str(r).startswith(expect_code), r)


def pj(n):
    return doc(n)["project"]


def past(n):
    try:
        return len(doc(n).get("history", {}).get("past", []))
    except FileNotFoundError:
        return 0


def pixel(file, t, x, y):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(t), "-i", file, "-frames:v", "1", "-vf", f"format=rgb24,crop=1:1:{x}:{y}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    return tuple(raw[:3]) if len(raw) >= 3 else None


def band_dark(file, t, y0, y1, w):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(t), "-i", file, "-frames:v", "1", "-vf", f"format=rgb24,crop={w}:{y1 - y0}:0:{y0}", "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True).stdout
    return sum(1 for b in raw if b < 30) / max(1, len(raw))


def band_yellow(file, t, y0, y1, w):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(t), "-i", file, "-frames:v", "1", "-vf", f"format=rgb24,crop={w}:{y1 - y0}:0:{y0}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    n = len(raw) // 3
    return sum(1 for i in range(n) if raw[3 * i] > 180 and raw[3 * i + 1] > 180 and raw[3 * i + 2] < 90) / max(1, n)


def volume(file, ss=None, t=None):
    args = ["ffmpeg", "-v", "info"] + (["-ss", str(ss)] if ss is not None else []) + ["-i", file] + (["-t", str(t)] if t else []) + ["-af", "volumedetect", "-f", "null", "-"]
    err = subprocess.run(args, capture_output=True, text=True).stderr
    mean = re.search(r"mean_volume: (-?[\d.]+|-inf) dB", err)
    mx = re.search(r"max_volume: (-?[\d.]+|-inf) dB", err)
    f = lambda m: -200.0 if not m or m.group(1) == "-inf" else float(m.group(1))
    return f(mean), f(mx)


def probe(file):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type,width,height", "-of", "json", file], capture_output=True, text=True).stdout
    return json.loads(out)


def export(n, **kw):
    r = ok("export", dict({"project": n, "wait": True}, **kw), f"export {n} {kw}")
    return r.get("result", {})


# ---------------------------------------------------------------------------------------------------------------------
init = rpc("initialize", {"protocolVersion": "2025-06-18", "clientInfo": {"name": "mcp-test", "version": "1"}})
check("initialize", "result" in init, init)
tools = rpc("tools/list")["result"]["tools"]
names = {t["name"] for t in tools}
web_missing = "add_comment add_face_overlay approve_cuts check_sources create_draft_reel edit_comment get_draft_reel get_timeline import_video list_comments list_reels list_video_looks open_project_folder record_generation_cost relink_source rename_reel reopen_comment resolve_comment reveal_in_finder save_video_look set_caption_position set_clip_look set_clip_placement set_clip_title set_draft_need_status set_draft_published set_draft_section_status set_face_window set_music set_reel_caption set_reel_status set_references set_title_text set_video_look set_voice_eq set_voice_gain split_overlay".split()
check("tools/list has every web tool", all(n in names for n in web_missing), [n for n in web_missing if n not in names])
check("every schema is an object with additionalProperties false", all(t["inputSchema"].get("type") == "object" and t["inputSchema"].get("additionalProperties") is False for t in tools))
check("no em dash in any description", not any("—" in t["description"] or "—" in json.dumps(t["inputSchema"]) for t in tools))
print(f"{len(tools)} tools")

# ---------------------------------------------------------------------------------------------------------------------
# A project, the old tools
r = ok("create_project", {"path": f"{MEDIA}/blue.mp4", "name": "blue", "transcribe": False})
B = "blue"
check("create_project origin recorded", pj(B)["main"].get("origin", "").endswith("blue.mp4"), pj(B)["main"])
r = ok("import_video", {"path": f"{MEDIA}/test.mp4", "name": "colour", "transcribe": False, "link": False}, "import_video (alias, copy)")
check("import_video link false copies the video", pj("colour")["main"]["file"].endswith("colour source.mp4") and os.path.exists(os.path.join(HOME, "colour source.mp4")), pj("colour")["main"])
bad("create_project", {"path": f"{MEDIA}/blue.mp4", "name": "blue", "transcribe": False}, "exists")
r = ok("list_projects")
check("list_projects lists both", {p["name"] for p in r.get("projects", [])} >= {"blue", "colour"}, r)
r = ok("list_reels")
check("list_reels has reels", len(r.get("reels", [])) >= 2, r)
r = ok("get_project", {"project": B})
check("get_project new fields", all(k in r for k in ["look", "music", "voiceGain", "captionPos", "status", "references", "pendingWords", "titleHides", "comments"]), list(r.keys()))
r = ok("get_timeline", {"reel": B, "words": False}, "get_timeline with reel")
check("reel taken as project", r.get("project") == B, r.get("project"))
words = [{"w": w, "s": i * 0.5 + 0.05, "e": i * 0.5 + 0.45} for i, w in enumerate("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen".split())]
json.dump(words, open(os.path.join(SCRATCH, "words.json"), "w"))
ok("import_transcript", {"project": B, "path": os.path.join(SCRATCH, "words.json")})
r = ok("get_project", {"project": B})
check("words imported", len(r.get("words", [])) == 15, len(r.get("words", [])))
# Reading the words a page at a time, with the pauses between them (2 Nov 2026).
r = ok("get_words", {"project": B, "limit": 5})
lines = r.get("text", "").split("\n")
check("get_words gives index start end word lines", lines[0] == "0 0.05 0.45 one" and r.get("shown") == 5 and r.get("nextStart") == 5 and r.get("totalWords") == 15, r)
r = ok("get_words", {"project": B, "start": 13}, "get_words from a word index")
check("get_words from start reads to the end without a next page", r.get("text", "").split("\n")[0].startswith("13 ") and r.get("shown") == 2 and "nextStart" not in r, r)
r = ok("get_words", {"project": B, "from": 2.0, "to": 3.0, "pause": 0.1}, "get_words between two times with pauses")
check("get_words keeps to from and to and lists pauses, the one before the page too", r.get("text", "").split("\n") == ["pause 0.10 s, 1.95 to 2.05", "4 2.05 2.45 five", "pause 0.10 s, 2.45 to 2.55", "5 2.55 2.95 six"] and "pause 0.10 s, 2.45 to 2.55" in r.get("text", "") and r.get("shown") == 2, r)
# Paragraphs and what Claude is working on, shown in the app's transcript (2 Nov 2026).
focus_file = os.path.join(HOME, "_cache", B, "focus.json")
r = ok("get_paragraphs", {"project": B})
check("get_paragraphs lists the app's paragraphs with their words and times", r.get("count") == 1 and r["paragraphs"][0]["firstWord"] == 0 and r["paragraphs"][0]["lastWord"] == 14 and r["paragraphs"][0]["start"] == 0.05 and r["paragraphs"][0]["opens"].startswith("one two"), r)
r = ok("get_words", {"project": B, "paragraph": 0}, "get_words of one paragraph")
check("get_words paragraph reads it whole and shows Claude reading it", r.get("shown") == 15 and json.load(open(focus_file))["action"] == "Reading paragraph 1 of 1", (r.get("shown"), open(focus_file).read() if os.path.exists(focus_file) else None))
bad("get_words", {"project": B, "paragraph": 5}, "not_found", "get_words of a paragraph that is not there")
r = ok("set_focus", {"project": B, "action": "Checking the joins", "from": 2, "to": 4})
f = json.load(open(focus_file))
check("set_focus shows Claude's own words over the span of those words", f["action"] == "Checking the joins" and f["start"] == 1.05 and f["end"] == 2.45 and f["by"], f)
ok("set_focus", {"project": B, "done": True}, "set_focus done")
check("set_focus done clears it", not os.path.exists(focus_file))
bad("set_focus", {"project": B, "action": "x"}, "invalid_input", "set_focus needs a span")
long_words = [{"w": f"w{i}", "s": i * 0.002, "e": i * 0.002 + 0.001} for i in range(1600)]
json.dump(long_words, open(os.path.join(SCRATCH, "long.json"), "w"))
ok("import_transcript", {"project": B, "path": os.path.join(SCRATCH, "long.json")}, "import a long transcript")
r = ok("get_project", {"project": B}, "get_project of a long transcript")
check("get_project leaves out a long transcript and points at get_words", "words" not in r and r.get("wordsOmitted") == 1600 and "get_words" in r.get("readWordsWith", ""), {k: r.get(k) for k in ["wordsOmitted", "readWordsWith"]})
r = ok("get_project", {"project": B, "words": True}, "get_project with words true")
check("words true still gives every word", len(r.get("words", [])) == 1600, len(r.get("words", [])))
r = ok("get_words", {"project": B}, "get_words first page of a long transcript")
check("get_words pages a long transcript at 1500", r.get("shown") == 1500 and r.get("nextStart") == 1500, {k: r.get(k) for k in ["shown", "nextStart"]})
ok("import_transcript", {"project": B, "path": os.path.join(SCRATCH, "words.json")}, "back to the short transcript")
bad("get_words", {"project": B, "limit": 0}, "invalid_input", "get_words rejects a limit of 0")
# The audio audit on the project's own files: runs WhisperX when it is installed, says so when it is not.
good, r = call("audit_audio", {"project": B, "to": 4})
if good:
    check("audit_audio returns findings with edit times and what was heard", isinstance(r.get("findings"), list) and r.get("found") == len(r["findings"]) and all({"start", "end", "why", "heard"} <= set(f) for f in r["findings"]), r)
else:
    check("audit_audio without WhisperX says so", str(r).startswith("no_transcriber"), r)

# cut_range from MCP waits for approval
h0 = past(B)
r = ok("cut_range", {"project": B, "start": 1.0, "end": 1.5})
cuts = pj(B)["edits"]["cuts"]
check("cut_range from MCP is pending", len(cuts) == 1 and cuts[0].get("pending") is True, cuts)
check("cut_range shows Claude applying trims there", json.load(open(focus_file)) | {"t": 0, "by": ""} == {"action": "Applying trims", "start": 1.0, "end": 1.5, "t": 0, "by": ""}, open(focus_file).read())
ok("cut_range", {"project": B, "start": 6.0, "end": 6.5, "approved": True}, "cut_range approved")
check("approved cut is not pending", any(c.get("pending") is None and c["start"] == 6.0 for c in pj(B)["edits"]["cuts"]), pj(B)["edits"]["cuts"])
ok("restore_range", {"project": B, "start": 6.0, "end": 6.5})
ok("delete_words", {"project": B, "indexes": [4, 5]})
check("delete_words from MCP pending", pj(B)["edits"].get("pendingWords") == [4, 5], pj(B)["edits"])
ok("delete_words", {"project": B, "indexes": [8], "approved": True}, "delete_words approved")
check("approved word not pending", 8 in pj(B)["edits"]["deleted"] and 8 not in pj(B)["edits"].get("pendingWords", []), pj(B)["edits"])
r = ok("get_project", {"project": B})
check("words carry pending", r["words"][4].get("pending") is True and r.get("waitingCuts") == 3, (r["words"][4], r.get("waitingCuts")))
h1 = past(B)
r = ok("approve_cuts", {"project": B, "words": [4]})
check("approve_cuts one word", pj(B)["edits"].get("pendingWords") == [5] and r.get("waiting") == 2, (pj(B)["edits"].get("pendingWords"), r.get("waiting")))
ok("approve_cuts", {"project": B})
check("approve_cuts all", not pj(B)["edits"].get("pendingWords") and not any(c.get("pending") for c in pj(B)["edits"]["cuts"]), pj(B)["edits"])
ok("undo", {"project": B}, "undo approve all")
check("undo brings the pending cut back", any(c.get("pending") for c in pj(B)["edits"]["cuts"]), pj(B)["edits"]["cuts"])
ok("redo", {"project": B}, "redo approve all")
check("redo approves again", not any(c.get("pending") for c in pj(B)["edits"]["cuts"]), pj(B)["edits"]["cuts"])
ok("restore_words", {"project": B, "indexes": [4, 5, 8]})
ok("correct_word", {"project": B, "index": 0, "text": "One"})
ok("split_clip", {"project": B, "at": 4.0})
r = ok("get_project", {"project": B, "words": False})
check("two clips after split", len(r["clips"]) == 2, r["clips"])
ok("trim_clip", {"project": B, "clip": "c2", "out": 7.5})
ok("rename_clip", {"project": B, "clip": "c1", "label": "Part 1, opener"})
ok("mute_clip_audio", {"project": B, "clip": "c2", "muted": True})
ok("mute_clip_audio", {"project": B, "clip": "c2", "muted": False}, "mute_clip_audio off")
r = ok("add_clip", {"project": B, "path": f"{MEDIA}/silent.mp4", "in": 0, "out": 2, "transcribe": False})
check("add_clip created c3", r.get("created") == "c3", r.get("created"))
ok("reorder_clips", {"project": B, "order": ["c1", "c3", "c2"]})
ok("reorder_clips", {"project": B, "order": ["c1", "c2", "c3"]}, "reorder_clips back")
ok("delete_clip", {"project": B, "clip": "c3"})
ok("set_captions", {"project": B, "enabled": True})
ok("set_title", {"project": B, "enabled": True, "text": "Hiring alert!"})
ok("set_speed", {"project": B, "speed": 1})
ok("set_sections", {"project": B, "sections": [{"title": "Opening", "from": 0}, {"title": "Middle", "from": 6}]})
ok("list_animation_kinds")
r = ok("add_animation", {"project": B, "kind": "text-pop", "start": 0.5, "end": 2.0, "text": "Hi"})
aid = r.get("created")
ok("update_animation", {"project": B, "id": aid, "text": "Hello"})
ok("get_animations", {"project": B})
ok("set_animations", {"project": B, "animations": [{"kind": "counter", "start": 1, "end": 3, "from": 0, "to": 10}]})
ok("remove_animation", {"project": B, "id": "a1"})
ok("get_status", {"project": B})
ok("open_in_app", {"project": B})
ok("get_logs", {"limit": 5})
ok("create_project", {"path": f"{MEDIA}/silent.mp4", "name": "silent", "transcribe": True}, "create_project of a silent video skips transcribing")
bad("transcribe", {"project": "silent", "wait": True}, "no_audio", "transcribe a video with no sound")
bad("transcribe_source", {"project": B}, "invalid_input", "transcribe_source needs source or overlay")
bad("transcribe_source", {"project": B, "source": "s9"}, "not_found", "transcribe_source unknown source")

# ---------------------------------------------------------------------------------------------------------------------
# Overlays: voice over, face overlay, split, window, eq
r = ok("add_audio_overlay", {"project": B, "path": f"{MEDIA}/tone8k.m4a", "start": 0.5, "transcribe": False})
check("add_audio_overlay without start works", ok and r.get("created") == "o1", r.get("created"))
check("transcribe false makes it a sound effect", pj(B)["edits"]["audioOverlays"][0].get("sound") is True, pj(B)["edits"]["audioOverlays"][0])
h = past(B)
ok("update_audio_overlay", {"project": B, "id": "o1", "bass": 3, "treble": 6, "sound": False, "gain": 1.5})
o1 = pj(B)["edits"]["audioOverlays"][0]
check("update_audio_overlay eq and sound saved", o1.get("eq") == {"bass": 3, "treble": 6} and "sound" not in o1 and o1["gain"] == 1.5, o1)
check("update_audio_overlay leaves an undo step", past(B) == h + 1, (h, past(B)))
bad("update_audio_overlay", {"project": B, "id": "o1", "bass": 20}, "invalid_input", "bass 20 rejected by schema")
ok("update_audio_overlay", {"project": B, "id": "o1", "bass": 0, "treble": 0}, "eq back to 0")
check("eq 0 leaves the field out", "eq" not in pj(B)["edits"]["audioOverlays"][0], pj(B)["edits"]["audioOverlays"][0])
r = ok("add_face_overlay", {"project": B, "path": f"{MEDIA}/portrait.mp4", "start": 1.0, "out": 4, "transcribe": False, "label": "Face",
                           "window": {"x": 0.05, "y": 0.5, "w": 0.2, "radius": 30, "moves": [{"at": 1.5, "x": 0.7, "y": 0.3}]}})
fid = r.get("created")
face = next((o for o in pj(B)["edits"]["audioOverlays"] if o["id"] == fid), {})
check("face overlay saved with window", face.get("window", {}).get("w") == 0.2 and face["window"]["moves"][0]["dur"] == 0.35, face)
bad("add_face_overlay", {"project": B, "path": f"{MEDIA}/portrait.mp4", "transcribe": False}, "invalid_input", "add_face_overlay needs window")
bad("add_face_overlay", {"project": B, "path": f"{MEDIA}/portrait.mp4", "window": {"x": 0, "y": 0, "w": 3}}, "invalid_input", "window w 3 rejected")
h = past(B)
ok("set_face_window", {"project": B, "id": fid, "window": {"x": 0.6, "y": 0.4, "w": 0.25, "ratio": 1}})
face = next(o for o in pj(B)["edits"]["audioOverlays"] if o["id"] == fid)
check("set_face_window replaced the window", face["window"] == {"x": 0.6, "y": 0.4, "w": 0.25, "ratio": 1}, face["window"])
ok("undo", {"project": B}, "undo set_face_window")
face = next(o for o in pj(B)["edits"]["audioOverlays"] if o["id"] == fid)
check("undo restores the window", face["window"]["w"] == 0.2, face["window"])
ok("redo", {"project": B}, "redo set_face_window")
bad("set_face_window", {"project": B, "id": "o1", "window": {"x": 0, "y": 0, "w": 0.2}}, "not_found", "set_face_window on a voice over")
ok("set_face_window", {"project": B, "id": fid, "window": {"x": 0.05, "y": 0.5, "w": 0.2, "moves": [{"at": 1.5, "x": 0.6, "y": 0.5, "dur": 0.5}]}}, "set_face_window with moves")
r = ok("split_overlay", {"project": B, "id": fid, "at": 3.0})
second = next((o for o in pj(B)["edits"]["audioOverlays"] if o["id"] == r.get("created")), {})
check("split_overlay carries the window on", second.get("start") == 3.0 and abs(second.get("window", {}).get("x", 0) - 0.6) < 0.01 and "moves" not in second.get("window", {}), second)
ok("undo", {"project": B}, "undo split_overlay")
check("undo split leaves one face", len([o for o in pj(B)["edits"]["audioOverlays"] if o.get("window")]) == 1, pj(B)["edits"]["audioOverlays"])
bad("split_overlay", {"project": B, "id": fid, "at": 0.2}, "invalid_range", "split_overlay outside")

# ---------------------------------------------------------------------------------------------------------------------
# Clip title, look, placement (undoable)
h = past(B)
ok("set_clip_title", {"project": B, "clip": "c2", "visible": False})
check("set_clip_title saved and undoable", pj(B)["edits"]["clips"][1].get("hideTitle") is True and past(B) == h + 1, pj(B)["edits"]["clips"][1])
r = ok("get_project", {"project": B, "words": False})
check("titleHides in state", len(r.get("titleHides", [])) == 1, r.get("titleHides"))
ok("set_clip_look", {"project": B, "clip": "c1", "values": {"saturation": -100}, "name": "Grey"})
check("set_clip_look own look", pj(B)["edits"]["clips"][0].get("look", {}).get("saturation") == -100 and pj(B)["edits"]["clips"][0]["look"].get("name") == "Grey", pj(B)["edits"]["clips"][0])
ok("set_clip_look", {"project": B, "clips": ["c1", "c2"], "off": True}, "set_clip_look off on two")
check("set_clip_look off", all(c.get("hideLook") for c in pj(B)["edits"]["clips"]), pj(B)["edits"]["clips"])
ok("set_clip_look", {"project": B, "clips": ["c1", "c2"], "reel_look": True}, "set_clip_look reel")
check("set_clip_look reel clears", not any(c.get("hideLook") or c.get("look") for c in pj(B)["edits"]["clips"]), pj(B)["edits"]["clips"])
ok("undo", {"project": B}, "undo set_clip_look")
check("undo set_clip_look brings off back", all(c.get("hideLook") for c in pj(B)["edits"]["clips"]), pj(B)["edits"]["clips"])
ok("redo", {"project": B}, "redo set_clip_look")
bad("set_clip_look", {"project": B}, "invalid_input", "set_clip_look needs a clip")
bad("set_clip_look", {"project": B, "clip": "c1", "look": "nope"}, "not_found", "set_clip_look unknown saved look")
ok("set_clip_placement", {"project": B, "clip": "c1", "zoom": 0.5})
check("set_clip_placement saved", pj(B)["edits"]["clips"][0].get("place") == {"zoom": 0.5, "x": 0, "y": 0}, pj(B)["edits"]["clips"][0])
ok("set_clip_placement", {"project": B, "clip": "c1", "x": 0.25}, "set_clip_placement keeps zoom")
check("set_clip_placement merged", pj(B)["edits"]["clips"][0].get("place") == {"zoom": 0.5, "x": 0.25, "y": 0}, pj(B)["edits"]["clips"][0])
bad("set_clip_placement", {"project": B, "clip": "c1", "zoom": 9}, "invalid_input", "zoom 9 rejected")
bad("set_clip_placement", {"project": B, "clip": "c1"}, "invalid_input", "placement needs a field")
ok("set_clip_placement", {"project": B, "clip": "c1", "reset": True}, "set_clip_placement reset")
check("reset removes place", "place" not in pj(B)["edits"]["clips"][0], pj(B)["edits"]["clips"][0])
ok("undo", {"project": B}, "undo placement reset")
check("undo brings the place back", pj(B)["edits"]["clips"][0].get("place", {}).get("x") == 0.25, pj(B)["edits"]["clips"][0])
ok("split_clip", {"project": B, "at": 1.0}, "split keeps clip fields")
cl = pj(B)["edits"]["clips"]
check("split carries place and label", cl[1].get("place") == cl[0].get("place") and cl[1].get("label") == cl[0].get("label"), cl)
ok("undo", {"project": B}, "undo split")

# ---------------------------------------------------------------------------------------------------------------------
# Settings: no undo step
h = past(B)
ok("set_video_look", {"project": B, "saturation": 40, "vignette": 30, "name": "Warm"})
check("set_video_look saved", pj(B)["edits"].get("look", {}).get("saturation") == 40 and pj(B)["edits"]["look"].get("name") == "Warm", pj(B)["edits"].get("look"))
ok("set_video_look", {"project": B, "contrast": 10}, "set_video_look merges")
check("set_video_look kept old values", pj(B)["edits"]["look"].get("saturation") == 40 and pj(B)["edits"]["look"].get("contrast") == 10, pj(B)["edits"]["look"])
bad("set_video_look", {"project": B, "saturation": 200}, "invalid_input", "saturation 200 rejected")
r = ok("save_video_look", {"name": "Screen look", "sharpness": 40, "vignette": 20, "default": True})
check("save_video_look wrote a file", os.path.exists(os.path.join(HOME, "_looks", "screen-look.json")), r)
r = ok("save_video_look", {"name": "Reel warm", "project": B}, "save_video_look from a project")
r = ok("list_video_looks", {"reel": B})
check("list_video_looks lists two with a default", len(r.get("looks", [])) == 2 and sum(1 for l in r["looks"] if l["default"]) == 1, r)
ok("set_video_look", {"project": B, "template": "Screen look"}, "set_video_look template")
check("template laid on", pj(B)["edits"]["look"].get("sharpness") == 40 and pj(B)["edits"]["look"].get("saturation", 0) == 0, pj(B)["edits"]["look"])
ok("set_clip_look", {"project": B, "clip": "c2", "look": "Screen look"}, "set_clip_look saved look")
check("clip carries saved look by name", pj(B)["edits"]["clips"][1].get("look", {}).get("name") == "Screen look", pj(B)["edits"]["clips"][1])
ok("set_video_look", {"project": B, "reset": True}, "set_video_look reset")
check("reset clears look", "look" not in pj(B)["edits"], pj(B)["edits"].get("look"))
r = ok("create_project", {"path": f"{MEDIA}/blue.mp4", "name": "default-look", "transcribe": False}, "new project after a default look")
check("new project starts with the default look", pj("default-look")["edits"].get("look", {}).get("name") == "Screen look", pj("default-look")["edits"].get("look"))
h = past(B)
ok("set_reel_caption", {"project": B, "text": "A caption for the post"})
check("caption saved", pj(B)["edits"].get("caption") == "A caption for the post")
ok("set_reel_caption", {"project": B, "text": "  "}, "set_reel_caption clear")
check("caption cleared", "caption" not in pj(B)["edits"])
ok("set_title_text", {"project": B, "text": "Big news"})
check("title text saved", pj(B)["edits"].get("titleText") == "Big news")
ok("set_title_text", {"project": B, "reset": True}, "set_title_text reset")
check("title text reset", "titleText" not in pj(B)["edits"])
ok("set_title_text", {"project": B, "text": "Hiring alert!"}, "set_title_text again")
ok("set_caption_position", {"project": B, "y": 300})
h += 1  # the caption's place is part of its style, an undo step since 2 Nov 2026
check("caption position saved in the caption style", pj(B)["edits"].get("captionStyle", {}).get("y") == 300 and pj(B)["edits"].get("captionStyle", {}).get("x") == 0 and "captionPos" not in pj(B)["edits"], pj(B)["edits"].get("captionStyle"))
bad("set_caption_position", {"project": B, "y": -5}, "invalid_input", "caption y -5 rejected")
ok("set_voice_gain", {"project": B, "gain": 2.5})
check("voice gain saved", pj(B)["edits"].get("voiceGain") == 2.5)
bad("set_voice_gain", {"project": B, "gain": 11}, "invalid_input", "voice gain 11 rejected")
ok("set_voice_eq", {"project": B, "bass": 4})
ok("set_voice_eq", {"project": B, "treble": -3}, "set_voice_eq keeps bass")
check("voice eq merged", pj(B)["edits"].get("voiceEq") == {"bass": 4, "treble": -3}, pj(B)["edits"].get("voiceEq"))
ok("set_voice_eq", {"project": B, "bass": 0, "treble": 0}, "set_voice_eq off")
check("voice eq off removed", "voiceEq" not in pj(B)["edits"])
ok("set_voice_gain", {"project": B, "gain": 1}, "set_voice_gain back to 1")
check("voice gain 1 removed", "voiceGain" not in pj(B)["edits"])
ok("set_references", {"project": B, "references": [{"kind": "format", "title": "Format", "path": "projects/x/format"}, {"kind": "json", "title": "Manifest", "path": "tools/x.json"}]})
check("references saved", len(pj(B)["edits"].get("references", [])) == 2)
bad("set_references", {"project": B, "references": [{"kind": "pdf", "title": "x", "path": "y"}]}, "invalid_input", "reference kind pdf rejected")
ok("set_reel_status", {"project": B, "status": "live"})
check("status live", pj(B)["edits"].get("status") == "live")
bad("set_reel_status", {"project": B, "status": "gone"}, "invalid_input", "status gone rejected")
ok("set_reel_status", {"project": B, "status": "draft"}, "set_reel_status draft")
ok("record_generation_cost", {"project": B, "items": [{"kind": "argon-video", "part": "opener"}, {"kind": "heygen-voice", "part": "part2", "seconds": 30}, {"kind": "argon-video", "part": "part3", "failed": True}]})
cost = pj(B)["edits"].get("cost", {})
check("cost lines and totals", len(cost.get("items", [])) == 3 and cost["total"]["byCurrency"].get("INR") == 16.25 and cost["total"]["generations"] == 2 and cost["total"]["failed"] == 1 and abs(cost["total"]["inr"] - (16.25 + 0.5 * 0.049 * 96.3)) < 0.02, cost)
ok("record_generation_cost", {"project": B, "remove": ["g3"]}, "record_generation_cost remove")
check("cost line removed", [x["id"] for x in pj(B)["edits"]["cost"]["items"]] == ["g1", "g2"], pj(B)["edits"]["cost"]["items"])
ok("record_generation_cost", {"project": B, "items": [{"kind": "argon-video", "part": "part4", "cost": 0, "currency": "INR", "account": "work"}]}, "record_generation_cost add")
check("new line gets g3", pj(B)["edits"]["cost"]["items"][-1]["id"] == "g3", pj(B)["edits"]["cost"]["items"])
r = ok("set_music", {"project": B, "track": "bed", "gain": 0.4, "fadeIn": 0.5})
check("music saved", pj(B)["edits"].get("music", {}).get("track") == "bed" and pj(B)["edits"]["music"]["gain"] == 0.4, pj(B)["edits"].get("music"))
r = ok("get_project", {"project": B, "words": False})
check("musicFile resolved", str(r.get("musicFile", "")).endswith("_music/bed.m4a"), r.get("musicFile"))
bad("set_music", {"project": B, "track": "/no/such.m4a"}, "not_found", "set_music missing track")
ok("set_music", {"project": B, "none": True}, "set_music none")
check("none removes the track", pj(B)["edits"]["music"].get("none") is True and "track" not in pj(B)["edits"]["music"], pj(B)["edits"]["music"])
ok("set_music", {"project": B, "track": "bed"}, "set_music track brings it back")
check("track brings music back", "none" not in pj(B)["edits"]["music"], pj(B)["edits"]["music"])
check("settings left no undo step", past(B) == h, (h, past(B)))

# ---------------------------------------------------------------------------------------------------------------------
# Comments
r = ok("add_comment", {"project": B, "from": 2, "to": 3, "comment": "Tighten this"})
cid = r.get("comment", {}).get("id")
check("word comment", r.get("comment", {}).get("words") == "three four" and r["comment"]["start"] == 1.05, r)
r = ok("add_comment", {"project": B, "start": 2.0, "end": 3.5, "comment": "Range note"}, "add_comment on a range")
check("range comment", r.get("comment", {}).get("range") is True and r["comment"]["from"] == -1, r)
bad("add_comment", {"project": B, "from": 3, "to": 99, "comment": "x"}, "invalid_input", "add_comment outside the words")
bad("add_comment", {"project": B, "comment": "x"}, "invalid_input", "add_comment with nothing to point at")
ok("edit_comment", {"project": B, "id": cid, "comment": "Tighten this part"})
r = ok("list_comments", {"project": B})
check("two unresolved", r.get("unresolved") == 2 and len(r.get("comments", [])) == 2, r)
ok("resolve_comment", {"project": B, "id": cid, "note": "Cut two words"})
r = ok("list_comments", {"project": B, "status": "resolved"}, "list_comments resolved")
check("resolved with note", len(r.get("comments", [])) == 1 and r["comments"][0].get("resolution") == "Cut two words" and r["comments"][0]["comment"] == "Tighten this part", r)
ok("reopen_comment", {"project": B, "id": cid})
r = ok("list_comments", {"project": B, "status": "all"}, "list_comments all")
check("reopened", all(c["status"] == "unresolved" for c in r.get("comments", [])) and "resolution" not in r["comments"][0], r)
bad("resolve_comment", {"project": B, "id": "nope"}, "not_found", "resolve unknown comment")

# ---------------------------------------------------------------------------------------------------------------------
# Drafts
D = "2026-10-31-test-draft-v1"
ok("create_draft_reel", {"project": D, "title": "Test draft", "summary": "Two parts", "references": [{"kind": "format", "title": "F", "path": "a/b"}],
                         "sections": [{"part": "Part 1", "title": "Opener", "script": "Hello", "needs": [{"kind": "talking-head", "label": "Generate the opener", "required": True}, {"kind": "voice", "label": "Make the voice", "required": False}]},
                                      {"part": "Part 2", "title": "Close", "script": "Bye", "logo": "whatfix"}]})
bad("create_draft_reel", {"project": D, "title": "x", "sections": [{"part": "1", "title": "t", "script": "s"}]}, "exists", "create_draft_reel twice")
bad("create_draft_reel", {"project": B, "title": "x", "sections": [{"part": "1", "title": "t", "script": "s"}]}, "exists", "create_draft_reel on a project")
bad("create_draft_reel", {"project": "x-draft", "title": "x", "sections": []}, "invalid_input", "create_draft_reel with no sections")
r = ok("get_draft_reel", {"project": D})
check("draft read back", r.get("draft", {}).get("sections", [{}])[0].get("needs", [{}])[0].get("status") == "todo", r)
r = ok("list_projects", {}, "list_projects with a draft")
check("draft listed", any(p["name"] == D and p["draft"] for p in r.get("projects", [])), r)
r = ok("set_draft_need_status", {"project": D, "section": "d1", "step": "voice", "status": "running"})
d = doc(D)["draft"]
check("need running marks part running", d["sections"][0]["needs"][1]["status"] == "running" and d["sections"][0]["status"] == "running", d["sections"][0])
ok("set_draft_need_status", {"project": D, "section": "d1", "step": 1, "status": "done"}, "set_draft_need_status by index")
d = doc(D)["draft"]
check("part back to pending when no step runs", d["sections"][0]["status"] == "pending", d["sections"][0])
bad("set_draft_need_status", {"project": D, "section": "d1", "step": True, "status": "done"}, "invalid_input", "step true rejected")
bad("set_draft_need_status", {"project": D, "section": "d1", "step": 7, "status": "done"}, "not_found", "step 7 not found")
r = ok("set_draft_section_status", {"project": D, "section": "d1", "status": "done", "needsDone": True})
check("section done", r.get("done") == 1 and r.get("pending") == 1, r)
bad("set_draft_section_status", {"project": D, "section": "d9", "status": "done"}, "not_found", "unknown section")
r = ok("create_project", {"path": f"{MEDIA}/blue.mp4", "name": D, "transcribe": False}, "create_project into the draft folder")
r = ok("set_draft_published", {"project": D, "post": "test-post", "section": "d2", "script": "Went live", "blocks": [{"label": "Caption", "text": "The caption"}], "links": [{"label": "Reel", "url": "https://example.com"}]})
d = doc(D)["draft"]
check("published recorded", d.get("post") == "test-post" and d["sections"][1]["blocks"][0]["text"] == "The caption" and r.get("pending") == 0, (d, r))
check("published sets live", pj(D)["edits"].get("status") == "live", pj(D)["edits"])

# ---------------------------------------------------------------------------------------------------------------------
# Sources, Finder, rename
moved = os.path.join(SCRATCH, "moved")
os.makedirs(moved, exist_ok=True)
shutil.copy(f"{MEDIA}/tone8k.m4a", os.path.join(moved, "tone8k-copy.m4a"))
r = ok("check_sources", {"project": B})
check("check_sources all found", r.get("missing") == 0 and len(r.get("sources", [])) >= 3, r)
r = ok("relink_source", {"project": B, "source": "o1", "path": os.path.join(moved, "tone8k-copy.m4a")})
o1 = pj(B)["edits"]["audioOverlays"][0]
check("relink_source pointed the overlay at the file", o1["file"].endswith("moved/tone8k-copy.m4a") and o1.get("origin", "").endswith("tone8k-copy.m4a"), o1)
hist = doc(B)["history"]
check("relink patched the history", not any(o.get("file", "").endswith("media/tone8k.m4a") for s in hist["past"] + hist["future"] for o in (s["snap"].get("audioOverlays") or [])), "old path left in history")
bad("relink_source", {"project": B, "source": "main", "path": f"{MEDIA}/silent.mp4"}, "duration_mismatch", "relink wrong length")
ok("relink_source", {"project": B, "source": "main", "path": f"{MEDIA}/blue.mp4"}, "relink main same file")
bad("relink_source", {"project": B, "source": "s7", "path": f"{MEDIA}/blue.mp4"}, "not_found", "relink unknown source")
bad("relink_source", {"project": B, "source": "main"}, "invalid_input", "relink with no path")
ok("open_project_folder", {"project": B})
bad("reveal_in_finder", {"project": B, "file": "/etc/hosts"}, "invalid_path", "reveal outside the project")

# ---------------------------------------------------------------------------------------------------------------------
# Exports: picture and sound
base = f"{SCRATCH}/out"
os.makedirs(base, exist_ok=True)
# A clean project for render checks.
R = "render"
ok("create_project", {"path": f"{MEDIA}/blue.mp4", "name": R, "transcribe": False}, "create render project")
ok("set_video_look", {"project": R, "reset": True}, "render: no default look")
res = export(R, path=f"{base}/plain.mp4")
p = probe(f"{base}/plain.mp4")
check("plain export is an mp4 of 8 s", abs(float(p["format"]["duration"]) - 8) < 0.2 and any(s["codec_type"] == "video" and s["width"] == 1280 for s in p["streams"]), p)
px = pixel(f"{base}/plain.mp4", 2, 640, 360)
check("plain export is blue", px and px[2] > 150 and px[0] < 90, px)
mean0, max0 = volume(f"{base}/plain.mp4")

ok("set_video_look", {"project": R, "saturation": -100}, "render: grey look")
res = export(R, path=f"{base}/grey.mp4")
check("export reports the compositor", res.get("compositor") is True, res)
px = pixel(f"{base}/grey.mp4", 2, 640, 360)
check("look renders: saturation -100 is grey", px and max(px) - min(px) < 12 and 40 < max(px) < 200, px)
ok("set_video_look", {"project": R, "reset": True}, "render: look off")
ok("split_clip", {"project": R, "at": 4.0}, "render: split")
ok("set_clip_look", {"project": R, "clip": "c2", "values": {"temperature": 100}}, "render: warm clip 2")
ok("set_clip_placement", {"project": R, "clip": "c1", "zoom": 0.5}, "render: clip 1 half size")
res = export(R, path=f"{base}/placed.mp4")
corner, centre = pixel(f"{base}/placed.mp4", 1, 20, 20), pixel(f"{base}/placed.mp4", 1, 640, 360)
check("placement renders: corner black, centre blue", corner and max(corner) < 20 and centre and centre[2] > 150 and centre[0] < 90, (corner, centre))
warm = pixel(f"{base}/placed.mp4", 6, 640, 360)
blue = pixel(f"{base}/plain.mp4", 6, 640, 360)
check("clip look renders: temperature +100 is warmer", warm and blue and (warm[0] - warm[2]) > (blue[0] - blue[2]) + 20 and min(warm) < 200, (warm, blue))
c2px = pixel(f"{base}/placed.mp4", 6, 20, 20)
check("clip 2 is not placed", c2px and c2px[2] > 100 and c2px[1] < 160, c2px)

# Face window
F = "face"
ok("create_project", {"path": f"{MEDIA}/blue.mp4", "name": F, "transcribe": False}, "create face project")
ok("set_video_look", {"project": F, "reset": True}, "face: no look")
ok("add_face_overlay", {"project": F, "path": f"{MEDIA}/portrait.mp4", "start": 1, "transcribe": False, "window": {"x": 0.05, "y": 0.5, "w": 0.2, "moves": [{"at": 3, "x": 0.6, "y": 0.5, "dur": 0}]}}, "face: add")
res = export(F, path=f"{base}/face.mp4")
check("export reports one face", res.get("faces") == 1, res)
# window: left 64 px, 256 wide, 455 tall centred at y 360. At t 2 (local 1) it is at the left.
inside, outside, before = pixel(f"{base}/face.mp4", 2, 64 + 128, 360), pixel(f"{base}/face.mp4", 2, 900, 360), pixel(f"{base}/face.mp4", 0.5, 64 + 128, 360)
check("face window renders green over blue", inside and inside[1] > 150 and inside[2] < 80, inside)
check("outside the window stays blue", outside and outside[2] > 150 and outside[0] < 90, outside)
check("no window before its start", before and before[2] > 150 and before[0] < 90, before)
border = pixel(f"{base}/face.mp4", 2, 64 + 128, 360 - 227 + 1)
check("window has the dark #333 border", border and max(border) < 100 and max(border) - min(border) < 20, border)
moved_px = pixel(f"{base}/face.mp4", 5, int(0.6 * 1280) + 128, 360)
check("window moved at 3 s into the overlay", moved_px and moved_px[1] > 150 and moved_px[2] < 100, moved_px)
ok("set_face_window", {"project": F, "id": "o1", "window": {"x": 0.5, "y": 0.5, "w": 0.3, "ratio": 1, "radius": 0}}, "face: square window")
res = export(F, path=f"{base}/face2.mp4")
sq = pixel(f"{base}/face2.mp4", 2, 640 + 192, 360 + 160)
check("square window renders", sq and sq[1] > 150 and sq[2] < 100, sq)

# Title hidden over a clip, caption position
T = "title"
ok("create_project", {"path": f"{MEDIA}/blue.mp4", "name": T, "transcribe": False}, "create title project")
ok("set_video_look", {"project": T, "reset": True}, "title: no look")
ok("import_transcript", {"project": T, "path": os.path.join(SCRATCH, "words.json")}, "title: words")
ok("set_title", {"project": T, "enabled": True, "text": "HIRING"}, "title: on")
ok("split_clip", {"project": T, "at": 4.0}, "title: split")
ok("set_clip_title", {"project": T, "clip": "c2", "visible": False}, "title: hide over c2")
res = export(T, path=f"{base}/title.mp4", captions=False)
y1, y2 = band_yellow(f"{base}/title.mp4", 2, 20, 140, 1280), band_yellow(f"{base}/title.mp4", 6, 20, 140, 1280)
check("title shows over c1 and is hidden over c2", y1 > 0.005 and y2 < 0.0005, (y1, y2))
ok("set_caption_position", {"project": T, "y": 200}, "title: captions near the top")
res = export(T, path=f"{base}/caps.mp4", title=False)
top, low = band_dark(f"{base}/caps.mp4", 1.1, 100, 170, 1280), band_dark(f"{base}/caps.mp4", 1.1, 560, 640, 1280)
check("captions drawn at the set position", top > 0.05 and low < 0.01, (top, low))
# Captions and text layers (2 Nov 2026): a caption style of every font property, hidden stretches, text layers.
r = ok("get_caption_style", {"project": T}, "get_caption_style")
st = r.get("style", {})
check("the built in caption look is the web editor's, Advercase in a word box", st.get("font") == "Advercase" and st.get("weight") == 700 and st.get("box") == "word" and st.get("maxWords") == 3 and r.get("landscape") is True and st.get("size") == 72, r)
check("the caption position set before styles is the project's own place", st.get("y") == 200 and r.get("own", {}).get("y") == 200, r.get("own"))
r = ok("set_caption_style", {"project": T, "font": "Inter", "weight": 900, "size": 110, "color": "#ff0", "strokeWidth": 0, "box": "line", "boxColor": "#112233", "boxOpacity": 0.5, "uppercase": True, "letterSpacing": 4, "highlight": "#00ff00", "animation": "pop", "maxWords": 2}, "set_caption_style")
st = r.get("style", {})
check("set_caption_style sets every field it is given, colours made #rrggbb", st.get("font") == "Inter" and st.get("weight") == 900 and st.get("size") == 110 and st.get("color") == "#ffff00" and st.get("box") == "line" and st.get("boxColor") == "#112233" and st.get("uppercase") is True and st.get("highlight") == "#00ff00" and st.get("animation") == "pop" and st.get("maxWords") == 2 and st.get("y") == 200, st)
check("the project keeps only the fields it sets", pj(T)["edits"]["captionStyle"].get("size") == 110 and "strokeColor" not in pj(T)["edits"]["captionStyle"], pj(T)["edits"]["captionStyle"])
ok("undo", {"project": T}, "undo set_caption_style")
check("undo takes the caption style back", pj(T)["edits"].get("captionStyle", {}).get("size") is None and pj(T)["edits"].get("captionStyle", {}).get("y") == 200, pj(T)["edits"].get("captionStyle"))
ok("redo", {"project": T}, "redo set_caption_style")
check("redo puts it back", pj(T)["edits"]["captionStyle"].get("size") == 110, pj(T)["edits"].get("captionStyle"))
r = ok("set_caption_style", {"project": T, "clear": ["size", "highlight"]}, "set_caption_style clear")
check("clear puts fields back to the default", r["style"].get("size") == 72 and r["style"].get("highlight") == "none" and r["style"].get("font") == "Inter", r["style"])
bad("set_caption_style", {"project": T, "color": "red"}, "invalid_input", "a caption colour that is not a colour")
bad("set_caption_style", {"project": T, "box": "circle"}, "invalid_input", "a box kind that does not exist")
r = ok("list_fonts", {}, "list_fonts")
check("list_fonts lists the bundled Advercase and Inter first, then the Mac's", r.get("families", [])[:2] == ["Advercase", "Inter"] and r.get("count", 0) > 10, r.get("families", [])[:5])
r = ok("set_caption_style", {"project": T, "size": 64, "saveAsDefault": True}, "set_caption_style saveAsDefault")
sett = json.load(open(os.path.join(HOME, "settings.json")))
check("saveAsDefault saves the look for new landscape projects", sett.get("captionStyleLandscape", {}).get("size") == 64 and sett.get("captionStyleLandscape", {}).get("font") == "Inter", sett.get("captionStyleLandscape"))
ok("create_project", {"path": f"{MEDIA}/blue.mp4", "name": "caps-default", "transcribe": False}, "a new project after a saved caption look")
check("a new project's captions start from the saved look", ok("get_caption_style", {"project": "caps-default"})["style"].get("size") == 64, None)
ok("set_caption_style", {"project": T, "resetDefault": True}, "set_caption_style resetDefault")
check("resetDefault clears the saved look", "captionStyleLandscape" not in json.load(open(os.path.join(HOME, "settings.json"))), None)
check("a project without its own look is back to the built in one", ok("get_caption_style", {"project": "caps-default"})["style"].get("size") == 72, None)
r = ok("set_caption_style", {"project": T, "reset": True, "burnIn": False}, "set_caption_style reset and burn in off")
check("reset clears the project's own look and burnIn turns the captions off", "captionStyle" not in pj(T)["edits"] and r["style"].get("font") == "Advercase" and pj(T)["edits"]["export"].get("captions") is False, pj(T)["edits"])
ok("set_caption_style", {"project": T, "burnIn": True, "y": 200}, "captions back on near the top")
r = ok("hide_captions", {"project": T, "start": 1, "end": 2}, "hide_captions by time")
check("hide_captions keeps a hidden stretch with an id", r.get("hidden") == "h1" and r.get("hides") == [{"id": "h1", "start": 1, "end": 2}], r)
r = ok("hide_captions", {"project": T, "start": 1.5, "end": 3}, "hide_captions overlapping")
check("an overlapping stretch joins the one it meets", r.get("hides") == [{"id": "h1", "start": 1, "end": 3}], r)
r = ok("hide_captions", {"project": T, "from": 9, "to": 10}, "hide_captions by words")
check("hide_captions by word indexes hides those words' times", len(r.get("hides", [])) == 2 and r["hides"][1]["id"] == "h2", r)
r = ok("show_captions", {"project": T, "start": 1.5, "end": 2}, "show_captions in the middle of a stretch")
check("show_captions over part of a stretch splits it", [(h["start"], h["end"]) for h in r.get("hides", [])][:2] == [(1, 1.5), (2, 3)], r)
r = ok("hide_captions", {"project": T, "clip": "c2"}, "hide_captions over a clip")
check("hide_captions over a whole clip", any(abs(h["start"] - 4) < 0.01 for h in r.get("hides", [])), r)
ok("undo", {"project": T}, "undo hide_captions")
check("undo takes a hidden stretch back", not any(abs(h["start"] - 4) < 0.01 for h in pj(T)["edits"].get("captionHides", [])), pj(T)["edits"].get("captionHides"))
r = ok("show_captions", {"project": T, "all": True}, "show_captions all")
check("show_captions all shows them everywhere", "captionHides" not in pj(T)["edits"] and r.get("hides") == [], r)
bad("show_captions", {"project": T, "id": "h9"}, "not_found", "show_captions of a stretch that is not there")
bad("hide_captions", {"project": T}, "invalid_input", "hide_captions with no stretch")
ok("hide_captions", {"project": T, "start": 0, "end": 1.5}, "hide the captions at the start")
r = ok("add_text_layer", {"project": T, "text": "Big news\nToday", "whole": True, "font": "Inter", "weight": 800, "size": 120, "color": "#ffff00", "y": 540, "enter": "pop", "exit": "slide-left"}, "add_text_layer over the whole reel")
tid = r.get("created")
anims = ok("get_animations", {"project": T})["animations"]
ta = next((a for a in anims if a["id"] == tid), {})
check("add_text_layer adds a text kind on the Animation layer over the whole reel with its style and motions", ta.get("kind") == "text" and ta.get("start") == 0 and abs(ta.get("end", 0) - ok("get_project", {"project": T, "words": False})["editDuration"]) < 0.01 and ta.get("style", {}).get("size") == 120 and ta.get("enter") == "pop" and ta.get("exit") == "slide-left", ta)
r = ok("update_text_layer", {"project": T, "id": tid, "text": "HIRING NOW", "start": 0.5, "end": 3, "enter": "typewriter", "box": "line", "clear": ["weight"]}, "update_text_layer")
ta = next((a for a in ok("get_animations", {"project": T})["animations"] if a["id"] == tid), {})
check("update_text_layer changes the text, times, motion and style", ta.get("text") == "HIRING NOW" and ta.get("start") == 0.5 and ta.get("end") == 3 and ta.get("enter") == "typewriter" and ta["style"].get("box") == "line" and "weight" not in ta["style"] and ta["style"].get("size") == 120, ta)
bad("add_text_layer", {"project": T, "text": "x", "start": 1, "end": 1.2}, "invalid_animation", "a text layer shorter than half a second")
bad("add_text_layer", {"project": T, "text": "x", "start": 1, "end": 3, "enter": "spin"}, "invalid_input", "an enter motion that does not exist")
bad("update_text_layer", {"project": T, "id": "a99"}, "not_found", "update_text_layer of a layer that is not there")
r = ok("add_animation", {"project": T, "kind": "text", "start": 4, "end": 6, "text": "Through add_animation", "style": {"size": 70, "color": "#00ffff"}, "enter": "rise"}, "add_animation of kind text with a style")
ta = next((a for a in ok("get_animations", {"project": T})["animations"] if a["id"] == r.get("created")), {})
check("add_animation takes a text layer's style and motion too", ta.get("style", {}).get("color") == "#00ffff" and ta.get("enter") == "rise", ta)
res = export(T, path=f"{base}/text.mp4", title=False)
cyan = lambda f, t: sum(1 for p in [pixel(f, t, x, y) for x in range(200, 1100, 20) for y in range(300, 420, 12)] if p and p[0] < 90 and p[1] > 170 and p[2] > 170)
yel = band_yellow(f"{base}/text.mp4", 1.5, 300, 420, 1280)
check("the export draws the text layer in its colour where it sits", yel > 0.01, yel)
check("the export draws the second text layer only in its own span", cyan(f"{base}/text.mp4", 5.2) > 3 and cyan(f"{base}/text.mp4", 2) == 0, (cyan(f"{base}/text.mp4", 5.2), cyan(f"{base}/text.mp4", 2)))
hid, shown = band_dark(f"{base}/text.mp4", 0.6, 100, 170, 1280), band_dark(f"{base}/text.mp4", 2.2, 100, 170, 1280)
check("the captions are left out over a hidden stretch and drawn after it", hid < 0.01 and shown > 0.02, (hid, shown))
check("export title override off", res.get("title") is False, res)

# Sound: voice gain via the tap, eq, music, speed
A = "audio"
ok("create_project", {"path": f"{MEDIA}/blue.mp4", "name": A, "transcribe": False}, "create audio project")
ok("set_video_look", {"project": A, "reset": True}, "audio: no look")
ok("set_voice_gain", {"project": A, "gain": 0}, "audio: silent voice")
export(A, path=f"{base}/silent.mp4")
m, _ = volume(f"{base}/silent.mp4")
check("voice gain 0 is silent", m < -80, m)
ok("set_voice_gain", {"project": A, "gain": 4}, "audio: loud voice")
export(A, path=f"{base}/loud.mp4")
m4, x4 = volume(f"{base}/loud.mp4")
check("voice gain 4 is louder (the tap runs in the export)", m4 > mean0 + 6, (mean0, m4))
check("the limiter holds the peaks", x4 <= -0.5, x4)
# 200 percent, the usual boost, and 1000 percent, the most (2 Nov 2026): each really louder, never clipping.
ok("set_voice_gain", {"project": A, "gain": 2}, "audio: voice at 200 percent")
export(A, path=f"{base}/loud2.mp4")
m2, x2 = volume(f"{base}/loud2.mp4")
ok("set_voice_gain", {"project": A, "gain": 10}, "audio: voice at 1000 percent")
export(A, path=f"{base}/loud10.mp4")
m10, x10 = volume(f"{base}/loud10.mp4")
check("voice gain 2 is about 6 dB louder", m2 > mean0 + 4, (mean0, m2))
check("voice gain 10 is louder still than 4", m10 > m4 + 2, (m4, m10))
check("the limiter holds the peaks at 200 and 1000 percent", x2 <= -0.5 and x10 <= -0.5, (x2, x10))
ok("set_voice_gain", {"project": A, "gain": 1}, "audio: voice back")
ok("mute_clip_audio", {"project": A, "clip": "c1"}, "audio: mute the clip")
ok("add_audio_overlay", {"project": A, "path": f"{MEDIA}/tone8k.m4a", "start": 0, "transcribe": False, "sound": False}, "audio: 8 kHz overlay")
export(A, path=f"{base}/tone.mp4")
t0, _ = volume(f"{base}/tone.mp4", 0.5, 3)
ok("update_audio_overlay", {"project": A, "id": "o1", "treble": 12}, "audio: treble +12")
export(A, path=f"{base}/treble.mp4")
t12, _ = volume(f"{base}/treble.mp4", 0.5, 3)
check("treble +12 raises an 8 kHz tone", t12 > t0 + 6, (t0, t12))
ok("set_voice_eq", {"project": A, "treble": -12}, "audio: voice treble -12")
export(A, path=f"{base}/treble2.mp4")
t24, _ = volume(f"{base}/treble2.mp4", 0.5, 3)
check("voice eq lays on the overlay too", t24 < t12 - 6, (t12, t24))
ok("set_voice_eq", {"project": A, "treble": 0}, "audio: voice eq off")
ok("delete_audio_overlay", {"project": A, "id": "o1"}, "audio: no overlay")
ok("set_music", {"project": A, "track": "bed", "gain": 1, "fadeIn": 0, "fadeOut": 0}, "audio: music")
ok("set_speed", {"project": A, "speed": 2}, "audio: speed 2")
res = export(A, path=f"{base}/music.mp4")
p = probe(f"{base}/music.mp4")
mm, _ = volume(f"{base}/music.mp4", 0.5, 2)
check("music export is 4 s at speed 2", abs(float(p["format"]["duration"]) - 4) < 0.2, p["format"])
check("music plays over a muted clip", mm > -40 and res.get("music") is True, (mm, res))
ok("set_music", {"project": A, "mute": True}, "audio: music muted")
res = export(A, path=f"{base}/nomusic.mp4")
check("muted music is not mixed", res.get("music") is False, res)

# The busy project B exports too, with every layer on.
res = export(B, path=f"{base}/busy.mp4")
check("busy project exports", os.path.exists(f"{base}/busy.mp4") and res.get("seconds", 0) > 3, res)
ok("reveal_in_finder", {"project": B}, "reveal_in_finder last export")
ok("reveal_in_finder", {"reel": B, "url": f"{base}/busy.mp4"}, "reveal_in_finder by url")

# ---------------------------------------------------------------------------------------------------------------------
# Renaming last, since it moves folders
r = ok("rename_reel", {"project": "colour", "to": "colour-renamed"})
check("rename_reel moved the folder", os.path.exists(os.path.join(HOME, "colour-renamed.reel.json")) and r.get("from") == "colour", r)
bad("rename_reel", {"project": "colour-renamed", "to": B}, "exists", "rename_reel onto a taken name")
r = ok("rename_project", {"project": "colour-renamed", "title": "Colour Bars"})
check("rename_project still works", r.get("project") == "colour-bars", r)

# Schema checks on a few more
bad("approve_cuts", {"project": B, "cuts": "x1"}, "invalid_input", "approve_cuts cuts must be a list")
bad("set_clip_title", {"project": B, "clip": "c1"}, "invalid_input", "set_clip_title needs visible")
bad("set_music", {"project": B, "gain": 2}, "invalid_input", "music gain 2 rejected")
bad("record_generation_cost", {"project": B, "items": [{"kind": "Bad Kind", "part": "x"}]}, "invalid_input", "cost kind pattern")
bad("list_comments", {"project": B, "status": "open"}, "invalid_input", "comment status enum")
bad("set_clip_look", {"project": B, "clip": "c1", "values": {"saturation": 1, "hue": 3}}, "invalid_input", "look values unknown key")
bad("get_project", {"project": "Bad Name"}, "invalid_input", "project name pattern")
bad("cut_range", {"project": B, "start": 1}, "invalid_input", "cut_range needs end")

untested = sorted(names - called)
# One file per project: a project saved in a chosen folder, taken off the list and added back by its path.
other = os.path.join(SCRATCH, "elsewhere")
os.makedirs(other, exist_ok=True)
r = ok("create_project", {"path": os.path.join(MEDIA, "test.mp4"), "name": "saved-elsewhere", "folder": other, "transcribe": False}, "create_project in a folder")
check("create_project saved one file in the folder", os.path.exists(os.path.join(other, "saved-elsewhere.reel.json")) and not os.path.exists(os.path.join(HOME, "saved-elsewhere.reel.json")), r)
ok("add_animation", {"project": "saved-elsewhere", "kind": "text-pop", "start": 1, "end": 2, "text": "Kept"}, "edit a project saved elsewhere")
r = ok("remove_project", {"project": "saved-elsewhere"})
listed = [p["name"] for p in ok("list_projects", {}, "list after remove")["projects"]]
check("remove_project took it off the list and kept the file", "saved-elsewhere" not in listed and os.path.exists(os.path.join(other, "saved-elsewhere.reel.json")), listed)
r = ok("add_project", {"path": os.path.join(other, "saved-elsewhere.reel.json")})
anims = ok("get_animations", {"project": "saved-elsewhere"}, "animations after add")["animations"]
check("add_project brought it back with its edits", r.get("project") == "saved-elsewhere" and len(anims) == 1 and anims[0].get("text") == "Kept", anims)
d = json.load(open(os.path.join(other, "saved-elsewhere.reel.json")))
check("everything is in the one file", "project" in d and "animations" in d and "history" in d and d["project"]["name"] == "saved-elsewhere", sorted(d))
bad("add_project", {"path": os.path.join(other, "nothing.reel.json")}, "not_found", "add_project of a missing file is refused")
# Moving a project's file to another folder: only the file moves, the video stays, the edits and the list follow it.
moved = os.path.join(SCRATCH, "moved here")
video_before = json.load(open(os.path.join(other, "saved-elsewhere.reel.json")))["project"]["main"]["file"]
r = ok("move_project", {"project": "saved-elsewhere", "folder": moved})
check("move_project moved only the project file", os.path.exists(os.path.join(moved, "saved-elsewhere.reel.json")) and not os.path.exists(os.path.join(other, "saved-elsewhere.reel.json")) and os.listdir(moved) == ["saved-elsewhere.reel.json"], r)
check("move_project returns the old and new paths", r.get("file", "").endswith("moved here/saved-elsewhere.reel.json") and r.get("previous", "").endswith("elsewhere/saved-elsewhere.reel.json"), r)
check("the video was not moved and the project still points at it", os.path.exists(video_before) and json.load(open(os.path.join(moved, "saved-elsewhere.reel.json")))["project"]["main"]["file"] == video_before, video_before)
listed = {p["name"]: p for p in ok("list_projects", {}, "list after move")["projects"]}
check("the list points at the new place", "saved-elsewhere" in listed and "moved here" in json.dumps(listed["saved-elsewhere"]), listed.get("saved-elsewhere"))
ok("add_animation", {"project": "saved-elsewhere", "kind": "text-pop", "start": 3, "end": 4, "text": "After move"}, "edit after move")
d = json.load(open(os.path.join(moved, "saved-elsewhere.reel.json")))
check("edits after the move land in the moved file", len(d["animations"]["animations"]) == 2 and not os.path.exists(os.path.join(other, "saved-elsewhere.reel.json")), d.get("animations"))
ok("undo", {"project": "saved-elsewhere"}, "undo after move")
check("undo works on the moved file", len(json.load(open(os.path.join(moved, "saved-elsewhere.reel.json")))["animations"]["animations"]) == 1)
r = ok("move_project", {"project": "saved-elsewhere", "folder": moved}, "move into the folder it is already in")
check("moving into the same folder changes nothing", r.get("file") == r.get("previous") and os.path.exists(os.path.join(moved, "saved-elsewhere.reel.json")), r)
open(os.path.join(other, "saved-elsewhere.reel.json"), "w").write("{}")
bad("move_project", {"project": "saved-elsewhere", "folder": other}, "exists", "move_project onto a taken file name is refused")
check("a refused move leaves the file where it was", os.path.exists(os.path.join(moved, "saved-elsewhere.reel.json")))
os.remove(os.path.join(other, "saved-elsewhere.reel.json"))
bad("move_project", {"project": "no-such-project", "folder": moved}, "not_found", "move_project of an unknown project")
# Any session opens a project file by its path in the app, and sees what the app has on screen.
r = ok("remove_project", {"project": "saved-elsewhere"}, "take the moved project off the list")
r = ok("open_in_app", {"path": os.path.join(moved, "saved-elsewhere.reel.json")}, "open_in_app by path")
listed = [p["name"] for p in ok("list_projects", {}, "list after open by path")["projects"]]
check("open_in_app by path puts the file on the list", r.get("project") == "saved-elsewhere" and r.get("file", "").endswith("moved here/saved-elsewhere.reel.json") and "saved-elsewhere" in listed, r)
bad("open_in_app", {}, "invalid_input", "open_in_app needs project or path")
bad("open_in_app", {"path": os.path.join(moved, "nothing.reel.json")}, "not_found", "open_in_app of a missing file")
state_file = os.path.join(HOME, ".app-state.json")
r = ok("get_app_state", {}, "get_app_state with the app closed")
check("get_app_state says the app is not open", r.get("running") is False, r)
json.dump({"pid": os.getpid(), "tabs": ["saved-elsewhere"], "project": "saved-elsewhere", "playhead": 2.5, "playing": False, "selectedWords": {"from": 1, "to": 2, "text": "hello there"}}, open(state_file, "w"))
r = ok("get_app_state", {}, "get_app_state with the app open")
check("get_app_state returns what is on screen", r.get("running") is True and r.get("project") == "saved-elsewhere" and r.get("playhead") == 2.5 and r.get("selectedWords", {}).get("text") == "hello there" and "pid" not in r, r)
json.dump({"pid": 999999, "project": "saved-elsewhere"}, open(state_file, "w"))
r = ok("get_app_state", {}, "get_app_state after the app died")
check("a state left by a quit app is ignored", r.get("running") is False, r)
os.remove(state_file)
# Rule books: the _rules folder by default, any folder through rulesDir in settings.json, read fresh on every call.
r = ok("get_rules", {}, "get_rules with no rule books")
check("get_rules reads the default _rules folder, empty at first", r.get("count") == 0 and r.get("default") is True and r.get("folder", "").endswith("/_rules") and os.path.isdir(os.path.join(HOME, "_rules")), r)
rules = os.path.join(HOME, "_rules")
os.makedirs(os.path.join(rules, "voice"), exist_ok=True)
open(os.path.join(rules, "b-cuts.md"), "w").write("# Cuts\nCut every um.")
open(os.path.join(rules, "a-captions.txt"), "w").write("Captions stay low.")
open(os.path.join(rules, "voice", "tone.markdown"), "w").write("Keep it warm.")
open(os.path.join(rules, "notes.png"), "w").write("not a rule")
open(os.path.join(rules, ".hidden.md"), "w").write("hidden")
r = ok("get_rules", {}, "get_rules with rule books")
check("get_rules reads md, txt and markdown, subfolders too, in order, and skips other and hidden files", [b["name"] for b in r.get("books", [])] == ["a-captions.txt", "b-cuts.md", "voice/tone.markdown"] and r["books"][1]["text"] == "# Cuts\nCut every um.", r)
mine = os.path.join(SCRATCH, "my rules")
os.makedirs(mine, exist_ok=True)
open(os.path.join(mine, "only.md"), "w").write("Mine.")
settings_path = os.path.join(HOME, "settings.json")
settings = json.load(open(settings_path)) if os.path.exists(settings_path) else {}
json.dump(dict(settings, rulesDir=mine, keep="this"), open(settings_path, "w"))
r = ok("get_rules", {}, "get_rules from a picked folder")
check("get_rules follows rulesDir in settings.json", r.get("default") is False and r.get("folder") == mine and [b["name"] for b in r.get("books", [])] == ["only.md"], r)
open(os.path.join(mine, "second.md"), "w").write("Added later.")
r = ok("get_rules", {}, "get_rules after a rule book is added")
check("get_rules reads the folder again on every call", r.get("count") == 2, r)
# Each project keeps its own rules folder; a new project starts with the folder saved last.
r = ok("create_project", {"path": os.path.join(MEDIA, "test.mp4"), "name": "rules-new", "transcribe": False}, "create a project after picking a rules folder")
check("a new project starts with the rules folder saved last", doc("rules-new")["project"].get("rulesDir") == mine, doc("rules-new")["project"].get("rulesDir"))
r = ok("get_rules", {"project": "rules-new"}, "get_rules for a project")
check("get_rules reads the project's own folder", r.get("folder") == mine and r.get("count") == 2, r)
other_rules = os.path.join(SCRATCH, "other rules")
os.makedirs(other_rules, exist_ok=True)
open(os.path.join(other_rules, "x.md"), "w").write("Other.")
r = ok("set_rules_folder", {"project": B, "folder": other_rules}, "set_rules_folder for one project")
check("set_rules_folder sets the project's folder and the one saved last", r.get("folder") == other_rules and r.get("last") == other_rules and pj(B).get("rulesDir") == other_rules and json.load(open(settings_path)).get("rulesDir") == other_rules and json.load(open(settings_path)).get("keep") == "this", r)
r = ok("get_rules", {"project": "rules-new"}, "get_rules for the other project after the change")
check("a project keeps its own folder when another project changes", r.get("folder") == mine, r)
r = ok("get_rules", {"project": B}, "get_rules for the changed project")
check("get_rules follows the changed project", [b["name"] for b in r.get("books", [])] == ["x.md"], r)
r = ok("set_rules_folder", {"project": B}, "set_rules_folder back to the default")
check("set_rules_folder without folder goes back to _rules", pj(B).get("rulesDir", "").endswith("/_rules") and r.get("count") == 3 and "rulesDir" not in json.load(open(settings_path)), r)
bad("set_rules_folder", {"project": B, "folder": os.path.join(SCRATCH, "no such folder")}, "not_found", "set_rules_folder of a missing folder")
# Writing rule books (2 Nov 2026): a new book, a whole new text, a part changed, and a project's own folder.
r = ok("write_rule_book", {"project": B, "name": "pace", "text": "Keep it quick."}, "write_rule_book makes a new book")
pace = os.path.join(rules, "pace.md")
check("write_rule_book writes a new .md into the project's folder and names the projects sharing it", r.get("created") is True and r.get("name") == "pace.md" and open(pace).read() == "Keep it quick.\n" and "pace.md" in r.get("books", []) and len(r.get("sharedWith", [])) > 0 and B not in r.get("sharedWith", []) and "previous" not in r, r)
r = ok("write_rule_book", {"project": B, "name": "pace.md", "text": "Keep it brisk and warm."}, "write_rule_book replaces a book")
check("write_rule_book keeps the text it had in .previous", r.get("created") is False and open(pace).read() == "Keep it brisk and warm.\n" and os.path.exists(r.get("previous", "")) and "/.previous/" in r.get("previous", "") and open(r["previous"]).read() == "Keep it quick.\n", r)
for name in ["../x.md", "/abs.md", ".hidden.md", "notes.png", "voice/../x.md"]:
    bad("write_rule_book", {"project": B, "name": name, "text": "x"}, "invalid_input", "write_rule_book refuses the name " + name)
r = ok("edit_rule_book", {"project": B, "name": "pace.md", "old": "brisk", "new": "lively"}, "edit_rule_book changes a part")
check("edit_rule_book replaces the exact text once", r.get("replaced") == 1 and open(pace).read() == "Keep it lively and warm.\n" and os.path.exists(r.get("previous", "")), r)
bad("edit_rule_book", {"project": B, "name": "pace.md", "old": "no such text", "new": "x"}, "not_found", "edit_rule_book of text not in the book")
bad("edit_rule_book", {"project": B, "name": "missing.md", "old": "a", "new": "b"}, "not_found", "edit_rule_book of a missing book")
bad("edit_rule_book", {"project": B, "name": "pace.md", "old": "e", "new": "E"}, "ambiguous", "edit_rule_book of text found more than once")
r = ok("edit_rule_book", {"project": B, "name": "pace.md", "old": "e", "new": "E", "all": True}, "edit_rule_book with all")
check("edit_rule_book with all replaces every one", r.get("replaced") == 3 and open(pace).read() == "KEEp it livEly and warm.\n", r)
r = ok("get_rules", {"project": B}, "get_rules after writing rule books")
check("the kept texts in .previous are not read as rule books", [b["name"] for b in r.get("books", [])] == ["a-captions.txt", "b-cuts.md", "pace.md", "voice/tone.markdown"], r)
r = ok("make_project_rules_folder", {"project": B}, "make_project_rules_folder")
own = r.get("folder", "")
check("make_project_rules_folder gives the project its own folder with copies of its rule books", own.endswith("/_rules-by-project/" + B) and sorted(r.get("copied", [])) == ["a-captions.txt", "b-cuts.md", "pace.md", "voice/tone.markdown"] and pj(B).get("rulesDir") == own and r.get("sharedWith") == [] and r.get("already") is False, r)
check("the folder new projects start with is not changed", "rulesDir" not in json.load(open(settings_path)), json.load(open(settings_path)))
r = ok("write_rule_book", {"project": B, "name": "only-this-one.md", "text": "Only for this project."}, "write_rule_book into the project's own folder")
check("a rule book written into a project's own folder", r.get("folder") == own and os.path.exists(os.path.join(own, "only-this-one.md")) and r.get("sharedWith") == [], r)
r = ok("get_rules", {}, "get_rules of the shared folder after a project's own book")
check("a project's own rule book reaches no other project", "only-this-one.md" not in [b["name"] for b in r.get("books", [])] and "pace.md" in [b["name"] for b in r.get("books", [])], r)
r = ok("make_project_rules_folder", {"project": B}, "make_project_rules_folder again")
check("a project that has its own folder keeps it", r.get("already") is True and r.get("folder") == own and "only-this-one.md" in r.get("books", []), r)
r = ok("make_project_rules_folder", {"project": "rules-new", "copy": False}, "make_project_rules_folder empty")
check("make_project_rules_folder with copy false starts empty", r.get("books") == [] and r.get("copied") == [] and pj("rules-new").get("rulesDir", "").endswith("/_rules-by-project/rules-new"), r)
r = ok("delete_rule_book", {"project": B, "name": "pace.md"}, "delete_rule_book")
check("delete_rule_book takes the book out and keeps its text in .previous", r.get("deleted") is True and "pace.md" not in r.get("books", []) and not os.path.exists(os.path.join(own, "pace.md")) and open(r.get("previous", "")).read() == "KEEp it livEly and warm.\n" and r.get("sharedWith") == [], r)
check("a book deleted from a project's own folder stays in the shared one", os.path.exists(pace), pace)
bad("delete_rule_book", {"project": B, "name": "pace.md"}, "not_found", "delete_rule_book of a book that is not there")
bad("delete_rule_book", {"project": B, "name": "../_rules/pace.md"}, "invalid_input", "delete_rule_book outside the rules folder")
r = ok("write_rule_book", {"name": "for-new-projects.md", "text": "Default rules."}, "write_rule_book without project")
check("write_rule_book without project writes into the folder new projects start with", r.get("folder", "").endswith("/_rules") and os.path.exists(os.path.join(rules, "for-new-projects.md")), r)
# A reel of several videos, arranged by the agent (2 Nov 2026).
r = ok("create_project", {"videos": [os.path.join(MEDIA, "test.mp4"), os.path.join(MEDIA, "blue.mp4")], "order": "given", "name": "multi", "transcribe": False}, "create_project from several videos")
check("several videos become one project, the first its own video and the others clips after it", [c["source"] for c in r["state"]["clips"]] == ["main", "s1"] and r["state"]["sources"][1]["file"].endswith("blue.mp4"), r.get("state", {}).get("clips"))
bad("create_project", {"transcribe": False}, "invalid_input", "create_project needs path or videos")
ok("import_transcript", {"project": "multi", "path": os.path.join(SCRATCH, "words.json")}, "multi: words")
r = ok("get_paragraphs", {"project": "multi"}, "get_paragraphs of a reel of several videos")
check("get_paragraphs names each paragraph's clip and video", r["paragraphs"][0]["clip"] == "c1" and r["paragraphs"][0]["source"] == "main" and r["paragraphs"][0]["video"] == "test.mp4" and r.get("clips") == 2, r)
d0 = ok("get_project", {"project": "multi", "words": False})["editDuration"]
bad("move_range", {"project": "multi", "start": 1, "end": 2, "to": 1.5}, "invalid_range", "move_range refuses a place inside the part")
h0 = past("multi")
r = ok("move_range", {"project": "multi", "start": 1, "end": 2, "to": 5})
check("move_range puts the part where it was asked, keeping the length", r.get("to") == 4 and r.get("end") == 5 and ok("get_project", {"project": "multi", "words": False})["editDuration"] == d0, r)
check("move_range shows where the part landed", json.load(open(os.path.join(HOME, "_cache", "multi", "focus.json")))["action"].startswith("Moving 0:01 to 0:02"), None)
w = ok("get_words", {"project": "multi", "from": 4, "limit": 1}, "get_words after a move")
check("the moved words play at their new place", w.get("text", "").startswith("2 4.05 4.45 three"), w.get("text"))
check("move_range is one undo step", past("multi") == h0 + 1, past("multi"))
ok("undo", {"project": "multi"}, "undo the move")
w = ok("get_words", {"project": "multi", "from": 1, "limit": 1}, "get_words after undoing the move")
check("undo puts the part back", w.get("text", "").startswith("2 1.05 1.45 three"), w.get("text"))
r = ok("insert_clip", {"project": "multi", "video": "main", "in": 0, "out": 1, "at": 3})
check("insert_clip puts a part of the video in at the time asked", r.get("start") == 3 and r.get("end") == 4 and ok("get_project", {"project": "multi", "words": False})["editDuration"] == d0 + 1, r)
check("insert_clip names the video it places", json.load(open(os.path.join(HOME, "_cache", "multi", "focus.json")))["action"] == "Placing 0:00 to 0:01 of test.mp4 here", None)
r = ok("insert_clip", {"project": "multi", "video": os.path.join(MEDIA, "blue.mp4"), "in": 0, "out": 0.5, "at": 0}, "insert_clip of another video by its path")
check("a video already in the project is used again, not added twice", len(ok("get_project", {"project": "multi", "words": False})["sources"]) == 2 and r.get("start") == 0, r)
r = ok("get_words", {"project": "multi", "video": "main", "limit": 3}, "get_words of one video")
check("get_words with video lists its own words and where the reel plays them", r.get("text", "").split("\n")[0].startswith("0 0.05 0.45 one [in the reel at") and r.get("file") == "test.mp4", r)
bad("get_words", {"project": "multi", "video": "s9"}, "not_found", "get_words of a video the project does not have")
# Transcribing every video (2 Nov 2026): a first video with no sound does not stop the others, and WhisperX's own
# output is read from its file, not looked for in the project's document ("has no words").
ok("create_project", {"videos": [os.path.join(MEDIA, "silent.mp4"), os.path.join(MEDIA, "test.mp4")], "order": "given", "name": "silent-first", "transcribe": False}, "create_project, the first video silent")
r = ok("transcribe", {"project": "silent-first", "wait": True}, "transcribe every video, the first silent")
check("transcribe goes on to the videos after a silent first one", r.get("done") == ["test.mp4"] and r.get("failed") == [] and r.get("words", 0) > 0, r)
check("the words of the added video are kept in the project's file", any(doc("silent-first").get("words", {}).values()), list(doc("silent-first").get("words", {}).keys()))
check("transcribe leaves no working files behind", not [f for f in os.listdir(os.path.join(HOME, "_cache", "silent-first", "media")) if f.startswith(("whisperx-", "audio-"))], os.listdir(os.path.join(HOME, "_cache", "silent-first", "media")))
check("get_status says how many words came from which videos", "words from 1 of 1 video" in ok("get_status", {"project": "silent-first"}).get("message", ""), ok("get_status", {"project": "silent-first"}))
r = ok("get_words", {"project": "silent-first", "video": "s1", "limit": 3}, "get_words of the transcribed video")
check("the added video's words are read", r.get("file") == "test.mp4" and len(r.get("text", "")) > 0, r)
bad("transcribe", {"project": "silent-first", "wait": True}, "no_audio", "transcribe again when the silent video is all that is left")
# Who edited a project, kept in the app's folder for it.
ed = json.load(open(os.path.join(HOME, "_cache", B, "editors.json")))
check("the edits are recorded with who made them", len(ed) >= 1 and ed[0]["edits"] >= 1 and ed[0]["who"] and ed[0]["lastTool"], ed)
json.dump(settings, open(settings_path, "w"))
untested = sorted(names - called)
check("every tool was called", not untested, untested)
proc.stdin.close()
proc.wait(timeout=10)
fails = [r for r in results if not r[1]]
print(f"\n{len(results) - len(fails)} passed, {len(fails)} failed of {len(results)}")
for f in fails:
    print("  FAIL", f[0], str(f[2])[:300])

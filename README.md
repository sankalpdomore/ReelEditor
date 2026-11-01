# Reel Editor for Mac

> **Its own repo since 1 Nov 2026.** The app began as `tools/reel-editor-mac` inside ContentApp, and was detached into this
> repo on 1 Nov 2026. The copy in ContentApp is frozen as it was that day; all work happens here.

The ContentApp reel editor as its own native Mac app (SwiftUI and AVFoundation), with an MCP server so Claude or any
other agent can edit the same projects through tools. The web reel editor (`/reel-editor`, `lib/reel-tools`) is
untouched. This is a separate port of it.

## How it works

- **The video is never touched.** A project points at the video where it is and only ever reads it.
- **One file per project** (Sankalp, 1 Nov 2026). A project is a single JSON file, `<name>.reel.json`, saved in any
  folder you pick (`~/Movies/Reel Editor` by default, or `$REEL_EDITOR_HOME`), with one section per kind of data:
  - `project`: the source video and the edit decision list. Clips with in and out points, range cuts, word cuts, word
    corrections, sections, captions, title and speed. It is the same EDL as the web editor's `edits.json`, ported line
    for line in `Sources/ReelCore/EDL.swift`.
  - `animations`: the coded animation layer. Each animation has a kind, a `start` and `end` in edit time, a side, a
    height and its fields (text, colour, numbers).
  - `transcript`: the words with their times (WhisperX, or imported), and `words`: the words of the added videos and
    voice overs, by a hash of their path.
  - `history`: undo and redo. Cuts (and their approval), trims, clip changes (a clip's look, placement and hidden
    title too), word cuts, audio and face overlays (with their windows) and animation changes are undoable. The reel's
    settings (its look, music, voice volume and bass and treble, caption, caption position, status, links, cost) are not.
  - `comments`: the comments on the script (`add_comment`), and `draft`: a draft reel's plan (`create_draft_reel`),
    which can exist before the project has a video.
- **What is not project data stays out of the file.** `projects.json` in the Reel Editor folder lists where each project
  file is and when it was opened. The running job's status, the lock and the cached waveforms are in the app's own
  folder for the project, `_cache/<name>/`. Exports go beside the project file, in `<name> exports/`. In the code each
  section is still named by its old file name: `Store.file(name, "project.json")` is a key whose reads and writes land
  in the `project` section (`Sources/ReelCore/Project.swift`).
- **Opening and saving.** File > New Project from Video (Cmd N) asks for the video, then where to save the project file.
  File > Open Project (Cmd O) opens a `.reel.json` from anywhere and puts it on the list. The tabs open at launch are the
  ones left open last time, not every project. The Open a reel page lists the recent projects with their paths; right
  click one to show it in Finder or take it off the list (the file stays). For agents: `create_project` takes `folder`,
  `add_project` puts a file on the list, `remove_project` takes one off, and `list_projects` shows each project's file.
- **Projects made the old way** (a folder of JSON files in the Reel Editor folder) become one file each the first time the
  app or `reel-mcp` starts; the old folder is kept in `_migrated/`.
- **Three times**, as in the web editor: source time (inside a video), edit time (the clips end to end, before cuts,
  which is what every tool takes) and output time (after the cuts, divided by the speed).
- **Preview equals export.** The plan becomes an `AVMutableComposition` (`Composition.swift`). The title and the
  animations are one Core Animation layer tree (`Overlay.swift`, `AnimationLayers.swift`), which the preview plays on an
  `AVSynchronizedLayer` and the export hands to `AVVideoCompositionCoreAnimationTool`.
- **Looks, placed clips and face windows** are drawn by `ReelCompositor` (`Compositor.swift`), a custom
  `AVVideoCompositing` with Core Image, used only when a reel has one: the reel's look and each clip's own look (the
  mapping of the web editor's `lib/reel-look.ts`), a clip's picture zoomed and moved (`lib/reel-place.ts`), and each face
  overlay's video in a rounded window with a #333 border and a soft shadow, easing between its moves. The preview plays
  it as is. AVFoundation's animation tool draws white over a custom compositor, so such a reel exports in two passes: the
  picture and the sound to a ProRes file beside the export, then the captions, title and animations laid on it.
- **Sound.** Voice overs and face overlays are tracks of their own; the music bed is laid after the speed, so it never
  speeds up, with its volume and fades. The voice volume (0 to 10), the voice's bass and treble and each overlay's own gain
  above 1 and bass and treble run as an `MTAudioProcessingTap` on the audio mix (`AudioFX.swift`): RBJ shelves at 120 Hz
  and 6 kHz and a limiter at 0.89, in the preview and the export alike. A sound effect (`sound` on an overlay) skips the
  voice volume and the voice's bass and treble.
- **The app and agents share one tool layer.** Every button in the app calls the same tool an agent calls
  (`Sources/ReelCore/Tools.swift`). The files are locked per project, so both can edit at once. The open window polls
  the project's revisions and reloads within half a second of an agent's edit.

## Look

The app uses the main ContentApp web app's design language, not stock macOS (Sankalp, 31 Oct 2026), and is laid out
like the web reel editor. `Sources/ReelEditor/Design.swift` ports it: Inter type and Phosphor Bold and Fill icons (both
in `Resources/Fonts`, copied into the app by build.sh and registered at launch), the clean grey stops `#111` to `#eee`
with `#ddd` borders, the web Button variants as fully round pills (the black gradient primary, the white outline, the
ghost, the white to grey gradient of Open folder), the grey Tabs container with a white active tab, uppercase panel
labels, the Draft and Live pills, the inset card (a grey shell with a white card inside, each level 4 points less
rounded), fields, the switch, the slider and the spinner. Spacing is in multiples of 4. A view takes its look from
there and never from a native control style; only the right click menus are the system's. An icon is named as on the
web (`Icon("scissors")` is `ph-bold ph-scissors`), and `phosphor-codes.sh` writes `PhosphorCodes.swift` from the names
used, so run it after naming a new icon. The app icon is the web editor's brand mark, the film strip in white on a black
tile, drawn by `make-icon.swift` into `Resources/AppIcon.icns`.

The window, top to bottom: the top bar (the brand, undo and redo, the reel's name with its Draft or Live pill, which
switches it, the Wide, Tall and Distraction free tabs and Export), the row of project tabs (the open one white and
joined to the page, a Draft or Live pill and a close button on each, + New / Open project, Cmd T new tab, Cmd W close
tab, Shift Cmd ] and [ to move between tabs) with the MCP status at its right end, then the editor. Every project opens
as a tab at launch. A project made later, from File > Open Video, a dropped video or an agent's `create_project`, gets
a tab of its own, and a new tab shows the Open a reel page: a dashed drop area with Choose a video, then every project
as a card, newest first. The MCP status shows the agent connected (Claude Code, Codex, Claude and so on) and the Mac it
runs on, or MCP not connected. Each reel-mcp writes a heartbeat to `.mcp/<pid>.json` in the projects folder once its
client introduces itself, and removes it on exit. The pill shows the Claude logo (`Resources/Brand/claude.svg`, from the web app's
brand marks) after a green dot, and "Claude session (1)", the number of sessions using the editor; the
sessions themselves are listed in the panel. The status is green while an agent is connected. Click it and a panel drops down under it, right
aligned inside the window (Escape or a click elsewhere closes it), with every connection in two tabs, each account drawn
as the LiveAssistant app draws it: the account with its plan, and a tree line down from it with a branch to its 5 hour
limit, its weekly limit and each of its sessions. Each limit is one bar of what is used, green for the part this
editor's sessions used and blue for the rest of the account, with the split in words under it, estimated as the
LiveAssistant app estimates its own share: the account's use times these sessions' share of the tokens all the
account's sessions spent since the window began (new input, cache writes and output in full, cache reads at a tenth).
Each estimate is logged as `editor_share_of_limits`. The pill's count is the sessions using this editor, not every session that has its tools.
Each session in the panel has a disconnect button (with a confirm): it asks that session's reel-mcp to quit (SIGTERM),
so the session loses the editor's tools and leaves the panel until it reconnects with `/mcp` in Claude Code; the Claude
session itself keeps running. Each disconnect is logged as `mcp_disconnect`. `REEL_EDITOR_MCP=editor` (or all) opens the panel at launch, for a
snapshot. This editor (the default) shows only the Claude sessions that have used the editor, a tool
called or the Chat tab listened to, each with its account's limits, and the pill names the latest of them. All
sessions shows every connection, grouped by the Claude account it is signed in to: the session's name and folder, the config folder it runs
under (claude, claude-2, claude-3), its last tool, and the tokens it has used. reel-mcp finds its Claude Code session
from `CLAUDE_CONFIG_DIR` and `<config>/sessions/<parent pid>.json`, reads only the email and organisation from the
account file, and the app adds up the session's transcript (`SessionUsage.swift`), its agents included. A server
started before it reported its session is matched from outside, by its parent process and that process's session file
in whichever `~/.claude*` folder holds it. Each account's 5 hour and weekly limits are read the way the LiveAssistant app
reads them (`AccountLimits.swift`): the claude command line is started with that account's config folder, asked for
one word on Haiku (about 2,000 tokens), and its `rate_limit_event` line gives each window's use and reset; no token is
ever read. An account is read at most every 20 minutes, or on Refresh. Every reading goes to the app's log: an
`account_limits` line per account (used and left percent, reset time) and an `mcp_session_usage` line per session (the
account, the config folder, the session, its tokens), written when the connections change, every 20 minutes and when
the details open. `get_logs` reads them back.

Inside a tab, the left panel is the transcript, as in the web editor: its head reads TRANSCRIPT with the cuts and seconds
saved, Approve for cuts Claude made from the chat (they wait in amber until approved), and the Project and Chat buttons,
which open their cards floating under the head, and Open folder. The project's title
sits in big bold type under them: it is plain text until clicked, then Return or a click elsewhere saves it, which also
renames the project folder to match (`.renames.json` remembers old names). Clicking a layer on the timeline (an
animation, a clip, a voice or face overlay) opens its settings in a card floating just above it (`Floating.swift`): an
animation's kind, times, side, height and fields; a clip's name, sound, title, look, placement, voice over, split and
delete; an overlay's name, volume, voice or sound effect, words, split and remove. A click elsewhere or Escape closes a
card. `REEL_EDITOR_FLOAT=project` (or chat, animation:a3, clip:c1, overlay:o1) opens a card at launch, for a snapshot.
The transcript has a time column on the left
and a coloured ring and heading for each part. The Project card holds the reel's status, its post caption and caption
position, the look (a saved look or the seven sliders), the sound (voice volume, bass and treble, the music bed), the
comments, the source files with Relink for one that moved, the clips, the title, the transcript, Export, the theme and
the MCP command. The video is on the right on a light grey backdrop with the transport under it. The timeline panel
runs across the bottom: a toolbar (cut, restore, split, delete, play, the times, speed, zoom, and Follow in a pill of its
own), then the
layers with their names in a column on the left (Add layer, Animation, Video, Audio, Voice and face, Captions). Cuts are
red hatching. Right click a clip for its name, its sound, a voice over, the title over it, its own look and its
placement; right click a voice or face overlay for its volume, name, words, split or sound effect flag. A trackpad pinch on
the timeline zooms it around the fingers. The dividers between the transcript and the video and above the timeline drag,
and a double click resets them; the column widths, the timeline's height, its zoom and Follow are saved, so the app
opens as it was left.

Cmd plus and Cmd minus zoom the whole window in 10% steps, 60% to 140%, and Cmd 0 puts it back, like a browser's page
zoom: the window is laid out at its size divided by the zoom and scaled, so everything reflows. It is saved per Mac. It
opens in Light mode. View > Appearance, or the theme tabs in the Project card, switch it to Dark or System, and the
choice is saved. The app needs macOS 26 or later.

Menus never open outside the window: a dropdown's options open in the window's own menu layer (`MenuHost.swift`),
right aligned under the field with an arrow at the top right pointing at its caret, springing out of that corner; the
MCP panel has the same arrow. `REEL_EDITOR_OPEN_MENU=<value>` opens the dropdown set to that value at launch.

For checking the interface without screen recording access, `REEL_EDITOR_SNAPSHOT=<file.png>` writes a picture of the
window every few seconds and keeps the app in the background, `REEL_EDITOR_FLOAT=project` opens the Project card, and
`REEL_EDITOR_CARD=look` (or reel, sound, comments, sources) scrolls the Project card to that section.

## Build and run

```bash
./build.sh
```

This builds in release mode, assembles `Reel Editor.app` (with the `reeleditor://` URL scheme and video document
types), signs it ad hoc, installs it to `~/Applications` and opens it. Use `--no-open` to skip opening it.
`swift build` on its own builds debug binaries in `.build/`.

## Connecting an agent (MCP)

The MCP server ships inside the app, `Contents/MacOS/reel-mcp`, and speaks MCP over stdio:

```bash
claude mcp add --scope user reel-editor -- "$HOME/Applications/Reel Editor.app/Contents/MacOS/reel-mcp"
```

Tools: `list_projects create_project get_project cut_range restore_range delete_words restore_words correct_word
trim_clip split_clip delete_clip reorder_clips add_clip undo redo set_captions set_title set_speed set_sections
list_animation_kinds get_animations add_animation update_animation remove_animation set_animations transcribe
import_transcript get_status export rename_project open_in_app rename_clip add_audio_overlay update_audio_overlay
delete_audio_overlay mute_clip_audio transcribe_source wait_for_app_message reply_in_app get_app_chat get_logs`. Each one publishes a JSON schema, and every call is checked against it.

The web editor's tools as of 31 Oct 2026 are here too, with the same names, arguments and meaning (`ToolsWeb.swift`), so
an agent uses either editor the same way, and `reel` is taken as another name for `project` in every tool:
`approve_cuts set_clip_title set_clip_look set_clip_placement add_face_overlay set_face_window split_overlay set_music
set_video_look list_video_looks save_video_look set_reel_caption set_title_text set_caption_position set_voice_gain
set_voice_eq set_references set_reel_status record_generation_cost list_comments add_comment resolve_comment
edit_comment reopen_comment create_draft_reel get_draft_reel set_draft_section_status set_draft_need_status
set_draft_published check_sources relink_source reveal_in_finder open_project_folder rename_reel`, and the web names
`list_reels`, `get_timeline` and `import_video` for `list_projects`, `get_project` and `create_project`. Where the Mac
app differs: `set_music` takes a track as an audio file's path or a file name in `<projects folder>/_music` (there is no
music library); saved looks live in `<projects folder>/_looks` (or `looksDir` in settings.json, which can point at the
repo's `data/video-look-settings`); `reveal_in_finder` takes the export's path (`file`) instead of a served url;
`set_references` stores the links without adding the web editor's default rule books. `REEL_EDITOR_NO_OPEN=1` keeps the
Finder and app opening tools from opening anything, for tests.

A cut or word cut made through MCP waits for Sankalp's approval (`pending` on the cut, `pendingWords` on the EDL) until
`approve_cuts`, unless the call passes `approved: true`; it plays and exports as a cut either way. A cut made in the app
is approved at once.

A typical session: `list_projects`, `get_project` (clips, cuts, words with indexes and edit times, animations), then
`delete_words` or `cut_range`, `add_animation`, check with `get_project`, and `export` with `wait: true`.
`open_in_app` brings the project up in the window.

## Talking to Claude from the app

The Chat (the button in the transcript's head) has two pairs of tabs. **Direct** or **Claude Code** picks who answers;
**side panel** or **floating** picks where it sits, a 400 point column on the right of the window or a card under the
button, and the app remembers both.

**Direct** (`DirectChat.swift`) needs no Claude Code session: the app starts the claude command line itself, as the
LiveAssistant app does, on the account and model picked at the top of the chat (a `~/.claude*` config folder through
`CLAUDE_CONFIG_DIR`; Sonnet, Opus or Haiku; and an effort, the command line's `--effort`: default, low, medium, high,
extra high or max), with this app's reel-mcp as its only tools (`--strict-mcp-config`,
`--tools ""`, `--allowedTools mcp__reel-editor`). It keeps running for the conversation. Each message goes in with what
is on screen (the project, the playhead, the clip, the selection); Claude's answers and each tool it runs show in the
chat, and the editor reloads as its edits land. The command line signs in by itself, no token is read. The conversation
is kept in `<projects folder>/_chat/direct.json`; every start is logged as `direct_chat_start` and every turn as
`direct_chat_turn` with its tokens and cost, and the account's limits read from each turn update the MCP panel.
`REEL_EDITOR_DIRECT_SAY=<text>` sends one message at launch, for checking it end to end.

**Claude Code** is the conversation with a Claude Code session that listens, as below.

The Chat tab is one conversation with the agent connected over MCP, for every project, kept in
`~/Movies/Reel Editor/_chat/chat.json`. A message sent there carries what is on screen (the project, the playhead, the
clip, the selection and the selected words). Ask Claude once, in its own chat: "Listen to the Reel Editor chat". It then
calls `wait_for_app_message`, which waits until a message arrives and hands it over, so the message also shows in
Claude's chat as that tool's result. Claude acts with the other tools, answers with `reply_in_app` (shown in the app)
and calls `wait_for_app_message` again to keep listening. Every tool it runs shows in the Chat tab as a short activity
line, and the MCP status in the tab bar says listening. A message sent while no agent listens waits, marked waiting
for an agent, and is handed over as soon as one does.

## QA logs

Every tool call (from the app's buttons or from an agent), every app action (launch, opening and closing tabs,
creating and renaming projects, layouts, transcriptions, exports) and every error is one JSON line in
`~/Movies/Reel Editor/_dump/app-<date>.jsonl` or `mcp-<date>.jsonl`: the time, the process, the build (from
`Contents/Resources/build.json`, written by build.sh with the date and the git commit), the arguments, whether it
worked, the error and how long it took. The MCP server also logs its start, its client and its exit. `get_logs` reads
them back (`errors_only` for the failures), so a QA pass starts with one call.

## Layouts

As in the web editor: **Wide** (the transcript and the video side by side, the timeline across the bottom, the default for
a landscape video), **Tall** (the video full height on the right, the timeline under the transcript, the default for a
portrait video) and **Distraction free** (only the video; Escape leaves). The buttons sit in the transport bar. The
divider between the transcript and the video and the one above the timeline can be dragged, a double click resets
them, and the layout per kind of video, the timeline's height and the video's width are kept. A taller timeline gives
the extra room to the filmstrip and the waveform.

## Clips, muted sound and voice overs

Ported from the web editor's 21 Oct 2026 changes: a clip can be renamed (an added clip gets a readable name from its
file, `part2-login-voiced-v4.mp4` is "Part 2 login"), its own sound can be muted, and audio files can be laid over the
project on the Voice over layer (`audioOverlays` in project.json, part of undo). An overlay stays at its edit time,
follows the cuts like a clip's own sound, and moves with the picture when a clip before it is trimmed, deleted or put
in. The words of added clips and of voice overs are fetched with WhisperX (or placed from an exact script) and kept in
`media/words-<hash>.json`, so the captions read every part; a muted clip's words are left out. On the timeline, right
click a clip (rename, mute or unmute, lay a voice over on it, split, delete), a voice over (volume, rename, get its
words, remove) or the empty Voice over layer (add audio there); hovering shows each one's name. An overlay's
gain above 1 is played louder by the audio tap (`AudioFX.swift`) and limited so it does not clip.

## Animation kinds

`text-pop`, `lower-third`, `counter`, `emoji-burst`, `progress-bar`, `callout` and `checklist`. Each one is drawn
natively from its span alone, so scrubbing and the export always agree. The web editor's React animations (three goals,
gmail flood and the rest) are not ported. A new kind is one function in `AnimationLayers.swift` plus an entry in
`ANIMATION_KINDS`.

## Transcription

`transcribe` runs `Resources/transcribe_whisperx.py`, a copy of `tools/reel-stitch/transcribe_whisperx.py`, with the
WhisperX venv in `~/Coding projects/WhisperX/venv`. To point it elsewhere, set `whisperxPython` and `whisperxScript` in
`~/Movies/Reel Editor/settings.json`, or the `REEL_WHISPERX_PYTHON` and `REEL_WHISPERX_SCRIPT` environment variables.
`import_transcript` takes any `[{w, s, e}]` file instead.

## Keys in the app

Drag across words in the transcript, or click one and shift click another, to select them; a menu floats at the
selection with Cut, Uncut, Correct (retype the words, one for each selected) and Comment for Claude (left on the words
with add_comment for an agent to pick up), as the web editor's selection menu. A range dragged on the timeline gets the
same menu without Correct. Escape lets go of a selection. `REEL_EDITOR_SELECT=words:5-9` or `range:1.5-3` opens with a
selection, for checking the menus in a snapshot.

Space plays, Delete cuts the selection (a dragged range on the timeline, or words selected in the transcript),
Shift Delete restores it, S splits at the playhead, the arrows step a frame (a second with Shift), and = and - zoom
the timeline in and out. Cmd plus, Cmd minus and Cmd 0 zoom the whole window. Cmd E exports. Cmd Z and Shift Cmd Z undo
and redo. Drag an animation block to move it, or drag its edges to stretch it.

## Planned: individual layers

Decided by Sankalp on 21 Oct 2026, the same decision as in the web editor (PRD.md, Phase 32, "Individual layers"): the timeline is free of a fixed set of rows and shows every layer individually. A layer is any piece of the reel, a screen clip, the face of a call out as a video overlay in a rounded window, a coded animation, a voice over, a music bed, each its own row with its own name that can be added, trimmed, cut, split, moved, animated and removed on its own, with no limit on how many. The layer tools are allowed in `reel-mcp` (add a layer of a kind, list the layers, change one, remove one), so an agent builds a reel from layers, and they are the same tools as the web editor's `lib/reel-tools`. The first example, the Face layer (`add_face_overlay`, `set_face_window`, `split_overlay`), is in this app's model, preview and export since 31 Oct 2026; the app's window does not draw it on the timeline yet. The general layer list is not built yet.

## Not in this version

There is no caption style editor yet: captions use the fixed reel look (their position can be set with
`set_caption_position`). The app's window does not yet show the controls for the tools ported on 31 Oct 2026 (looks,
placement, face windows, music, voice volume, comments, drafts): they work through MCP and render in the preview and the
export. The first open of a long video takes about a minute to read its waveform, which is then cached.

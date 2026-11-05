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
- **Opening and saving.** File > New Project from Videos (Cmd N) asks for one video or several, then where to save the project file. Several videos, chosen together or dropped together, make one reel laid out in the order they were recorded (each video's own creation date, or its file's), the first as the project's own video and each of the others as a clip after it, and every one is transcribed in turn (Sankalp, 2 Nov 2026); `create_project` takes `videos` and `order` (recorded or given) for the same.
  File > Open Project (Cmd O) opens a `.reel.json` from anywhere and puts it on the list. The tabs open at launch are the
  ones left open last time, not every project. The Open a reel page lists the recent projects with their paths; right
  click one to show it in Finder, move it to another folder or take it off the list (the file stays). Hovering a card shows
  Move, which asks for a folder in Finder and moves only the project file there: the video stays where it is, an open tab
  keeps working, and new exports go beside the file's new place (Sankalp, 1 Nov 2026). For agents: `create_project` takes
  `folder`, `add_project` puts a file on the list, `remove_project` takes one off, `move_project` moves the file to
  another folder, and `list_projects` shows each project's file.
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
with `#ddd` borders and separators (Sankalp, 2 Nov 2026), the web Button variants as fully round pills (the black gradient primary, the white outline, the
ghost, the white to grey gradient of Open folder), the grey Tabs container with a white active tab, uppercase panel
labels, the Draft and Live pills, the inset card (a grey shell with a white card inside, each level 4 points less
rounded), fields, the switch, the slider and the spinner. Spacing is in multiples of 4. A view takes its look from
there and never from a native control style; only the right click menus are the system's. An icon is named as on the
web (`Icon("scissors")` is `ph-bold ph-scissors`), and `phosphor-codes.sh` writes `PhosphorCodes.swift` from the names
used, so run it after naming a new icon. The app icon is the web editor's brand mark, the film strip in white on a black
tile, drawn by `make-icon.swift` into `Resources/AppIcon.icns`.

The window, top to bottom: the top bar (the brand, undo and redo, the reel's name with its Draft or Live pill, which
switches it, and a gear whose menu holds Project details, Show in Finder and Move to another folder, which moves the
project file, then the Wide, Tall and Distraction free tabs and Export), the row of project tabs (the open one white and
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
Each session on the panel's This editor tab has a Disconnect button (All sessions has none, since only a session's link to this editor is the editor's to cut, Sankalp, 4 Nov 2026), which asks Disconnect? with No and Yes; Yes asks that session's
reel-mcp to quit (SIGTERM) and takes the session off the panel at once, so the session loses the editor's tools and stays off until it reconnects with `/mcp` in Claude Code; the Claude
session itself keeps running. Each disconnect is logged as `mcp_disconnect`. `REEL_EDITOR_MCP=editor` (or all) opens the panel at launch, for a
snapshot. This editor (the default) shows only the Claude sessions that have used the editor, a tool
called, each with its account's limits, and the pill names the latest of them. All
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
and a coloured ring and heading for each part. The Project card holds only what the project is, nothing that changes the
reel (Sankalp, 1 Nov 2026): when it was started, when it was last edited, where its file is saved, the video it reads,
its length and size, and Edited by, each session or the app that edited it with its account, how many edits and the last
one (kept in `_cache/<name>/editors.json`, counted from every tool call that changed the project, from 1 Nov 2026 on).
The reel's look, sound, caption, comments and the rest are set from each layer's own card or through the chat and the
tools. App settings, the button left of Export at the right end of the top bar (Sankalp, 2 Nov 2026), opens a card under itself with the Appearance tabs, Notifications and the
command that adds the editor's tools to Claude Code; `REEL_EDITOR_APP_SETTINGS=1` opens it at launch, for a snapshot. The video is on the right on a light grey backdrop with the transport under it. The timeline panel
runs across the bottom: a toolbar (cut, restore, split, delete, play, the times, speed, zoom, and Follow in a pill of its
own), then the
layers with their names in a column on the left (Add layer, Animation, Video, Audio, Voice and face, Captions). Cuts are
red hatching. Right click a clip for its name, its sound, a voice over, the title over it, its own look and its
placement; right click a voice or face overlay for its volume, name, words, split or sound effect flag. Every card, panel and modal (the layer cards, Project, Chat, Captions, App settings, the MCP panel, the rule books) is at most 60% of the window's height and scrolls past it, and every scroll bar is 8 points wide, half the system's, a rounded grey knob with no track (`ThinScrollers.swift`). The caption on the video preview is a layer too: outlined on hover, and a click opens the Captions card. The transcript's head says the time saved as people say it, 2 min 26 s or 1 h 4 min (Sankalp, 2 Nov 2026). The Audio layer's name opens the Voice card (Sankalp, 2 Nov 2026), as the web editor's: how loud all the voices are together, 0 to 1000% with steps at 100, 150, 200, 250, 300, 400, 500, 600, 700, 800 and 1000%, and their bass and treble (set_voice_gain and set_voice_eq). Above 100% the sound runs through the app's own gain and limiter in the preview and the export alike; on an export, 200% measured 6 dB louder, 400% 12 dB and 1000% 17 dB, the peaks held under -0.5 dB. The app remembers the project in front and opens on it after a restart. Clips read Clip 1, Clip 2 on screen, in the clip heads, on the timeline and in the clip card, not c1 (Sankalp, 2 Nov 2026): the number is the clip's own, the tools' c5 is Clip 5, and it stays with the clip when clips move, so the chat's Claude, told to say clip 5, always means what is on screen. Name it from the script, in the gear beside the reel's name, asks the chat's Claude to read the script and the rule books' naming rule (by default the date the video was recorded as year-month-day, then two to four words on what it is about; get_project gives recorded) and rename the project. A rename, from the app or an agent, copies the project file under the new name, reads the copy back and checks it part by part against the old one, moves the list and the cache to it, and only then sends the old file to the Trash; a copy that does not match is removed and nothing changes. The tab, its chat and the playhead follow the project to its new name (Sankalp, 2 Nov 2026). In the transcript the word at the playhead is white on black, so it stands out as the video plays (Sankalp, 2 Nov 2026). A click in the gap before time zero takes the playhead to the start, and in the gap after the end to the end, and the 0:00 label starts at the edge (Sankalp, 2 Nov 2026). A trackpad pinch on
the timeline zooms it around the fingers, and so does Cmd or Ctrl with the scroll wheel, around the pointer. Each divider takes only its 1 point line in the layout, with its 8 point grab area laid over it, so the lines that meet it run right up to it with no white gap (Sankalp, 2 Nov 2026). The dividers between the transcript and the video and above the timeline drag,
and a double click resets them; the timeline's layers keep their own heights however tall it is dragged, the room past the last layer is left empty, and a timeline shorter than its layers scrolls up and down to show them all (Sankalp, 2 Nov 2026). The column widths, the timeline's height, its zoom and Follow are saved, so the app
opens as it was left.

Cmd plus and Cmd minus zoom the whole window in 10% steps, 60% to 140%, and Cmd 0 puts it back, like a browser's page
zoom: the window is laid out at its size divided by the zoom and scaled, so everything reflows. It is saved per Mac. It
opens in Light mode. View > Appearance, or the Appearance tabs in App settings, switch it to Dark or System, and the
choice is saved. The app needs macOS 26 or later.

Menus never open outside the window: a dropdown's options open in the window's own menu layer (`MenuHost.swift`),
right aligned under the field with an arrow at the top right pointing at its caret, springing out of that corner; the
MCP panel has the same arrow. `REEL_EDITOR_OPEN_MENU=<value>` opens the dropdown set to that value at launch, and `REEL_EDITOR_OPEN_MENU=project-settings`
opens the top bar's gear menu.

For checking the interface without screen recording access, `REEL_EDITOR_SNAPSHOT=<file.png>` writes a picture of the
window every few seconds and keeps the app in the background, `REEL_EDITOR_FLOAT=project` opens the Project card, and
`REEL_EDITOR_APP_SETTINGS=1` opens App settings.

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

Tools: `list_projects create_project add_project remove_project move_project get_project get_words get_paragraphs set_focus audit_audio move_range insert_clip cut_range restore_range delete_words restore_words correct_word
trim_clip split_clip delete_clip reorder_clips add_clip undo redo set_captions set_title set_speed set_sections
list_animation_kinds get_animations add_animation update_animation remove_animation set_animations transcribe
import_transcript get_status export rename_project open_in_app get_app_state get_caption_style set_caption_style list_fonts hide_captions show_captions add_text_layer update_text_layer get_rules set_rules_folder write_rule_book edit_rule_book delete_rule_book make_project_rules_folder rename_clip add_audio_overlay update_audio_overlay
delete_audio_overlay mute_clip_audio transcribe_source get_logs`. Each one publishes a JSON schema, and every call is checked against it.

The web editor's tools as of 31 Oct 2026 are here too, with the same names, arguments and meaning (`ToolsWeb.swift`), so
an agent uses either editor the same way, and `reel` is taken as another name for `project` in every tool:
`approve_cuts set_clip_title set_clip_look set_clip_placement add_face_overlay set_face_window split_overlay set_music
set_video_look list_video_looks save_video_look set_reel_caption set_title_text set_caption_position set_voice_gain
set_voice_eq set_references set_reel_status add_post_link remove_post_link record_generation_cost list_comments add_comment resolve_comment
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

Many cuts go in one call (Sankalp, 2 Nov 2026): `cut_range` takes `ranges`, a list of start and end, in place of `start` and `end`, makes them all as one undo step and cuts nothing when one range is bad; edit times do not move when something is cut, so every range is read against the same times. An edit tool answers with a short summary, what changed with `changed`, the new `cuts` or ids, `duration`, `editDuration`, `clips`, `cutRanges`, `waitingCuts`, `canUndo` and `canRedo`, never the whole state, which for a 23 minute reel is over 50,000 characters; `get_project` and `get_timeline` give the whole state. A trim pass of 73 cuts that got the whole state back after each one filled the chat Claude's context until it stopped with Prompt is too long.

A long transcript is read a page at a time (Sankalp, 2 Nov 2026): `get_project` leaves out more than 1,500 words unless `words` is true and says how many in `wordsOmitted`, and `get_words` gives up to 1,500 words per page as short lines, `index start end word` in edit seconds, marked `[cut]` or `[cut, waiting]`, with a `pause` line for every silence of `pause` seconds or more (0.5 by default), from `from` or the word index `start`, with `nextStart` for the next page; a 23 minute reel is two pages of about 41,000 characters. `audit_audio` is the rule books' audio audit (the web editor's `audit-audio.py`) on the project's own files, in `Resources/audit_audio.py`: it flags a word stretched over more than 0.8 s with speech inside and speech no word covers, transcribes each spot again with WhisperX (the small model, loaded once), and returns each finding with its edit times, why and what was heard; `from` and `to` audit a part, and two minutes of a reel take about half a minute. Since 4 Nov 2026 the audit also finds a phrase said twice that the transcript writes once (Sankalp's "People have been asking me" and "That's all for" on 2026-11-04-img-4842-v1): Whisper writes a repeat or a restarted sentence once and spreads its times over both takes, so no word is stretched and no speech is uncovered. The wav2vec2 model WhisperX aligns with also reads letters straight off the sound, greedily and with no language model, so it keeps every repeat, misspelled; the audit lines its letters up with the transcript's and flags a stretch of 8 or more letters heard beyond it (letters the listener missed never cancel them), under a second for 30 s of sound. The flagged spots go to Claude in one call through the claude command line with no tools, no MCP servers and a short system prompt (`Decipher.swift`), which says for each one repeat, restart, missed or none, what was said and where the earlier take is; the finding then carries `cut`, the edit seconds that take the earlier take out up to the kept one, and `alreadyCut`. Sonnet at medium effort reads them: run 5 times each on his spots it named both repeats 5 of 5 times in 15 to 20 s for about 2.7 cents, Haiku 3 or 4 of 5 for 0.25 to 0.5 cents; `REEL_DECIPHER_MODEL` and `REEL_DECIPHER_EFFORT` pick another, `REEL_NO_DECIPHER=1` (the test suite) skips the call and gives the heard and transcript words as kind unchecked. A run of the audit that dies on a signal is tried once more.

`check_rules` (Sankalp, 4 Nov 2026) checks the reel as it plays against the rules of the rule books that can be measured, on the kept words only (`RuleCheck.swift`): a silence over `maxGap` (0.3 s) between kept words or more than about 0.2 s before the first or after the last, a filler kept, the same word kept twice in a row, a sentence or an I in lower case, a number written as a word, 30 words with no full stop, the last word without one, and see you in the next one without an exclamation mark. Each finding has its edit times and the call that fixes it. The chat's Claude is told to cut every audit repeat or restart that is not cut already, place that clip's words again from a script, and run `check_rules` until it is clean, naming in its report anything it leaves and why.

`resize_cut` moves the edges of one cut, the one at `at`, a range cut or a run of cut words: its words come back and the new span is one range cut, waiting for approval when the old one was, one undo step. On the timeline a click on a cut selects it with a red outline and a handle on each edge, and dragging a handle makes the cut longer or shorter through it (Sankalp, 4 Nov 2026); Escape or a click elsewhere lets it go, and `REEL_EDITOR_SELECT=cut:<seconds>` opens with one selected for a snapshot. An export opens a modal from its start, whether Export, Cmd E or an agent's `export` began it (Sankalp, 4 Nov 2026): a card in the middle shows the progress bar, the percent and the step, over a dimmed window that takes no clicks and no keys but Cmd Q, so nothing changes the reel while it renders (`ExportModal.swift`). When it is done the card names the file, its folder and its length, with Show in Finder and Close (Return or Escape); Finder no longer opens on its own. When it stops it says why. An export's status keeps the id of the process running it, and one whose process has ended is marked stopped, so the modal never waits for an export that is gone. In the transcript a cut word keeps its red or amber strike but is faded with no box behind it, so the kept words are what reads (Sankalp, 4 Nov 2026).

A typical session: `list_projects`, `get_project` (clips, cuts, words with indexes and edit times, animations), then
`delete_words` or `cut_range`, `add_animation`, check with `get_project`, and `export` with `wait: true`.
`open_in_app` brings the project up in the window.

**Any session works with the open app** (Sankalp, 1 Nov 2026). reel-mcp is registered for every Claude Code account, so
any session can do this from its own chat, with no listening loop:
- `open_in_app` with `path` opens any `.reel.json` saved anywhere in a tab of the app, putting it on the list first and
  starting the app when it is closed; with `project` it opens one already on the list.
- `get_app_state` returns what the app has on screen: whether it is open, its tabs, the project in front and its file, the
  playhead and whether it plays, the clip under the playhead, and the selection (a range, words with their text, an
  animation). So "cut this" from Sankalp means the selection the session reads there.
- The app writes this to `.app-state.json` in the projects folder when it changes, about twice a second at most, and
  removes it when it quits; a file left by an app that crashed is ignored, since its process is gone.
- Edits from any session land in the open tab within half a second, as before.

## Talking to Claude from the app

The Chat (the button in the transcript's head) talks to a Claude the app starts itself. The two icons beside the account
pick where it sits, **side panel** or **floating**: a column on the right of the window, 400 points until its divider is dragged (320 to 900, saved, a double click resets it; Sankalp, 2 Nov 2026), or a card under the
button, and the app remembers it.

The chat (`DirectChat.swift`) needs no Claude Code session: the app starts the claude command line itself, as the
LiveAssistant app does, on the account and model picked at the top of the chat (a `~/.claude*` config folder through
`CLAUDE_CONFIG_DIR`; Sonnet, Opus or Haiku; and an effort, the command line's `--effort`: default, low, medium, high,
extra high or max), with this app's reel-mcp as its only tools (`--strict-mcp-config`,
`--tools ""`, `--allowedTools mcp__reel-editor`). It keeps running for the conversation. Each message goes in with what
is on screen (the project, the playhead, the clip, the selection); Claude's answers and each tool it runs show in the
chat, and the editor reloads as its edits land. The command line signs in by itself, no token is read. Each project has a chat of its own (Sankalp, 2 Nov 2026): a new project opens on a fresh chat, and going back to a project shows its conversation again, kept beside the project file as `<name>-chat-history.json`, the messages and what the chat used in one file, which moves with the project when it is renamed or moved to another folder (Sankalp, 2 Nov 2026; chats kept in the cache folder before that are moved there the first time they load) (the chat with no project open is kept in `<projects folder>/_chat/direct.json`). Each one has its own Claude, started with its first message and kept while the project's tab is open, so a Claude still working on one project carries on while another is in front; closing the tab ends it, after the turn it is on. Clear clears the chat in front only. When Claude's context fills up in the middle of a request (Prompt is too long), the chat shows no error and no bubble for it: a fresh Claude takes the request over with what was already done, read from the chat's own rows of tool calls and answers, says so in a line with a circling arrows icon, and carries on from where the first one stopped, once per request so it can never loop; a second time shows the error (`carryOn` in `DirectChat.swift`, logged as `direct_chat_carry_on`). Every start is logged as `direct_chat_start` and every turn as
`direct_chat_turn` with its tokens and cost, and the account's limits read from each turn update the MCP panel.
`REEL_EDITOR_DIRECT_SAY=<text>` sends one message at launch, for checking it end to end.

While no Claude has used the editor, the panel shows how to connect one (Sankalp, 1 Nov 2026): a line to paste into any
Claude Code chat, which makes it call `get_app_state` and show up, and the `claude mcp add` command for a chat without
the tools, after which every new chat connects on its own (`/mcp` reconnects one already open; another account starts
the command with its `CLAUDE_CONFIG_DIR`).

**Rule books** (Sankalp, 1 Nov 2026). Every `.md`, `.markdown` and `.txt` file in the rules folder, subfolders too, is a
rule book: how Sankalp wants his reels edited. Each project keeps its own rules folder, `rulesDir` in its file, and a
new project starts with the folder saved last (`rulesDir` in `settings.json`; `<projects folder>/_rules` until one is
picked, not inside the app, which every build replaces). The rules row in the chat (under the account, model and effort)
shows the project in front's rule books, how many and where (click the count to read them: a modal over the window lists every rule book on the left and shows the one picked on the right, its markdown laid out, with Open to edit it in its own app and Show in Finder; the up and down arrows move between them, Escape closes it, and `REEL_EDITOR_RULES=1` opens it at launch for a snapshot; Sankalp, 2 Nov 2026; the count and the modal read the folder again when the app comes to the front and every 5 seconds, from a timer in DirectChat, so books added in Finder, by an agent or through iCloud show without a restart, 4 Nov 2026), with Change to pick any folder in Finder for this project,
which also becomes the folder new projects start with, Default to go back to `_rules`, and a button that shows the folder
in Finder (`set_rules_folder` does the same for agents). Agents can write rule books too (Sankalp, 2 Nov 2026), so the chat's Claude makes custom rules for a project when asked: `write_rule_book` writes a new book or a whole new text for one, `edit_rule_book` replaces exact text in one, and `delete_rule_book` takes one out, each keeping the text it had in the folder's hidden `.previous` folder, which is never read as a rule book. Their answers name the other projects that read the same folder, and rules meant for one project go into a folder of its own made by `make_project_rules_folder`: `<projects folder>/_rules-by-project/<name>`, with copies of the rule books the project read until then, without changing the folder new projects start with. The rules row reads the folder again after each of Claude's turns. When a conversation starts, the rule books of the project in
front go into Claude's system prompt once,
through a temporary file passed with `--system-prompt-file`, so they hold for the whole conversation, and one line
above the first message says how many were sent with the request; later messages do not repeat it. Asked to read the
rules again, Claude calls `get_rules`, which reads the folder as it is now (any session can call it too). Past 300,000
characters the rest is left out of the prompt and the line says so. Nothing is copied when the folder changes: a line
in the chat says to copy the rule books into the new folder or drop them in the chat. `.md`, `.markdown` and `.txt`
files dropped anywhere on the chat are saved into the project in front's rules folder (a file of the same name with
other text is kept, and the new one saved beside it with a number, such as `cuts 2.md`); a Claude already running is told
of them with the next message and reads them with `get_rules`. When a message is sent from a project whose rules
folder is not the one the conversation started with (another tab, or a folder changed meanwhile), the message tells
Claude where that project's rule books are and to read them with `get_rules` before editing it.

The chat's Claude has no shell and no file reader, only the editor's tools, so its system prompt tells it to read the words with `get_words`, to call `audit_audio` where a rule book says to run `audit-audio.py`, and to do a whole trim pass itself with the cuts waiting for approval; it runs with `MAX_MCP_OUTPUT_TOKENS` at 60,000 and `MCP_TOOL_TIMEOUT` at 30 minutes, so a long page and a long audit both fit (Sankalp, 2 Nov 2026). Claude's answers show as formatted markdown, and every code block in them has a Copy button at its top right that puts the block on the clipboard; the system prompt tells Claude to write an Instagram caption, or any other text to paste somewhere, in one fenced code block holding only that text (Sankalp, 5 Nov 2026). The conversation reads as one timeline (Sankalp, 2 Nov 2026): every row's icon sits in one column with the Claude mark, each run of Claude's messages and tool calls joined by a line that stops before each of Sankalp's messages and starts again after it, none running past his message (Sankalp, 2 Nov 2026); a tool call has its time on the right, and a message has it under its bubble, Sankalp's messages on the right with his icon beside them and Claude's on the left, each bubble at most 80% of the chat's width (Sankalp, 2 Nov 2026); each tool call has its own icon and what it worked on (the times of a cut, the paragraph read), and a run of the same tool is one row, such as cut range 34 times, last 22:55 to 22:59, which opens to list each call with its time. Separators set off the status row and the rule books row. Stop and Clear, and Change and Default on the rule books row, each carry an icon, and the rules folder's path sits on its own line under the rule books row (Sankalp, 2 Nov 2026); when the chat is too narrow for their words, Change and Default show as icons only, and the effort menu reads Default, Low, Medium and so on beside its gauge icon, so the header never pushes the chat wider than the window (Sankalp, 5 Nov 2026). Two rows right above the input show what this chat has used since it was last cleared, the tokens first and the rest under them: its tokens, its share of the account's 5 hour limit (estimated as the MCP panel estimates the editor's, the account's use times this chat's part of the tokens the account spent in the window, the chat's own turns added since it keeps no transcript), the turns and the tools Claude ran, with the tokens by kind and the account's own use on hover; no money is shown, since a subscription does not pay what the command line reports (Sankalp, 2 Nov 2026). While Claude works the token count runs on, read again every 5 seconds from the usage each of Claude's calls reports as it is made and shown as tokens so far, so a long edit never ends on a surprise; the turn's own total replaces it when the turn ends, and a turn stopped before its end keeps what it used (Sankalp, 5 Nov 2026). It is kept in `_chat/direct-usage.json` and cleared with Clear. While Claude works, the send button is a stop button: it interrupts the turn the way the Agent SDK does (a `control_request` of subtype interrupt), so the conversation and what Claude knows are kept for the next message; a Claude that has not stopped in five seconds is ended.

**Published links** (Sankalp, 5 Nov 2026). A reel is draft or live (`set_reel_status`, which takes published as live), and where it was published is kept in the project file as `posts`: each post's platform, link, when it was posted and a note, added with `add_post_link` (the platform is read from the link when not given, twitter is X, and the same link given again is updated) and taken out with `remove_post_link`; `add_post_link` sets the reel live. The Draft or Live pill's menu lists them under Published on, each opening in the browser. The chat's Claude sets the status and records links Sankalp gives it. When his account has LiveAssistant set up (its `live-assistant` server in that account's `.claude.json`), the chat starts with it too, allowed only `list_agents`, `list_accounts` and `send_to_agent`, so asked to find the links it hands the ContentApp agent, which posts the reels, a message naming the project and asking it to record each post itself with `add_post_link`: the reel-editor tools are in every account, and an answer through LiveAssistant may not come back into the app's chat, which runs with no hooks.

**What Claude is working on, live in the transcript** (Sankalp, 2 Nov 2026). An agent's `get_words`, `audit_audio`, `cut_range` and `delete_words` write what they touch to `_cache/<name>/focus.json` (Reading paragraph 3 of 31, Auditing the sound, Applying trims), and `set_focus` says anything else in Claude's own words; the app reads it twice a second, lights up those paragraphs with a breathing blue wash and a tag such as "Claude is applying trims", scrolls them into view unless the video plays, and shows the same line under Claude is working in the chat. Every paragraph of the span being worked on is blue, however many Claude reads at once, as long as it still has a kept or waiting word, the tag on the first one gives the times when no paragraph is named, and the timeline shows the same span as a blue band and scrolls to it; only work over nearly the whole reel, such as the audit of all of it, is one line at the top of the transcript instead, and the audit then moves through the reel as it listens again to each spot it found. Once Claude starts reading the reel, the paragraphs it has not reached yet wait in yellow while it works, and each goes back to plain once Claude has been through it; the paragraphs it went through are kept across its turns, so continue picks up where it was, and Clear in the chat starts over. A paragraph with cuts that wait for approval has no outline of its own: its cut words are amber, the words of a waiting range cut too, and Approve at the top counts them (Sankalp, 2 Nov 2026). While Claude works on a reel the words in that span shimmer, the whole reel when it reads all of it, and Sankalp's own edits wait so the two never undo each other: every edit from the app is held at `EditorModel.run`, the editing buttons and Add layer are greyed, the timeline's clips, voice overs and animations and the clip heads take no drags, renaming waits, and a pill in the timeline's toolbar says Claude is editing, with Stop. Playing, reading, selecting, comments and export still work (Sankalp, 2 Nov 2026). It lets go when the turn ends, on Stop, or after 90 seconds without a call. `get_paragraphs` gives the transcript's paragraphs as the app draws them (`transcriptParagraphs` in `Focus.swift`), and the chat's Claude is told to make a trim pass paragraph by paragraph: the audit once, then each paragraph read with `get_words paragraph n`, cut, and on to the next, unless Sankalp asks otherwise.

One conversation keeps one Claude: a message half an hour later still goes to the Claude that made the earlier edits,
and it remembers them. Quitting the app, Stop, or picking another account, model or effort starts a new Claude that
remembers nothing, while the old messages stay on screen.

The Claude Code route, a session told to listen that called `wait_for_app_message` again and again and answered with
`reply_in_app`, was removed on 1 Nov 2026 (Sankalp), with those two tools and `get_app_chat`: an idle listener woke its
session every few minutes and spent that account's tokens for nothing. A Claude Code session still edits through every
other reel-mcp tool from its own chat.

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
divider between the transcript and the video and the one above the timeline can be dragged, a double click resets them (the timeline to the height of its layers), and the layout per kind of video, the timeline's height and the video's width are kept. Every layer of the timeline has a height of its own that never changes (Sankalp, 2 Nov 2026): the ruler 28 points, the animation layer 36, the video 80, the audio 40, voice and face 32 and the captions 24, with 8 between them. Dragging the timeline taller leaves empty room under the last layer, and dragging it shorter, down to 96 points, lets it scroll up and down. The lanes are one scroll view that scrolls both ways, so the scroll bar to move along the reel sits at the timeline's bottom edge, not under the captions, and the layer names follow the lanes up and down.

## A reel of several videos

Decided by Sankalp on 2 Nov 2026. The transcript reads as the reel plays: clip by clip, in the order of the clips, each with the words of its own video between its in and out (`transcriptLayout` in `Arrange.swift`, the same paragraphs `get_paragraphs` gives an agent). When a reel has more than one clip each clip starts with a head naming its video, the part of it that plays and its length; drag a head onto another to put that clip before it (`reorder_clips`). A clip whose video has no words yet still shows, with a line saying so. A run of paragraphs Claude works on is one blue box, from the top of the first paragraph, or of the clip head above it, to the last line of the last, the clip heads inside it included and no gap between the paragraphs; a paragraph Claude is not on, such as one cut whole, stays outside it and splits the box (Sankalp, 4 Nov 2026). A reel with no words at all still lists its clips the same way, every clip with its head even when there is only one, under a card that says there is no transcript yet, holds the Transcribe with WhisperX button and shows how the last transcription went (Sankalp, 4 Nov 2026); the pane is never blank while the reel has clips. The words of the other videos are selected, cut, restored and commented on like the project's own, by their times (`cut_range`, a comment on a range), since word indexes belong to the project's own video; a selection stays among one kind of word.

For agents: `move_range` takes the part from `start` to `end` (edit seconds) and puts it at `to`, splitting the clips at the three points and reordering them with the cuts inside; `insert_clip` puts the part `in` to `out` of a video (`main`, a source id such as `s1`, or the path of another video, which is added) at the edit time `at`, splitting the clip playing there; `get_words` with `video` reads one video's own words in its own seconds, each marked with where the reel plays it or that it does not, so a part left out can be put back. Each is one undo step in the project's file, the videos are only ever read, and the app lights up where the part lands, naming its video (Moving 0:01 to 0:02 here, Placing 0:00 to 0:01 of test.mp4 here). get_paragraphs and get_words go clip by clip and name each clip's video, and Reading paragraph 3 of 12, from IMG_0042.mov says which video Claude is reading.

Transcribing a reel of several videos (Sankalp, 2 Nov 2026): a new project starts transcribing at once, and every video with sound is transcribed one after another, the project's own video first and then the others in the order their clips play (`Jobs.transcribeAll`). A video that fails or has no speech does not stop the rest; the status says which one it is on ("IMG_4878.MOV, 2 of 8") and, at the end, how many words came from how many videos and which could not be transcribed. The app's Transcribe button and the `transcribe` tool do the same, the tool doing the project's own video again. The status keeps the id of the process running the job, so a transcription cut off when the app quits or is rebuilt picks up when the project opens again, the videos already done keeping their words. Until 2 Nov 2026 every WhisperX run in the app failed with "has no words": its output file, `media/words-<id>.raw.json`, was taken for words kept in the project's file and looked for there; it is now `whisperx-<id>.json`, and only `words-<hash>.json` names are parts of the document. Until 4 Nov 2026 every WhisperX run of the app opened from the Dock failed with code 1 and a traceback from `subprocess.py`: such an app gets launchd's PATH, `/usr/bin:/bin:/usr/sbin:/sbin`, so `whisperx.load_audio` could not find Homebrew's `ffmpeg`. `transcribe_whisperx.py` now reads the app's 16 kHz mono wav itself, as `audit_audio.py` does, the Python helpers run with `/opt/homebrew/bin` and `/usr/local/bin` added to their PATH (`Jobs.toolEnvironment`), and a failure reports the traceback's last line, the one that names the error. WhisperX also dies on a signal now and then, an abort or a segfault, on a video that transcribes the next time, so a run that crashed is tried once more and logged as `transcribe_retry`.

When a reel has more than one clip, each clip's head has a dot beside it on the line that joins the paragraphs, so the clips and their words read as one timeline, as the chat's rows do (Sankalp, 2 Nov 2026).

**Notifications** (Sankalp, 2 Nov 2026, `Notify.swift`). The app sends a macOS notification when a transcription or an export of an open project ends, from the app or an agent, with how it went, and when the chat's Claude finishes what it was asked, with its last words; they show while the app is in front too, and a click brings that project's tab forward. macOS asks once for leave; Notifications in App settings turns them off. A build outside an app bundle (`swift build`, snapshot runs) sends none. During a transcription of several videos the status stays at transcribing between videos, so only the end of the whole run notifies.

## Captions and text layers

Decided by Sankalp on 2 Nov 2026, brought over from the ContentApp reel editor's captions and title style (`lib/reel-style.ts`) and made agentic (`Captions.swift`, `CaptionTools.swift`, `CaptionsCard.swift`). One text style dresses both the captions and text layers: the font family (any on this Mac; Advercase, the reels' font, and Inter are bundled and registered by the app and by reel-mcp alike), weight 100 to 900, italic, size, letter spacing, line height and case; the colour, an outline and a shadow; a box behind the whole line or, for captions, behind the word being spoken, with its colour, opacity, padding and corners; the spoken word in its own colour; how each caption line comes in (at once, pop, fade or rise); and where it sits (x from the centre, y down from the top), the widest line, the most words a line and the alignment. Sizes and places are px of the 1080 by 1920 frame (1920 by 1080 for a landscape video), as on the web.

The captions take the project's own style (`captionStyle`) over the default saved for new projects (`captionStyle` and `captionStyleLandscape` in `settings.json`) over the built in look, the web editor's: Advercase Bold 95 px in white with a 7 px black outline, the spoken word in a black box, three words a line at 1490 px down (72 px at 900 landscape). A position set with `set_caption_position` before styles existed counts as the project's own place, and the tool now writes the style's x and y. A line ends after a half second pause, at a full stop or a comma, at the word limit, or before it would run wider than the widest line. They can be hidden over stretches of the reel (`captionHides`, edit seconds): a time, words or a whole clip, joined where they meet; no line runs across one. The style and the hidden stretches are undo steps.

A line's height and its word box come from where the font's letters really reach, measured once per font and size by drawing tall and deep letters, so no font's tops are cut and the box sits evenly round the word. Each caption line is drawn as one picture per spoken word (or one for the line when there is no word box or highlight); the export shows them in turn and the preview draws the picture for the playhead with the same function, with the line's entrance, so the two match.

A text layer is an animation of kind text on the Animation layer: its words, on more than one line too, in its own style, for a part of the reel or all of it, coming in by fade, pop, rise, drop, slide from the left or right or typewriter, and going out by fade, pop, rise, drop or a slide. It is drawn under the captions.

For agents: `get_caption_style`, `set_caption_style` (any field, `clear` for some, `reset` for all, `burnIn`, `saveAsDefault`, `resetDefault`), `list_fonts`, `hide_captions` (start and end, from and to, or clip), `show_captions` (id, a stretch, or all), `add_text_layer` (whole for the whole reel) and `update_text_layer`; `add_animation` and `set_animations` take a text layer's `style`, `enter` and `exit` too. In the app, Captions on the timeline opens the Captions card: burned in or not, the hidden stretches with Show and Hide over the selection or this clip, the font, colours, box and place, Reset and Use for new projects. A text layer's card has its motions, Over the whole reel and the same style controls; Add layer, Animation Text adds one at the playhead. `REEL_EDITOR_FLOAT=captions` opens the Captions card and `REEL_EDITOR_SEEK=2.5` puts the playhead there at launch, for snapshots.

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
same menu without Correct. Escape lets go of a selection. A comment left there is saved on the reel and sent straight to the chat's Claude as a message of Sankalp's, with the words or the range it is on and its id, so Claude acts on it and resolves it; while Claude works on something else it waits and goes when that turn ends, or at once after Stop (Sankalp, 2 Nov 2026). `REEL_EDITOR_SELECT=words:5-9` or `range:1.5-3` opens with a
selection, for checking the menus in a snapshot.

In any text field (the chat's input, the title, a name or a number), the keys work as in any Mac text field: Cmd Delete
deletes to the start of the line, Option Delete deletes a word, and Cmd Z undoes the typing, before the menu shortcuts that
share those keys (Cut Selection, Undo Edit) see them (`TextKeys` in `ReelEditorApp.swift`, Sankalp, 1 Nov 2026).

Space plays, Delete cuts the selection (a dragged range on the timeline, or words selected in the transcript),
Shift Delete restores it, S splits at the playhead, the arrows step a frame (a second with Shift), and = and - zoom
the timeline in and out. Cmd or Ctrl with the scroll wheel, or a two finger scroll, zooms the timeline around the pointer while it is over the timeline (Sankalp, 2 Nov 2026). Cmd plus, Cmd minus and Cmd 0 zoom the whole window. Cmd E exports. Cmd Z and Shift Cmd Z undo
and redo. Drag an animation block to move it, or drag its edges to stretch it.

## Planned: individual layers

Decided by Sankalp on 21 Oct 2026, the same decision as in the web editor (PRD.md, Phase 32, "Individual layers"): the timeline is free of a fixed set of rows and shows every layer individually. A layer is any piece of the reel, a screen clip, the face of a call out as a video overlay in a rounded window, a coded animation, a voice over, a music bed, each its own row with its own name that can be added, trimmed, cut, split, moved, animated and removed on its own, with no limit on how many. The layer tools are allowed in `reel-mcp` (add a layer of a kind, list the layers, change one, remove one), so an agent builds a reel from layers, and they are the same tools as the web editor's `lib/reel-tools`. The first example, the Face layer (`add_face_overlay`, `set_face_window`, `split_overlay`), is in this app's model, preview and export since 31 Oct 2026; the app's window does not draw it on the timeline yet. The general layer list is not built yet.

## Not in this version

There is no caption style editor yet: captions use the fixed reel look (their position can be set with
`set_caption_position`). The app's window does not yet show the controls for the tools ported on 31 Oct 2026 (looks,
placement, face windows, music, voice volume, comments, drafts): they work through MCP and render in the preview and the
export. The first open of a long video takes about a minute to read its waveform, which is then cached.

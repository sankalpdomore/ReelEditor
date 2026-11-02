# Reel Editor for Mac

**Last Updated**: November 2, 2026  
**Status**: 🚧 Phase 11 and 11b In Progress - reels of several videos, a chat per project that writes rule books, notifications, Claude editing alone, captions and text layers (Phase 11c) and the voice up to 1000% landed on 2 Nov 2026; the music library, free layers, the web editor's React animations and moving words by hand are still open.  
**Priority**: High  

> **Its own repo since 1 Nov 2026.** The app began as `tools/reel-editor-mac` inside ContentApp and was detached into `~/Coding projects/ReelEditor` (github.com/sankalpdomore/ReelEditor); the copy in ContentApp is frozen as it was that day.

---

## ✅ Implementation Checklist

### Phase 1: Core editor and project files ✅ COMPLETE
- [x] Project folders - every project was a folder under `~/Movies/Reel Editor/<project>/` (or `$REEL_EDITOR_HOME`) holding `project.json` (the source video and the edit decision list), `animations.json`, `transcript.json`, `history.json`, `status.json`, `media/` and `exports/`, replaced by one file per project in Phase 9; the video itself is only ever read (`Sources/ReelCore/Project.swift`)
- [x] Edit decision list ported from the web editor line for line - clips with in and out points, range cuts, word cuts, corrections, sections, captions, title and speed, with source, edit and output time kept apart (`Sources/ReelCore/EDL.swift`)
- [x] Preview equals export - the plan becomes one `AVMutableComposition`, and the title, captions and animations are one Core Animation layer tree played on an `AVSynchronizedLayer` in the preview and handed to `AVVideoCompositionCoreAnimationTool` in the export (`Composition.swift`, `Overlay.swift`, `AnimationLayers.swift`)
- [x] Undo and redo for every edit, kept in `history.json`; files are locked per project so the app and agents can edit at once, and the open window polls the project's revisions and reloads within half a second
- [x] Transcription with WhisperX on this Mac (`Resources/transcribe_whisperx.py`), or an imported `[{w, s, e}]` file; the words of added clips and voice overs are fetched too, so the captions read every part
- [x] Seven native animation kinds drawn from their span alone, so scrubbing and the export agree - text pop, lower third, counter, emoji burst, progress bar, callout and checklist
- [x] Clips, muted sound and voice overs - rename a clip, mute its own sound, lay audio over the project on its own layer that follows the cuts (`audioOverlays`)
- [x] QA logs - every tool call, app action and error is one JSON line in `_dump/app-<date>.jsonl` or `mcp-<date>.jsonl` with the build stamp, readable through `get_logs`

### Phase 2: MCP server and the shared tool layer ✅ COMPLETE
- [x] `reel-mcp`, an MCP server over stdio shipped inside the app (`Contents/MacOS/reel-mcp`) - every button in the app calls the same tool an agent calls (`Sources/ReelCore/Tools.swift`), and every call is checked against the tool's JSON schema
- [x] Presence heartbeat - each running server writes `.mcp/<pid>.json` with its client, Mac and last tool, refreshed every five seconds and removed on exit (`Presence.swift`)
- [x] Chat through MCP - `wait_for_app_message`, `reply_in_app` and `get_app_chat`, so a Claude Code session told once to listen answered the app's Chat; removed on 1 Nov 2026 in Phase 8 for the direct chat
- [x] Any session works with the open app (Sankalp, 1 Nov 2026) - `open_in_app` takes `path` to open any `.reel.json` in a tab, starting the app when closed, and `get_app_state` returns the tabs, the project in front, the playhead and the selection, from `.app-state.json` the app writes (`AppState.swift`)
- [x] Registered for Claude Code on all three accounts on 31 Oct 2026 - `claude mcp add --scope user reel-editor` in `~/.claude`, `~/.claude-2` and `~/.claude-3`, each confirmed Connected

### Phase 3: Parity with the web editor's tools ✅ COMPLETE
- [x] All 37 tools the web editor had gained since 23 Oct 2026 added on 31 Oct 2026 - 34 ported under the same names and arguments and 3 as aliases (`list_reels`, `get_timeline`, `import_video`), and `reel` taken as another name for `project` in every tool (`Sources/ReelCore/ToolsWeb.swift`, `Layers.swift`, `Records.swift`)
- [x] Cuts from the chat wait for approval - a cut made through MCP is pending unless `approved: true`, drawn in amber, and `approve_cuts` keeps it; a cut made in the app is approved at once
- [x] Comments, drafts, references, reel status and caption, generation cost, source checks and relinking - `add_comment`, `resolve_comment`, `create_draft_reel`, `set_draft_published`, `set_references`, `set_reel_status`, `set_reel_caption`, `record_generation_cost`, `check_sources`, `relink_source` and the rest
- [x] Mac specific choices - `set_music` takes an audio file's path or a file in `<projects folder>/_music`; saved looks live in `<projects folder>/_looks` (or `looksDir` in settings.json); `REEL_EDITOR_NO_OPEN=1` stops the tools that open Finder or the app
- [x] MCP test suite - a script drives `reel-mcp` over stdio through every one of the 78 tools in a scratch projects folder, checking results, files, schema rejection, undo and redo, exports with ffprobe, sampled frames and audio levels; 327 of 327 checks passed on the merged build

### Phase 4: Rendering the web editor's features ✅ COMPLETE
- [x] Looks for the whole reel and per clip, clip placement (zoom and move), and face windows (rounded, the #333 border and shadow, their moves), drawn by a Core Image compositor when a reel needs one (`Compositor.swift`); other reels keep AVFoundation's own compositor
- [x] The title hidden over chosen clips and the caption position in the export, and the preview's captions placed with `Overlay.captionCenter`
- [x] Music bed never sped up with the reel; voice volume from 0 to 10 with a limiter, voice bass and treble, and each overlay's own EQ, gain and sound effect flag, as audio taps on the mix (`AudioFX.swift`)
- [x] Two pass export for reels with the custom compositor - AVFoundation's animation tool turned its frames white, so the picture and sound go to a temporary ProRes file first and the captions, title and animations are laid on in a second pass; output matches the single pass pixel for pixel
- [x] Fixed on the way - the export progress ticker could overwrite the final ready status with exporting after an export finished

### Phase 5: The main app's design language ✅ COMPLETE
- [x] Liquid Glass and native controls replaced by ContentApp's web design language on 31 Oct 2026, ported in `Sources/ReelEditor/Design.swift` - Inter and Phosphor Bold and Fill in `Resources/Fonts`, registered at launch; the grey stops #111 to #eee with #ddd borders; the Button variants as pills, the grey Tabs container with a white active tab, uppercase panel labels, Draft and Live pills, the inset card, fields, the switch, the slider and the spinner; light and dark tokens
- [x] Icons by their web names - `Icon("scissors")` is `ph-bold ph-scissors`, and `phosphor-codes.sh` writes `PhosphorCodes.swift` from every name used
- [x] App icon - the web editor's brand mark, the film strip in white on a black tile shaded #333 to #111, drawn by `make-icon.swift` into `Resources/AppIcon.icns`
- [x] Window zoom - Cmd plus and Cmd minus in 10% steps from 60% to 140% and Cmd 0 back, like a browser's page zoom; the window is laid out at its size over the zoom and scaled, so everything reflows
- [x] Motion - every card, panel and menu springs open out of where it was opened from and shrinks back into it with SwiftUI's spring (`Animation.cardOpen`, `.cardClose`, `AnyTransition.card`); cards cast a soft shadow on their shape only (`CardChrome`)

### Phase 6: Editor layout and interaction ✅ COMPLETE
- [x] Window laid out like the web reel editor - a top bar (brand, undo and redo, the reel's name with its Draft or Live pill, the Wide, Tall and Distraction free tabs, Export on Cmd E), browser style project tabs with + New / Open project, and the Open a reel page with a dashed drop area and project cards
- [x] Transcript column headed TRANSCRIPT with the cuts and seconds saved, Approve for waiting cuts, Project, Chat and Open folder; the reel's title as plain text until clicked, so it never takes the keyboard on its own; a time column and a coloured ring and heading per part; line height 1.16 times the 16 point type, words 2 points apart with 2 points of padding each side (Sankalp, 31 Oct 2026)
- [x] Project card as details only (Sankalp, 1 Nov 2026) - started, last edited, saved at, video, length, size and Edited by (each session or the app with its account, edits and last one, from `_cache/<name>/editors.json`, `Editors.swift`); the reel's settings cards removed; App settings button after Export with the appearance and the MCP command
- [x] Text fields keep their own keys (Sankalp, 1 Nov 2026) - Cmd Delete, Option Delete, Fn Delete with Cmd or Option, and Cmd Z with Shift Cmd Z edit the field being typed in instead of reaching Cut Selection or Undo Edit (`TextKeys`)
- [x] Selecting - drag across words, or click and shift click, then a menu floats at the selection with Cut, Uncut, Correct (one word typed for each selected) and Comment for Claude; a range dragged on the timeline gets Cut, Uncut and Comment; Escape lets go
- [x] Timeline - layer names in a column on the left (Add layer, Animation, Video, Audio, Voice and face, Captions), a 48 point gap before time zero and 24 after the end as on the web, cuts as red hatching (red kept for cuts only), animation blocks in their own colour with a light fill of it, ruler dots kept clear of the time labels
- [x] The word at the playhead white on black in the transcript (Sankalp, 2 Nov 2026), where it was a light grey
- [x] Cards, panels and modals at most 60% of the window's height (Sankalp, 2 Nov 2026) - the layer cards, Project, Chat, Captions, App settings, the MCP panel and the rule books modal scroll past it (`CappedScroll`, `CARD_SHARE`)
- [x] Thin scroll bars (Sankalp, 2 Nov 2026) - 8 points, half the system's, a rounded grey knob with no track, in every scroll area (`ThinScrollers.swift`, NSScrollView given its own viewDidMoveToWindow so no other view changes)
- [x] Time saved as people say it (Sankalp, 2 Nov 2026) - 45 s, 2 min 26 s, 1 h 4 min 9 s in the transcript's head
- [x] Captions clickable in the preview (Sankalp, 2 Nov 2026) - outlined on hover with a tooltip, a click opens the Captions card
- [x] Voice volume up to 1000% in the app (Sankalp, 2 Nov 2026) - the Audio layer's name opens the Voice card, as the web editor's voice card: a slider from 0 to 1000% with steps at 100, 150, 200, 250, 300, 400, 500, 600, 700, 800 and 1000%, and bass and treble; above 100% the app's own gain and limiter (AudioFX.swift, the web export's volume and alimiter at 0.89) run in the preview and the export; measured on an export, 200% is 6 dB louder, 400% 12 dB and 1000% 17 dB, peaks held under -0.5 dB
- [x] Clips named Clip 1, Clip 2 on screen (Sankalp, 2 Nov 2026) - in the clip heads, on the timeline and in the clip card, never c1; the number is the clip's own (Clip 5 is the tools' c5) and stays with it when clips move, and the chat's Claude says clip 5 too
- [x] The chat's line joins Claude's runs only (Sankalp, 2 Nov 2026) - it joins one run of Claude's messages and tool calls, ends at the icon before each of Sankalp's messages, starts again at the icon after it, and none runs past his message
- [x] Name it from the script (Sankalp, 2 Nov 2026) - in the gear beside the reel's name: the chat's Claude reads the script and the rule books' naming rule (by default the recording date as year-month-day, then two to four words on what the video is about) and renames the project with rename_project; get_project gives recorded, when the video was recorded
- [x] Renames keep a backup (Sankalp, 2 Nov 2026) - the project file is copied under the new name, the copy read back and checked part by part against the old one, the list and cache moved to it, and only then the old file goes to the Trash; a copy that does not match is removed and the project keeps its old name
- [x] A renamed project stays in place (Sankalp, 2 Nov 2026) - its tab, its chat and its playhead follow it to the new name, from the app or an agent
- [x] The project in front reopens in front (Sankalp, 2 Nov 2026) - the tab in front is remembered (frontTab), and the app opens on it after a restart
- [x] Timeline ends (Sankalp, 2 Nov 2026) - a click in the gap before time zero takes the playhead to the start and after the end to the end, and the 0:00 label starts at the edge
- [x] Timeline controls - pinch to zoom around the fingers, Cmd or Ctrl with the scroll wheel to zoom around the pointer (Sankalp, 2 Nov 2026), = and - to zoom, speed and zoom steppers, Follow in a pill of its own; the timeline zoom and Follow are saved
- [x] Layer settings float above the layer clicked - an animation's kind, times, side, height and fields; a clip's name, sound, title, look, placement, voice over, split and delete; an overlay's name, volume, voice or sound effect, words, split and remove (`Floating.swift`); the Project card holds only the project's details (started, last edited, saved at, video, length, size) and who edited it, since 1 Nov 2026, and App settings beside Export hold the appearance and the MCP command
- [x] Animation blocks drag to move and stretch from either edge - the drags take priority over the timeline's own seek and select drag and are measured in the window's space so they never jitter; the edges are 8 point grab areas with a grip on hover
- [x] Resizable panels - the dividers between the transcript and the video and above the timeline drag and reset on a double click, and their sizes are saved per landscape and portrait video; each divider takes only its 1 point line, its 8 point grab area laid over it, so the lines meeting it run right up to it with no white gap (Sankalp, 2 Nov 2026)
- [x] Menus never open outside the window - a dropdown's options open in the window's menu layer, right aligned under the field with an arrow at the top right pointing at its caret (`MenuHost.swift`)
- [x] Timeline layers of fixed heights (Sankalp, 2 Nov 2026) - ruler 28 points, animation 36, video 80, audio 40, voice and face 32, captions 24, 8 between them; the timeline's divider still drags, the room past the last layer is left empty, a timeline shorter than its layers scrolls up and down with the names following, the sideways scroll bar sits at the timeline's bottom edge, and a double click fits it to its layers

### Phase 7: MCP connection panel, accounts and usage ✅ COMPLETE
- [x] The pill at the right of the tab row - a green dot, the Claude logo (`Resources/Brand/claude.svg`, from the web app's brand marks) and "Claude session (n)", the sessions using this editor, with a #ddd border
- [x] The panel drops down under the pill inside the window with two tabs - This editor (only the sessions that have called a tool) and All sessions - and draws each account as LiveAssistant does, a tree with a branch to its 5 hour limit, its weekly limit and each session
- [x] Which account a session is on - the server reads `CLAUDE_CONFIG_DIR` and `<config>/sessions/<parent pid>.json`, and the app finds the same from outside for servers started earlier; only the account's email and organisation are read, never a token; the plan comes from `claude auth status`
- [x] Limits read as LiveAssistant reads them (`AccountLimits.swift`) - the claude command line of that account is asked one word on Haiku (about 2,000 tokens) and its `rate_limit_event` gives each window's use and reset, at most every 20 minutes or on Refresh
- [x] This editor's share of each window - a two colour bar, green for the sessions using the editor and blue for the rest of the account, estimated as the account's use times their share of the tokens the account spent in that window (cache reads at a tenth)
- [x] Tokens per session from its own transcript, its agents included (`SessionUsage.swift`), checked equal to an independent count (73.5M tokens over 250 messages)
- [x] Disconnect - a labelled button per session asks Disconnect? with No and Yes, and Yes sends its `reel-mcp` SIGTERM and takes it off the panel at once (Sankalp, 1 Nov 2026), so the session loses the editor's tools until `/mcp` reconnects it; the Claude session keeps running
- [x] Connect help (Sankalp, 1 Nov 2026) - while no Claude has used the editor, the panel shows a line to paste into any Claude Code chat to connect it and the `claude mcp add` command for chats without the tools
- [x] Logs - `account_limits`, `mcp_session_usage`, `editor_share_of_limits` and `mcp_disconnect` lines in the app's log when the connections change, every 20 minutes and when the panel opens

### Phase 8: Chat with Claude ✅ COMPLETE
- [x] Two pairs of tabs at the top of the Chat - Direct or Claude Code chose who answers until 1 Nov 2026, Side panel or Floating chooses where it sits (a 400 point column on the right of the window, or a card under the button); both are remembered
- [x] Direct chat (`DirectChat.swift`) - the app starts the claude command line itself on the account, model (Sonnet, Opus, Haiku) and effort (default, low, medium, high, extra high, max) picked in the chat, with this app's `reel-mcp` as its only tools (`--strict-mcp-config`, `--tools ""`, `--allowedTools mcp__reel-editor`), and keeps it running for the conversation; each message goes with what is on screen
- [x] Direct is the only chat (Sankalp, 1 Nov 2026) - the Claude Code route and its tools `wait_for_app_message`, `reply_in_app` and `get_app_chat` removed, since an idle listener woke its session every few minutes and spent tokens; the Direct and Claude Code tabs are gone and the Side panel and Floating icons sit beside the account
- [x] Rule books (Sankalp, 1 Nov 2026) - each project keeps its own rules folder (`rulesDir` in its file) and a new project starts with the folder saved last (`rulesDir` in settings.json, `_rules` until one is picked); every .md, .markdown and .txt in it goes into Claude's system prompt once per conversation with one line saying how many were sent, and `get_rules` rereads the folder on request (`Rules.swift`); checked end to end on Haiku on a scratch folder of three rule books
- [x] A full trim pass from the chat (Sankalp, 2 Nov 2026) - the chat's Claude stopped because `get_project` on a 23 minute reel was 175,000 characters, saved to a file it could not open, and the rule books' `audit-audio.py` needs a shell; now `get_project` leaves out more than 1,500 words, `get_words` pages the transcript with its pauses, `audit_audio` runs the audit on the project's own files (`Audit.swift`, `Resources/audit_audio.py`), and the system prompt points Claude at both
- [x] Claude's work shown live in the transcript (Sankalp, 2 Nov 2026) - `get_words`, `audit_audio`, `cut_range` and `delete_words` from an agent write `_cache/<name>/focus.json`, `set_focus` adds Claude's own words, `get_paragraphs` lists the app's paragraphs; the app lights up the paragraph being worked on in blue with a tag such as Claude is applying trims and follows it, lights every paragraph of a longer read and shows it as a blue band on the timeline, which scrolls to it, shows work over nearly the whole reel such as the full audit as one line at the top, moves with the audit as it listens again to each spot, and while Claude works washes the paragraphs it has not reached yet in yellow, plain again once it has been through them (a paragraph whose cuts wait for approval has no outline of its own since 2 Nov 2026, its amber words and Approve show it), and the chat's Claude works paragraph by paragraph (`Focus.swift`)
- [x] Claude edits alone (Sankalp, 2 Nov 2026) - nothing in the transcript or on the timeline can be selected and no Cut or Comment menu opens while Claude edits, a selection made before it started is let go and Approve waits; only the part read lights up, not every clip of the video read; the timeline's band shimmers and says Claude is editing this part on hover; while the chat's Claude works on a reel, or an agent's calls show what it works on, the words in that span shimmer (the whole reel when it reads all of it) and Sankalp's own edits wait: every edit from the app is held at `EditorModel.run`, the cut, restore, split and delete buttons and Add layer are greyed, the timeline's clips, voice overs and animations and the clip heads take no drags, and renaming waits; a pill in the timeline's toolbar says Claude is editing, with Stop; playing, reading, selecting, comments and export still work
- [x] The chat as a timeline (Sankalp, 2 Nov 2026) - icons in one column with the Claude mark joined by a line, the time of every row (under the bubble for a message, Sankalp's on the right with his icon), the side chat resizable from its divider, each tool's icon and what it worked on, runs of one tool folded into a row that opens; separators around the rule books row; every separator in the app #ddd
- [x] Comments go to the chat (Sankalp, 2 Nov 2026) - Comment for Claude on words or a timeline range saves the comment and sends it to the chat's Claude with what it is on and its id, to act on and resolve; queued while Claude works and sent when the turn ends or after Stop
- [x] Chat bubbles at most 80% of the chat's width (Sankalp, 2 Nov 2026) - `WidthShare` in `Design.swift`; the Side panel and Floating tabs as tall as the account beside them; Stop, Clear, Change and Default with icons, and the rules folder's path on its own line under the rule books row
- [x] Export at the right end of the top bar (Sankalp, 2 Nov 2026) - App settings left of it, its card right aligned under its own button
- [x] Stop while Claude works (Sankalp, 2 Nov 2026) - the send button becomes a stop button that interrupts the turn and keeps the conversation
- [x] What this chat used, above the input (Sankalp, 2 Nov 2026) - tokens, its share of the 5 hour limit, turns and tools since the last Clear, no money, kept in `_chat/direct-usage.json`; Claude's answers show as formatted markdown; the rules row keeps Change and Default whole
- [x] Rule books to read in the app (Sankalp, 2 Nov 2026) - the rule book count in the chat, and the line saying how many were sent, open a modal listing every rule book with the one picked shown as laid out markdown, Open and Show in Finder, the arrows to move between them and Escape to close (`RuleBooks.swift`, `MarkdownBlocks` in `Design.swift`)
- [x] A chat for each project (Sankalp, 2 Nov 2026) - a new project opens on a fresh chat and going back to a project shows its own conversation, kept beside the project file as `<name>-chat-history.json`, moving with it on a rename or a move (Sankalp, 2 Nov 2026); each has its own Claude, kept while its tab is open, so one still working carries on while another project is in front, and ended when the tab closes; the chat with no project open stays in `_chat/direct.json`
- [x] Agents write rule books (Sankalp, 2 Nov 2026) - `write_rule_book` writes a new book or a whole new text, `edit_rule_book` replaces exact text in one, each keeping the text it had in the folder's hidden `.previous`; their answers name the other projects sharing the folder, and `make_project_rules_folder` gives a project its own `_rules-by-project/<name>` with copies of its books, without changing the folder new projects start with
- [x] Rule books into the chat (Sankalp, 1 Nov 2026) - .md, .markdown and .txt files dropped on the chat are saved to the project's rules folder, never over a different file of the same name; a folder change copies nothing and says in the chat to copy or drop the rule books; checked in the app on a scratch project
- [x] Direct chat checked end to end on 31 Oct 2026 - on Haiku on support@nextdoor.company, Claude called `get_animations` and answered with the three animations for about $0.007; every start and turn is logged with its tokens and cost
- [x] Account list without duplicates - one entry per email; the `~/.claude-secondary` shortcut to `~/.claude-2` was removed on 31 Oct 2026 at Sankalp's request, no data touched

### Phase 9: One file per project, saved anywhere ✅ COMPLETE
- [x] One JSON file per project, `<name>.reel.json`, with sections for the project and its edit list, animations, transcript, words of added videos and voice overs, undo history, comments and draft (Sankalp, 1 Nov 2026) - the store keeps naming each section by its old file name, so `Store.file(name, "project.json")` reads and writes the `project` section (`Sources/ReelCore/Project.swift`)
- [x] Saved in any folder - New Project from Video (Cmd N) asks where to save the file; `create_project` takes `folder`; `projects.json` in the Reel Editor folder lists where each file is and when it was opened
- [x] Open Project (Cmd O) opens a `.reel.json` from anywhere; `add_project` and `remove_project` put a file on the list or take it off, leaving the file
- [x] Move a project file to another folder (Sankalp, 1 Nov 2026) - Move on each Open a reel card, shown on hover, and Move to another folder in its right click menu; in the top bar, a gear beside the reel's name with Project details, Show in Finder and Move to another folder; pick a folder in Finder and only the `.reel.json` moves; the video stays, an open tab keeps working, and `move_project` does the same for agents
- [x] Only the tabs left open last time reopen at launch, not every project; the Open a reel page lists recent projects with their paths, with Show in Finder and Remove from this list
- [x] Job status, the lock and cached waveforms in `_cache/<name>/`; exports beside the project file in `<name> exports/`; a parsed file is cached by its modification time so the two second polling reads a file only when it changed
- [x] Old project folders become one file each on first launch, the old folder kept in `_migrated/`; checked on a copy of a test project (four undo steps, words and a comment carried over), then edits, undo, redo, rename, export, save elsewhere, remove and add back all work on the one file
- [x] MCP suite extended to the one file - 338 of 338 checks pass

### Phase 10: Its own repo ✅ COMPLETE
- [x] Detached from ContentApp on 1 Nov 2026 - the whole app copied from ContentApp's `tools/reel-editor-mac` into `~/Coding projects/ReelEditor`, built and launched from here, and pushed to github.com/sankalpdomore/ReelEditor; the copy in ContentApp is frozen as it was that day
- [x] The MCP suite moved in with it - `tests/mcp_test.py` with its media in `tests/media`, run with `swift build && python3 tests/mcp_test.py .build/debug/reel-mcp <scratch folder>`
- [x] `CLAUDE.md` for this repo, carrying the rules the app followed inside ContentApp - the design language, the documentation structure, no em dashes, the commit message format, testing in snapshots and never touching real projects in tests

### Phase 11: Open work against the web editor 🚧 IN PROGRESS
- [ ] Music library as folders with beds to pick, as the web editor has it - the Mac app takes a file path or `_music` today
- [x] Caption style editor (Sankalp, 2 Nov 2026) - see Phase 11c
- [ ] Individual layers (decided 21 Oct 2026) - any piece of the reel its own row with its own name, added, trimmed, cut, split, moved, animated and removed on its own, with layer tools in `reel-mcp`, the same as the web editor's `lib/reel-tools`
- [ ] The web editor's React animations (three goals, gmail flood and the rest) - the Mac app draws seven native kinds
- [ ] Draft parts with models and estimated cost, the rule books dropdown and part costs in the transcript, as the web editor shows them - the data is reachable through the draft tools, the interface is not built
- [ ] Trim a clip by dragging its edges on the timeline, and drag a face window or a placed clip in the preview
- [ ] Highlight the words a comment is on in the transcript, as the web editor does
- [ ] Update the Mac app note in the main `PRD.md` (around line 1500), which still lists the look, voice gain, music and face layer as missing

### Phase 11b: A reel of several videos 🚧 IN PROGRESS
- [x] New project from several videos (Sankalp, 2 Nov 2026) - chosen or dropped together, laid out in the order they were recorded, the first as the project's own video, each transcribed in turn; `create_project` with `videos` and `order` (`Arrange.swift`)
- [x] The transcript in the order the reel plays - clip by clip with each video's words, a head per clip naming its video, dragged to reorder the clips; other videos' words cut and commented on by their times
- [x] `move_range` and `insert_clip` for agents - a part of the reel moved to another place, a part of any video put in between two places, one undo step each in the JSON, the app lighting up where it lands and naming the video; `get_words` with `video` reads a video's own words, the parts not in the reel too
- [ ] Drag a range of words in the transcript to a new place by hand, as `move_range` does for agents
- [ ] Drop a clip's head after the last clip (today a head is dropped before another clip)
- [ ] Voice overs follow a moved part (today they stay at their edit time)
- [x] Every video transcribed (Sankalp, 2 Nov 2026) - a new project transcribes at once, every video with sound one after another, a silent or failing one not stopping the rest, the status saying which one of how many; the Transcribe button and the `transcribe` tool do the same; a transcription cut off by the app quitting picks up when the project opens
- [x] WhisperX in the app fixed (2 Nov 2026) - its output `media/words-<id>.raw.json` was read from the project's document since the move to one file per project, so every run failed with "has no words"; renamed `whisperx-<id>.json`, and only `words-<hash>.json` are document parts
- [x] Clip heads on the transcript's line (Sankalp, 2 Nov 2026) - a dot beside each clip's head on the line that joins the paragraphs, as the chat's rows are joined
- [x] Notifications (Sankalp, 2 Nov 2026) - a macOS notification when a transcription or an export ends and when the chat's Claude finishes, with its last words; shown with the app in front too, a click opens the project, Notifications in App settings turns them off
- [x] `delete_rule_book` (Sankalp, 2 Nov 2026) - takes a rule book out of the folder, keeping its text in `.previous`

### Phase 11c: Captions and text layers ✅ COMPLETE
- [x] One text style for captions and text layers (Sankalp, 2 Nov 2026) - font family (any on this Mac, Advercase and Inter bundled), weight, italic, size, letter spacing, line height, case, colour, outline, shadow, a box behind the line or the spoken word with its colour, opacity, padding and corners, the spoken word's colour, how a line comes in, x and y, widest line, words a line and alignment, in px of the 1080 by 1920 frame as on the web (`Captions.swift`)
- [x] The web editor's caption look as the built in one - Advercase Bold 95 px, white with a 7 px black outline, the spoken word in a black box, three words a line at 1490 px down (72 px at 900 landscape); the project's own style over the default saved for new projects over the built in look
- [x] Letters placed by their ink (Sankalp, 2 Nov 2026) - a caption line's height and its word box come from where the font's letters really reach, measured once per font and size, so Advercase's tops are never cut and the box sits evenly round the word
- [x] Preview equals export - each caption line drawn once per spoken word as one picture, shown in turn by the export and drawn for the playhead by the preview from the same function
- [x] Hidden stretches - captions hidden over a time, words or a clip, joined where they meet, shown again by id, by a stretch that splits one, or everywhere; drawn nowhere there, a line never runs across one
- [x] Text layers - kind text on the Animation layer, for a part of the reel or all of it, in the same style, coming in by fade, pop, rise, drop, a slide or typewriter and going out by fade, pop, rise, drop or a slide
- [x] Tools - `get_caption_style`, `set_caption_style` (clear, reset, burnIn, saveAsDefault, resetDefault), `list_fonts`, `hide_captions`, `show_captions`, `add_text_layer`, `update_text_layer`, and `add_animation` and `set_animations` take a text layer's style; the caption style and hidden stretches are undo steps; `set_caption_position` writes the style's x and y
- [x] The app - Captions on the timeline opens the Captions card (burned in, hidden stretches with Show and Hide over the selection or this clip, font, colours, box, place, Reset and Use for new projects), a text layer's card has its motions and the same style controls, Add layer has Animation Text; the chat's Claude is told of the tools
- [x] Fonts registered by the app and by reel-mcp alike, so an export from either draws the same letters
- [ ] Hands on checks - the preview's text layers and line motions while playing, the colour pickers, and a long font list in the Family dropdown

### Phase 12: Testing and Validation 🚧 IN PROGRESS
- [x] MCP suite - 557 of 557 checks pass across the 98 tools, with a rename that copies the file whole first and the recording date, the voice at 200 and 1000 percent measured louder, the caption style, hidden captions, text layers and their export, `delete_rule_book`, `transcribe` of every video after a silent first one, `write_rule_book`, `edit_rule_book` and `make_project_rules_folder`, `move_range`, `insert_clip`, `create_project` of several videos, `get_words` of one video, `get_paragraphs`, `set_focus`, `get_words`, the long transcript left out of `get_project` and `audit_audio` added on 2 Nov 2026, rerun after the merge, the design work, the move to one file per project, `move_project`, the removal of the chat listening tools, and `open_in_app` by path with `get_app_state`, `get_rules`, per project rules folders with `set_rules_folder`, and the editors of a project
- [x] Interface checks through window snapshots (`REEL_EDITOR_SNAPSHOT`, with `REEL_EDITOR_FLOAT`, `REEL_EDITOR_APP_SETTINGS`, `REEL_EDITOR_SELECT`, `REEL_EDITOR_MCP`, `REEL_EDITOR_OPEN_MENU`, `REEL_EDITOR_DIRECT_SAY` and `REEL_EDITOR_RULES` to open a state at launch) for the editor, dark mode, 80% zoom, the cards, the menus and the panel
- [ ] Hands on checks that snapshots cannot make - trackpad pinch and Cmd or Ctrl scroll on the timeline, dragging the dividers, dragging and stretching animation blocks, the video's place while the window is zoomed, and the spring of each card
- [ ] Hands on checks of 2 Nov 2026 - the timeline scrolling up and down with the names following and its sideways bar at the bottom, the side chat's divider, Stop in the chat, a comment going to the chat, clip heads dragged to reorder, switching projects while a chat's Claude works, a notification's click, the shimmer while Claude reads, and the editing buttons coming back when it finishes, the Voice card at 200% heard in the preview, the thin scroll bars in the transcript, chat and timeline, a click on the caption in the preview, cards scrolling at 60% of the window, and the app reopening on the project in front
- [ ] Automated interface tests - none exist; `swift test` finds no tests
- [ ] A long project from start to export in the Mac app alone, compared with the web editor's export of the same edits

### Phase 13: Analytics and PostHog Tracking ⏳ PENDING
- [ ] Decide whether the Mac app reports to PostHog at all - it is a local tool for one person today and logs every action to `_dump/*.jsonl`; if it does, the events below are sent with `email` (the Claude account in use) and `user_id`, and added to `README-Analytics-Posthog-Universal-Logging-System.md` in NextDoorCompanyCode
- [ ] `reel_project_opened` - a project opens in a tab; properties `project`, `duration_s`, `has_transcript`
- [ ] `reel_video_imported` - a video is dropped or chosen; properties `duration_s`, `width`, `height`, `transcribe`
- [ ] `reel_edit_made` - any edit from the app; properties `tool`, `project`, `source` (app or mcp)
- [ ] `reel_cuts_approved` - Approve pressed; properties `count`, `project`
- [ ] `reel_layer_card_opened` - a layer's floating card opens; properties `kind` (animation, clip, overlay)
- [ ] `reel_chat_message_sent` - a Chat message; properties `mode` (direct or session), `model`, `effort`, `account`
- [ ] `reel_chat_turn_completed` - a direct chat turn ends; properties `cost_usd`, `input_tokens`, `output_tokens`, `tools_called`, `error`
- [ ] `reel_mcp_panel_opened` and `reel_mcp_session_disconnected` - properties `tab`, `sessions`, `account`
- [ ] `reel_export_started`, `reel_export_completed` and `reel_export_failed` - properties `project`, `duration_s`, `two_pass`, `seconds_taken`, `error_message`

### Phase 14: Production / Pre-Launch ⏳ PENDING
- [x] Commit the Mac app's work of 31 Oct and 1 Nov 2026 - committed in ContentApp (frozen there in 6522c0c) and pushed as the first commit of this repo
- [ ] Sign with a Developer ID certificate and notarize, so the app opens on another Mac without a Gatekeeper warning - today `build.sh` signs with the Apple Development certificate for this Mac
- [ ] Version and build numbers that move with each release (`CFBundleShortVersionString` is 1.0.0 today), and the build stamp already written to `build.json`
- [ ] An update path, Sparkle or a release folder, and a rollback to the previous build
- [ ] Crash and error reporting beyond the local `_dump` logs
- [ ] A clean install check on a fresh Mac account - fonts, brand marks and the WhisperX path resolve, `reel-mcp` registers, the direct chat finds the claude command line
- [ ] Final QA pass of Phase 12's hands on checks on the release build

---

## ⚠️ Current Status / Known Issues

**Issue**: Some interactions are checked only in snapshots, not by hand - trackpad pinch, divider drags, animation block drags and the video under window zoom
**Fix**: Sankalp tries each one; anything off is fixed and noted in Phase 12
**Impact**: Low; each has a code path verified to build, and the MCP suite covers every edit they make

**Issue**: A running Claude Code session keeps the `reel-mcp` it started with, so a rebuild of the app does not reach it
**Fix**: `/mcp` and reconnect `reel-editor`, or restart the session
**Impact**: Sessions started before a rebuild miss new tools until they reconnect

**Issue**: Some of 2 Nov 2026's work is checked in exports and snapshots, not by hand - text layers and caption entrances in the preview while playing, the voice boost heard in the preview, and hover and click on the caption in the preview
**Fix**: Sankalp tries each one (Phase 11c and Phase 12 hands on checks); exports were measured and looked at frame by frame
**Impact**: Low; the preview and the export draw captions and run the voice gain with the same code

**Issue**: Notifications for a transcription or an export only come for projects open in a tab, which is where the app watches their status
**Fix**: Keep the project's tab open while a long job runs, or ask the chat to report when it is done
**Impact**: Low

**Issue**: The direct chat spends tokens from the account picked, and each limits check costs about 2,000 tokens on Haiku
**Fix**: Checks run at most every 20 minutes per account; every turn's cost is logged as `direct_chat_turn`
**Impact**: Visible in the MCP panel's bars and in the logs

**Files Modified**: everything in the app on 31 Oct and 1 Nov 2026, listed in Phase 3 to Phase 10

---

## 📋 Summary

Reel Editor for Mac is ContentApp's reel editor as its own native Mac app, built with SwiftUI and AVFoundation, with an MCP server inside it so Claude or any agent edits the same projects through tools. It is a separate port of the web editor (`/reel-editor`, `lib/reel-tools`), not a wrapper: the two share the idea, the edit decision list and the tool names, not the files. The video is never touched; every edit is JSON in the project's one file, `<name>.reel.json`, saved in any folder, and the preview and the export are drawn from the same composition, so what plays is what exports.

Since 31 Oct 2026 the app looks like the main ContentApp web app rather than stock macOS, does everything the web editor's tools allow, and can talk to Claude from its Chat, a Claude the app starts itself with the editor's tools; Claude Code sessions edit through the same tools over MCP. The MCP pill shows which Claude is connected, and its panel shows each account's limits and how much of them this editor used.

```
┌─────────────────────────────────────────────────────────────────────────┐
│        REEL EDITOR FOR MAC: FROM A RAW VIDEO TO AN EXPORTED REEL        │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ 1. Open the app                                                   │  │
│  │ Every project opens as a tab; a new tab shows Open a reel         │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                    │                                    │
│                                    ▼                                    │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ 2. Drop or choose a video                                         │  │
│  │ Read only; WhisperX puts a time on every word                     │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                    │                                    │
│                                    ▼                                    │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ 3. Edit by hand                                                   │  │
│  │ Drag across words: Cut, Uncut, Correct, Comment for Claude        │  │
│  │ Click a layer on the timeline: its settings float above it        │  │
│  │ Project card: started, last edited, saved at, who edited it       │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                    │                                    │
│                                    ▼                                    │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ 4. Or ask Claude                                                  │  │
│  │ Direct chat: the app runs its own Claude on a picked account      │  │
│  │ Claude Code sessions edit over MCP (reel-mcp) from their own chat │  │
│  │ Both edit the same JSON files through the same tools              │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                    │                                    │
│                                    ▼                                    │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ 5. The window follows along                                       │  │
│  │ Reloads within half a second of any edit                          │  │
│  │ Cuts from the chat wait in amber until Approve                    │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                    │                                    │
│                                    ▼                                    │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ 6. Check the MCP pill                                             │  │
│  │ Claude session (n); the panel shows each account,                 │  │
│  │ its 5 hour and weekly limits and this editor's share              │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                    │                                    │
│                                    ▼                                    │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ 7. Export                                                         │  │
│  │ Cmd E: an MP4 with the looks, music, captions and animations      │  │
│  │ Preview equals export (one composition, one layer tree)           │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Who it is for and why

It is Sankalp's own tool for cutting the talking head and job lead reels he posts, alongside the web editor in the ContentApp dashboard. The Mac app exists so the editor can run on its own, with native playback and export (AVFoundation) and no dev server, and so Claude can drive it through an MCP server that ships inside the app. Anything the web editor's tools can do, an agent can do here under the same names.

## Decisions made on 31 Oct 2026

- The Mac app takes the main app's design language, not Apple's native look; the main app itself is never changed for it.
- The app icon is the web editor's brand mark, the white film strip on a black tile.
- Cmd plus and minus zoom the whole window in 10% steps; = and - zoom the timeline; a trackpad pinch zooms the timeline too.
- The panel sizes, the timeline zoom and Follow are remembered.
- The transcript head reads TRANSCRIPT, as on the web; Project and Chat open as cards, not tabs.
- A layer's settings open in a card floating above the layer, not in a side panel.
- Cards and menus never open outside the window, are right aligned to what opened them with an arrow at the top right, cast a shadow, and spring open with the native spring.
- Animation blocks never use red or pink; red is kept for cuts.
- The transcript's line height is 1.16 times the type, words 2 points apart with 2 points of padding each side.
- The MCP pill reads "Claude session (n)" with a green dot and the Claude logo; session details live in the panel, whose default tab shows only the sessions using this editor.
- Each account's limits are read the way LiveAssistant reads them, and this editor's share is shown green against the rest in blue.
- A session can be disconnected from the panel and reconnected with `/mcp`.
- The chat can run its own Claude (Direct), on a picked account, model and effort, and can sit in a side panel or float.

## How it is built

| Part | Where |
|---|---|
| Edit decision list, project files, composition, overlay, export, jobs | `Sources/ReelCore/` (`EDL.swift`, `Project.swift`, `Composition.swift`, `Overlay.swift`, `AnimationLayers.swift`, `Jobs.swift`) |
| Tools shared by the app and agents | `Sources/ReelCore/Tools.swift`, `ToolsWeb.swift`, `Layers.swift`, `Records.swift` |
| Looks, placement and face windows; voice and music processing | `Sources/ReelCore/Compositor.swift`, `AudioFX.swift` |
| MCP server | `Sources/ReelMCP/main.swift` |
| Design language | `Sources/ReelEditor/Design.swift`, `PhosphorCodes.swift`, `Resources/Fonts`, `Resources/Brand` |
| Window, tabs, top bar, MCP pill and panel | `Sources/ReelEditor/ReelEditorApp.swift`, `AccountLimits.swift`, `SessionUsage.swift` |
| Editor, transcript, timeline, player | `Sources/ReelEditor/EditorView.swift`, `TranscriptView.swift`, `TimelineView.swift`, `PlayerView.swift`, `EditorModel.swift` |
| Floating cards and menus | `Sources/ReelEditor/Floating.swift`, `MenuHost.swift`, `InspectorView.swift` |
| Chat | `Sources/ReelEditor/ChatPanel.swift`, `DirectChat.swift` |
| Build and install | `build.sh` (release build, signs, installs to `~/Applications`), `make-icon.swift`, `phosphor-codes.sh` |

## Build, run and connect

```bash
./build.sh            # release build, install to ~/Applications, open
./build.sh --no-open  # build and install only
claude mcp add --scope user reel-editor -- "$HOME/Applications/Reel Editor.app/Contents/MacOS/reel-mcp"
```

For the chat nothing is needed; it starts with the first message.

## Related documentation

- `README.md` - how the app works in detail, every tool, keys, layouts and the debug switches
- `CLAUDE.md` - the rules for working in this repo
- `tests/mcp_test.py` - the MCP suite, 557 checks
- ContentApp's `PRD.md` - the web reel editor's phases, and the frozen copy of this app in `tools/reel-editor-mac`
- ContentApp's `lib/reel-tools/` and `components/reel-editor/` - the web editor the Mac app is ported from
- `NextDoorCompanyCode/DOCUMENTATION-STRUCTURE.md` and `DESIGN.md` - the documentation and design rules this app follows

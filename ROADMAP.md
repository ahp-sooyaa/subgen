# Roadmap

Planned improvements and new features. Nothing here is built yet.

## 1080p copy for watching

**Problem.** Jobs download 720p H.264 (`subgen/fetch.py`). That is enough to read burned-in captions
and keeps OCR fast, but it looks soft when watching.

**Plan.** Keep processing on 720p, and fetch a 1080p copy only for playback. Subtitles are separate
.srt files drawn over the video, so the same cues fit either copy and nothing is reprocessed.

- Start the 1080p download as soon as the 720p one finishes, so it runs while OCR / ASR /
  translation use the CPU. It is usually ready when the subtitles are.
- Download only the 1080p video stream and mux it with the 720p file's audio (`ffmpeg -c copy`).
- Prefer 1080p H.264 (`avc1`). Above 1080p YouTube mostly offers VP9/AV1 only, which AVPlayer
  does not play reliably on every Mac — leave higher resolutions for later.
- Save it as `video.1080.mp4` next to `video.mp4`, and reuse it from the cache like the 720p file.
  Keep the 720p file: reruns process it.
- Show it as an optional stage in the job view ("HD copy"). If it fails, or the video has no
  1080p, the job still succeeds and the viewer plays 720p.
- Compare the two files' durations; if they differ noticeably, fall back to 720p so subtitles
  stay in sync.
- Not for local files — those play the original.

**Viewer.**

- A 720p / 1080p switch, shown only once the 1080p file exists ("1080p downloading…" until then).
- Switching keeps the playback position and play/pause state.
- Remember the choice; default to the best copy available.

**Setting.** "Download HD copy for watching", on by default (1080p files are roughly 2–3× larger).

## Keyboard controls in the viewer

**Problem.** Space doesn't reliably play/pause, and arrows don't seek. The viewer has an
`.onKeyPress(.space)` on the video pane (`app/Subgen/ViewerView.swift`), but it only fires while
that pane has keyboard focus. Clicking the video goes through `onTapGesture`, which doesn't take
focus, and the English text fields in the Lines list keep it once you've edited a line.

**Plan.**

| Key | Action |
| --- | --- |
| Space | Play / pause |
| ← | Back 10 s |
| → | Forward 10 s |

- Handle the keys at the window level, so they work wherever focus is — except while a text field
  is being edited, where Space and the arrows must keep typing and moving the cursor.
- Clicking the video should give it focus (and end any text edit).
- Clamp seeks to the start and end of the video.
- Maybe later: ↑/↓ for previous/next line, and show the shortcuts in the transport bar's tooltips.

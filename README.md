# subgen

English `.srt` subtitles for videos that have **burned-in Chinese captions** (e.g. Mango TV variety shows).
It reads the on-screen captions with Apple Vision OCR (offline), then translates them with Claude Code
in headless mode, which uses your Claude subscription.

## Install
Requires macOS (Apple Vision OCR), Python 3.11+, `ffmpeg` (`brew install ffmpeg`) and the
[Claude Code](https://claude.com/claude-code) CLI, logged in.
```
git clone https://github.com/ahp-sooyaa/subgen.git
cd subgen
python3 -m venv .venv
.venv/bin/pip install -e .
```

## Use
```
.venv/bin/subgen "https://www.youtube.com/watch?v=..." -o ~/Downloads
```
Outputs `<title>.zh.srt` and `<title>.en.srt`. Load the `.en.srt` into the Substital extension.

Useful options:
- `--preview`: save `work/<id>/preview.jpg` showing the detected caption band (green), then stop.
- `--region x,y,w,h`: set the caption band manually in pixels if auto-detection picks the wrong area.
- `--start 300 --duration 180`: process only part of the video (quick test).
- `--speakers`: prefix lines with the speaker name (`Na Ying: …`).
- `--bilingual`: also write English + Chinese in one file.
- `--no-translate`: stop after the Chinese `.srt`.
- `--redo region|ocr|translate`: ignore cached results from that stage on (results are cached in `work/`).
- `--model sonnet|opus`: Claude model used for translation.
- `--no-hd`: skip the 1080p copy for watching (see below).

`glossary.txt` maps cast names to English spellings. Add new guests there.

## How it works
1. `yt-dlp` downloads 720p H.264. Meanwhile a 1080p H.264 copy (`work/<id>/video.1080.mp4`) downloads in the
   background for watching only; it reuses the 720p audio and is dropped if the lengths differ or YouTube has no
   1080p H.264. Processing always uses 720p.
2. About 40–120 frames are OCR'd to find the band where changing text lives (the caption band).
3. `ffmpeg` crops that band at 4 fps. A frame is only OCR'd when its white-text pixels change.
4. Watermarks, sponsor badges (far left and right edges) and blacklisted words are dropped. Frames with the same text are merged into timed cues.
5. Cues are translated in batches of 80 with `claude -p` (three batches at a time). Ads and OCR garbage come back as `[DROP]` and are removed.

Requires `ffmpeg` (Homebrew) and the `claude` CLI logged in.

## Speech recognition (experimental, Mandarin only)
For videos without burned-in captions, or to compare against OCR. Install the extra once:
```
.venv/bin/pip install -e '.[asr]'
```
- `--asr whisper` (mlx-whisper large-v3-turbo) or `--asr sensevoice` (FunASR SenseVoiceSmall) uses the
  audio instead of OCR. `--asr merge` runs both and lets Claude reconcile them (most accurate).
  Outputs `<name>.asr-<engine>.zh.srt` (raw), `.fixed.zh.srt` (corrected by Claude) and `.en.srt`.
  Models download on first use.
- The name glossary is built automatically from the title, YouTube description and a first-pass transcript
  (saved as `work/<id>/glossary.auto.txt`; edit it and re-run with `--redo translate`, or pass `--glossary`).
- `--whisper-hints`: also give Whisper the glossary names (a second Whisper pass; small gain).
- `subgen-compare <video> --ref <ocr .zh.srt> [--start --duration]` runs both engines and scores them
  against the OCR captions: character error rate, timing, and speed. Writes `work/<id>/compare.md`.

## Mac app
`app/` is a SwiftUI front end for the same pipeline: a job queue, live progress per stage with ETA,
pause / continue / stop, resume after stopping or quitting (finished chunks come from the cache), a
glossary editor with "Save & Re-translate", and a viewer that plays the video with the subtitles and
lets you fix English lines. The viewer switches between 720p and the 1080p copy once it's downloaded
(Settings → "Download HD copy for watching"). It runs `.venv/bin/subgen --events …`, so the CLI setup above is required.
```
cd app && xcodegen generate && xcodebuild -scheme Subgen -configuration Release -derivedDataPath build.noindex build
open /Applications/Subgen.app
```
A Release build installs itself to `/Applications/Subgen.app`, replacing any previous copy; quit the
app before rebuilding.
Settings (⌘,) set the subgen folder, output folder and Claude model.

## Notes
Only process videos you have the right to download and subtitle. Downloaded videos and generated
subtitles stay in the local `work/` and `out/` folders and are not part of this repository.

## License
[MIT](LICENSE)

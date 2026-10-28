# subgen

English `.srt` subtitles for videos that have **burned-in Chinese captions** (e.g. Mango TV variety shows).
It reads the on-screen captions with Apple Vision OCR (offline), then translates them with Claude Code
in headless mode, which uses your Claude subscription.

## Use
```
~/Personal/subgen/.venv/bin/subgen "https://www.youtube.com/watch?v=..." -o ~/Downloads
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

`glossary.txt` maps cast names to English spellings. Add new guests there.

## How it works
1. `yt-dlp` downloads 720p H.264.
2. About 40–120 frames are OCR'd to find the band where changing text lives (the caption band).
3. `ffmpeg` crops that band at 4 fps. A frame is only OCR'd when its white-text pixels change.
4. Watermarks, sponsor badges (far left and right edges) and blacklisted words are dropped. Frames with the same text are merged into timed cues.
5. Cues are translated in batches of 80 with `claude -p` (three batches at a time). Ads and OCR garbage come back as `[DROP]` and are removed.

Requires `ffmpeg` (Homebrew) and the `claude` CLI logged in.

## Speech recognition (experimental, Mandarin only)
For videos without burned-in captions, or to compare against OCR. Install the extra once:
```
~/Personal/subgen/.venv/bin/pip install -e '.[asr]'
```
- `--asr whisper` (mlx-whisper large-v3-turbo) or `--asr sensevoice` (FunASR SenseVoiceSmall) uses the
  audio instead of OCR. Outputs `<name>.asr-<engine>.zh.srt` / `.en.srt`. Models download on first use.
- `subgen-compare <video> --ref <ocr .zh.srt> [--start --duration]` runs both engines and scores them
  against the OCR captions: character error rate, timing, and speed. Writes `work/<id>/compare.md`.

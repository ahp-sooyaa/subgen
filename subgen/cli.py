"""subgen: English subtitles for videos with burned-in Chinese captions."""
import argparse
import json
import os
import re
from pathlib import Path

from . import cues as cuesmod
from . import asr, events, fetch, ocr, region, translate

ROOT = Path(__file__).resolve().parent.parent
# Overlay text that sits inside the caption band but is never dialogue (matched lowercase).
BLACKLIST = ["芒果", "果tv", "会员抢", "抢先看", "独播", "京东", "jdh"]


def main():
    ap = argparse.ArgumentParser(prog="subgen", description=__doc__)
    ap.add_argument("src", help="YouTube URL or local video file")
    ap.add_argument("-o", "--out", type=Path, default=Path.cwd(), help="output folder for .srt files (default: current folder)")
    ap.add_argument("--name", help="output file name (default: video title)")
    ap.add_argument("--start", type=float, default=0, help="only process from this second (for testing)")
    ap.add_argument("--duration", type=float, help="only process this many seconds (for testing)")
    ap.add_argument("--region", help="caption band as x,y,w,h in pixels (skips auto-detection)")
    ap.add_argument("--preview", action="store_true", help="save preview.jpg of the detected caption band and stop")
    ap.add_argument("--fps", type=float, default=4, help="frames per second to read (default 4)")
    ap.add_argument("--sim", type=float, default=80, help="text similarity %% to treat frames as the same caption (default 80)")
    ap.add_argument("--change", type=float, default=0.1, help="pixel-change threshold that triggers a new OCR (default 0.1)")
    ap.add_argument("--model", default="sonnet", help="Claude model alias for translation (default sonnet)")
    ap.add_argument("--glossary", type=Path,
                    help="name glossary file (default: glossary.txt for OCR; built automatically for --asr)")
    ap.add_argument("--speakers", action="store_true", help="prefix English lines with the speaker name")
    ap.add_argument("--bilingual", action="store_true", help="also write an English+Chinese .srt")
    ap.add_argument("--no-translate", action="store_true", help="stop after writing the Chinese .srt")
    ap.add_argument("--asr", choices=asr.ENGINES + (asr.MERGE,),
                    help="use speech recognition instead of OCR (Mandarin audio); merge = both engines")
    ap.add_argument("--whisper-hints", action="store_true",
                    help="with --asr: give Whisper the glossary names too (runs Whisper a second time)")
    ap.add_argument("--redo", choices=["region", "ocr", "asr", "translate"], help="ignore cached results from this stage on")
    ap.add_argument("--events", help="append machine-readable progress (JSON lines) to this file")
    a = ap.parse_args()
    if a.events:
        events.init(a.events)
        os.setpgrp()  # own process group, so the app can pause/stop us with ffmpeg and claude
    try:
        run(a)
    except BaseException as e:
        events.emit("error", message=str(e) or type(e).__name__)
        raise
    events.emit("finished")


def run(a):
    slug = fetch.slug_for(a.src)
    if a.start or a.duration:
        slug += f"_{int(a.start)}_{int(a.duration or 0)}"
    work = ROOT / "work" / slug
    work.mkdir(parents=True, exist_ok=True)
    redo = {"region": 0, "ocr": 1, "asr": 1, "translate": 2}.get(a.redo, 99)

    with events.stage("download"):
        video, title = fetch.fetch(a.src, ROOT / "work" / fetch.slug_for(a.src))
    W, H, total = fetch.probe(video)
    end = min(total, a.start + a.duration) if a.duration else total
    print(f"Video: {title or video.name}  ({W}x{H}, {(end - a.start) / 60:.1f} min)")

    name = a.name or (re.sub(r'[\\/:*?"<>|]+', "_", title).strip()[:80] if title else slug)
    a.out.mkdir(parents=True, exist_ok=True)
    events.emit("job", work=str(work), video=str(video.resolve()), title=title, name=name,
                start=a.start, end=end, mode=a.asr or "ocr")
    if a.asr:
        cues, _info = asr.transcribe(video, work, a.asr, a.start, a.duration, redo <= 1)
        if a.glossary:
            glossary = a.glossary.read_text()
            events.emit("glossary", path=str(a.glossary.resolve()), auto=False)
        else:
            desc = fetch.description(a.src, ROOT / "work" / fetch.slug_for(a.src))
            with events.stage("glossary"):
                glossary = translate.auto_glossary(cues, title, desc, work / "glossary.auto.txt", a.model, redo <= 1)
            print("  Glossary (" + str(work / "glossary.auto.txt") + "):\n    " + glossary.strip().replace("\n", "\n    "))
            events.emit("glossary", path=str(work / "glossary.auto.txt"), auto=True)
        if a.whisper_hints and a.asr != "sensevoice":
            cues, _info = asr.transcribe(video, work, a.asr, a.start, a.duration, redo <= 1, asr.hint_words(glossary))
        finish(a, cues, work, title, f"{name}.asr-{a.asr}", "merge" if a.asr == asr.MERGE else "asr",
               f"translate_asr-{a.asr}", redo, glossary)
        return

    # 1. caption band
    reg_path = work / "region.json"
    if a.region:
        x, y, w, h = (int(v) for v in a.region.split(","))
        reg = {"crop": [x, y, w - w % 2, h - h % 2], "zones": []}
        reg_path.write_text(json.dumps(reg))
    elif reg_path.exists() and redo > 0:
        reg = json.loads(reg_path.read_text())
        events.cached("region")
    else:
        with events.stage("region"):
            reg = region.detect(video, W, H, a.start, end, n=min(120, max(40, int((end - a.start) / 10))))
        reg_path.write_text(json.dumps(reg, ensure_ascii=False, indent=1))
        redo = min(redo, 1)
    print(f"  Caption band: {reg['crop']}  excluded zones: {len(reg['zones'])}")
    if a.preview:
        region.preview(video, reg, work / "preview.jpg", a.start, end)
        print(f"Preview saved: {work / 'preview.jpg'}")
        return

    # 2. OCR
    frames = work / "frames.jsonl"
    params = {"crop": reg["crop"], "zones": reg["zones"], "fps": a.fps, "change": a.change}
    params_path = work / "ocr_params.json"
    if redo <= 1 or not frames.exists() or not params_path.exists() or json.loads(params_path.read_text()) != params:
        if redo <= 1:  # don't continue an interrupted run
            (work / "ocr_running.json").unlink(missing_ok=True)
        with events.stage("ocr"):
            ocr.ocr_video(video, frames, a.fps, reg["crop"], reg["zones"], BLACKLIST, a.change,
                          total, a.start, a.duration, params)
        params_path.write_text(json.dumps(params))
        redo = min(redo, 2)
    else:
        events.cached("ocr")

    # 3. cues
    cues = cuesmod.build(frames, a.fps, a.sim)
    glossary_file = a.glossary or ROOT / "glossary.txt"
    glossary = glossary_file.read_text() if glossary_file.exists() else ""
    if glossary_file.exists():
        events.emit("glossary", path=str(glossary_file.resolve()), auto=False)
    finish(a, cues, work, title, name, "ocr", "translate", redo, glossary)


def finish(a, cues, work, title, name, source, cache_name, redo, glossary):
    """Write the Chinese .srt, then translate and write the English ones."""
    zh_path = a.out / f"{name}.zh.srt"
    cuesmod.write_srt(cues, zh_path, "zh")
    print(f"  {len(cues)} captions → {zh_path}")
    events.emit("output", kind="zh", path=str(zh_path.resolve()))
    if a.no_translate:
        return

    # 4. translate
    if redo <= 2:
        for f in (work / cache_name).glob("*.json"):
            f.unlink()
    with events.stage("translate"):
        cues = translate.translate(cues, work, glossary, title, a.model, source=source, cache_name=cache_name)
    (work / ("cues.json" if source == "ocr" else f"cues_{cache_name}.json")).write_text(json.dumps(cues, ensure_ascii=False, indent=1))
    cues = cuesmod.polish(cues)
    if source != "ocr":
        fixed = a.out / f"{name}.fixed.zh.srt"
        cuesmod.write_srt(cues, fixed, "zh")
        print(f"  corrected Chinese → {fixed}")
        events.emit("output", kind="fixed", path=str(fixed.resolve()))
    en_path = a.out / f"{name}.en.srt"
    cuesmod.write_srt(cues, en_path, "en", a.speakers)
    print(f"Done → {en_path}")
    events.emit("output", kind="en", path=str(en_path.resolve()))
    if a.bilingual:
        bi = a.out / f"{name}.en-zh.srt"
        cuesmod.write_srt(cues, bi, "both", a.speakers)
        print(f"     → {bi}")
        events.emit("output", kind="en-zh", path=str(bi.resolve()))


if __name__ == "__main__":
    main()

"""Merge per-frame OCR text into timed subtitle cues."""
import json
from collections import Counter
from datetime import timedelta
from pathlib import Path

import srt
from rapidfuzz import fuzz


def body(text: str) -> str:
    """Caption text without the leading speaker-name tag (if any)."""
    parts = text.split(" | ")
    if len(parts) > 1 and len(parts[0]) <= 4:
        return " | ".join(parts[1:])
    return text


def similar(a: str, b: str, thresh: float) -> bool:
    ba, bb = body(a), body(b)
    if min(len(ba), len(bb)) <= 3:
        return ba == bb
    return fuzz.ratio(ba, bb) >= thresh


def build(frames_path: Path, fps: float, sim: float = 80, min_dur: float = 0.3,
          max_dur: float = 30.0) -> list[dict]:
    frames = [json.loads(l) for l in frames_path.read_text().splitlines()]
    step = 1 / fps
    cues: list[dict] = []
    cur, gap = None, 0

    def close():
        if cur:
            best = max(cur["variants"].items(), key=lambda kv: (kv[1], len(kv[0])))[0]
            cues.append({"start": cur["start"], "end": cur["end"], "zh": best})

    for f in frames:
        t, text = f["t"], f["text"]
        if not text:
            gap += 1
            if gap > 1:  # tolerate a single missed frame
                close()
                cur = None
            continue
        if cur and similar(text, cur["last"], sim):
            cur["end"] = t + step
            cur["variants"][text] += 1
            cur["last"] = text
        else:
            close()
            cur = {"start": t, "end": t + step, "variants": Counter({text: 1}), "last": text}
        gap = 0
    close()

    # Join near-identical neighbours split by OCR noise or a short flicker.
    merged: list[dict] = []
    for c in cues:
        prev = merged[-1] if merged else None
        if prev and c["start"] - prev["end"] < 0.6 and similar(c["zh"], prev["zh"], sim):
            if (c["end"] - c["start"]) > (prev["end"] - prev["start"]):
                prev["zh"] = c["zh"]
            prev["end"] = c["end"]
        else:
            merged.append(c)

    # Promo banners repeat the same long text many times through the episode.
    counts = Counter(c["zh"] for c in merged)
    out = [
        c for c in merged
        if min_dur <= c["end"] - c["start"] <= max_dur
        and not (counts[c["zh"]] >= 4 and len(body(c["zh"])) >= 8)
    ]
    for i, c in enumerate(out, 1):
        c["id"] = i
    return out


def polish(cues: list[dict], min_show: float = 1.0) -> list[dict]:
    """After translation: drop empty lines, merge repeated English, keep lines readable."""
    out: list[dict] = []
    for c in cues:
        if not c.get("en"):
            continue
        prev = out[-1] if out else None
        if prev and prev["en"] == c["en"] and c["start"] - prev["end"] < 0.8:
            prev["end"] = c["end"]
            continue
        out.append(dict(c))
    for i, c in enumerate(out):
        nxt = out[i + 1]["start"] if i + 1 < len(out) else c["end"] + min_show
        if c["end"] - c["start"] < min_show:
            c["end"] = max(c["end"], min(c["start"] + min_show, nxt))
    return out


def write_srt(cues: list[dict], path: Path, key: str, speakers: bool = False):
    subs = []
    for c in cues:
        en = c.get("en", "")
        if en and speakers and c.get("speaker"):
            en = f"{c['speaker']}: {en}"
        zh = c["zh"].replace(" / ", "\n")
        text = {"zh": zh, "en": en, "both": f"{en}\n{zh}" if en else ""}[key]
        if not text:
            continue
        subs.append(srt.Subtitle(len(subs) + 1, timedelta(seconds=c["start"]),
                                 timedelta(seconds=c["end"]), text))
    path.write_text(srt.compose(subs), encoding="utf-8")

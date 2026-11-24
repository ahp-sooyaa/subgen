"""Find the caption band automatically, per stretch of the video, and the watermark zones inside it.

Most shows keep captions in one place, but some move them for a while (e.g. above a quiz card
that covers the usual spot). So the result is a list of time segments, each with its own band.
"""
import json
import re
import subprocess
from pathlib import Path

import cv2
import numpy as np
from rapidfuzz import fuzz

from . import events
from .ocr import CJK, Box, plausible, vision_ocr

BINS = 40
MAX_BANDS = 3
MIN_ALT_RUN = 3  # samples in a row that must put captions in another band before we switch


def sample_frames(video: Path, n: int, start: float, end: float):
    cap = cv2.VideoCapture(str(video))
    for i in range(n):
        t = start + (end - start) * (i + 0.5) / n
        cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000)
        ok, frame = cap.read()
        if ok:
            yield t, frame
    cap.release()


def frame_at(video: Path, t: float):
    cap = cv2.VideoCapture(str(video))
    cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000)
    ok, frame = cap.read()
    cap.release()
    return frame if ok else None


def crop_for(top: float, bot: float, width: int, height: int) -> list[int]:
    by = max(0, int(top * height))
    bh = min(height - by, int((bot - top) * height))
    bh -= bh % 2
    return [0, by, width - width % 2, bh]


def zones_for(watermarks: list[list[float]], crop: list[int], height: int) -> list[list[float]]:
    """Watermark rectangles (frame fractions) that overlap the band, in band-relative coords."""
    _, by, _, bh = crop
    top, bot = by / height, (by + bh) / height
    zones = []
    for x, y, w, h in watermarks:
        if y + h < top or y > bot:
            continue
        z = [round(v, 4) for v in (x - 0.01, (y * height - by) / bh - 0.05, w + 0.02, h * height / bh + 0.1)]
        if not any(abs(z[0] - o[0]) < 0.02 and abs(z[1] - o[1]) < 0.05 for o in zones):
            zones.append(z)
    return zones


def _band(boxes: list[Box], lo: int, hi: int) -> tuple[float, float]:
    inside = [b for b in boxes if lo <= min(int(b.cy * BINS), BINS - 1) <= hi]
    return max(0.0, min(b.y for b in inside) - 0.015), min(1.0, max(b.y + b.h for b in inside) + 0.015)


def _peak_band(hist: np.ndarray, used: np.ndarray) -> tuple[int, int, int]:
    h = np.where(used, 0, hist)
    peak = int(h.argmax())
    lo = hi = peak
    while lo > 0 and not used[lo - 1] and h[lo - 1] >= 0.15 * h[peak]:
        lo -= 1
    while hi < BINS - 1 and not used[hi + 1] and h[hi + 1] >= 0.15 * h[peak]:
        hi += 1
    return peak, lo, hi


def _captionish(b: Box) -> bool:
    return len(CJK.findall(b.text)) >= 2


def _centred(b: Box) -> bool:
    return abs(b.cx - 0.5) < 0.15


def detect(video: Path, width: int, height: int, start: float, end: float, n: int = 120) -> dict:
    """Sample frames, OCR them whole, and decide where captions live over time.

    Text that shows the same thing at the same place in many samples is a logo/watermark and
    becomes an exclusion zone. The band where the remaining (changing) text clusters is the main
    caption band. Smaller clusters of centred, changing text are other bands; a stretch of the
    video where captions keep showing up in one of them, and not in the main band, uses that band.
    """
    times: list[float] = []
    samples: list[list[Box]] = []
    for i, (t, frame) in enumerate(sample_frames(video, n, start, end)):
        boxes = []
        for b in vision_ocr(frame):
            txt = plausible(b.text)
            if txt:
                b.text = txt
                boxes.append(b)
        times.append(t)
        samples.append(boxes)
        events.progress("region", i + 1, n, f"Finding caption area… {i + 1}/{n}")
    print()
    return analyse(times, samples, width, height, start, end)


def analyse(times: list[float], samples: list[list[Box]], width: int, height: int, start: float, end: float) -> dict:
    def near(a: Box, b: Box):
        # Loose text match: OCR misreads a logo a little differently each time (浙江卫视, 浙红正视).
        return abs(a.cx - b.cx) < 0.03 and abs(a.cy - b.cy) < 0.03 and \
            (a.text == b.text or fuzz.ratio(a.text, b.text) >= 50)

    # Static: the same text at the same place in many samples (logo, watermark), or in
    # a neighbouring sample. Samples are seconds apart and a caption rarely lasts that long,
    # but scene titles ("南非之旅 状况百出") and quiz cards stay up for minutes and change
    # too often to reach the 20% bar.
    # Only the first kind (watermark) becomes an exclusion zone: a zone applies to its whole
    # segment, and lingering overlays can sit right on the caption line, so masking their
    # spot would drop every caption there.
    static, watermarks = [], []
    moving: list[list[Box]] = []
    for si, boxes in enumerate(samples):
        neighbours = [samples[j] for j in (si - 1, si + 1) if 0 <= j < len(samples)]
        mv = []
        for b in boxes:
            hits = sum(any(near(b, o) for o in other) for oj, other in enumerate(samples) if oj != si)
            lingers = any(near(b, o) for other in neighbours for o in other)
            if hits >= 0.2 * len(samples):
                watermarks.append(b)
            (static if hits >= 0.2 * len(samples) or lingers else mv).append(b)
        moving.append(mv)

    all_moving = [b for mv in moving for b in mv]
    if not all_moving:
        raise SystemExit("No changing text found. Pass --region x,y,w,h manually (see --preview).")

    # Main band: the peak of the histogram of vertical centres of all changing text.
    hist = np.zeros(BINS)
    for b in all_moving:
        hist[min(int(b.cy * BINS), BINS - 1)] += 1
    used = np.zeros(BINS, bool)
    _, lo, hi = _peak_band(hist, used)
    used[lo:hi + 1] = True
    bands = [_band(all_moving, lo, hi)]

    # Other bands: sharp peaks of centred caption-like text outside the main band. A caption
    # line is one or two bins tall; scattered scene text makes a low, wide floor instead.
    centred = [b for b in all_moving if _centred(b) and _captionish(b)]
    chist = np.zeros(BINS)
    for b in centred:
        chist[min(int(b.cy * BINS), BINS - 1)] += 1
    for _ in range(MAX_BANDS - 1):
        h = np.where(used, 0, chist)
        peak = int(h.argmax())
        if h[peak] < max(8, 0.04 * len(centred)):
            break
        lo = hi = peak
        while lo > max(0, peak - 2) and not used[lo - 1] and h[lo - 1] >= 0.4 * h[peak]:
            lo -= 1
        while hi < min(BINS - 1, peak + 2) and not used[hi + 1] and h[hi + 1] >= 0.4 * h[peak]:
            hi += 1
        used[max(0, lo - 1):hi + 2] = True
        top, bot = _band(centred, lo, hi)
        if any(min(bot, b) - max(top, t) > 0.5 * (bot - top) for t, b in bands):
            continue
        bands.append((top, bot))

    # Which band each sample's captions are in: another band if centred caption-like text is
    # there (when captions move, it's to make room for an overlay in the main band, whose text
    # is then also on screen), else the main band if caption-like text is there, else unknown.
    def label(mv: list[Box]) -> int | None:
        for k in [*range(1, len(bands)), 0]:
            top, bot = bands[k]
            if any(top <= b.cy <= bot and _captionish(b) and (k == 0 or _centred(b)) for b in mv):
                return k
        return None

    labels = [label(mv) for mv in moving]

    # Runs of the same label (unknowns don't break a run). Short runs in another band are
    # noise (a sign, a name tag), so they fold back into the main band.
    runs: list[list] = []  # [band, first sample, last sample, count]
    for i, k in enumerate(labels):
        if k is None:
            continue
        if runs and runs[-1][0] == k:
            runs[-1][2], runs[-1][3] = i, runs[-1][3] + 1
        else:
            runs.append([k, i, i, 1])
    for r in runs:
        if r[0] != 0 and r[3] < MIN_ALT_RUN:
            r[0] = 0
    merged: list[list] = []
    for r in runs:
        if merged and merged[-1][0] == r[0]:
            merged[-1][2], merged[-1][3] = r[2], merged[-1][3] + r[3]
        else:
            merged.append(list(r))
    if not merged:
        merged = [[0, 0, len(samples) - 1, 0]]

    wm = [[round(b.x, 4), round(b.y, 4), round(b.w, 4), round(b.h, 4)] for b in watermarks]
    used_bands = sorted({r[0] for r in merged} | {0})
    band_list = []
    for k in used_bands:
        crop = crop_for(*bands[k], width, height)
        hits = [i for i, lb in enumerate(labels) if lb == k] or list(range(len(times)))
        picks = [hits[int(len(hits) * (q + 0.5) / 4)] for q in range(min(4, len(hits)))]
        band_list.append({"crop": crop, "zones": zones_for(wm, crop, height),
                          "previews": sorted({round(times[i], 2) for i in picks})})
    segments = []
    for j, (k, first, last, _count) in enumerate(merged):
        s = start if j == 0 else round((times[merged[j - 1][2]] + times[first]) / 2, 2)
        e = end if j == len(merged) - 1 else round((times[last] + times[merged[j + 1][1]]) / 2, 2)
        segments.append({"start": s, "end": e, "band": used_bands.index(k)})

    reg = {
        "bands": band_list,
        "segments": segments,
        "watermarks": wm,
        "static_text": sorted({b.text for b in static}),
        "band_frac": [round(bands[0][0], 3), round(bands[0][1], 3)],
    }
    return sync(reg)


def sync(reg: dict) -> dict:
    """Copy each band's crop and zones into its segments (what OCR reads), and the main band to the top level."""
    bands = reg["bands"]
    for seg in reg["segments"]:
        b = bands[seg["band"]]
        seg["crop"], seg["zones"] = b["crop"], b["zones"]
        # Captions moved up for an overlay go back to the main band between overlays, so a frame
        # with nothing in this band is read in the main band too.
        seg["fallback"] = None if seg["band"] == 0 else {"crop": bands[0]["crop"], "zones": bands[0]["zones"]}
    reg["crop"], reg["zones"] = bands[0]["crop"], bands[0]["zones"]
    return reg


def normalise(reg: dict, start: float, end: float) -> dict:
    """Older region.json files (and --region) have one band for the whole video."""
    if "bands" not in reg:
        reg["bands"] = [{"crop": reg["crop"], "zones": reg["zones"]}]
        reg["segments"] = [{"start": start, "end": end, "band": 0}]
    return sync(reg)


def hms(t: float) -> str:
    t = int(t)
    return f"{t // 3600}:{t // 60 % 60:02d}:{t % 60:02d}" if t >= 3600 else f"{t // 60}:{t % 60:02d}"


def stretches(reg: dict, k: int) -> list[str]:
    return [f"{hms(s['start'])}-{hms(s['end'])}" for s in reg["segments"] if s["band"] == k]


def draw(frame: np.ndarray, crop: list[int], zones: list[list[float]], caption: str) -> np.ndarray:
    """The frame with the caption band (green), excluded zones (red) and a height ruler (% of frame)."""
    f = frame.copy()
    H = f.shape[0]
    x, y, w, h = crop
    for zx, zy, zw, zh in zones:
        p1 = (int(x + zx * w), int(y + zy * h))
        p2 = (int(x + (zx + zw) * w), int(y + (zy + zh) * h))
        cv2.rectangle(f, p1, p2, (0, 0, 255), 2)
    cv2.rectangle(f, (x, y), (x + w - 1, y + h - 1), (0, 255, 0), 3)
    for p in range(10, 100, 10):
        py = int(H * p / 100)
        cv2.line(f, (0, py), (14, py), (255, 255, 255), 2)
        cv2.line(f, (0, py), (14, py), (0, 0, 0), 1)
        cv2.putText(f, f"{p}%", (17, py + 5), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 0), 3)
        cv2.putText(f, f"{p}%", (17, py + 5), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1)
    cv2.putText(f, caption, (60, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 4)
    cv2.putText(f, caption, (60, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1)
    return f


def render_previews(video: Path, reg: dict, outdir: Path, only: set[int] | None = None):
    """Save preview frames of each band into `outdir`; their file names go in band['images']."""
    outdir.mkdir(exist_ok=True)
    for k, band in enumerate(reg["bands"]):
        if only is not None and k not in only:
            continue
        for old in outdir.glob(f"band{k}_*.jpg"):
            old.unlink()
        times = band.get("previews")
        if not times:
            segs = [s for s in reg["segments"] if s["band"] == k]
            s0, s1 = segs[0]["start"], segs[-1]["end"]
            times = band["previews"] = [round(s0 + (s1 - s0) * q / 4, 2) for q in (1, 2, 3)]
        band["images"] = []
        for i, t in enumerate(times):
            frame = frame_at(video, t)
            if frame is None:
                continue
            H = frame.shape[0]
            cap = (f"Band {k + 1} of {len(reg['bands'])}  ({band['crop'][1] / H:.0%}-"
                   f"{(band['crop'][1] + band['crop'][3]) / H:.0%})   frame at {hms(t)}")
            name = f"band{k}_{i}.jpg"
            cv2.imwrite(str(outdir / name), draw(frame, band["crop"], band["zones"], cap), [cv2.IMWRITE_JPEG_QUALITY, 88])
            band["images"].append(name)


REVIEW_SYSTEM = "You check caption-band settings for a subtitle OCR tool. You reply with JSON only."

REVIEW_PROMPT = """A tool reads burned-in Chinese dialogue captions from a video with OCR. It only reads the area
inside a horizontal band. Some videos move their captions for a while (e.g. above a quiz card that covers
the usual spot), so there can be more than one band, each used for some stretches of the video.
Before the (slow) OCR runs, check that each band is right.

In every image the green rectangle is the band, red rectangles are ignored zones (watermarks), and the
ruler on the left edge gives the height as % of the frame (0% top, 100% bottom). The text at the top of
each image names the band.

Dialogue captions are the subtitles of what people say: usually white or yellow text with an outline,
roughly centred, often with a small speaker-name tag on the left. They are NOT logos, show titles,
scene titles, quiz/question cards, answer options, name tags on clothes, or signs in the scene.

A band is right when dialogue captions sit fully inside it, and as little other text as possible does.
A frame with no caption on screen tells you nothing; judge from the frames that have one.

Bands, the stretches of the video they are used for, and their images (Read every image file):
{bands}

Reply with JSON only, one entry per band:
{{"bands": [{{"id": 1, "ok": true, "note": "short reason"}},
            {{"id": 2, "ok": false, "top": 0.66, "bottom": 0.76, "note": "captions sit above the quiz card"}}]}}
When a band is wrong, give "top" and "bottom" as fractions of the frame height that tightly enclose the
dialogue captions with a small margin. If no image of a band shows a dialogue caption, say ok and say so.
Keep each note to one short sentence.
"""


def review(video: Path, reg: dict, outdir: Path, width: int, height: int, model: str) -> dict:
    """Have Claude look at the preview frames and fix bands that miss the captions.

    Notes go in band['review']; a moved band gets new preview frames.
    """
    listing = "\n".join(
        f"- Band {k + 1} ({b['crop'][1] / height:.3f}-{(b['crop'][1] + b['crop'][3]) / height:.3f}), used for "
        + ", ".join(stretches(reg, k)[:12]) + ": " + ", ".join(b.get("images", []))
        for k, b in enumerate(reg["bands"]))
    r = subprocess.run(
        ["claude", "-p", "--model", model, "--tools", "Read", "--allowedTools", "Read", "--strict-mcp-config",
         "--no-session-persistence", "--system-prompt", REVIEW_SYSTEM],
        input=REVIEW_PROMPT.format(bands=listing), capture_output=True, text=True, cwd=outdir, timeout=900,
    )
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip() or "claude failed")
    m = re.search(r"\{.*\}", r.stdout, re.S)
    if not m:
        raise RuntimeError(f"no JSON in reply: {r.stdout.strip()[:200]}")
    verdicts = {v.get("id"): v for v in json.loads(m.group(0)).get("bands", [])}
    changed = set()
    for k, band in enumerate(reg["bands"]):
        v = verdicts.get(k + 1)
        if not v:
            continue
        note = str(v.get("note", ""))
        top, bot = v.get("top"), v.get("bottom")
        if not v.get("ok", True) and isinstance(top, (int, float)) and isinstance(bot, (int, float)) \
                and 0 <= top < bot <= 1 and bot - top >= 0.04:
            band["detected"] = band["crop"]
            band["crop"] = crop_for(top, bot, width, height)
            band["zones"] = zones_for(reg.get("watermarks", []), band["crop"], height)
            band["review"] = {"ok": False, "fixed": True, "note": note}
            changed.add(k)
        else:
            band["review"] = {"ok": bool(v.get("ok", True)), "fixed": False, "note": note}
    sync(reg)
    if changed:
        render_previews(video, reg, outdir, only=changed)
    return reg

"""Find the caption band automatically and the watermark zones inside it."""
from pathlib import Path

import cv2
import numpy as np

from . import events
from .ocr import Box, plausible, vision_ocr


def sample_frames(video: Path, n: int, start: float, end: float):
    cap = cv2.VideoCapture(str(video))
    for i in range(n):
        t = start + (end - start) * (i + 0.5) / n
        cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000)
        ok, frame = cap.read()
        if ok:
            yield t, frame
    cap.release()


def detect(video: Path, width: int, height: int, start: float, end: float, n: int = 120) -> dict:
    """Sample frames, OCR them whole, and decide where captions live.

    Text that shows the same thing at the same place in many samples is a
    logo/watermark/ad and becomes an exclusion zone. The band where the
    remaining (changing) text clusters is the caption band.
    """
    samples: list[list[Box]] = []
    for i, (_t, frame) in enumerate(sample_frames(video, n, start, end)):
        boxes = []
        for b in vision_ocr(frame):
            t = plausible(b.text)
            if t:
                b.text = t
                boxes.append(b)
        samples.append(boxes)
        events.progress("region", i + 1, n, f"Finding caption area… {i + 1}/{n}")
    print()

    def near(a: Box, b: Box):
        return a.text == b.text and abs(a.cx - b.cx) < 0.03 and abs(a.cy - b.cy) < 0.03

    static, moving = [], []
    for si, boxes in enumerate(samples):
        for b in boxes:
            hits = sum(any(near(b, o) for o in other) for oj, other in enumerate(samples) if oj != si)
            (static if hits >= 0.2 * len(samples) else moving).append(b)

    if not moving:
        raise SystemExit("No changing text found. Pass --region x,y,w,h manually (see --preview).")

    # Histogram of vertical centres of changing text; the peak is the caption band.
    bins = 40
    hist = np.zeros(bins)
    for b in moving:
        hist[min(int(b.cy * bins), bins - 1)] += 1
    peak = int(hist.argmax())
    lo = hi = peak
    while lo > 0 and hist[lo - 1] >= 0.15 * hist[peak]:
        lo -= 1
    while hi < bins - 1 and hist[hi + 1] >= 0.15 * hist[peak]:
        hi += 1
    in_band = [b for b in moving if lo <= int(b.cy * bins) <= hi]
    top = max(0.0, min(b.y for b in in_band) - 0.015)
    bot = min(1.0, max(b.y + b.h for b in in_band) + 0.015)

    by, bh = int(top * height), int((bot - top) * height)
    bh -= bh % 2
    crop = [0, by, width - width % 2, bh]

    # Watermark rectangles that overlap the band, in band-relative coords.
    zones = []
    for b in static:
        if b.y + b.h < top or b.y > bot:
            continue
        zx, zw = b.x - 0.01, b.w + 0.02
        zy = (b.y * height - by) / bh - 0.05
        zh = b.h * height / bh + 0.1
        z = [round(v, 4) for v in (zx, zy, zw, zh)]
        if not any(abs(z[0] - o[0]) < 0.02 and abs(z[1] - o[1]) < 0.05 for o in zones):
            zones.append(z)

    return {
        "crop": crop,
        "zones": zones,
        "static_text": sorted({b.text for b in static}),
        "band_frac": [round(top, 3), round(bot, 3)],
    }


def preview(video: Path, region: dict, out: Path, start: float, end: float):
    """Save a frame with the caption band (green) and excluded zones (red) drawn on it."""
    x, y, w, h = region["crop"]
    frames = [f for _t, f in sample_frames(video, 4, start, end)]
    tiles = []
    for f in frames:
        f = f.copy()
        cv2.rectangle(f, (x, y), (x + w - 1, y + h - 1), (0, 255, 0), 3)
        for zx, zy, zw, zh in region["zones"]:
            p1 = (int(x + zx * w), int(y + zy * h))
            p2 = (int(x + (zx + zw) * w), int(y + (zy + zh) * h))
            cv2.rectangle(f, p1, p2, (0, 0, 255), 3)
        tiles.append(cv2.resize(f, (f.shape[1] // 2, f.shape[0] // 2)))
    while len(tiles) < 4:
        tiles.append(np.zeros_like(tiles[0]))
    grid = np.vstack([np.hstack(tiles[:2]), np.hstack(tiles[2:4])])
    cv2.imwrite(str(out), grid)

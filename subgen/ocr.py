"""Frame extraction, change detection and Apple Vision OCR of the caption band."""
import json
import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from . import events

CJK = re.compile(r"[㐀-鿿]")
# Characters we keep from OCR output; everything else is banner decoration noise.
KEEP = re.compile(r"[㐀-鿿A-Za-z0-9，。！？、…—～“”‘’：；,.!?~:;'\"%·\s-]")
DECOR_EDGES = "。.·•…,，、 \t"
EDGE = 0.82


@dataclass
class Box:
    text: str
    x: float  # left, 0..1 of the image OCR'd
    y: float  # top, 0..1
    w: float
    h: float

    @property
    def cx(self):
        return self.x + self.w / 2

    @property
    def cy(self):
        return self.y + self.h / 2


def vision_ocr(img_bgr: np.ndarray) -> list[Box]:
    from ocrmac import ocrmac

    pil = Image.fromarray(cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB))
    res = ocrmac.OCR(pil, language_preference=["zh-Hans", "zh-Hant", "en-US"],
                     recognition_level="accurate").recognize()
    # ocrmac boxes are (x, y, w, h) normalised with a bottom-left origin.
    return [Box(t, x, 1 - y - h, w, h) for t, _conf, (x, y, w, h) in res]


def clean(text: str) -> str:
    kept = "".join(KEEP.findall(text))
    kept = re.sub(r"(?<=[\u3400-\u9fff])\s+(?=[\u3400-\u9fff])", "", kept)  # 李 沁 -> 李沁
    kept = re.sub(r"[。.“”\"]+\S{0,2}$", "", kept.strip())  # trailing decoration junk like "。没"
    return re.sub(r"\s+", " ", kept).strip(DECOR_EDGES)


def plausible(raw: str) -> str | None:
    """Return cleaned text if it looks like real caption text, else None."""
    t = clean(raw)
    if not CJK.search(t):
        return None
    if len(raw) and (len(raw) - len(t)) / len(raw) >= 0.4:  # mostly decoration symbols
        return None
    return t


def in_zone(b: Box, zones: list[list[float]]) -> bool:
    return any(zx <= b.cx <= zx + zw and zy <= b.cy <= zy + zh for zx, zy, zw, zh in zones)


def read_band(img: np.ndarray, blacklist: list[str], zones: list[list[float]]) -> str:
    """OCR one caption-band image and return the caption text ('' if none).

    Speaker-name tags and caption text come back as separate boxes; they are
    joined left-to-right with ' | ' so the translator can tell them apart.
    """
    boxes = []
    for b in vision_ocr(img):
        t = plausible(b.text)
        # Captions are centred; logos and sponsor badges sit at the far edges.
        if not t or in_zone(b, zones) or b.cx > EDGE or b.cx < 1 - EDGE:
            continue
        low = t.lower()
        if any(k in low for k in blacklist):
            continue
        b.text = t
        boxes.append(b)
    if not boxes:
        return ""
    # Decorative glyphs on the banner read as small text; real captions are the tallest.
    hmax = max(b.h for b in boxes)
    boxes = [b for b in boxes if b.h >= 0.6 * hmax]
    # Group into lines by vertical centre, then left-to-right.
    boxes.sort(key=lambda b: b.cy)
    lines: list[list[Box]] = []
    for b in boxes:
        if lines and abs(lines[-1][0].cy - b.cy) < 0.5 * hmax:
            lines[-1].append(b)
        else:
            lines.append([b])
    return " / ".join(" | ".join(b.text for b in sorted(ln, key=lambda b: b.x)) for ln in lines)


def text_mask(img: np.ndarray) -> np.ndarray:
    """Bright, low-saturation pixels: the white caption glyphs and outlines."""
    small = cv2.resize(img, (img.shape[1] // 2, img.shape[0] // 2))
    hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
    return (hsv[..., 2] > 200) & (hsv[..., 1] < 60)


def changed(a: np.ndarray | None, b: np.ndarray, thresh: float) -> bool:
    if a is None:
        return True
    union = np.count_nonzero(a | b)
    if union < 30:  # both (nearly) empty
        return False
    return np.count_nonzero(a ^ b) / union > thresh


def iter_frames(video: Path, fps: float, crop: tuple[int, int, int, int], start: float = 0, duration: float | None = None):
    """Yield (timestamp, BGR image) of the cropped band at `fps`, decoded by ffmpeg."""
    x, y, w, h = crop
    cmd = ["ffmpeg", "-v", "error"]
    if start:
        cmd += ["-ss", str(start)]
    cmd += ["-i", str(video)]
    if duration:
        cmd += ["-t", str(duration)]
    cmd += ["-vf", f"fps={fps},crop={w}:{h}:{x}:{y}", "-f", "rawvideo", "-pix_fmt", "bgr24", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    size = w * h * 3
    i = 0
    try:
        while True:
            buf = proc.stdout.read(size)
            if len(buf) < size:
                break
            yield start + i / fps, np.frombuffer(buf, np.uint8).reshape(h, w, 3)
            i += 1
    finally:
        proc.stdout.close()
        proc.wait()


def ocr_video(video: Path, out: Path, fps: float, segments: list[dict], blacklist, change_thresh: float,
              total: float, start: float = 0, duration: float | None = None, params: dict | None = None):
    """OCR every sampled frame of the band; writes JSONL of {t, text}.

    `segments` are time ranges, each with its own band (`crop`) and excluded `zones`.
    `params` identify the run: if an interrupted run with the same params left a partial
    `out`, it continues after its last frame instead of starting over.
    """
    running = out.with_name("ocr_running.json")
    prev_mask, prev_text = None, ""
    n = n_ocr = 0
    t0 = time.time()
    span = duration or (total - start)
    begin, mode = start, "w"
    if params is not None and out.exists() and running.exists() and json.loads(running.read_text()) == params:
        rows = []
        for line in out.read_text().splitlines():
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:  # half-written last line
                break
        if rows:
            out.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
            begin, prev_text, n, mode = rows[-1]["t"] + 1 / fps, rows[-1]["text"], len(rows), "a"
            print(f"  Resuming OCR at {begin / 60:.1f} min")
    if params is not None:
        running.write_text(json.dumps(params))
    stop = start + duration if duration else total
    last_t = begin - 1e-6

    def frames():
        # Each segment from the first frame on the fps grid at or after its start; a new band
        # has a different size, so change detection starts over. A segment with a fallback band
        # decodes the area covering both and reads the fallback only when its own band is empty.
        nonlocal prev_mask
        for seg in segments:
            s, e = max(seg["start"], begin), min(seg["end"], stop)
            s = start + np.ceil((s - start) * fps - 1e-6) / fps
            if s >= e:
                continue
            bands = [(seg["crop"], seg["zones"])]
            if seg.get("fallback"):
                bands.append((seg["fallback"]["crop"], seg["fallback"]["zones"]))
            top = min(c[1] for c, _ in bands)
            bot = max(c[1] + c[3] for c, _ in bands)
            x, _, w, _ = seg["crop"]
            area = [x, top, w, bot - top - (bot - top) % 2]
            parts = [(c[1] - top, c[3], z) for c, z in bands]
            prev_mask = None
            for t, img in iter_frames(video, fps, area, s, e - s + 1 / fps):
                if t >= e:
                    break
                yield t, img, parts

    with out.open(mode) as f:
        for t, img, parts in frames():
            if t <= last_t:
                continue
            last_t = t
            mask = text_mask(img)
            if changed(prev_mask, mask, change_thresh):
                for y0, h0, zones in parts:
                    prev_text = read_band(img[y0:y0 + h0], blacklist, zones)
                    if prev_text:
                        break
                prev_mask = mask
                n_ocr += 1
            f.write(json.dumps({"t": round(t, 3), "text": prev_text}, ensure_ascii=False) + "\n")
            n += 1
            if n % 20 == 0:
                f.flush()
                events.progress("ocr", t - start, span,
                                f"OCR {(t - start) / span:5.1%}  ({n_ocr} frames read this run)")
    if n == 0:
        out.unlink()
        raise SystemExit("ffmpeg returned no frames; check the video file and the --region values.")
    print(f"\r  OCR done: {n} frames, {n_ocr} OCR'd in {(time.time()-t0)/60:.1f} min" + " " * 20)

"""Score speech-recognition cues against an OCR Chinese .srt of the same video."""
import argparse
import re
import statistics
from pathlib import Path

import srt
from rapidfuzz import fuzz
from rapidfuzz.distance import Levenshtein

from . import asr, fetch
from .cues import body

ROOT = Path(__file__).resolve().parent.parent
NOT_HANZI = re.compile(r"[^㐀-鿿]")


def norm(text: str) -> str:
    """Hanzi only, Simplified, no speaker tag: what both sides should agree on."""
    return NOT_HANZI.sub("", asr.simplified(body(text.replace("\n", " / "))))


def cer(ref: str, hyp: str) -> float:
    return Levenshtein.distance(ref, hyp) / max(len(ref), 1)


def load_ref(path: Path, start: float, end: float) -> list[dict]:
    out = []
    for s in srt.parse(path.read_text(encoding="utf-8")):
        t0, t1 = s.start.total_seconds(), s.end.total_seconds()
        if start <= t0 < end:
            out.append({"start": t0, "end": t1, "zh": s.content})
    return out


def in_window(cues, lo, hi):
    return "".join(norm(c["zh"]) for c in cues if lo <= c["start"] < hi)


def timing(ref: list[dict], hyp: list[dict]) -> tuple[float, float | None]:
    """Share of OCR cues with a matching ASR cue within ±5 s, and median |start diff| of matches."""
    diffs, matched = [], 0
    for r in ref:
        rt = norm(r["zh"])
        if len(rt) < 2:
            continue
        best = max(((fuzz.partial_ratio(rt, norm(h["zh"])), h) for h in hyp
                    if abs(h["start"] - r["start"]) <= 5), key=lambda x: x[0], default=(0, None))
        if best[0] >= 60:
            matched += 1
            diffs.append(abs(best[1]["start"] - r["start"]))
    n = sum(1 for r in ref if len(norm(r["zh"])) >= 2)
    return matched / max(n, 1), statistics.median(diffs) if diffs else None


def main():
    ap = argparse.ArgumentParser(prog="subgen-compare", description=__doc__)
    ap.add_argument("src", help="YouTube URL or local video file")
    ap.add_argument("--ref", type=Path, required=True, help="OCR Chinese .srt of the same video")
    ap.add_argument("--start", type=float, default=0)
    ap.add_argument("--duration", type=float)
    ap.add_argument("--engines", default=",".join(asr.ENGINES), help="comma-separated (default: all)")
    ap.add_argument("--window", type=float, default=60, help="seconds per CER window (default 60)")
    ap.add_argument("--redo", action="store_true", help="re-run speech recognition")
    a = ap.parse_args()

    slug = fetch.slug_for(a.src)
    if a.start or a.duration:
        slug += f"_{int(a.start)}_{int(a.duration or 0)}"
    work = ROOT / "work" / slug
    work.mkdir(parents=True, exist_ok=True)
    video, title = fetch.fetch(a.src, ROOT / "work" / fetch.slug_for(a.src))
    _W, _H, total = fetch.probe(video)
    end = min(total, a.start + a.duration) if a.duration else total

    ref = load_ref(a.ref, a.start, end)
    if not ref:
        raise SystemExit(f"No reference captions between {a.start}s and {end}s in {a.ref}")
    engines = [e.strip() for e in a.engines.split(",")]
    hyps, infos = {}, {}
    for e in engines:
        hyps[e], infos[e] = asr.transcribe(video, work, e, a.start, a.duration, a.redo)

    ref_text = in_window(ref, a.start, end)
    rows = []
    for e in engines:
        hyp = hyps[e]
        match, med = timing(ref, hyp)
        info = infos[e]
        rows.append([e, f"{cer(ref_text, in_window(hyp, a.start, end)):.1%}", f"{match:.0%}",
                     f"{med:.2f}s" if med is not None else "-", str(len(hyp)),
                     f"{info['seconds']:.0f}s", f"{info['audio_seconds'] / max(info['seconds'], 0.1):.1f}x"])

    head = ["engine", "CER vs OCR", "OCR lines matched", "median start diff", "lines", "ASR time", "speed (x real time)"]
    md = [f"# ASR vs OCR: {title or video.name}", "",
          f"Range {a.start:.0f}s – {end:.0f}s ({(end - a.start) / 60:.1f} min), {len(ref)} OCR captions, "
          f"{len(ref_text)} reference characters.", "",
          "| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    md += ["| " + " | ".join(r) + " |" for r in rows]
    md += ["", "OCR captions are edited by the show (filler words dropped, some on-screen text that isn't "
           "speech), so CER overstates the real recognition error somewhat.", "",
           f"## CER per {a.window:.0f} s", "", "| from | ref chars | " + " | ".join(engines) + " |",
           "|" + "---|" * (len(engines) + 2)]
    t = a.start
    while t < end:
        r = in_window(ref, t, t + a.window)
        cells = [f"{cer(r, in_window(hyps[e], t, t + a.window)):.0%}" if r else "-" for e in engines]
        md.append(f"| {int(t // 60)}:{int(t % 60):02d} | {len(r)} | " + " | ".join(cells) + " |")
        t += a.window

    md += ["", "## Samples", "", "| time | OCR | " + " | ".join(engines) + " |", "|" + "---|" * (len(engines) + 2)]
    step = max(1, len(ref) // 20)
    for r in ref[::step][:20]:
        cells = []
        for e in engines:
            near = [h["zh"] for h in hyps[e] if r["start"] - 1.5 <= h["start"] <= r["end"] + 0.5]
            cells.append(" ".join(near) or "·")
        tt = r["start"]
        md.append(f"| {int(tt // 60)}:{int(tt % 60):02d} | {r['zh'].replace(chr(10), ' / ').replace(' | ', '：')} | "
                  + " | ".join(c.replace("|", "/") for c in cells) + " |")

    report = work / "compare.md"
    report.write_text("\n".join(md) + "\n", encoding="utf-8")
    widths = [max(len(h), *(len(r[i]) for r in rows)) for i, h in enumerate(head)]
    print()
    print("  ".join(h.ljust(w) for h, w in zip(head, widths)))
    for r in rows:
        print("  ".join(c.ljust(w) for c, w in zip(r, widths)))
    print(f"\nReport → {report}")


if __name__ == "__main__":
    main()

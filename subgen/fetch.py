"""Get the video: download from YouTube with yt-dlp, or use a local file."""
import json
import re
import shutil
import subprocess
from pathlib import Path

from . import events


def is_url(src: str) -> bool:
    return src.startswith(("http://", "https://"))


def slug_for(src: str) -> str:
    if is_url(src):
        m = re.search(r"(?:v=|youtu\.be/|shorts/)([\w-]{6,})", src)
        return m.group(1) if m else re.sub(r"\W+", "_", src)[-40:]
    return re.sub(r"[^\w.-]+", "_", Path(src).stem)


def _js_runtimes() -> dict:
    """JS runtimes yt-dlp may use to solve YouTube's player challenges.

    Without one, yt-dlp falls back to clients whose stream URLs often 403.
    The Mac app runs us with a bare PATH, so also look in common install spots.
    """
    home = Path.home()
    known = {
        "deno": [home / ".deno/bin/deno"],
        "bun": [home / ".bun/bin/bun"],
        "node": [home / ".local/share/fnm/aliases/default/bin/node", home / ".volta/bin/node"],
    }
    found = {}
    for name, extra in known.items():
        path = shutil.which(name) or next((str(c) for c in extra if c.exists()), None)
        if path:
            found[name] = {"path": path}
    return found


def fetch(src: str, workdir: Path) -> tuple[Path, str]:
    """Return (video path, human title)."""
    if not is_url(src):
        p = Path(src).expanduser().resolve()
        if not p.exists():
            raise SystemExit(f"File not found: {p}")
        return p, p.stem

    video = workdir / "video.mp4"
    meta = workdir / "meta.json"
    import yt_dlp

    if video.exists() and meta.exists():
        m = json.loads(meta.read_text())
        if "description" not in m:  # cached before descriptions were kept
            with yt_dlp.YoutubeDL({"quiet": True, "noplaylist": True, "js_runtimes": _js_runtimes()}) as ydl:
                m["description"] = ydl.extract_info(src, download=False).get("description", "")
            meta.write_text(json.dumps(m, ensure_ascii=False))
        return video, m["title"]

    opts = {
        "noplaylist": True,
        "format": "bv*[height<=720][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=720]+ba/b[height<=720]/b",
        "merge_output_format": "mp4",
        "outtmpl": str(workdir / "video.%(ext)s"),
        "quiet": True,
        "noprogress": True,
        "progress_hooks": [_download_progress],
        "js_runtimes": _js_runtimes(),
        "retries": 10,
        "fragment_retries": 10,
    }
    print("Downloading video (720p)…")
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(src, download=True)
    meta.write_text(json.dumps({"title": info.get("title", ""), "id": info.get("id"),
                                "description": info.get("description", "")}, ensure_ascii=False))
    return video, info.get("title", "")


def _download_progress(d: dict):
    if d.get("status") == "downloading":
        total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
        got = d.get("downloaded_bytes", 0)
        events.progress("download", got, total, f"Downloading… {got / 1e6:.0f}/{total / 1e6:.0f} MB")


def description(src: str, workdir: Path) -> str:
    """The YouTube description saved by fetch() ('' for local files)."""
    meta = workdir / "meta.json"
    return json.loads(meta.read_text()).get("description", "") if is_url(src) and meta.exists() else ""


def probe(video: Path) -> tuple[int, int, float]:
    """Return (width, height, duration seconds)."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height:format=duration", "-of", "json", str(video)],
        capture_output=True, text=True, check=True,
    ).stdout
    d = json.loads(out)
    s = d["streams"][0]
    return int(s["width"]), int(s["height"]), float(d["format"]["duration"])

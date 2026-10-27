"""Get the video: download from YouTube with yt-dlp, or use a local file."""
import json
import re
import subprocess
from pathlib import Path


def is_url(src: str) -> bool:
    return src.startswith(("http://", "https://"))


def slug_for(src: str) -> str:
    if is_url(src):
        m = re.search(r"(?:v=|youtu\.be/|shorts/)([\w-]{6,})", src)
        return m.group(1) if m else re.sub(r"\W+", "_", src)[-40:]
    return re.sub(r"[^\w.-]+", "_", Path(src).stem)


def fetch(src: str, workdir: Path) -> tuple[Path, str]:
    """Return (video path, human title)."""
    if not is_url(src):
        p = Path(src).expanduser().resolve()
        if not p.exists():
            raise SystemExit(f"File not found: {p}")
        return p, p.stem

    video = workdir / "video.mp4"
    meta = workdir / "meta.json"
    if video.exists() and meta.exists():
        return video, json.loads(meta.read_text())["title"]

    import yt_dlp

    opts = {
        "noplaylist": True,
        "format": "bv*[height<=720][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=720]+ba/b[height<=720]/b",
        "merge_output_format": "mp4",
        "outtmpl": str(workdir / "video.%(ext)s"),
        "quiet": True,
        "noprogress": True,
    }
    print("Downloading video (720p)…")
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(src, download=True)
    meta.write_text(json.dumps({"title": info.get("title", ""), "id": info.get("id")}, ensure_ascii=False))
    return video, info.get("title", "")


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

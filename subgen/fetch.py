"""Get the video: download from YouTube with yt-dlp, or use a local file."""
import json
import re
import shutil
import subprocess
import threading
import time
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


HD_NAME = "video.1080.mp4"
HD_MAX_DRIFT = 1.0  # seconds the 1080p and 720p copies may differ before subtitles could drift


def start_hd(src: str, workdir: Path, video: Path) -> threading.Thread | None:
    """Fetch a 1080p copy of a YouTube video for watching, in the background.

    Processing stays on the 720p file; this one is only played. Uses `workdir/video.1080.mp4` from an
    earlier run, and remembers in hd.json when a video has no usable 1080p. Never fails the job.
    """
    if not is_url(src):
        return None
    hd = workdir / HD_NAME
    state = workdir / "hd.json"
    if hd.exists():
        events.cached("hd")
        events.emit("hd", path=str(hd.resolve()))
        return None
    if state.exists():
        events.skipped("hd", json.loads(state.read_text()).get("reason", "No 1080p copy"))
        return None
    t = threading.Thread(target=_fetch_hd, args=(src, workdir, video), name="hd", daemon=True)
    t.start()
    return t


def _fetch_hd(src: str, workdir: Path, video: Path):
    t0 = time.time()
    events.emit("stage", stage="hd", status="start")
    try:
        reason = _download_hd(src, workdir, video)
    except Exception as e:  # the subtitles don't depend on it, so just report it
        events.warn(f"HD copy failed, the viewer will play 720p: {e}")
        events.skipped("hd", "Download failed")
        return
    if reason:
        (workdir / "hd.json").write_text(json.dumps({"reason": reason}))
        print(f"\n  HD copy: {reason}; the viewer will play 720p.")
        events.skipped("hd", reason)
        return
    hd = workdir / HD_NAME
    print(f"\n  HD copy ready: {hd}")
    events.emit("stage", stage="hd", status="done", seconds=round(time.time() - t0, 1))
    events.emit("hd", path=str(hd.resolve()))


def _download_hd(src: str, workdir: Path, video: Path) -> str | None:
    """Download the 1080p video stream and give it the 720p file's audio. Returns why not, or None."""
    import yt_dlp
    from yt_dlp.utils import DownloadError

    for old in workdir.glob("video.1080.v.*"):  # a finished stream from an interrupted run
        if not old.name.endswith((".part", ".ytdl")):
            old.unlink()
    opts = {
        "noplaylist": True,
        # H.264 only: above 720p YouTube's other codecs are VP9/AV1, which AVPlayer doesn't play reliably.
        "format": "bv*[height>720][height<=1080][vcodec^=avc1]",
        "outtmpl": str(workdir / "video.1080.v.%(ext)s"),
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "progress_hooks": [_hd_progress],
        "js_runtimes": _js_runtimes(),
        "retries": 10,
        "fragment_retries": 10,
    }
    print("\n  Downloading HD copy (1080p) in the background…")
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(src, download=True)
    except DownloadError as e:
        if "format is not available" in str(e):
            return "No 1080p H.264 copy on YouTube"
        raise
    stream = Path(info["requested_downloads"][0]["filepath"])

    hd_dur, sd_dur = probe(stream)[2], probe(video)[2]
    if abs(hd_dur - sd_dur) > HD_MAX_DRIFT:
        stream.unlink(missing_ok=True)
        return f"1080p and 720p lengths differ ({hd_dur:.1f}s vs {sd_dur:.1f}s)"

    tmp = workdir / "video.1080.tmp.mp4"
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", str(stream), "-i", str(video),
         "-map", "0:v:0", "-map", "1:a:0?", "-c", "copy", "-movflags", "+faststart", str(tmp)],
        check=True, capture_output=True,
    )
    tmp.replace(workdir / HD_NAME)  # only a complete file ever gets the real name
    stream.unlink(missing_ok=True)
    return None


def _hd_progress(d: dict):
    if d.get("status") == "downloading":
        total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
        got = d.get("downloaded_bytes", 0)
        events.progress("hd", got, total, f"Downloading 1080p… {got / 1e6:.0f}/{total / 1e6:.0f} MB", echo=False)


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

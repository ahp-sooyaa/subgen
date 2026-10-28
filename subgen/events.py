"""Machine-readable progress for the Mac app: JSON lines appended to a file.

Off unless init() is called (the CLI's --events flag), so terminal use only sees the usual
human-readable lines.
"""
import json
import sys
import time
from contextlib import contextmanager

_file = None
_base: dict[str, tuple[float, float]] = {}  # stage -> (time, frac) of its first progress report
_last: dict[str, float] = {}


def init(path: str):
    global _file
    _file = open(path, "a", encoding="utf-8")


def emit(kind: str, /, **fields):
    if _file:
        _file.write(json.dumps({"ts": round(time.time(), 3), "type": kind, **fields},
                               ensure_ascii=False, default=str) + "\n")
        _file.flush()


@contextmanager
def stage(name: str):
    """Mark a pipeline step: emits stage start, and stage done with its duration."""
    t0 = time.time()
    emit("stage", stage=name, status="start")
    yield
    emit("stage", stage=name, status="done", seconds=round(time.time() - t0, 1))


def cached(name: str):
    """A stage whose result came from the cache: report it as done right away."""
    emit("stage", stage=name, status="done", seconds=0, cached=True)


def progress(stage_name: str, done: float, total: float, text: str):
    """Print `text` as the usual \\r status line and emit a throttled progress event with an ETA."""
    sys.stdout.write(f"\r  {text} ")
    sys.stdout.flush()
    frac = min(1.0, done / total) if total else 0.0
    now = time.time()
    t0, f0 = _base.setdefault(stage_name, (now, frac))
    if frac < 1 and now - _last.get(stage_name, 0) < 0.5:
        return
    _last[stage_name] = now
    # ETA from this run's own speed, so a resumed stage doesn't count work done earlier.
    eta = (now - t0) / (frac - f0) * (1 - frac) if frac > f0 else None
    emit("progress", stage=stage_name, frac=round(frac, 4),
         eta=round(eta) if eta is not None else None, text=text)


def warn(message: str):
    print(f"\n  warning: {message}", file=sys.stderr)
    emit("warning", message=message)

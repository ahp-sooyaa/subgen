"""Mandarin speech recognition: audio → timed Chinese cues (same shape as cues.build())."""
import json
import re
import subprocess
import time
from pathlib import Path

from . import events

ENGINES = ("sensevoice", "whisper")
MERGE = "merge"  # whisper timing + sensevoice as a second opinion, reconciled by the translator
WHISPER_REPO = "mlx-community/whisper-large-v3-turbo"
RATE = 16000
CHUNK = 300  # seconds of audio per resumable piece
MAX_CHARS = 20
# Whisper's favourite hallucinations on music/silence (subtitle credits, "subscribe", etc.).
JUNK = re.compile(r"字幕|订阅|点赞|转发|打赏|明镜|栏目|谢谢观看|感谢观看|请不吝")
SPLIT = re.compile(r"(?<=[，。！？；、,.!?;])")
TRIM = "，。、；,.;： "
# SenseVoice language/emotion/event tags, raw (<|zh|>) or already turned into emoji.
TAGS = re.compile(r"<\|[^|]*\|>|[\U0001F000-\U0001FFFF\u2600-\u27BF\uFE0F]")

_t2s = None


def simplified(text: str) -> str:
    global _t2s
    if _t2s is None:
        import opencc
        _t2s = opencc.OpenCC("t2s")
    return _t2s.convert(text)


def extract_audio(video: Path, out: Path, start: float = 0, duration: float | None = None):
    tmp = out.with_suffix(".part.wav")  # renamed when complete, so a killed run never leaves half a file
    cmd = ["ffmpeg", "-v", "error", "-y"]
    if start:
        cmd += ["-ss", str(start)]
    cmd += ["-i", str(video)]
    if duration:
        cmd += ["-t", str(duration)]
    cmd += ["-vn", "-ac", "1", "-ar", str(RATE), str(tmp)]
    subprocess.run(cmd, check=True)
    tmp.rename(out)


def hint_words(glossary: str) -> list[str]:
    """Chinese names and places from glossary lines like `李沁 = Li Qin (she)`."""
    return [l.split("=")[0].strip() for l in glossary.splitlines() if "=" in l]


_models = {}


def model(name: str):
    """A FunASR model, loaded once per run."""
    if name not in _models:
        from funasr import AutoModel
        kw = {"max_single_segment_time": 15000} if name == "fsmn-vad" else {}
        _models[name] = AutoModel(model=name, disable_update=True, disable_pbar=True, **kw)
    return _models[name]


def speech_spans(wav: Path, work: Path) -> list[list[float]]:
    """Speech segments as [start, end] seconds, found by fsmn-vad (cached in vad.json)."""
    cache = work / "vad.json"
    if cache.exists():
        return json.loads(cache.read_text())
    spans = [[s / 1000, e / 1000] for s, e in model("fsmn-vad").generate(input=str(wav))[0]["value"]]
    cache.write_text(json.dumps(spans))
    return spans


def chunks(spans: list[list[float]], total: float) -> list[tuple[float, float]]:
    """Split 0..total into pieces of about CHUNK seconds, cut in the silence nearest each mark."""
    gaps = [(x[1] + y[0]) / 2 for x, y in zip(spans, spans[1:])]
    cuts = [0.0]
    k = 1
    while k * CHUNK < total - CHUNK / 2:
        cut = min(gaps, key=lambda g: abs(g - k * CHUNK), default=k * CHUNK)
        cuts.append(cut if abs(cut - k * CHUNK) < 60 and cut > cuts[-1] else k * CHUNK)
        k += 1
    return list(zip(cuts, cuts[1:] + [total]))


def sensevoice(audio, spans: list[list[float]], tick) -> list[dict]:
    """SenseVoiceSmall on each speech span (it takes no hint words)."""
    m = model("iic/SenseVoiceSmall")
    segs = []
    for s, e in spans:
        res = m.generate(input=audio[int(s * RATE):int(e * RATE)], language="zh", use_itn=True, batch_size_s=60)
        segs.append({"start": s, "end": e, "zh": res[0]["text"] if res else ""})
        tick(e)
    return segs


def whisper(audio, a: float, b: float, hints: list[str]) -> list[dict]:
    import mlx_whisper

    prompt = "以下是普通话综艺节目的对话。"
    if hints:  # names in the prompt bias Whisper towards spelling them right
        prompt += "人物和地点：" + "、".join(hints) + "。"
    res = mlx_whisper.transcribe(
        audio[int(a * RATE):int(b * RATE)], path_or_hf_repo=WHISPER_REPO, language="zh", task="transcribe",
        condition_on_previous_text=False, initial_prompt=prompt, verbose=None,
    )
    segs = []
    for s in res["segments"]:
        if s["no_speech_prob"] > 0.6 and s["avg_logprob"] < -1:
            continue
        if s["compression_ratio"] > 2.4:  # looping repetition
            continue
        segs.append({"start": s["start"] + a, "end": s["end"] + a, "zh": s["text"]})
    return segs


def transcribe(video: Path, work: Path, engine: str, start: float = 0, duration: float | None = None,
               redo: bool = False, hints: list[str] = ()) -> tuple[list[dict], dict]:
    """Return (cues, info). Raw segments and wall time are cached in work/asr_<engine>[_hints].json,
    built from per-chunk results in work/asr_<engine>[_hints]/ so an interrupted run can resume."""
    if engine == MERGE:
        return merge(video, work, start, duration, redo, hints)
    hints = list(hints) if engine == "whisper" else []
    cache = work / f"asr_{engine}{'_hints' if hints else ''}.json"
    data = json.loads(cache.read_text()) if cache.exists() and not redo else None
    if not data or data.get("hints", []) != hints:  # cached run used other hint words
        data = run_engine(video, work, engine, start, duration, redo, hints)
        cache.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    else:
        events.cached("audio")
        events.cached(engine)
    info = {k: v for k, v in data.items() if k != "segments"}
    print(f"  {engine}: {info['audio_seconds'] / 60:.1f} min of audio in {info['seconds'] / 60:.1f} min")
    return to_cues(data["segments"]), info


def run_engine(video, work, engine, start, duration, redo, hints) -> dict:
    import soundfile as sf

    wav = work / "audio.wav"
    if not wav.exists():
        with events.stage("audio"):
            extract_audio(video, wav, start, duration)
    cdir = work / f"asr_{engine}{'_hints' if hints else ''}"
    cdir.mkdir(exist_ok=True)
    if redo:
        (work / "vad.json").unlink(missing_ok=True)
        for f in cdir.glob("*.json"):
            f.unlink()
    print(f"  Speech recognition ({engine})…")
    audio, _sr = sf.read(str(wav), dtype="float32")
    total = len(audio) / RATE
    label = {"whisper": "Whisper", "sensevoice": "SenseVoice"}[engine]

    def tick(pos):
        events.progress(engine, pos, total, f"{label} {pos / 60:.1f}/{total / 60:.1f} min")

    segs, seconds = [], 0.0
    with events.stage(engine):
        spans = speech_spans(wav, work)
        for i, (a, b) in enumerate(chunks(spans, total)):
            f = cdir / f"{i:03d}.json"
            d = json.loads(f.read_text()) if f.exists() else None
            if not d or d["range"] != [a, b] or d["hints"] != hints:
                tick(a)
                t0 = time.time()
                inner = [sp for sp in spans if a <= sp[0] < b]
                if not inner:  # no speech: skip, Whisper would only hallucinate
                    got = []
                elif engine == "whisper":
                    got = whisper(audio, a, b, hints)
                else:
                    got = sensevoice(audio, inner, tick)
                d = {"range": [a, b], "hints": hints, "seconds": round(time.time() - t0, 1), "segments": got}
                f.write_text(json.dumps(d, ensure_ascii=False))
            segs += d["segments"]
            seconds += d["seconds"]
            tick(b)
    print()
    for s in segs:
        s["start"], s["end"] = round(s["start"] + start, 3), round(s["end"] + start, 3)
    return {"engine": engine, "seconds": round(seconds, 1), "audio_seconds": round(total, 1),
            "hints": hints, "segments": segs}


def merge(video, work, start, duration, redo, hints) -> tuple[list[dict], dict]:
    """Whisper cues, each carrying the SenseVoice text heard at the same time as `alt`."""
    cues, wi = transcribe(video, work, "whisper", start, duration, redo, hints)
    other, si = transcribe(video, work, "sensevoice", start, duration, redo, hints)
    for c in cues:
        c["alt"] = ""
    extra = []
    for o in other:
        # Share each SenseVoice line among the Whisper lines it overlaps, by time, so a long
        # line doesn't hand its neighbours' words to one Whisper line.
        span = o["end"] - o["start"]
        hits = [(c, min(c["end"], o["end"]) - max(c["start"], o["start"])) for c in cues]
        hits = sorted(((c, ov) for c, ov in hits if ov > 0), key=lambda h: h[0]["start"])
        if not hits:  # speech Whisper missed; keep it only if it's more than filler
            if len(o["zh"]) >= 5:
                extra.append({"start": o["start"], "end": o["end"], "zh": o["zh"], "alt": ""})
            continue
        i = 0
        for c, ov in hits:
            n = round(len(o["zh"]) * ov / span) if span > 0 else len(o["zh"])
            c["alt"] += o["zh"][i:i + n]
            i += n
        hits[-1][0]["alt"] += o["zh"][i:]
    cues = sorted(cues + extra, key=lambda c: c["start"])
    for i, c in enumerate(cues, 1):
        c["id"] = i
    info = {"engine": MERGE, "seconds": wi["seconds"] + si["seconds"], "audio_seconds": wi["audio_seconds"]}
    return cues, info


def to_cues(segs: list[dict]) -> list[dict]:
    """Simplify, drop junk/repeats, and split long segments into subtitle-sized lines."""
    cues: list[dict] = []
    for s in segs:
        text = simplified(TAGS.sub("", s["zh"])).strip()
        if not text or JUNK.search(text):
            continue
        if len(cues) >= 2 and cues[-1]["zh"] == cues[-2]["zh"] == text.strip(TRIM):
            continue
        # Group clauses into lines of at most MAX_CHARS; time is shared by character count.
        lines, cur = [], ""
        for part in filter(None, SPLIT.split(text)):
            if cur and len(cur) + len(part) > MAX_CHARS:
                lines.append(cur)
                cur = ""
            cur += part
        if cur:
            lines.append(cur)
        total = sum(len(l) for l in lines)
        t = s["start"]
        for l in lines:
            dt = (s["end"] - s["start"]) * len(l) / total
            l = l.strip(TRIM)
            if l:
                cues.append({"start": round(t, 3), "end": round(t + dt, 3), "zh": l})
            t += dt
    for i, c in enumerate(cues, 1):
        c["id"] = i
    return cues

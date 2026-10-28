"""Mandarin speech recognition: audio → timed Chinese cues (same shape as cues.build())."""
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ENGINES = ("sensevoice", "whisper")
WHISPER_REPO = "mlx-community/whisper-large-v3-turbo"
RATE = 16000
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
    cmd = ["ffmpeg", "-v", "error", "-y"]
    if start:
        cmd += ["-ss", str(start)]
    cmd += ["-i", str(video)]
    if duration:
        cmd += ["-t", str(duration)]
    cmd += ["-vn", "-ac", "1", "-ar", str(RATE), str(out)]
    subprocess.run(cmd, check=True)


def sensevoice(wav: Path) -> list[dict]:
    """fsmn-vad finds speech segments, SenseVoiceSmall transcribes each one."""
    import soundfile as sf
    from funasr import AutoModel

    audio, _sr = sf.read(str(wav), dtype="float32")
    vad = AutoModel(model="fsmn-vad", max_single_segment_time=15000, disable_update=True, disable_pbar=True)
    spans = vad.generate(input=str(wav))[0]["value"]  # [[start_ms, end_ms], ...]
    asr = AutoModel(model="iic/SenseVoiceSmall", disable_update=True, disable_pbar=True)
    segs = []
    for i, (s, e) in enumerate(spans):
        chunk = audio[int(s * RATE / 1000):int(e * RATE / 1000)]
        res = asr.generate(input=chunk, language="zh", use_itn=True, batch_size_s=60)
        text = res[0]["text"] if res else ""
        segs.append({"start": s / 1000, "end": e / 1000, "zh": text})
        sys.stdout.write(f"\r  SenseVoice {i + 1}/{len(spans)} segments")
        sys.stdout.flush()
    print()
    return segs


def whisper(wav: Path) -> list[dict]:
    import mlx_whisper

    res = mlx_whisper.transcribe(
        str(wav), path_or_hf_repo=WHISPER_REPO, language="zh", task="transcribe",
        condition_on_previous_text=False, initial_prompt="以下是普通话综艺节目的对话。",
        verbose=False,
    )
    segs = []
    for s in res["segments"]:
        if s["no_speech_prob"] > 0.6 and s["avg_logprob"] < -1:
            continue
        if s["compression_ratio"] > 2.4:  # looping repetition
            continue
        segs.append({"start": s["start"], "end": s["end"], "zh": s["text"]})
    return segs


def transcribe(video: Path, work: Path, engine: str, start: float = 0,
               duration: float | None = None, redo: bool = False) -> tuple[list[dict], dict]:
    """Return (cues, info). Raw segments and wall time are cached in work/asr_<engine>.json."""
    cache = work / f"asr_{engine}.json"
    if cache.exists() and not redo:
        data = json.loads(cache.read_text())
    else:
        wav = work / "audio.wav"
        if not wav.exists():
            extract_audio(video, wav, start, duration)
        print(f"  Speech recognition ({engine})…")
        t0 = time.time()
        segs = {"sensevoice": sensevoice, "whisper": whisper}[engine](wav)
        for s in segs:
            s["start"], s["end"] = round(s["start"] + start, 3), round(s["end"] + start, 3)
        import soundfile as sf
        data = {"engine": engine, "seconds": round(time.time() - t0, 1),
                "audio_seconds": round(sf.info(str(wav)).duration, 1), "segments": segs}
        cache.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    info = {k: v for k, v in data.items() if k != "segments"}
    print(f"  {engine}: {info['audio_seconds'] / 60:.1f} min of audio in {info['seconds'] / 60:.1f} min")
    return to_cues(data["segments"]), info


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

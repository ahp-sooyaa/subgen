"""Translate Chinese cues to English with Claude Code in headless mode (uses your subscription)."""
import json
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SYSTEM = "You are a professional Chinese-to-English subtitle translator. You output only the requested lines."

PROMPT = """You are subtitling a Chinese variety/reality show{title}.
{intro}
Translate each line into natural, concise spoken English suitable for subtitles. Keep the tone, jokes and slang.
Reply with exactly one line per ID, same order, and nothing else:
{reply}

Use [DROP] as the English subtitle for lines that are advertisements, sponsor slogans or voice-over product
pitches, platform promos (e.g. 芒果TV, 会员, 独播) or unreadable garbage.
{glossary}
{context}
Lines to translate:
{lines}
"""

OCR_REPLY = "ID<TAB>speaker name in English (pinyin, or the glossary name), or empty if no tag<TAB>English subtitle"
ASR_REPLY = "ID<TAB>corrected Chinese<TAB>English subtitle"
ASR_RULES = """- Lines are cut at pauses, so a sentence may run over several lines. Translate each line as its part of the sentence.
- Speech recognition often writes a wrong character that sounds the same or similar (e.g. 权利 for 权力, 公式 for 公事,
  信念 for 新年), misspells names, and garbles crosstalk. First work out what was actually said, using context,
  the glossary and the setting, and write it as the corrected Chinese (unchanged if it was already right).
  Then translate the corrected Chinese.
- 他 and 她 sound identical (tā), so the transcript cannot tell he from she. Decide from context who is meant,
  using the cast genders in the glossary.
- Answer every ID on its own line, even one-word lines.
"""

SOURCES = {
    "ocr": ("""Below are the on-screen Chinese captions, read by OCR, in order. Each line is `ID<TAB>caption`.
- A caption may begin with a speaker-name tag followed by " | " (e.g. `李沁 | 然后我就在`).
- " / " separates two lines of the same caption.
- OCR can contain small mistakes (wrong look-alike characters, stray symbols). Use context to infer what was meant.
""", OCR_REPLY),
    "asr": ("""Below is a speech-recognition transcript of the spoken Chinese, in order. Each line is `ID<TAB>text`.
""" + ASR_RULES, ASR_REPLY),
    "merge": ("""Below is the spoken Chinese, transcribed by two different speech-recognition engines, in order.
Each line is `ID<TAB>A<TAB>B`. A sets the line's timing. B is the second engine's hearing of about the same moment:
it may include words from neighbouring lines, or be empty. The engines make different mistakes, so where they
differ, pick what was most likely said. The corrected Chinese covers only this line's part of the speech (A's span).
""" + ASR_RULES, ASR_REPLY),
}

GLOSSARY_PROMPT = """Below is information about an episode of a Chinese variety/reality show and a rough
speech-recognition transcript of it (it mishears names). Make a name glossary for the subtitle translator:
the cast and other recurring people (with nicknames they are called by), the show, and the places visited.
- One entry per line: `Chinese = English`. For people add (he) or (she) only when you are sure (you know the
  person, or the transcript makes it clear); if unsure, leave it out, since a wrong gender is worse than none.
  For nicknames add a short note, e.g. `沁沁 = Qinqin (Li Qin's nickname)`.
- Proper names only (people, the show, places); no roles or common words.
- Use the official English name for well-known people, shows and places; otherwise pinyin.
- Write each name as it is really spelled, even if the transcript gets it wrong.
- Only include names you are fairly sure of. Output only the glossary lines.

Title: {title}

Description:
{description}

Transcript:
{text}
"""


def auto_glossary(cues: list[dict], title: str, description: str, cache: Path, model: str,
                  redo: bool = False) -> str:
    """Build a name glossary from the title, description and a first-pass transcript (cached)."""
    if cache.exists() and not redo:
        return cache.read_text()
    print("  Building name glossary from the title, description and transcript…")
    text = " ".join(c["zh"] + (" " + c["alt"] if c.get("alt") else "") for c in cues)[:40000]
    out = call_claude(GLOSSARY_PROMPT.format(title=title or "(unknown)", description=description[:3000] or "(none)",
                                             text=text), model)
    glossary = "\n".join(l.strip() for l in out.splitlines() if " = " in l) + "\n"
    cache.write_text(glossary)
    return glossary


def call_claude(prompt: str, model: str) -> str:
    with tempfile.TemporaryDirectory() as tmp:  # empty cwd: no project context gets loaded
        r = subprocess.run(
            ["claude", "-p", "--model", model, "--tools", "", "--strict-mcp-config",
             "--no-session-persistence", "--system-prompt", SYSTEM],
            input=prompt, capture_output=True, text=True, cwd=tmp, timeout=900,
        )
    if r.returncode != 0:
        raise RuntimeError(f"claude failed: {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout


def parse(out: str, ids: set[int]) -> dict[int, tuple[str, str]]:
    """ID, then the middle field, then the English. Extra echoed columns in between are ignored."""
    res = {}
    for line in out.splitlines():
        parts = line.strip().split("\t")
        if len(parts) >= 3 and parts[0].isdigit() and int(parts[0]) in ids:
            res[int(parts[0])] = (parts[-2].strip(), parts[-1].strip())
    return res


def translate_batch(batch: list[dict], context: list[dict], glossary: str, title: str,
                    model: str, cache: Path, source: str = "ocr") -> dict[int, tuple[str, str]]:
    if cache.exists():
        return {int(k): tuple(v) for k, v in json.loads(cache.read_text()).items()}
    ctx = ""
    if context:
        ctx = "Previous captions, for context only (do not translate):\n" + "\n".join(c["zh"] for c in context) + "\n"
    gl = f"Name glossary (Chinese = English):\n{glossary}\n" if glossary.strip() else ""
    want = {c["id"] for c in batch}
    got: dict[int, tuple[str, str]] = {}
    todo = batch
    for _attempt in range(3):
        prompt = PROMPT.format(
            title=f" ({title})" if title else "", intro=SOURCES[source][0], reply=SOURCES[source][1],
            glossary=gl, context=ctx,
            lines="\n".join(f"{c['id']}\t{c['zh']}" + (f"\t{c.get('alt', '')}" if source == "merge" else "")
                            for c in todo),
        )
        got.update(parse(call_claude(prompt, model), {c["id"] for c in todo}))
        todo = [c for c in batch if c["id"] not in got]
        if not todo:
            break
    missing = want - got.keys()
    if missing:
        print(f"\n  warning: {len(missing)} lines untranslated (ids {sorted(missing)[:10]}…)", file=sys.stderr)
    cache.write_text(json.dumps(got, ensure_ascii=False))
    return got


def translate(cues: list[dict], workdir: Path, glossary: str, title: str, model: str,
              batch_size: int = 80, workers: int = 3, source: str = "ocr",
              cache_name: str = "translate") -> list[dict]:
    if not shutil.which("claude"):
        raise SystemExit("`claude` CLI not found. Install Claude Code and log in with your subscription.")
    cache_dir = workdir / cache_name
    cache_dir.mkdir(exist_ok=True)
    batches = [cues[i:i + batch_size] for i in range(0, len(cues), batch_size)]
    jobs = []
    with ThreadPoolExecutor(workers) as ex:
        for i, b in enumerate(batches):
            ctx = cues[max(0, i * batch_size - 15): i * batch_size]
            jobs.append(ex.submit(translate_batch, b, ctx, glossary, title, model,
                                  cache_dir / f"{i:03d}.json", source))
        results = {}
        for n, j in enumerate(jobs, 1):
            results.update(j.result())
            sys.stdout.write(f"\r  Translating… batch {n}/{len(batches)}")
            sys.stdout.flush()
    print()
    for c in cues:
        field, en = results.get(c["id"], ("", ""))
        if en.upper().startswith("[DROP]"):
            en = ""
        if source == "ocr":
            c["speaker"], c["en"] = field, en
        else:  # speech recognition: the first field is the corrected Chinese
            c["zh_raw"], c["zh"], c["en"] = c["zh"], field or c["zh"], en
    return cues

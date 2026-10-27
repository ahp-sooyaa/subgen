"""Translate Chinese cues to English with Claude Code in headless mode (uses your subscription)."""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SYSTEM = "You are a professional Chinese-to-English subtitle translator. You output only the requested lines."

PROMPT = """You are subtitling a Chinese variety/reality show{title}.
Below are the on-screen Chinese captions, read by OCR, in order. Each line is `ID<TAB>caption`.
- A caption may begin with a speaker-name tag followed by " | " (e.g. `李沁 | 然后我就在`).
- " / " separates two lines of the same caption.
- OCR can contain small mistakes (wrong look-alike characters, stray symbols). Use context to infer what was meant.

Translate each caption into natural, concise spoken English suitable for subtitles. Keep the tone, jokes and slang.
Reply with exactly one line per ID, same order, and nothing else:
ID<TAB>speaker name in English (pinyin, or the glossary name), or empty if no tag<TAB>English subtitle

Use [DROP] as the English subtitle for lines that are advertisements, sponsor slogans, platform promos (e.g. 芒果TV, 会员, 独播) or unreadable OCR garbage.
{glossary}
{context}
Captions to translate:
{lines}
"""

LINE = re.compile(r"^\s*(\d+)\t([^\t]*)\t(.*)$")


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
    res = {}
    for line in out.splitlines():
        m = LINE.match(line)
        if m and int(m.group(1)) in ids:
            res[int(m.group(1))] = (m.group(2).strip(), m.group(3).strip())
    return res


def translate_batch(batch: list[dict], context: list[dict], glossary: str, title: str,
                    model: str, cache: Path) -> dict[int, tuple[str, str]]:
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
            title=f" ({title})" if title else "", glossary=gl, context=ctx,
            lines="\n".join(f"{c['id']}\t{c['zh']}" for c in todo),
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
              batch_size: int = 80, workers: int = 3) -> list[dict]:
    if not shutil.which("claude"):
        raise SystemExit("`claude` CLI not found. Install Claude Code and log in with your subscription.")
    cache_dir = workdir / "translate"
    cache_dir.mkdir(exist_ok=True)
    batches = [cues[i:i + batch_size] for i in range(0, len(cues), batch_size)]
    jobs = []
    with ThreadPoolExecutor(workers) as ex:
        for i, b in enumerate(batches):
            ctx = cues[max(0, i * batch_size - 15): i * batch_size]
            jobs.append(ex.submit(translate_batch, b, ctx, glossary, title, model,
                                  cache_dir / f"{i:03d}.json"))
        results = {}
        for n, j in enumerate(jobs, 1):
            results.update(j.result())
            sys.stdout.write(f"\r  Translating… batch {n}/{len(batches)}")
            sys.stdout.flush()
    print()
    for c in cues:
        speaker, en = results.get(c["id"], ("", ""))
        if en.upper().startswith("[DROP]"):
            en = ""
        c["speaker"], c["en"] = speaker, en
    return cues

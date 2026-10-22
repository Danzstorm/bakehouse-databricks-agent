"""Builds docs/Bakehouse-Agent-Guia.pdf from docs/guia_template.html.

Why a script: the PDF embeds the real source files, so it cannot drift from the repo.
  {{CMD}}...{{/CMD}}      -> dark command block (HTML-escaped)
  {{FILE:path|caption}}   -> full source listing of a repo file
Personal values (workspace user, warehouse id) are replaced by placeholders (by pattern) so the PDF is shareable.
Rendering: Microsoft Edge in headless mode (print to PDF). No extra Python dependencies.

Usage: python docs/build_pdf.py
"""
import html
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
OUT = DOCS / "Bakehouse-Agent-Guia.pdf"

# Personal values are scrubbed by pattern (no real values live in this file).
SCRUBS = [
    (re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+"), "<TU_USUARIO>"),   # workspace user (email)
    (re.compile(r"\b[0-9a-f]{16}\b"), "<WAREHOUSE_ID>"),   # SQL warehouse id
]


def scrub(text: str) -> str:
    for pattern, placeholder in SCRUBS:
        text = pattern.sub(placeholder, text)
    return text


def cmd_block(m: re.Match) -> str:
    body = html.escape(m.group(1).strip("\n"))
    return f'<pre class="code cmd">{body}</pre>'


def file_block(m: re.Match) -> str:
    rel, caption = m.group(1), m.group(2)
    src = scrub((ROOT / rel).read_text(encoding="utf-8")).rstrip("\n")
    return (f'<div class="src-title"><b>{html.escape(rel)}</b><span>{html.escape(caption)}</span></div>'
            f'<pre class="code src">{html.escape(src)}</pre>')


page = (DOCS / "guia_template.html").read_text(encoding="utf-8")
page = re.sub(r"\{\{CMD\}\}(.*?)\{\{/CMD\}\}", cmd_block, page, flags=re.S)
page = re.sub(r"\{\{FILE:([^|}]+)\|([^}]+)\}\}", file_block, page)
if "{{" in page:
    sys.exit("unresolved placeholder: " + page[page.index("{{"):][:80])

built = DOCS / "_build.html"
built.write_text(page, encoding="utf-8")

subprocess.run([
    EDGE, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
    f"--print-to-pdf={OUT}", built.as_uri(),
], check=True, timeout=180)
print("written", OUT, OUT.stat().st_size // 1024, "KB")

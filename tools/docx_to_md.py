#!/usr/bin/env python3
"""
Convert the PatterOS Word guides to Markdown, preserving the author's words.

WHY THIS EXISTS
---------------
The Part 2 setup guide and the Local AI Handbook were written in Word and lived
outside the repository, which meant the installer could print "see the guide,
Step 12" with nothing in the repo for the reader to open. Publishing them as
Markdown makes those references resolvable, makes the guides reviewable in a
pull request, and lets a guide change and a script change land in one commit.

This converter is deliberately mechanical. It does not rewrite prose: the point
is to carry the author's exact wording across, so that any correction is a
separate, visible edit rather than something smuggled in by a conversion.

Structure is recovered from the Word markup:
  Heading1 / Heading2      ->  ##  /  ###
  single-column table with
    Consolas runs          ->  fenced code block
  single-column table
    otherwise              ->  blockquote callout
  multi-column table       ->  Markdown table
  TOC entries              ->  dropped (Markdown renderers build their own)

Usage:
  python tools/docx_to_md.py IN.docx OUT.md [--title "Page title"]
"""
from __future__ import annotations

import html
import re
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"


def q(tag: str) -> str:
    return f"{W}{tag}"


def run_text(r: ET.Element) -> str:
    out = []
    for node in r.iter():
        if node.tag == q("t"):
            out.append(node.text or "")
        elif node.tag == q("tab"):
            out.append("\t")
        elif node.tag in (q("br"), q("cr")):
            out.append("\n")
    return "".join(out)


def is_mono(r: ET.Element) -> bool:
    rpr = r.find(q("rPr"))
    if rpr is None:
        return False
    f = rpr.find(q("rFonts"))
    if f is None:
        return False
    return any("Consolas" in (f.get(f"{W}{a}") or "") for a in ("ascii", "hAnsi", "cs", "eastAsia"))


def para_text(p: ET.Element, inline_code: bool = True, strip: bool = True) -> str:
    """Paragraph text, with monospace runs wrapped in backticks.

    strip=False keeps leading whitespace, which matters inside code blocks where
    indentation carries meaning (continued commands, nested arguments).
    """
    parts, buf, buf_mono = [], "", False
    for r in p.findall(q("r")):
        t = run_text(r)
        if not t:
            continue
        m = is_mono(r)
        if m == buf_mono:
            buf += t
        else:
            if buf:
                parts.append((buf, buf_mono))
            buf, buf_mono = t, m
    if buf:
        parts.append((buf, buf_mono))

    out = ""
    for text, mono in parts:
        if mono and inline_code and text.strip():
            lead = " " if text[:1].isspace() else ""
            trail = " " if text[-1:].isspace() else ""
            out += f"{lead}`{text.strip()}`{trail}"
        else:
            out += text
    return out.strip() if strip else out.rstrip()


def style_of(p: ET.Element) -> str:
    ppr = p.find(q("pPr"))
    if ppr is None:
        return "Normal"
    st = ppr.find(q("pStyle"))
    return (st.get(f"{W}val") if st is not None else "Normal") or "Normal"


def cell_paras(tc: ET.Element):
    return tc.findall(q("p"))


def table_to_md(tbl: ET.Element) -> str:
    rows = tbl.findall(q("tr"))
    if not rows:
        return ""
    grid = tbl.find(q("tblGrid"))
    ncols = len(grid.findall(q("gridCol"))) if grid is not None else 1

    # Single column: either a command box or a prose callout.
    #
    # The test is whether EVERY non-empty paragraph is entirely monospace, not
    # whether any run is. A callout that happens to name a script in monospace
    # is still prose, and wrapping it in a bash fence would tell the reader to
    # run an English sentence.
    if ncols == 1:
        paras, all_mono = [], True
        for tr in rows:
            for tc in tr.findall(q("tc")):
                for p in cell_paras(tc):
                    runs = [r for r in p.findall(q("r")) if run_text(r).strip()]
                    if runs and not all(is_mono(r) for r in runs):
                        all_mono = False
                    paras.append((p, bool(runs)))
        if not paras:
            return ""

        if all_mono:
            body = "\n".join(
                para_text(p, inline_code=False, strip=False) for p, _ in paras
            ).strip("\n")
            return f"```bash\n{body}\n```" if body.strip() else ""

        lines = [para_text(p) for p, _ in paras]
        body = "\n".join(lines).strip("\n")
        if not body.strip():
            return ""
        return "\n".join(f"> {ln}" if ln.strip() else ">" for ln in body.splitlines())

    # Multi column: a real table.
    out_rows = []
    for tr in rows:
        cells = []
        for tc in tr.findall(q("tc")):
            txt = " ".join(para_text(p) for p in cell_paras(tc) if para_text(p))
            cells.append(txt.replace("|", "\\|").strip())
        if any(c for c in cells):
            out_rows.append(cells)
    if not out_rows:
        return ""
    width = max(len(r) for r in out_rows)
    out_rows = [r + [""] * (width - len(r)) for r in out_rows]
    head, *body = out_rows
    md = ["| " + " | ".join(head) + " |", "|" + "|".join(["---"] * width) + "|"]
    md += ["| " + " | ".join(r) + " |" for r in body]
    return "\n".join(md)


def convert(src: Path, title: str | None) -> str:
    with zipfile.ZipFile(src) as z:
        root = ET.fromstring(z.read("word/document.xml"))
    body = root.find(q("body"))
    if body is None:
        raise SystemExit("no document body")

    out: list[str] = []
    for el in list(body):
        if el.tag == q("p"):
            st = style_of(el)
            if st.startswith("TOC"):
                continue
            txt = para_text(el)
            if not txt:
                continue
            if st == "Heading1":
                out += ["", f"## {txt}", ""]
            elif st == "Heading2":
                out += ["", f"### {txt}", ""]
            else:
                out += [txt, ""]
        elif el.tag == q("tbl"):
            md = table_to_md(el)
            if md:
                out += ["", md, ""]

    text = "\n".join(out)
    text = re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"
    if title:
        text = f"# {title}\n\n{text}"
    return html.unescape(text)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    title = None
    if "--title" in sys.argv:
        title = sys.argv[sys.argv.index("--title") + 1]
    md = convert(src, title)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(md, encoding="utf-8", newline="\n")
    print(f"{src.name} -> {dst}  ({len(md)} chars, {md.count(chr(10))} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

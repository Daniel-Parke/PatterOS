#!/usr/bin/env python3
"""
Surgically correct factual errors in the Part 1 BOM and build guide.

WHY THIS EXISTS
---------------
docs/PatterOS_AI_Rig_BOM_and_Build_Guide.docx is linked directly from the
Part 1 YouTube video description, so the file cannot be renamed, moved or
regenerated without breaking a link in a video that is already published.

It is also a pre-Odysseus document: it describes ports, an application and an
installer that the project no longer uses. Rather than rewrite it and lose the
original formatting, this script patches only the specific strings that are
factually wrong, inside word/document.xml and the hyperlink relationships,
leaving every other byte of the document untouched.

Run:  python tools/patch_part1_docx.py [--check]
      --check reports what would change and exits non-zero if anything is stale.
"""
from __future__ import annotations

import re
import shutil
import sys
import zipfile
from pathlib import Path

DOCX = Path(__file__).resolve().parent.parent / "docs" / "PatterOS_AI_Rig_BOM_and_Build_Guide.docx"

# (old, new, why). Every entry must match EXACTLY once, or the script refuses to
# run: a silent zero-match would mean we shipped a document we believed we had
# fixed.
REPLACEMENTS = [
    (
        "Open the chat endpoint at http://YOUR-PC-IP:8080, and Unsloth Studio at port 7860.",
        "Open the Odysseus workspace at http://localhost:7000, and the model server answers at http://localhost:8020/v1.",
        "Wrong ports and wrong application. The installer serves llama.cpp on "
        "8020 and Odysseus on 7000, both bound to this computer only. Unsloth "
        "Studio is not installed.",
    ),
    (
        "https://github.com/Daniel-Parke/YouTube-Repo",
        "https://github.com/Daniel-Parke/PatterOS",
        "The repository was renamed. The old address only resolves through a "
        "GitHub rename redirect, which stops working if that name is reused.",
    ),
    (
        "drop in a bigger GPU, add a second one (the installer supports multi-GPU and mixed-vendor rigs), or even mix manufacturers.",
        "drop in a bigger GPU whenever your budget allows. One graphics card is supported today, and multi-GPU support is planned.",
        "The installer detects one GPU vendor and builds one backend. It has no "
        "multi-GPU or mixed-vendor support, so the whole sentence is replaced "
        "rather than just the parenthetical, which would otherwise contradict "
        "the advice around it.",
    ),
    (
        "Most VRAM per pound. Inference via ROCm, training via Unsloth Core.",
        "Most VRAM per pound. Inference via Vulkan, which needs no vendor toolkit.",
        "The installer builds llama.cpp against Vulkan for AMD, not ROCm. "
        "Vulkan is also faster than ROCm for token generation on this card.",
    ),
    (
        "Inference through llama.cpp (built against ROCm) is excellent.",
        "Inference through llama.cpp (built against Vulkan) is excellent, and Vulkan needs no vendor toolkit to install.",
        "Same correction as above, in the prose for the AMD configuration.",
    ),
]

# "(coming soon)" is no longer true: the installer exists and is what the Part 2
# video demonstrates. Word splits these into their own formatting runs, so they
# are removed as standalone tokens rather than as part of a sentence.
COMING_SOON = [
    ("(coming soon) which will handle", "which will handle"),
    ("(coming soon!) ", ""),
    ("(coming soon!)", ""),
]

# Removing "(coming soon!)" leaves a double space behind in two sentences.
# Targeted rather than a global squeeze, because the document uses double
# spaces deliberately elsewhere.
#
# These operate on the run markup itself, because the two spaces end up in
# DIFFERENT <w:t> elements: one run ends with a space, the removed token sat
# between them, and the following run begins with a space. Matching the visible
# sentence therefore finds nothing.
TIDY = [
    ('<w:t xml:space="preserve"> script  </w:t>',
     '<w:t xml:space="preserve"> script </w:t>',
     "collapse the double space left where (coming soon!) was removed"),
    ('<w:t xml:space="preserve">Run install_local_ai.sh </w:t>',
     '<w:t xml:space="preserve">Run install_local_ai.sh</w:t>',
     "same, before a following run that already starts with a space"),
]


def extract_text(xml: str) -> str:
    """Roughly what a reader sees, for before/after comparison."""
    t = re.sub(r"</w:p>", "\n", xml)
    t = re.sub(r"<[^>]+>", "", t)
    return t


def apply(xml: str, pairs, expect_one: bool = True) -> tuple[str, list[str]]:
    notes = []
    for old, new, *_ in pairs:
        n = xml.count(old)
        if n == 0:
            continue                      # already patched; the script is idempotent
        if expect_one and n > 1:
            raise SystemExit(f"refusing to patch: {old[:70]!r} appears {n} times, expected 1")
        xml = xml.replace(old, new)
        notes.append(f"patched x{n}: {old[:60]!r}\n        ->  {new[:60]!r}")
    return xml, notes


def rename_installer(xml: str) -> tuple[str, list[str]]:
    """install.sh -> install_local_ai.sh, at token level.

    Word splits the surrounding sentences across formatting runs, so matching
    whole phrases fails. The bare token is unambiguous and the replacement is
    idempotent, because 'install_local_ai.sh' does not contain 'install.sh'
    (the 'install' is followed by '_', not '.').
    """
    n = len(re.findall(r"install\.sh", xml))
    if n == 0:
        return xml, []
    return re.sub(r"install\.sh", "install_local_ai.sh", xml), [
        f"patched x{n}: 'install.sh' -> 'install_local_ai.sh'"
    ]


def main() -> int:
    check_only = "--check" in sys.argv
    if not DOCX.is_file():
        print(f"not found: {DOCX}")
        return 1

    with zipfile.ZipFile(DOCX) as z:
        parts = {n: z.read(n) for n in z.namelist()}
        order = z.namelist()

    doc = parts["word/document.xml"].decode("utf-8")
    before_text = extract_text(doc)

    doc, notes1 = apply(doc, REPLACEMENTS)
    doc, notes_cs = apply(doc, COMING_SOON, expect_one=False)
    doc, notes_rn = rename_installer(doc)
    doc, notes_td = apply(doc, TIDY)
    notes2 = notes_cs + notes_rn + notes_td

    rels_name = "word/_rels/document.xml.rels"
    rels = parts[rels_name].decode("utf-8")
    rels_new = rels.replace(
        "https://github.com/Daniel-Parke/YouTube-Repo",
        "https://github.com/Daniel-Parke/PatterOS",
    )
    notes3 = ["patched hyperlink target: YouTube-Repo -> PatterOS"] if rels_new != rels else []

    changed = (doc != parts["word/document.xml"].decode("utf-8")) or bool(notes3)
    for n in notes1 + notes2 + notes3:
        print("  " + n.replace("\n", "\n  "))

    if not changed:
        print("\nNothing to change: the document is already correct.")
        return 0
    if check_only:
        print("\n--check: the document is STALE and needs patching.")
        return 1

    parts["word/document.xml"] = doc.encode("utf-8")
    parts[rels_name] = rels_new.encode("utf-8")

    backup = DOCX.with_suffix(".docx.bak")
    shutil.copy2(DOCX, backup)
    with zipfile.ZipFile(DOCX, "w", zipfile.ZIP_DEFLATED) as z:
        for name in order:                      # preserve original part order
            z.writestr(name, parts[name])

    with zipfile.ZipFile(DOCX) as z:
        after_text = extract_text(z.read("word/document.xml").decode("utf-8"))
        bad = z.testzip()
    if bad:
        shutil.copy2(backup, DOCX)
        print(f"\nrebuilt archive is corrupt at {bad}; restored the original")
        return 1

    b = [l.strip() for l in before_text.splitlines() if l.strip()]
    a = [l.strip() for l in after_text.splitlines() if l.strip()]
    print(f"\nparagraph count before/after: {len(b)}/{len(a)}")
    if len(b) != len(a):
        print("WARNING: paragraph count changed; inspect before committing")
    diffs = sum(1 for x, y in zip(b, a) if x != y)
    print(f"paragraphs whose text differs: {diffs}")
    print(f"backup written to {backup.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

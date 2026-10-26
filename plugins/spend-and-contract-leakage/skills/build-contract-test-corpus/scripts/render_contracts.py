#!/usr/bin/env python3
"""
Render synthetic contract text into real document files so the parse phase
(AI_PARSE_DOCUMENT, then AI_EXTRACT on parsed text) runs against PDFs and
scans instead of clean text rows.

Input is a CSV export of the SANDBOX table SYNTH_CONTRACT_DOCUMENTS
(document_id, file_path, document_text). Never run this on customer
contracts: they must not leave the account (best practices rule 24).

Render kinds, chosen per document so every parse failure mode is exercised:

    DIGITAL_PDF     selectable text, Markdown tables drawn as real tables
    CLEAN_SCAN      rasterized at 200 DPI, no noise
    DEGRADED_SCAN   rasterized, then rotated, blurred, speckled and
                    contrast-reduced at a graded severity (0.3 / 0.6 / 0.9)

Every document also gets:
    - the rate schedule (any Markdown table) moved to its own final
      "SCHEDULE" page, so page attribution of rate evidence is tested;
    - an image-only signature page, so LOW_TEXT_PAGE handling is tested.

Writes manifest.csv with document_id, file_path, render_kind,
degradation_severity, page_count, schedule_page_index, signature_page_index.
The answer key is unchanged: the same contracts, now as files.

Dependencies:  pip install reportlab pymupdf pillow numpy

Usage:
    python render_contracts.py --input synth_contract_documents.csv --outdir ./rendered
    python render_contracts.py --input docs.csv --outdir ./rendered --seed 7 \
        --assign SYN-DOC-C007=DEGRADED_SCAN:0.9
"""

from __future__ import annotations

import argparse
import csv
import io
import random
import re
import sys
from dataclasses import dataclass, asdict
from pathlib import Path

# Default assignment for the ten sandbox documents. The duplicate is a
# degraded rescan on purpose: exact-hash deduplication no longer catches it,
# so the near-duplicate path (AI_SIMILARITY plus agreement number) must.
DEFAULT_ASSIGNMENT = {
    "SYN-DOC-C001":     ("DIGITAL_PDF", 0.0),
    "SYN-DOC-C001-A1":  ("CLEAN_SCAN", 0.0),
    "SYN-DOC-C001-DUP": ("DEGRADED_SCAN", 0.6),
    "SYN-DOC-C002":     ("DIGITAL_PDF", 0.0),
    "SYN-DOC-C003":     ("CLEAN_SCAN", 0.0),
    "SYN-DOC-C004":     ("CLEAN_SCAN", 0.0),
    "SYN-DOC-C006":     ("DEGRADED_SCAN", 0.6),
    "SYN-DOC-C007":     ("DEGRADED_SCAN", 0.3),
    "SYN-DOC-C008":     ("DIGITAL_PDF", 0.0),
    "SYN-DOC-N008":     ("CLEAN_SCAN", 0.0),
}

RENDER_KINDS = ("DIGITAL_PDF", "CLEAN_SCAN", "DEGRADED_SCAN")
SCAN_DPI = 200
TABLE_ROW = re.compile(r"^\s*\|.*\|\s*$")


@dataclass
class ManifestRow:
    document_id: str
    file_path: str
    render_kind: str
    degradation_severity: float
    page_count: int
    schedule_page_index: int      # -1 when the document has no table
    signature_page_index: int


def split_body_and_tables(text: str) -> tuple[list[str], list[list[list[str]]], list[str]]:
    """Separate prose lines from Markdown tables.

    Returns (prose_lines, tables, table_captions). A table caption is the
    nearest preceding non-empty prose line, kept so the SCHEDULE page still
    says which item a tier table belongs to.
    """
    prose: list[str] = []
    tables: list[list[list[str]]] = []
    captions: list[str] = []
    current: list[list[str]] = []
    last_prose = ""
    for line in (text or "").splitlines():
        if TABLE_ROW.match(line):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if not current:
                captions.append(last_prose)
            current.append(cells)
            continue
        if current:
            tables.append(current)
            current = []
        prose.append(line)
        if line.strip():
            last_prose = line.strip()
    if current:
        tables.append(current)
    return prose, tables, captions


def build_pdf(document_id: str, text: str) -> tuple[bytes, int, int, int]:
    """Lay out a contract as a digital PDF with reportlab.

    Prose first, then a SCHEDULE page with every table, then a signature
    page whose only content is a drawn image. Returns (pdf_bytes,
    page_count, schedule_page_index, signature_page_index).
    """
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import LETTER
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.lib.units import inch
    from reportlab.platypus import (Image, PageBreak, Paragraph, SimpleDocTemplate,
                                    Spacer, Table, TableStyle)

    styles = getSampleStyleSheet()
    body = styles["BodyText"]
    heading = styles["Heading2"]
    prose, tables, captions = split_body_and_tables(text)

    story = []
    for line in prose:
        if not line.strip():
            story.append(Spacer(1, 6))
            continue
        safe = (line.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
        style = heading if line.isupper() and len(line) < 80 else body
        story.append(Paragraph(safe, style))

    schedule_page = -1
    if tables:
        story.append(PageBreak())
        story.append(Paragraph("SCHEDULE", heading))
        for caption, rows in zip(captions, tables):
            if caption:
                story.append(Paragraph(caption.replace("&", "&amp;"), body))
            t = Table(rows, hAlign="LEFT")
            t.setStyle(TableStyle([
                ("GRID", (0, 0), (-1, -1), 0.5, colors.black),
                ("BACKGROUND", (0, 0), (-1, 0), colors.lightgrey),
                ("FONTSIZE", (0, 0), (-1, -1), 9),
            ]))
            story.append(t)
            story.append(Spacer(1, 12))

    story.append(PageBreak())
    story.append(Image(io.BytesIO(signature_png()), width=5.5 * inch, height=2.5 * inch))

    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=LETTER, title=document_id,
                            leftMargin=0.9 * inch, rightMargin=0.9 * inch)
    doc.build(story)
    pdf = buf.getvalue()

    pages = page_count(pdf)
    signature_page = pages - 1
    if tables:
        schedule_page = find_page_containing(pdf, "SCHEDULE", start_from_end=True)
    return pdf, pages, schedule_page, signature_page


def signature_png() -> bytes:
    """An image-only signature block: handwriting-like strokes, no text layer."""
    from PIL import Image as PILImage, ImageDraw

    img = PILImage.new("L", (1100, 500), 255)
    draw = ImageDraw.Draw(img)
    rng = random.Random(42)
    for y0 in (130, 360):
        draw.line([(80, y0 + 40), (520, y0 + 40)], fill=0, width=3)
        draw.line([(600, y0 + 40), (1020, y0 + 40)], fill=0, width=3)
        x, y = 100, y0
        for _ in range(40):
            nx, ny = x + rng.randint(5, 14), y0 + rng.randint(-25, 25)
            draw.line([(x, y), (nx, ny)], fill=0, width=4)
            x, y = nx, ny
    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()


def page_count(pdf: bytes) -> int:
    import pymupdf as fitz
    with fitz.open(stream=pdf, filetype="pdf") as d:
        return d.page_count


def find_page_containing(pdf: bytes, needle: str, start_from_end: bool = False) -> int:
    import pymupdf as fitz
    with fitz.open(stream=pdf, filetype="pdf") as d:
        indices = range(d.page_count - 1, -1, -1) if start_from_end else range(d.page_count)
        for i in indices:
            if needle in d[i].get_text():
                return i
    return -1


def rasterize(pdf: bytes, severity: float, rng: random.Random) -> bytes:
    """Render each page to an image, degrade it, and rebuild an image-only PDF.

    Severity is graded so the parse-quality signal is continuous:
      0.0  clean scan
      0.3  slight skew, light speckle
      0.6  visible skew, blur, speckle, reduced contrast
      0.9  heavy skew and noise; small print (rate tables) starts to fail
    """
    import pymupdf as fitz
    import numpy as np
    from PIL import Image as PILImage, ImageEnhance, ImageFilter

    out = fitz.open()
    with fitz.open(stream=pdf, filetype="pdf") as src:
        for page in src:
            pix = page.get_pixmap(dpi=SCAN_DPI, colorspace=fitz.csGRAY)
            img = PILImage.frombytes("L", (pix.width, pix.height), pix.samples)
            if severity > 0:
                img = img.rotate(rng.uniform(-2.5, 2.5) * severity, expand=False, fillcolor=255)
                if severity >= 0.5:
                    img = img.filter(ImageFilter.GaussianBlur(radius=0.6 + 1.2 * (severity - 0.5)))
                arr = np.array(img).astype(np.int16)
                mask = np.random.default_rng(rng.randint(0, 2**31)).random(arr.shape) < 0.004 * severity
                arr[mask] = 0
                arr = np.clip(arr, 0, 255).astype(np.uint8)
                img = PILImage.fromarray(arr)
                img = ImageEnhance.Contrast(img).enhance(1.0 - 0.45 * severity)
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            rect = page.rect
            new_page = out.new_page(width=rect.width, height=rect.height)
            new_page.insert_image(rect, stream=buf.getvalue())
    data = out.tobytes(deflate=True)
    out.close()
    return data


def parse_assign(values: list[str]) -> dict[str, tuple[str, float]]:
    """Parse --assign DOC=KIND[:SEVERITY] overrides."""
    result: dict[str, tuple[str, float]] = {}
    for v in values or []:
        doc, _, spec = v.partition("=")
        kind, _, sev = spec.partition(":")
        kind = kind.strip().upper()
        if kind not in RENDER_KINDS:
            raise SystemExit(f"unknown render kind {kind!r}; expected one of {RENDER_KINDS}")
        severity = float(sev) if sev else (0.6 if kind == "DEGRADED_SCAN" else 0.0)
        if not 0.0 <= severity <= 1.0:
            raise SystemExit(f"severity for {doc} must be within 0..1")
        result[doc.strip()] = (kind, severity)
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", required=True, help="CSV export of SYNTH_CONTRACT_DOCUMENTS")
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--id-col", default="DOCUMENT_ID")
    ap.add_argument("--path-col", default="FILE_PATH")
    ap.add_argument("--text-col", default="DOCUMENT_TEXT")
    ap.add_argument("--seed", type=int, default=20260930)
    ap.add_argument("--assign", action="append", help="override, e.g. SYN-DOC-C007=DEGRADED_SCAN:0.9")
    args = ap.parse_args()

    assignment = dict(DEFAULT_ASSIGNMENT)
    assignment.update(parse_assign(args.assign))
    rng = random.Random(args.seed)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    with open(args.input, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        cols = {c.upper(): c for c in (reader.fieldnames or [])}
        missing = [c for c in (args.id_col, args.path_col, args.text_col) if c.upper() not in cols]
        if missing:
            raise SystemExit(f"input is missing columns: {missing}")
        rows = list(reader)

    manifest: list[ManifestRow] = []
    for r in rows:
        doc_id = r[cols[args.id_col.upper()]].strip()
        rel_path = r[cols[args.path_col.upper()]].strip()
        text = r[cols[args.text_col.upper()]] or ""
        if not doc_id.startswith("SYN-"):
            raise SystemExit(f"refusing to render {doc_id!r}: only SYN- sandbox documents may leave the account")
        if not text.strip():
            print(f"skip {doc_id}: no text", file=sys.stderr)
            continue
        kind, severity = assignment.get(doc_id, ("DIGITAL_PDF", 0.0))

        pdf, pages, schedule_page, signature_page = build_pdf(doc_id, text)
        if kind in ("CLEAN_SCAN", "DEGRADED_SCAN"):
            pdf = rasterize(pdf, severity if kind == "DEGRADED_SCAN" else 0.0, rng)

        target = outdir / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(pdf)
        manifest.append(ManifestRow(doc_id, rel_path, kind, severity, pages, schedule_page, signature_page))
        print(f"{doc_id:18s} {kind:14s} sev={severity:.1f} pages={pages} -> {rel_path}")

    with open(outdir / "manifest.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(asdict(manifest[0]).keys()) if manifest else ["document_id"])
        w.writeheader()
        for m in manifest:
            w.writerow(asdict(m))
    print(f"wrote {len(manifest)} files and manifest.csv to {outdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

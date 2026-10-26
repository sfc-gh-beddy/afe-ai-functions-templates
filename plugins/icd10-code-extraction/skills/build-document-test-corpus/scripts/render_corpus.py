#!/usr/bin/env python3
"""
Render clinical note text into actual document artifacts for pipeline testing.

Produces a deliberate mix so every routing tier is exercised:

    DIGITAL_PDF     selectable text        -> T2 direct text
    CLEAN_SCAN      rasterized, 300 DPI    -> T1 OCR, clean signal
    DEGRADED_SCAN   rasterized + degraded  -> T1 OCR, poor signal
    FORM            labelled field boxes   -> T3 AI_EXTRACT
    ADMINISTRATIVE  consent / billing      -> T4 skip

Degradation is GRADED, not binary, so the OCR-quality routing threshold can be
placed on a continuous signal rather than guessed from a bimodal corpus.

Writes a manifest CSV that becomes the document table, carrying render_kind and
degradation_severity so routing decisions can be checked against known truth.

Dependencies:  pip install reportlab pymupdf pillow numpy

Usage:
    python render_corpus.py --input notes.csv --outdir ./rendered \
        --text-col clean_note_text --id-col clinical_note_id \
        --patient-col person_id --type-col note_type --limit 100
"""

from __future__ import annotations

import argparse
import csv
import io
import random
import sys
import unicodedata
from dataclasses import dataclass, asdict
from pathlib import Path

# Deliberate document mix. Shares must sum to 1.0.
DEFAULT_MIX = {
    "DIGITAL_PDF": 0.45,
    "CLEAN_SCAN": 0.20,
    "DEGRADED_SCAN": 0.20,
    "FORM": 0.10,
    "ADMINISTRATIVE": 0.05,
}

# Graded degradation. Rendering only 0.0 and 0.9 gives a bimodal corpus and makes
# the routing threshold unplaceable.
SEVERITY_LADDER = [0.3, 0.6, 0.9]

# Note subjects that are administrative regardless of what the mix would assign.
# Real consent and checklist content is better T4 material than anything
# hand-written, so route it there on content rather than by random draw.
ADMIN_HINTS = (
    "consent", "checklist", "privacy", "billing", "authorisation",
    "authorization", "financial", "release of information",
)

FORM_HINTS = ("checklist", "pre-op", "preop", "assessment form", "screening")


@dataclass
class ManifestRow:
    document_id: str
    patient_id: str
    document_date: str
    document_type: str
    source_system: str
    file_format: str
    page_count: int
    file_path: str
    render_kind: str
    degradation_severity: float
    corpus_source: str
    source_text: str


def clean(text: str) -> str:
    """Strip spreadsheet corruption and normalise decode artefacts."""
    t = (text or "").strip()
    if t in ("#NAME?", "#REF!", "#VALUE!", "#N/A", "#DIV/0!"):
        return ""
    return unicodedata.normalize("NFKC", t)


def choose_kind(subject: str, note_type: str, rng: random.Random, mix: dict) -> str:
    """Content-aware assignment, falling back to the configured mix."""
    haystack = f"{subject} {note_type}".lower()
    if any(h in haystack for h in ADMIN_HINTS):
        # Consent and privacy content is genuinely administrative. Send most of
        # it to the skip tier, but keep some as forms so T3 has real material.
        return "FORM" if rng.random() < 0.35 else "ADMINISTRATIVE"
    if any(h in haystack for h in FORM_HINTS):
        return "FORM"
    kinds, weights = zip(*mix.items())
    return rng.choices(kinds, weights=weights, k=1)[0]


def render_text_pdf(text: str, title: str, path: Path) -> int:
    """Digital-born PDF with selectable text."""
    from reportlab.lib.pagesizes import LETTER
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.units import inch
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer

    styles = getSampleStyleSheet()
    body = ParagraphStyle(
        "body", parent=styles["BodyText"], fontName="Helvetica",
        fontSize=9.5, leading=12.5,
    )
    head = ParagraphStyle("head", parent=styles["Heading4"], spaceAfter=6)

    doc = SimpleDocTemplate(
        str(path), pagesize=LETTER,
        leftMargin=0.9 * inch, rightMargin=0.9 * inch,
        topMargin=0.8 * inch, bottomMargin=0.8 * inch,
        title=title,
    )
    flow = [Paragraph(_esc(title), head), Spacer(1, 6)]
    for block in text.split("\n"):
        block = block.strip()
        flow.append(Spacer(1, 4) if not block else Paragraph(_esc(block), body))
    doc.build(flow)

    import fitz
    with fitz.open(str(path)) as d:
        return d.page_count


def render_form_pdf(text: str, title: str, path: Path) -> int:
    """
    Structured form with labelled field boxes, so AI_EXTRACT has real fields to
    target rather than prose.
    """
    from reportlab.lib.pagesizes import LETTER
    from reportlab.lib.units import inch
    from reportlab.pdfgen import canvas

    c = canvas.Canvas(str(path), pagesize=LETTER)
    w, h = LETTER
    y = h - 0.8 * inch

    c.setFont("Helvetica-Bold", 12)
    c.drawString(0.9 * inch, y, title[:80])
    y -= 0.18 * inch
    c.setLineWidth(1)
    c.line(0.9 * inch, y, w - 0.9 * inch, y)
    y -= 0.32 * inch

    # Parse "Label: value" lines into boxed fields; keep the rest as a notes block.
    fields, remainder = [], []
    for line in text.split("\n"):
        line = line.strip()
        if not line:
            continue
        if ":" in line and len(line.split(":", 1)[0]) <= 34 and not line.startswith("-"):
            label, value = line.split(":", 1)
            fields.append((label.strip(), value.strip()))
        else:
            remainder.append(line)

    for label, value in fields[:16]:
        c.setFont("Helvetica-Bold", 8.5)
        c.drawString(0.9 * inch, y, f"{label}:")
        c.setLineWidth(0.4)
        c.rect(2.7 * inch, y - 0.05 * inch, w - 3.6 * inch, 0.22 * inch, stroke=1, fill=0)
        c.setFont("Helvetica", 8.5)
        c.drawString(2.78 * inch, y + 0.02 * inch, value[:88])
        y -= 0.34 * inch
        if y < 1.4 * inch:
            c.showPage()
            y = h - 0.8 * inch

    if remainder:
        c.setFont("Helvetica-Bold", 8.5)
        c.drawString(0.9 * inch, y, "NOTES")
        y -= 0.16 * inch
        c.setFont("Helvetica", 8)
        for line in remainder:
            for chunk in _wrap(line, 105):
                c.drawString(0.9 * inch, y, chunk)
                y -= 0.14 * inch
                if y < 0.9 * inch:
                    c.showPage()
                    y = h - 0.8 * inch
                    c.setFont("Helvetica", 8)

    c.save()
    import fitz
    with fitz.open(str(path)) as d:
        return d.page_count


def rasterize_and_degrade(pdf_path: Path, out_path: Path, severity: float) -> int:
    """
    Turn a PDF into a scan-like PDF with NO text layer, so AI_PARSE_DOCUMENT must
    actually OCR it. severity 0.0 is a clean 300 DPI scan; 0.9 is a bad fax.

    This approximates a photocopy or fax. It does NOT reproduce handwriting,
    stamps, or the specific failure modes of a customer's scanning estate --
    routing thresholds tuned here will need re-tuning on real documents.
    """
    import fitz
    import numpy as np
    from PIL import Image, ImageFilter, ImageEnhance

    dpi = int(round(300 - 200 * severity))          # 300 -> 100
    skew = (random.uniform(-1.0, 1.0) * 2.2 * severity)
    noise_sigma = 26 * severity
    jpeg_q = int(round(95 - 55 * severity))          # 95 -> 40

    with fitz.open(str(pdf_path)) as src:
        pages = []
        for page in src:
            pix = page.get_pixmap(dpi=dpi, colorspace=fitz.csGRAY)
            img = Image.frombytes("L", (pix.width, pix.height), pix.samples)

            if severity > 0:
                if abs(skew) > 0.05:
                    img = img.rotate(skew, resample=Image.BICUBIC, expand=False, fillcolor=255)
                if severity >= 0.6:
                    img = img.filter(ImageFilter.GaussianBlur(radius=0.4 + 0.5 * severity))
                if noise_sigma > 0:
                    a = np.asarray(img).astype(np.float32)
                    a += np.random.normal(0.0, noise_sigma, a.shape)
                    img = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), mode="L")
                if severity >= 0.6:
                    img = ImageEnhance.Contrast(img).enhance(1.0 - 0.28 * severity)

            # Round-trip through JPEG so compression artefacts are real.
            buf = io.BytesIO()
            img.convert("L").save(buf, format="JPEG", quality=max(30, jpeg_q))
            buf.seek(0)
            pages.append(buf.read())

    # Rebuild as an image-only PDF: no text layer, so OCR is unavoidable.
    out = fitz.open()
    for data in pages:
        img_doc = fitz.open("jpeg", data)
        rect = img_doc[0].rect
        page = out.new_page(width=rect.width, height=rect.height)
        page.insert_image(rect, stream=data)
        img_doc.close()
    out.save(str(out_path), deflate=True)
    n = out.page_count
    out.close()
    return n


def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _wrap(s: str, width: int):
    while len(s) > width:
        cut = s.rfind(" ", 0, width)
        cut = cut if cut > 0 else width
        yield s[:cut]
        s = s[cut:].lstrip()
    if s:
        yield s


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input", required=True, help="CSV of note text")
    p.add_argument("--outdir", required=True)
    p.add_argument("--text-col", default="clean_note_text")
    p.add_argument("--id-col", default="clinical_note_id")
    p.add_argument("--patient-col", default="person_id")
    p.add_argument("--type-col", default="note_type")
    p.add_argument("--subject-col", default="note_subject")
    p.add_argument("--date-col", default="creation_timestamp")
    p.add_argument("--corpus-source", default="EXTERNAL",
                   help="Provenance marker written to every manifest row")
    p.add_argument("--limit", type=int, default=0, help="0 = all. Render a sample first.")
    p.add_argument("--seed", type=int, default=7)
    args = p.parse_args()

    rng = random.Random(args.seed)
    random.seed(args.seed)

    outdir = Path(args.outdir)
    (outdir / "files").mkdir(parents=True, exist_ok=True)

    # encoding="utf-8-sig" strips the BOM that otherwise breaks the first column name.
    with open(args.input, newline="", encoding="utf-8-sig", errors="replace") as fh:
        rows = list(csv.DictReader(fh))

    if args.text_col not in (rows[0].keys() if rows else {}):
        print(f"ERROR: --text-col '{args.text_col}' not in {list(rows[0].keys())}", file=sys.stderr)
        return 2

    manifest: list[ManifestRow] = []
    skipped = 0

    for row in rows:
        if args.limit and len(manifest) >= args.limit:
            break

        text = clean(row.get(args.text_col, ""))
        if len(text) < 20:
            skipped += 1
            continue

        doc_id = str(row.get(args.id_col) or f"DOC-{len(manifest):06d}")
        subject = str(row.get(args.subject_col) or "")
        note_type = str(row.get(args.type_col) or "CLINICAL_NOTE")
        kind = choose_kind(subject, note_type, rng, DEFAULT_MIX)
        title = subject or note_type

        safe = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in doc_id)[:60]
        work = outdir / "files" / f"{safe}__src.pdf"

        try:
            if kind == "FORM":
                render_form_pdf(text, title, work)
                final, sev = outdir / "files" / f"{safe}.pdf", 0.0
                work.rename(final)
                pages = _pages(final)
            elif kind in ("DIGITAL_PDF", "ADMINISTRATIVE"):
                render_text_pdf(text, title, work)
                final, sev = outdir / "files" / f"{safe}.pdf", 0.0
                work.rename(final)
                pages = _pages(final)
            else:
                render_text_pdf(text, title, work)
                sev = 0.0 if kind == "CLEAN_SCAN" else rng.choice(SEVERITY_LADDER)
                final = outdir / "files" / f"{safe}.pdf"
                pages = rasterize_and_degrade(work, final, sev)
                work.unlink(missing_ok=True)
        except Exception as exc:                      # noqa: BLE001
            print(f"  render failed {doc_id}: {exc}", file=sys.stderr)
            skipped += 1
            continue

        manifest.append(ManifestRow(
            document_id=doc_id,
            patient_id=str(row.get(args.patient_col) or "UNKNOWN"),
            document_date=str(row.get(args.date_col) or "")[:10],
            document_type=note_type if kind != "ADMINISTRATIVE" else "ADMINISTRATIVE_FORM",
            source_system="RENDERED_CORPUS",
            file_format="pdf",
            page_count=pages,
            file_path=final.name,
            render_kind=kind,
            degradation_severity=sev,
            corpus_source=args.corpus_source,
            # Kept so the loader can populate document_text for DIGITAL_PDF only.
            # Scans and forms MUST land with NULL text or routing takes the T2
            # fast path and the OCR tiers never run.
            source_text=text,
        ))

    man_path = outdir / "manifest.csv"
    with open(man_path, "w", newline="", encoding="utf-8") as fh:
        wr = csv.DictWriter(fh, fieldnames=list(asdict(manifest[0]).keys()))
        wr.writeheader()
        for m in manifest:
            wr.writerow(asdict(m))

    total_pages = sum(m.page_count for m in manifest)
    ocr_pages = sum(m.page_count for m in manifest
                    if m.render_kind in ("CLEAN_SCAN", "DEGRADED_SCAN"))

    print(f"\nRendered {len(manifest)} documents ({skipped} skipped) -> {outdir}/files")
    print(f"Manifest: {man_path}")
    print("\nMix:")
    for kind in DEFAULT_MIX:
        sel = [m for m in manifest if m.render_kind == kind]
        if sel:
            print(f"  {kind:<16} {len(sel):>5}  ({100*len(sel)/len(manifest):>4.1f}%)  "
                  f"{sum(m.page_count for m in sel):>5} pages")
    print(f"\nTotal pages: {total_pages}")
    print(f"Pages that will require OCR: {ocr_pages}")
    print("\nAI_PARSE_DOCUMENT bills PER PAGE. Validate tier distribution on this")
    print("sample before scaling up. Report pages and tokens, never dollars.")
    return 0


def _pages(path: Path) -> int:
    import fitz
    with fitz.open(str(path)) as d:
        return d.page_count


if __name__ == "__main__":
    raise SystemExit(main())

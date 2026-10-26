#!/usr/bin/env python3
"""Render SYNTHETIC inspection reports into PDF checklist forms and scanned-image variants.

Input is a CSV exported from the sandbox table SYNTH_INSPECTION_REPORTS with columns
REPORT_ID, ASSET_ID, INSPECTION_TS, REPORT_TEXT. Output is one file per report per variant plus
manifest.csv mapping each file back to its report_id.

This script must only ever be given synthetic sandbox rows. It refuses input whose report ids do
not carry the SYN- prefix, so customer inspection text cannot be rendered locally by accident.

Usage:
    python3 render_inspections.py --input synth_inspections.csv --out ./inspection_corpus \
        --variants typed,scan_clean,scan_degraded --limit 300 --seed 7
"""

import argparse
import csv
import io
import os
import random
import sys

VARIANTS = ("typed", "scan_clean", "scan_degraded")


def _require(module_name, pip_name):
    try:
        return __import__(module_name)
    except ImportError:
        sys.exit(f"Missing dependency '{pip_name}'. Install it with: pip install {pip_name}")


def read_rows(path, limit):
    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        rows = []
        for row in reader:
            norm = {k.strip().upper(): (v or "") for k, v in row.items()}
            missing = {"REPORT_ID", "ASSET_ID", "INSPECTION_TS", "REPORT_TEXT"} - set(norm)
            if missing:
                sys.exit(f"Input is missing columns: {sorted(missing)}")
            if not norm["REPORT_ID"].startswith("SYN-"):
                sys.exit(
                    f"Refusing to render report_id {norm['REPORT_ID']!r}: not a synthetic SYN- id. "
                    "This renderer is for sandbox data only."
                )
            rows.append(norm)
            if limit and len(rows) >= limit:
                break
    if not rows:
        sys.exit("No rows read from input.")
    return rows


def split_checklist(text):
    """Split report text into (header_lines, checklist_pairs, free_lines).

    Lines of the form 'Label: value' become checklist pairs so they render as a two-column table,
    which is the layout where negation is most easily separated from its label by a parser.
    Sentences of the form 'Seal - no leaks.' stay as free text.
    """
    text = text.replace("\\n", "\n")
    header, pairs, free = [], [], []
    for i, raw in enumerate(text.split("\n")):
        line = raw.strip()
        if not line:
            continue
        if ":" in line and len(line.split(":", 1)[0]) <= 40 and i > 0:
            label, value = line.split(":", 1)
            pairs.append((label.strip(), value.strip()))
        elif i == 0:
            header.append(line)
        else:
            free.append(line)
    return header, pairs, free


def render_pdf(row, path):
    _require("reportlab", "reportlab")
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

    styles = getSampleStyleSheet()
    doc = SimpleDocTemplate(path, pagesize=A4, title=f"Inspection {row['REPORT_ID']}")
    story = [
        Paragraph("EQUIPMENT INSPECTION REPORT (SYNTHETIC)", styles["Title"]),
        Paragraph(f"Report: {row['REPORT_ID']} &nbsp;&nbsp; Asset: {row['ASSET_ID']}", styles["Normal"]),
        Paragraph(f"Inspected: {row['INSPECTION_TS']}", styles["Normal"]),
        Spacer(1, 12),
    ]
    header, pairs, free = split_checklist(row["REPORT_TEXT"])
    for line in header + free:
        story.append(Paragraph(line.replace("&", "&amp;").replace("<", "&lt;"), styles["BodyText"]))
    if pairs:
        story.append(Spacer(1, 10))
        data = [["Check item", "Result"]] + [[k, v] for k, v in pairs]
        table = Table(data, colWidths=[300, 150])
        table.setStyle(TableStyle([
            ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
            ("BACKGROUND", (0, 0), (-1, 0), colors.lightgrey),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ]))
        story.append(table)
    story.append(Spacer(1, 24))
    story.append(Paragraph("Inspector signature: ______________________", styles["Normal"]))
    doc.build(story)


def render_image(row, path, degraded, rng):
    _require("PIL", "Pillow")
    from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

    width, height = 1654, 2339  # A4 at roughly 200 DPI
    img = Image.new("L", (width, height), 255)
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 30)
        bold = ImageFont.truetype("DejaVuSans-Bold.ttf", 40)
    except OSError:
        font = ImageFont.load_default()
        bold = font

    y = 120
    draw.text((120, y), "EQUIPMENT INSPECTION REPORT (SYNTHETIC)", font=bold, fill=0)
    y += 90
    draw.text((120, y), f"Report: {row['REPORT_ID']}    Asset: {row['ASSET_ID']}", font=font, fill=0)
    y += 50
    draw.text((120, y), f"Inspected: {row['INSPECTION_TS']}", font=font, fill=0)
    y += 90

    header, pairs, free = split_checklist(row["REPORT_TEXT"])
    for line in header + free:
        for chunk in [line[i:i + 80] for i in range(0, len(line), 80)]:
            draw.text((120, y), chunk, font=font, fill=0)
            y += 46
    if pairs:
        y += 30
        for label, value in [("Check item", "Result")] + pairs:
            draw.rectangle([110, y - 8, 1010, y + 42], outline=0, width=2)
            draw.rectangle([1010, y - 8, 1400, y + 42], outline=0, width=2)
            draw.text((125, y), label, font=font, fill=0)
            draw.text((1025, y), value, font=font, fill=0)
            y += 50

    if degraded:
        img = img.rotate(rng.uniform(-2.5, 2.5), expand=False, fillcolor=255)
        img = ImageEnhance.Contrast(img).enhance(rng.uniform(0.55, 0.8))
        noise = Image.effect_noise((width, height), rng.uniform(18, 32))
        img = Image.blend(img, noise, 0.18)
        img = img.filter(ImageFilter.GaussianBlur(radius=rng.uniform(0.6, 1.2)))
        buf = io.BytesIO()
        img.convert("RGB").save(buf, format="JPEG", quality=rng.randint(30, 50))
        img = Image.open(io.BytesIO(buf.getvalue()))
    img.save(path, format="PNG")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--variants", default=",".join(VARIANTS))
    parser.add_argument("--limit", type=int, default=300)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    variants = [v.strip() for v in args.variants.split(",") if v.strip()]
    unknown = set(variants) - set(VARIANTS)
    if unknown:
        sys.exit(f"Unknown variants: {sorted(unknown)}; choose from {VARIANTS}")

    rows = read_rows(args.input, args.limit)
    os.makedirs(args.out, exist_ok=True)
    rng = random.Random(args.seed)
    manifest = []

    for row in rows:
        rid = row["REPORT_ID"]
        for variant in variants:
            if variant == "typed":
                name = f"{rid}_typed.pdf"
                render_pdf(row, os.path.join(args.out, name))
            else:
                name = f"{rid}_{variant}.png"
                render_image(row, os.path.join(args.out, name), variant == "scan_degraded", rng)
            manifest.append((rid, variant, name))

    with open(os.path.join(args.out, "manifest.csv"), "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["report_id", "variant", "relative_path"])
        writer.writerows(manifest)

    print(f"Rendered {len(manifest)} files for {len(rows)} reports into {args.out}")


if __name__ == "__main__":
    main()

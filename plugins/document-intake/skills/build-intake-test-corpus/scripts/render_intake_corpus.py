#!/usr/bin/env python3
"""
Render a labeled synthetic document corpus for document-intake testing.

Two input modes:

  --generate N         Build N synthetic business documents from scratch
                       (invoices, credit notes, insurance claim forms,
                       contracts, W-9 style tax forms, out-of-scope letters)
                       with real visual layout: header blocks, line-item
                       tables, field boxes, remittance stubs, stamps.

  --from-sandbox DIR   Render the rows exported from seed-intake-sandbox
                       (SYN_DOCUMENTS.csv, SYN_FIELD_ANSWER_KEY.csv,
                       SYN_DOC_ANSWER_KEY.csv in DIR) so text-path and
                       file-path accuracy can be compared on identical content.

Every document is rendered to one of these kinds:

    DIGITAL_PDF     selectable text layer
    CLEAN_SCAN      rasterized at 300 DPI, image-only (forces OCR)
    DEGRADED_SCAN   rasterized and degraded on a GRADED ladder (forces OCR)
    PHOTO           single JPEG/PNG image, perspective tilt + uneven light
    MULTI_DOC       two documents concatenated in one PDF (invoice + slip)

Outputs, in --outdir:

    files/                     the rendered documents
    manifest.csv               one row per file: kind, severity, pages, type
    field_answer_key.csv       one row per document x field (canonical value,
                               PRESENT / NOT_PRESENT, posts flag)
    doc_answer_key.csv         one row per document (expected type, decision,
                               reason)

The keys use the SAME canonical forms and column names as the sandbox keys,
so evaluate-intake-accuracy reads either without change.

Dependencies:  pip install reportlab pymupdf pillow numpy

Usage:
    python render_intake_corpus.py --generate 120 --outdir ./rendered --seed 7
    python render_intake_corpus.py --from-sandbox ./sandbox_export --outdir ./rendered

Nothing here is real: every party, number and address is fabricated and
every identifier is prefixed SYN-. Do not feed real documents through this
script; it writes text into local files.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import random
import sys
from dataclasses import dataclass, asdict, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Share of documents per render kind. Must sum to 1.0. Scans are weighted
# heavily on purpose: they are where amounts and dates get mangled.
DEFAULT_MIX = {
    "DIGITAL_PDF": 0.35,
    "CLEAN_SCAN": 0.20,
    "DEGRADED_SCAN": 0.30,
    "PHOTO": 0.10,
    "MULTI_DOC": 0.05,
}

# Graded, not binary. The interesting question for intake is not "did OCR
# return text" (it nearly always does) but "at what severity do decimal
# points, commas and day/month digits start to change". A ladder lets the
# accuracy harness plot field accuracy against severity.
SEVERITY_LADDER = [0.2, 0.4, 0.6, 0.8, 1.0]

# Share of generated documents per type when --generate is used.
TYPE_MIX = {
    "invoice": 0.55,
    "credit_note": 0.07,
    "insurance_claim_form": 0.14,
    "contract": 0.08,
    "w9_tax_form": 0.08,
    "other_document": 0.08,
}

VENDORS = [
    # id, name, tax_id(digits), bank_last4, currency, number_locale, date_locale, terms, tax_rate
    ("SYN-V001", "Alderbrook Office Supply LLC", "900000101", "4411", "USD", "DOT", "MDY", "NET 30", 0.0725),
    ("SYN-V002", "Brightwater Facilities Inc", "900000102", "5522", "USD", "DOT", "MDY", "NET 45", 0.0725),
    ("SYN-V003", "Corvane Logistik GmbH", "900000103", "6633", "EUR", "COMMA", "DMY", "NET 30", 0.19),
    ("SYN-V004", "Duskfield Components Ltd", "900000104", "7744", "GBP", "DOT", "DMY", "NET 60", 0.20),
    ("SYN-V005", "Emberline Software Corp", "900000105", "8855", "USD", "DOT", "ISO", "2/10 NET 30", 0.0725),
    ("SYN-V006", "Fennick Industrial SARL", "900000106", "9966", "EUR", "COMMA", "DMY", "NET 30", 0.20),
    ("SYN-V007", "Glenmora Printing Co", "900000107", "1077", "USD", "DOT", "MDY", "NET 30", 0.0725),
]

ITEMS = [
    "Paper, A4, 80gsm (box)", "Toner cartridge, black", "Pallet freight", "Annual support subscription",
    "Janitorial service, monthly", "Bearing assembly 40mm", "Brochure print run", "Installation labor",
    "Spare parts kit", "Onsite visit", "Rush handling fee", "Packaging", "Safety gloves (pack of 50)",
    "Network switch, 24-port", "Cable, Cat6, 305m reel", "Consulting hours",
]

POLICIES = [
    ("SYN-POL-700101", "Ines Marrow", dt.date(2026, 1, 1), dt.date(2026, 12, 31), "ACTIVE"),
    ("SYN-POL-700102", "Bastian Quillon", dt.date(2025, 7, 1), dt.date(2026, 6, 30), "ACTIVE"),
    ("SYN-POL-700103", "Wren Tessaro", dt.date(2025, 1, 1), dt.date(2025, 12, 31), "LAPSED"),
]

LOSS_TYPES = ["Water damage - burst pipe", "Theft - bicycle from garage", "Storm damage - roof tiles",
              "Kitchen fire - stovetop", "Vehicle collision - parked car"]

STAMPS = ["RECEIVED", "PAID", "COPY", "SCANNED", "APPROVED"]

BUYER = "SYN Demo Buyer Co"

# Purchase orders created while generating invoices; written to po_reference.csv.
PO_REFERENCE: list[dict] = []


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class FieldTruth:
    field_name: str
    expected_value: str | None      # canonical form; None => NOT_PRESENT
    posts: bool

    @property
    def status(self) -> str:
        return "NOT_PRESENT" if self.expected_value is None else "PRESENT"


@dataclass
class DocTruth:
    document_id: str
    document_type: str
    expected_decision: str
    expected_reason: str | None
    title: str
    fields: list[FieldTruth] = field(default_factory=list)
    # Render payload: header key/value pairs, an optional line table, footer lines.
    header: list[tuple[str, str]] = field(default_factory=list)
    table: list[list[str]] | None = None
    footer: list[str] = field(default_factory=list)
    body: list[str] = field(default_factory=list)
    form_style: bool = False        # boxed fields instead of free layout
    late_fields: set = field(default_factory=set)   # fields that print after page 1
    case_role: str = "GENERATED"


@dataclass
class ManifestRow:
    document_id: str
    file_name: str
    document_type: str
    render_kind: str
    degradation_severity: float
    stamp: str
    rotation_deg: float
    page_count: int
    channel: str
    corpus_source: str


# ---------------------------------------------------------------------------
# Locale printers. These MUST agree with the canonical forms in the key,
# and with the normalizers in extract-document-fields.
# ---------------------------------------------------------------------------

def money(x: float, locale: str) -> str:
    s = f"{abs(x):,.2f}"
    if locale == "COMMA":
        s = s.replace(",", "~").replace(".", ",").replace("~", ".")
    return f"({s})" if x < 0 else s


def canon_money(x: float) -> str:
    return f"{x:.2f}"


def date_print(d: dt.date, locale: str) -> str:
    if locale == "MDY":
        return d.strftime("%m/%d/%Y")
    if locale == "DMY":
        return d.strftime("%d.%m.%Y")
    return d.isoformat()


def tax_id_print(digits: str) -> str:
    return f"{digits[:2]}-{digits[2:]}"


def doc_number(style: int, n: int) -> str:
    return [f"INV-{10000 + n:06d}", f"{10000 + n:07d}", f"A{10000 + n}", f"#{10000 + n}"][style % 4]


# ---------------------------------------------------------------------------
# Generators. Each returns a DocTruth whose fields are the answer key and
# whose render payload prints exactly those values in the vendor's locale.
# ---------------------------------------------------------------------------

def gen_invoice(n: int, rng: random.Random, base_date: dt.date) -> DocTruth:
    vid, vname, tax, last4, cur, nloc, dloc, terms, rate = rng.choice(VENDORS)
    inv_no = doc_number(n, n)
    inv_date = base_date - dt.timedelta(days=rng.randint(3, 120))
    net = {"NET 45": 45, "NET 60": 60}.get(terms, 30)
    due = inv_date + dt.timedelta(days=net)
    has_po = rng.random() < 0.7
    po = f"45{rng.randint(10000, 99999)}" if has_po else None

    # Line count varies so some tables span a page break on long invoices.
    n_lines = rng.choices([1, 2, 3, 5, 9, 18], weights=[20, 30, 25, 12, 8, 5])[0]
    lines, subtotal = [], 0.0
    for _ in range(n_lines):
        q = rng.randint(1, 40)
        u = round(rng.uniform(4.0, 900.0), 2)
        amt = round(q * u, 2)
        subtotal = round(subtotal + amt, 2)
        lines.append([rng.choice(ITEMS), str(q), money(u, nloc), money(amt, nloc)])
    tax_amt = round(subtotal * rate, 2)
    total = round(subtotal + tax_amt, 2)

    header = [
        ("Invoice No", inv_no),
        ("Invoice Date", date_print(inv_date, dloc)),
        ("Due Date", date_print(due, dloc)),
    ]
    if po:
        header.append(("PO Number", po))
    header += [("Terms", terms), ("Bill To", f"{BUYER}, Accounts Payable")]

    footer = [
        f"Subtotal: {money(subtotal, nloc)}",
        f"Tax ({rate * 100:.2f}%): {money(tax_amt, nloc)}",
        f"TOTAL DUE ({cur}): {money(total, nloc)}",
        f"Remit to account ending {last4}",
    ]

    t = DocTruth(
        document_id=f"SYN-RDOC-{n:06d}", document_type="invoice",
        expected_decision="AUTO_APPROVED", expected_reason=None,
        title=f"INVOICE\n{vname}\nTax ID: {tax_id_print(tax)}",
        header=header, table=[["Description", "Qty", "Unit Price", "Amount"]] + lines, footer=footer,
    )
    t.fields = [
        FieldTruth("invoice_number", inv_no, True),
        FieldTruth("invoice_date", inv_date.isoformat(), True),
        FieldTruth("due_date", due.isoformat(), True),
        FieldTruth("vendor_name", vname, True),
        FieldTruth("vendor_tax_id", tax_id_print(tax), False),
        FieldTruth("po_number", po, True),
        FieldTruth("currency", cur, True),
        FieldTruth("subtotal_amount", canon_money(subtotal), False),
        FieldTruth("tax_amount", canon_money(tax_amt), True),
        FieldTruth("total_amount", canon_money(total), True),
        FieldTruth("payment_terms", terms, False),
        FieldTruth("remit_account_last4", last4, False),
    ]
    # Register the PO so validation can find it: written to po_reference.csv
    # and loaded next to the corpus. Amount equals the invoice total, so a
    # correct extraction passes PO_AMOUNT_TOLERANCE.
    if po:
        PO_REFERENCE.append({"po_number": f"00{po}", "vendor_id": vid, "po_amount": canon_money(total),
                             "open_amount": canon_money(total), "currency": cur, "status": "OPEN"})
    # Fields printed after page 1 (the totals block on long invoices) are
    # recorded so a PHOTO render, which captures page 1 only, can mark them
    # NOT_PRESENT for that file.
    t.late_fields = {"subtotal_amount", "tax_amount", "total_amount", "remit_account_last4"} if n_lines >= 18 else set()
    return t


def gen_credit_note(n: int, rng: random.Random, base_date: dt.date) -> DocTruth:
    vid, vname, tax, last4, cur, nloc, dloc, terms, rate = rng.choice(VENDORS)
    cn = f"CN-{rng.randint(100, 9999):04d}"
    ref = doc_number(rng.randint(0, 3), rng.randint(0, 900))
    d = base_date - dt.timedelta(days=rng.randint(1, 60))
    amt = -round(rng.uniform(20, 2500), 2)
    t = DocTruth(
        document_id=f"SYN-RDOC-{n:06d}", document_type="credit_note",
        expected_decision="AUTO_APPROVED", expected_reason=None,
        title=f"CREDIT NOTE\n{vname}\nTax ID: {tax_id_print(tax)}",
        header=[("Credit Note No", cn), ("References Invoice", ref), ("Date", date_print(d, dloc))],
        table=[["Description", "Amount"], ["Service credit", money(amt, nloc)]],
        footer=[f"TOTAL CREDIT ({cur}): {money(amt, nloc)}",
                "This credit will be applied to your next invoice."],
    )
    t.fields = [
        FieldTruth("credit_note_number", cn, True),
        FieldTruth("referenced_invoice_number", ref, True),
        FieldTruth("issue_date", d.isoformat(), True),
        FieldTruth("vendor_name", vname, True),
        FieldTruth("currency", cur, True),
        FieldTruth("total_amount", canon_money(amt), True),
    ]
    return t


def gen_claim(n: int, rng: random.Random, base_date: dt.date) -> DocTruth:
    pol, holder, eff, exp, status = rng.choice(POLICIES)
    loss = base_date - dt.timedelta(days=rng.randint(2, 200))
    covered = status == "ACTIVE" and eff <= loss <= exp
    amt = round(rng.uniform(300, 25000), 2)
    loss_type = rng.choice(LOSS_TYPES)
    report = f"SYN-PR-{rng.randint(10000, 99999)}" if loss_type.startswith(("Theft", "Vehicle")) else None
    t = DocTruth(
        document_id=f"SYN-RDOC-{n:06d}", document_type="insurance_claim_form",
        expected_decision="AUTO_APPROVED" if covered else "EXCEPTION",
        expected_reason=None if covered else "POLICY_COVERS_LOSS",
        title="PROPERTY LOSS NOTICE - CLAIM FORM", form_style=True,
        header=[
            ("Policy Number", pol), ("Policyholder Name", holder),
            ("Date of Loss", date_print(loss, "MDY")), ("Type of Loss", loss_type),
            ("Loss Location", f"{rng.randint(1, 99)} Synthetic Lane"),
            ("Estimated Loss Amount (USD)", money(amt, "DOT")),
            ("Police/Fire Report Number", report or "N/A"),
            ("Claimant Signature", "on file"),
        ],
        body=["Describe the loss: see adjuster notes. Claimant states the loss was discovered the same day."],
    )
    t.fields = [
        FieldTruth("policy_number", pol, True),
        FieldTruth("policyholder_name", holder, False),
        FieldTruth("loss_date", loss.isoformat(), True),
        FieldTruth("loss_type", loss_type, False),
        FieldTruth("estimated_loss_amount", canon_money(amt), True),
        FieldTruth("police_report_number", report, False),
    ]
    return t


def gen_contract(n: int, rng: random.Random, base_date: dt.date) -> DocTruth:
    _, vname, *_ = rng.choice(VENDORS)
    eff = base_date - dt.timedelta(days=rng.randint(10, 400))
    term = rng.choice([12, 24, 36, 60])
    notice = rng.choice([30, 60, 90])
    auto = rng.random() < 0.6
    fee = float(rng.choice([24000, 60000, 120000, 250000]))
    cap = fee * rng.choice([1, 2])
    law = rng.choice(["Delaware", "New York", "England and Wales"])
    words = {12: "twelve", 24: "twenty-four", 36: "thirty-six", 60: "sixty"}
    nwords = {30: "thirty", 60: "sixty", 90: "ninety"}
    renewal = (f"and renews automatically for successive twelve (12) month periods unless either party "
               f"gives written notice of non-renewal at least {nwords[notice]} ({notice}) days before the "
               f"end of the then-current term." if auto else
               f"and does not renew automatically. Either party may terminate on {nwords[notice]} "
               f"({notice}) days written notice.")
    body = [
        f'This Master Services Agreement (the "Agreement") is entered into as of '
        f'{eff.strftime("%B")} {eff.day}, {eff.year} (the "Effective Date") by and between {BUYER} '
        f'("Customer") and {vname} ("Provider").',
        f"1. TERM. The initial term is {words[term]} ({term}) months from the Effective Date {renewal}",
        f"2. FEES. Customer shall pay annual fees of USD {money(fee, 'DOT')}, invoiced annually in advance.",
        f"3. LIMITATION OF LIABILITY. Each party's aggregate liability shall not exceed USD {money(cap, 'DOT')}.",
        "4. CONFIDENTIALITY. Each party shall protect the other's confidential information with reasonable care.",
        f"5. GOVERNING LAW. This Agreement is governed by the laws of {law}.",
    ]
    # Pad with boilerplate so contracts are multi-page and the key terms are
    # NOT all on page one -- page-1-only extraction must visibly fail.
    filler = ("GENERAL. This section is standard boilerplate covering notices, assignment, force majeure, "
              "severability, waiver, counterparts, audit rights, insurance, subcontracting, publicity, "
              "non-solicitation and entire agreement. ") * 8
    body = body[:2] + [f"{i + 6}. {filler}" for i in range(rng.randint(5, 9))] + body[2:]
    t = DocTruth(
        document_id=f"SYN-RDOC-{n:06d}", document_type="contract",
        expected_decision="AUTO_APPROVED", expected_reason=None,
        title="MASTER SERVICES AGREEMENT", body=body,
        footer=["Signed for Customer: ______    Signed for Provider: ______"],
    )
    t.fields = [
        FieldTruth("counterparty_name", vname, True),
        FieldTruth("effective_date", eff.isoformat(), True),
        FieldTruth("initial_term_months", str(term), True),
        FieldTruth("auto_renewal", "YES" if auto else "NO", True),
        FieldTruth("notice_period_days", str(notice), True),
        FieldTruth("annual_fee_amount", canon_money(fee), True),
        FieldTruth("liability_cap_amount", canon_money(cap), True),
        FieldTruth("governing_law", law, False),
        FieldTruth("currency", "USD", True),
    ]
    return t


def gen_w9(n: int, rng: random.Random, base_date: dt.date) -> DocTruth:
    _, vname, tax, *_ = rng.choice(VENDORS)
    cls = rng.choice(["C Corporation", "S Corporation", "Limited liability company"])
    t = DocTruth(
        document_id=f"SYN-RDOC-{n:06d}", document_type="w9_tax_form",
        expected_decision="AUTO_APPROVED", expected_reason=None,
        title="Form W-9 (SYNTHETIC SAMPLE)\nRequest for Taxpayer Identification Number and Certification",
        form_style=True,
        header=[("1 Name", vname), ("2 Business name", vname), ("3 Federal tax classification", cls),
                ("5 Address", f"{rng.randint(1, 99)} Synthetic Ave"), ("6 City, state, ZIP", "Exampleton, ZZ 00000"),
                ("Employer identification number", tax_id_print(tax)),
                ("Date", date_print(base_date - dt.timedelta(days=rng.randint(1, 300)), "MDY"))],
    )
    t.fields = [
        FieldTruth("legal_name", vname, True),
        FieldTruth("tin", tax_id_print(tax), True),
        FieldTruth("tax_classification", cls, False),
    ]
    return t


def gen_other(n: int, rng: random.Random, base_date: dt.date) -> DocTruth:
    _, vname, *_ = rng.choice(VENDORS)
    kind = rng.choice(["newsletter", "statement", "marketing"])
    body = {
        "newsletter": [f"{vname.upper()} - QUARTERLY NEWSLETTER",
                       "Our team is growing and we expanded weekend coverage. No action is required."],
        "statement": [f"{vname} - ACCOUNT STATEMENT (for information only, not an invoice)",
                      "Open items are listed on your portal. Please do not pay from this statement."],
        "marketing": [f"{vname} - SPECIAL OFFER",
                      "Order before month end for a 10 percent loyalty discount on selected items."],
    }[kind]
    # An account statement contains amounts and dates and is the classic thing
    # an invoice-only pipeline wrongly posts. It must be REJECTED, not extracted.
    return DocTruth(
        document_id=f"SYN-RDOC-{n:06d}", document_type="other_document",
        expected_decision="REJECTED", expected_reason="OUT_OF_SCOPE",
        title=body[0], body=body[1:],
    )


GENERATORS = {
    "invoice": gen_invoice, "credit_note": gen_credit_note, "insurance_claim_form": gen_claim,
    "contract": gen_contract, "w9_tax_form": gen_w9, "other_document": gen_other,
}


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def render_pdf(doc: DocTruth, path: Path, stamp: str = "") -> int:
    """Digital-born PDF with a real text layer and real table structure."""
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import LETTER
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.units import inch
    from reportlab.platypus import (SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle)

    ss = getSampleStyleSheet()
    body = ParagraphStyle("b", parent=ss["BodyText"], fontName="Helvetica", fontSize=9.5, leading=12.5)
    head = ParagraphStyle("h", parent=ss["Heading3"], fontName="Helvetica-Bold", spaceAfter=4)
    small = ParagraphStyle("s", parent=body, fontSize=8.5, leading=11)

    flow = []
    for i, line in enumerate(doc.title.split("\n")):
        flow.append(Paragraph(_esc(line), head if i == 0 else body))
    flow.append(Spacer(1, 10))

    if doc.header:
        if doc.form_style:
            rows = [[Paragraph(f"<b>{_esc(k)}</b>", small), Paragraph(_esc(v), body)] for k, v in doc.header]
            tbl = Table(rows, colWidths=[2.3 * inch, 4.3 * inch])
            tbl.setStyle(TableStyle([
                ("BOX", (0, 0), (-1, -1), 0.6, colors.black),
                ("INNERGRID", (0, 0), (-1, -1), 0.4, colors.grey),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ]))
            flow.append(tbl)
        else:
            for k, v in doc.header:
                flow.append(Paragraph(f"<b>{_esc(k)}:</b> {_esc(v)}", body))
        flow.append(Spacer(1, 10))

    if doc.table:
        widths = [3.4 * inch] + [1.0 * inch] * (len(doc.table[0]) - 1)
        tbl = Table(doc.table, colWidths=widths, repeatRows=1)
        tbl.setStyle(TableStyle([
            ("FONT", (0, 0), (-1, 0), "Helvetica-Bold", 9),
            ("FONT", (0, 1), (-1, -1), "Helvetica", 9),
            ("LINEBELOW", (0, 0), (-1, 0), 0.8, colors.black),
            ("ALIGN", (1, 0), (-1, -1), "RIGHT"),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.whitesmoke]),
        ]))
        flow.append(tbl)
        flow.append(Spacer(1, 10))

    for para in doc.body:
        flow.append(Paragraph(_esc(para), body))
        flow.append(Spacer(1, 6))
    for line in doc.footer:
        flow.append(Paragraph(_esc(line), body))

    def _stamp(canvas, _doc):
        if not stamp:
            return
        canvas.saveState()
        canvas.setFont("Helvetica-Bold", 34)
        canvas.setFillColorRGB(0.75, 0.1, 0.1, alpha=0.35)
        canvas.translate(4.6 * inch, 7.6 * inch)
        canvas.rotate(18)
        canvas.drawCentredString(0, 0, stamp)
        canvas.restoreState()

    SimpleDocTemplate(str(path), pagesize=LETTER, leftMargin=0.8 * inch, rightMargin=0.8 * inch,
                      topMargin=0.7 * inch, bottomMargin=0.7 * inch,
                      title=doc.title.split("\n")[0]).build(flow, onFirstPage=_stamp)
    return _pages(path)


def rasterize(pdf_path: Path, out_path: Path, severity: float, rotation: float, rng: random.Random) -> int:
    """
    Image-only PDF, so AI_PARSE_DOCUMENT / AI_EXTRACT must OCR it.
    severity 0.0 = clean 300 DPI scan; 1.0 = poor fax.

    Approximates fax/photocopy degradation. Does NOT reproduce handwriting,
    torn pages, coffee stains, or a specific scanner fleet.
    """
    fitz = _fitz()
    import numpy as np
    from PIL import Image, ImageEnhance, ImageFilter

    dpi = int(round(300 - 200 * severity))
    noise = 28 * severity
    jpeg_q = max(30, int(round(95 - 60 * severity)))

    pages = []
    with fitz.open(str(pdf_path)) as src:
        for page in src:
            pix = page.get_pixmap(dpi=dpi, colorspace=fitz.csGRAY)
            img = Image.frombytes("L", (pix.width, pix.height), pix.samples)
            if abs(rotation) > 0.05:
                img = img.rotate(rotation, resample=Image.BICUBIC, expand=False, fillcolor=255)
            if severity >= 0.4:
                img = img.filter(ImageFilter.GaussianBlur(radius=0.3 + 0.6 * severity))
            if noise > 0:
                a = np.asarray(img).astype(np.float32)
                a += np.random.default_rng(rng.randint(0, 2**31)).normal(0.0, noise, a.shape)
                img = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), mode="L")
            if severity >= 0.6:
                img = ImageEnhance.Contrast(img).enhance(1.0 - 0.3 * severity)
            if severity >= 0.8:
                # Fax-style thresholding: the transform most likely to merge a
                # decimal point into an adjacent digit.
                img = img.point(lambda p: 255 if p > 150 else 0)
            buf = io.BytesIO()
            img.convert("L").save(buf, format="JPEG", quality=jpeg_q)
            pages.append(buf.getvalue())

    out = fitz.open()
    for data in pages:
        with fitz.open("jpeg", data) as im:
            rect = im[0].rect
        pg = out.new_page(width=rect.width, height=rect.height)
        pg.insert_image(rect, stream=data)
    out.save(str(out_path), deflate=True)
    n = out.page_count
    out.close()
    return n


def photograph(pdf_path: Path, out_path: Path, rng: random.Random) -> int:
    """First page as a phone photo: perspective tilt and uneven lighting. One image = one billed page."""
    fitz = _fitz()
    import numpy as np
    from PIL import Image

    with fitz.open(str(pdf_path)) as src:
        pix = src[0].get_pixmap(dpi=170)
        img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
    w, h = img.size
    d = int(0.04 * w)
    # Perspective via quad transform: shrink one edge.
    quad = (rng.randint(0, d), 0, 0, h, w, h - rng.randint(0, d), w - rng.randint(0, d), rng.randint(0, d))
    img = img.transform((w, h), Image.QUAD, quad, resample=Image.BICUBIC, fillcolor=(235, 235, 230))
    a = np.asarray(img).astype(np.float32)
    grad = np.linspace(0.78, 1.05, w)[None, :, None]
    a = np.clip(a * grad, 0, 255).astype(np.uint8)
    Image.fromarray(a).save(str(out_path), format="JPEG", quality=82)
    return 1


def concat_pdfs(paths: list[Path], out_path: Path) -> int:
    fitz = _fitz()
    out = fitz.open()
    for p in paths:
        with fitz.open(str(p)) as src:
            out.insert_pdf(src)
    out.save(str(out_path))
    n = out.page_count
    out.close()
    return n


def packing_slip(ref: str) -> DocTruth:
    return DocTruth(document_id="", document_type="packing_slip", expected_decision="", expected_reason=None,
                    title="PACKING SLIP",
                    header=[("Ship To", f"{BUYER}, Receiving Dock 2"), ("Order Ref", ref),
                            ("Carrier", "SYN Freight"), ("Received by", "____________")])


def _fitz():
    """PyMuPDF under its current module name, falling back to the legacy alias."""
    try:
        import pymupdf
        return pymupdf
    except ImportError:  # older PyMuPDF releases
        import fitz
        return fitz


def _pages(path: Path) -> int:
    fitz = _fitz()
    with fitz.open(str(path)) as d:
        return d.page_count


# ---------------------------------------------------------------------------
# Sandbox import
# ---------------------------------------------------------------------------

def load_sandbox(src: Path) -> list[DocTruth]:
    """
    Read SYN_DOCUMENTS.csv, SYN_FIELD_ANSWER_KEY.csv and SYN_DOC_ANSWER_KEY.csv
    exported from the sandbox (column names as in 01_seed_sandbox.sql, any
    case). Renders document_text as-is, so the sandbox key applies unchanged.
    """
    def rd(name):
        with open(src / name, newline="", encoding="utf-8-sig") as fh:
            return [{k.lower(): v for k, v in r.items()} for r in csv.DictReader(fh)]

    docs = {r["document_id"]: r for r in rd("SYN_DOCUMENTS.csv")}
    dkey = {r["document_id"]: r for r in rd("SYN_DOC_ANSWER_KEY.csv")}
    fkey: dict[str, list[FieldTruth]] = {}
    for r in rd("SYN_FIELD_ANSWER_KEY.csv"):
        val = r.get("expected_value") or None
        if (r.get("expected_status") or "").upper() == "NOT_PRESENT":
            val = None
        fkey.setdefault(r["document_id"], []).append(
            FieldTruth(r["field_name"], val, (r.get("posts") or "").lower() in ("true", "1", "yes")))

    out = []
    for did, d in docs.items():
        text = (d.get("document_text") or "").replace("\\n", "\n").replace("\\f", "\f")
        parts = text.split("\n")
        k = dkey.get(did, {})
        out.append(DocTruth(
            document_id=did, document_type=k.get("expected_type", "unknown"),
            expected_decision=k.get("expected_decision", ""), expected_reason=k.get("expected_reason") or None,
            title=parts[0] if parts else did, body=[p for p in parts[1:] if p.strip()],
            fields=fkey.get(did, []),
            case_role=k.get("case_role") or "SANDBOX",
        ))
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--generate", type=int, help="number of synthetic documents to generate")
    g.add_argument("--from-sandbox", type=Path, help="directory of sandbox CSV exports")
    ap.add_argument("--outdir", type=Path, required=True)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--base-date", default="2026-10-15", help="anchor date for generated documents")
    ap.add_argument("--corpus-source", default="SYNTHETIC_RENDERED")
    ap.add_argument("--stamp-rate", type=float, default=0.15, help="share of docs with a PAID/RECEIVED stamp")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    base = dt.date.fromisoformat(args.base_date)
    files = args.outdir / "files"
    files.mkdir(parents=True, exist_ok=True)
    work = args.outdir / ".work"
    work.mkdir(exist_ok=True)

    if args.generate:
        types, weights = zip(*TYPE_MIX.items())
        docs = [GENERATORS[rng.choices(types, weights)[0]](i + 1, rng, base) for i in range(args.generate)]
    else:
        docs = load_sandbox(args.from_sandbox)

    kinds, kweights = zip(*DEFAULT_MIX.items())
    manifest: list[ManifestRow] = []
    failed = 0

    for d in docs:
        kind = rng.choices(kinds, kweights)[0]
        # Multi-document files are only meaningful for invoices.
        if kind == "MULTI_DOC" and d.document_type != "invoice":
            kind = "DEGRADED_SCAN"
        stamp = rng.choice(STAMPS) if rng.random() < args.stamp_rate else ""
        sev = 0.0
        rot = 0.0
        safe = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in d.document_id)
        src_pdf = work / f"{safe}.pdf"

        try:
            render_pdf(d, src_pdf, stamp)
            if kind == "DIGITAL_PDF":
                final = files / f"{safe}.pdf"
                src_pdf.replace(final)
                pages = _pages(final)
            elif kind == "CLEAN_SCAN":
                final = files / f"{safe}.pdf"
                rot = rng.uniform(-0.6, 0.6)
                pages = rasterize(src_pdf, final, 0.0, rot, rng)
            elif kind == "DEGRADED_SCAN":
                final = files / f"{safe}.pdf"
                sev = rng.choice(SEVERITY_LADDER)
                rot = rng.uniform(-1.0, 1.0) * 2.5 * sev
                pages = rasterize(src_pdf, final, sev, rot, rng)
            elif kind == "PHOTO":
                final = files / f"{safe}.jpg"
                src_pages = _pages(src_pdf)
                pages = photograph(src_pdf, final, rng)
                # A photo captures page 1 only. Anything printed on later pages is
                # genuinely absent from this FILE: mark those fields NOT_PRESENT so
                # they do not read as extraction misses, and expect an exception,
                # because a required field (the total) is now missing.
                if src_pages > 1:
                    late = d.late_fields or {f.field_name for f in d.fields}
                    if d.document_type == "contract":
                        late = {f.field_name for f in d.fields} - {"counterparty_name", "effective_date"}
                    for f in d.fields:
                        if f.field_name in late:
                            f.expected_value = None
                    d.expected_decision, d.expected_reason = "EXCEPTION", "REQUIRED_FIELD_MISSING"
            else:  # MULTI_DOC
                slip_pdf = work / f"{safe}__slip.pdf"
                inv_no = next((f.expected_value for f in d.fields if f.field_name == "invoice_number"), "")
                render_pdf(packing_slip(inv_no or ""), slip_pdf)
                final = files / f"{safe}.pdf"
                pages = concat_pdfs([src_pdf, slip_pdf], final)
                d.expected_decision, d.expected_reason = "EXCEPTION", "MULTI_DOCUMENT"
        except Exception as exc:  # noqa: BLE001
            print(f"  render failed {d.document_id}: {exc}", file=sys.stderr)
            failed += 1
            continue

        manifest.append(ManifestRow(
            document_id=d.document_id, file_name=final.name, document_type=d.document_type,
            render_kind=kind, degradation_severity=sev, stamp=stamp, rotation_deg=round(rot, 2),
            page_count=pages, channel=rng.choice(["EMAIL", "SCAN", "PORTAL", "SFTP"]),
            corpus_source=args.corpus_source,
        ))

    rendered = {m.document_id for m in manifest}
    with open(args.outdir / "manifest.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(asdict(manifest[0]).keys()))
        w.writeheader()
        for m in manifest:
            w.writerow(asdict(m))

    with open(args.outdir / "field_answer_key.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["document_id", "document_type", "field_name", "expected_value", "expected_status", "posts"])
        for d in docs:
            if d.document_id in rendered:
                for f in d.fields:
                    w.writerow([d.document_id, d.document_type, f.field_name,
                                f.expected_value if f.expected_value is not None else "", f.status, f.posts])

    with open(args.outdir / "doc_answer_key.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["document_id", "expected_type", "expected_decision", "expected_reason", "case_role", "note"])
        for d in docs:
            if d.document_id in rendered:
                w.writerow([d.document_id, d.document_type, d.expected_decision, d.expected_reason or "",
                            d.case_role, ""])

    # Reference data the validation rules join to. Load these with the corpus so
    # rendered documents validate the same way sandbox documents do.
    with open(args.outdir / "vendor_reference.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["vendor_id", "vendor_name", "tax_id", "bank_last4", "default_currency",
                    "number_locale", "date_locale", "payment_terms", "status"])
        for v in VENDORS:
            w.writerow([v[0], v[1], v[2], v[3], v[4],
                        "COMMA_DECIMAL" if v[5] == "COMMA" else "DOT_DECIMAL", v[6], v[7], "ACTIVE"])
    with open(args.outdir / "po_reference.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["po_number", "vendor_id", "po_amount", "open_amount", "currency", "status"])
        w.writeheader()
        w.writerows(PO_REFERENCE)
    # Contracts are generated with these vendors as counterparties.
    with open(args.outdir / "counterparty_reference.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["counterparty_id", "legal_name"])
        for v in VENDORS:
            w.writerow([v[0].replace("SYN-V", "SYN-CPV"), v[1]])
    with open(args.outdir / "policy_reference.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["policy_number", "policyholder", "effective_date", "expiry_date", "status"])
        for pnum, holder, eff, exp, st in POLICIES:
            w.writerow([pnum, holder, eff.isoformat(), exp.isoformat(), st])

    for p in work.glob("*"):
        p.unlink()
    work.rmdir()

    total_pages = sum(m.page_count for m in manifest)
    ocr_pages = sum(m.page_count for m in manifest if m.render_kind != "DIGITAL_PDF")
    print(f"\nRendered {len(manifest)} documents ({failed} failed) -> {files}")
    print("\nBy kind:")
    for k in DEFAULT_MIX:
        sel = [m for m in manifest if m.render_kind == k]
        if sel:
            print(f"  {k:<14} {len(sel):>5}  {sum(m.page_count for m in sel):>6} pages")
    print("\nBy type:")
    for t in sorted({m.document_type for m in manifest}):
        print(f"  {t:<22} {sum(1 for m in manifest if m.document_type == t):>5}")
    print(f"\nTotal pages: {total_pages}   image-only (OCR) pages: {ocr_pages}")
    print("AI_PARSE_DOCUMENT bills per page; file-based AI_EXTRACT bills ~970 tokens per page")
    print("(x scale_factor). Validate on a sample before scaling. Report pages and tokens, never dollars.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

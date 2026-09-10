# -*- coding: utf-8 -*-
"""从 content.py 生成 PPT（.pptx）和 Word（.docx）两份文件。

用法：
    pip install python-pptx python-docx
    python build_guide.py            # 输出到当前目录
"""
import math
import os
import sys

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Pt as DPt, RGBColor as DRGB, Cm
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.util import Inches, Pt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from content import SLIDES, SUBTITLE, TITLE  # noqa: E402

FONT = "微软雅黑"
NAVY = RGBColor(0x1F, 0x2A, 0x44)
ACCENT = RGBColor(0xE8, 0x7A, 0x1E)
GRAY_BG = RGBColor(0xF3, 0xF4, 0xF6)
GRAY_TXT = RGBColor(0x6B, 0x72, 0x80)
DARK = RGBColor(0x22, 0x22, 0x22)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
HEADER_BG = RGBColor(0x2F, 0x3E, 0x5C)
ROW_ALT = RGBColor(0xF8, 0xF9, 0xFB)

SLIDE_W, SLIDE_H = 13.333, 7.5
MARGIN = 0.5
BODY_TOP = 1.25
BODY_BOTTOM = 7.0
BODY_W = SLIDE_W - 2 * MARGIN


# ----------------------------------------------------------------- 估算工具
def _lines(text, font_pt, width_in):
    """粗估一段中文在给定宽度下占几行（中文按 1em 宽计）。"""
    per_line = max(8, int(width_in * 72 / (font_pt * 1.02)))
    total = 0
    for seg in text.split("\n"):
        total += max(1, math.ceil(len(seg) / per_line))
    return total


def _bullets_height(items, font_pt):
    h = 0.0
    for it in items:
        text, level = (it, 0) if isinstance(it, str) else it
        width = BODY_W - 0.3 - 0.4 * level
        h += _lines(text, font_pt, width) * font_pt * 1.35 / 72 + 0.06
    return h + 0.1


def _table_widths(rows):
    ncol = len(rows[0])
    maxlen = [1] * ncol
    for r in rows:
        for i, c in enumerate(r):
            maxlen[i] = max(maxlen[i], min(len(c), 60))
    weights = [max(11, m) for m in maxlen]
    total = sum(weights)
    return [BODY_W * w / total for w in weights]


def _table_height(rows, font_pt):
    widths = _table_widths(rows)
    h = 0.0
    for r in rows:
        lines = max(_lines(c, font_pt * 1.1, w - 0.2) for c, w in zip(r, widths))
        h += lines * font_pt * 1.32 / 72 + 0.14
    return h + 0.1


def _box_height(text, font_pt):
    return _lines(text, font_pt, BODY_W - 0.4) * font_pt * 1.4 / 72 + 0.3 + 0.1


def _note_height(text, font_pt):
    return _lines(text, font_pt, BODY_W) * font_pt * 1.3 / 72 + 0.1


BASE = {"bullets": 16, "table": 12.5, "box": 13, "note": 11}
CAP = {"bullets": 20, "table": 15, "box": 15.5, "note": 12.5}


def _pt(kind, scale):
    return min(BASE[kind] * scale, CAP[kind])


def _total_height(body, scale):
    h = 0.0
    for kind, payload in body:
        pt = _pt(kind, scale)
        if kind == "bullets":
            h += _bullets_height(payload, pt)
        elif kind == "table":
            h += _table_height(payload, pt)
        elif kind == "box":
            h += _box_height(payload, pt)
        elif kind == "note":
            h += _note_height(payload, pt)
    return h


def _fit_scale(body):
    avail = BODY_BOTTOM - BODY_TOP
    scale = 1.3
    while scale > 0.62 and _total_height(body, scale) > avail:
        scale -= 0.03
    return scale


# ----------------------------------------------------------------- PPT 绘制
def _set_font(run, size, bold=False, color=DARK, italic=False):
    run.font.name = FONT
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.italic = italic
    run.font.color.rgb = color
    rpr = run._r.get_or_add_rPr()
    ea = rpr.find(qn("a:ea"))
    if ea is None:
        ea = OxmlElement("a:ea")
        rpr.append(ea)
    ea.set("typeface", FONT)


def _rect(slide, x, y, w, h, fill, shape=MSO_SHAPE.RECTANGLE):
    shp = slide.shapes.add_shape(shape, Inches(x), Inches(y), Inches(w), Inches(h))
    shp.fill.solid()
    shp.fill.fore_color.rgb = fill
    shp.line.fill.background()
    shp.shadow.inherit = False
    return shp


def _textbox(slide, x, y, w, h):
    tb = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = Inches(0.05)
    tf.margin_top = tf.margin_bottom = Inches(0.03)
    return tf


def draw_cover(prs):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    _rect(slide, 0, 0, SLIDE_W, SLIDE_H, NAVY)
    _rect(slide, MARGIN, 3.9, 1.6, 0.08, ACCENT)
    tf = _textbox(slide, MARGIN, 2.2, BODY_W, 1.6)
    p = tf.paragraphs[0]
    _set_font(p.add_run(), 34, True, WHITE)
    p.runs[0].text = TITLE
    tf2 = _textbox(slide, MARGIN, 4.15, BODY_W, 1.2)
    p2 = tf2.paragraphs[0]
    r2 = p2.add_run()
    r2.text = SUBTITLE
    _set_font(r2, 16, False, RGBColor(0xC9, 0xD1, 0xE0))
    tf3 = _textbox(slide, MARGIN, 6.6, BODY_W, 0.5)
    r3 = tf3.paragraphs[0].add_run()
    r3.text = "内部培训资料 · 汽车零部件工厂仓库 · 2026-09"
    _set_font(r3, 11, False, RGBColor(0x9A, 0xA5, 0xB8))


def draw_chapter_divider(prs, chapter):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    _rect(slide, 0, 0, SLIDE_W, SLIDE_H, NAVY)
    _rect(slide, MARGIN, 4.1, 1.2, 0.08, ACCENT)
    tf = _textbox(slide, MARGIN, 2.8, BODY_W, 1.3)
    r = tf.paragraphs[0].add_run()
    r.text = chapter
    _set_font(r, 32, True, WHITE)


def draw_slide(prs, spec, chapter_label, page_no):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    # 标题栏
    _rect(slide, 0, 0, SLIDE_W, 1.0, NAVY)
    _rect(slide, 0, 1.0, SLIDE_W, 0.05, ACCENT)
    tf = _textbox(slide, MARGIN, 0.12, BODY_W, 0.8)
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    r = tf.paragraphs[0].add_run()
    r.text = spec["title"]
    title_pt = 22 if len(spec["title"]) <= 30 else 18
    _set_font(r, title_pt, True, WHITE)
    # 页脚
    ft = _textbox(slide, MARGIN, 7.08, BODY_W - 1.0, 0.3)
    rf = ft.paragraphs[0].add_run()
    rf.text = chapter_label or ""
    _set_font(rf, 9.5, False, GRAY_TXT)
    pn = _textbox(slide, SLIDE_W - MARGIN - 1.0, 7.08, 1.0, 0.3)
    pn.paragraphs[0].alignment = PP_ALIGN.RIGHT
    rp = pn.paragraphs[0].add_run()
    rp.text = str(page_no)
    _set_font(rp, 9.5, False, GRAY_TXT)

    body = spec["body"]
    scale = _fit_scale(body)
    y = BODY_TOP
    for kind, payload in body:
        pt = _pt(kind, scale)
        if kind == "bullets":
            h = _bullets_height(payload, pt)
            tfb = _textbox(slide, MARGIN, y, BODY_W, h)
            first = True
            for it in payload:
                text, level = (it, 0) if isinstance(it, str) else it
                p = tfb.paragraphs[0] if first else tfb.add_paragraph()
                first = False
                p.level = level
                p.space_after = Pt(4)
                bullet = "•  " if level == 0 else "–  "
                run = p.add_run()
                run.text = bullet + text
                _set_font(run, pt if level == 0 else pt - 1, False,
                          DARK if level == 0 else RGBColor(0x37, 0x41, 0x51))
                if level:
                    pPr = p._p.get_or_add_pPr()
                    pPr.set("marL", str(int(Inches(0.4 * level))))
            y += h
        elif kind == "table":
            h = _table_height(payload, pt)
            rows, cols = len(payload), len(payload[0])
            widths = _table_widths(payload)
            gt = slide.shapes.add_table(rows, cols, Inches(MARGIN), Inches(y),
                                        Inches(BODY_W), Inches(h)).table
            for i, w in enumerate(widths):
                gt.columns[i].width = Inches(w)
            for ri, row in enumerate(payload):
                for ci, val in enumerate(row):
                    cell = gt.cell(ri, ci)
                    cell.margin_left = cell.margin_right = Inches(0.07)
                    cell.margin_top = cell.margin_bottom = Inches(0.04)
                    cell.fill.solid()
                    if ri == 0:
                        cell.fill.fore_color.rgb = HEADER_BG
                    else:
                        cell.fill.fore_color.rgb = ROW_ALT if ri % 2 == 0 else WHITE
                    ctf = cell.text_frame
                    ctf.word_wrap = True
                    run = ctf.paragraphs[0].add_run()
                    run.text = val
                    if ri == 0:
                        _set_font(run, pt, True, WHITE)
                    else:
                        _set_font(run, pt, ci == 0 and cols > 2, DARK)
            y += h
        elif kind == "box":
            h = _box_height(payload, pt)
            shp = _rect(slide, MARGIN, y, BODY_W, h - 0.1, GRAY_BG,
                        MSO_SHAPE.ROUNDED_RECTANGLE)
            shp.adjustments[0] = 0.04
            _rect(slide, MARGIN, y, 0.08, h - 0.1, ACCENT)
            btf = shp.text_frame
            btf.word_wrap = True
            btf.margin_left = Inches(0.25)
            btf.margin_right = Inches(0.15)
            btf.margin_top = btf.margin_bottom = Inches(0.1)
            btf.vertical_anchor = MSO_ANCHOR.TOP
            first = True
            for seg in payload.split("\n"):
                p = btf.paragraphs[0] if first else btf.add_paragraph()
                first = False
                p.alignment = PP_ALIGN.LEFT
                run = p.add_run()
                run.text = seg
                _set_font(run, pt, False, RGBColor(0x1F, 0x29, 0x37))
            y += h
        elif kind == "note":
            h = _note_height(payload, pt)
            ntf = _textbox(slide, MARGIN, y, BODY_W, h)
            run = ntf.paragraphs[0].add_run()
            run.text = "※ " + payload
            _set_font(run, pt, False, GRAY_TXT, italic=True)
            y += h


def build_pptx(path):
    prs = Presentation()
    prs.slide_width = Inches(SLIDE_W)
    prs.slide_height = Inches(SLIDE_H)
    draw_cover(prs)
    page = 1
    current_chapter = None
    for spec in SLIDES:
        if spec.get("chapter"):
            current_chapter = spec["chapter"]
            if spec["chapter"] not in ("附录", "一页速查"):
                page += 1
                draw_chapter_divider(prs, current_chapter)
        page += 1
        draw_slide(prs, spec, current_chapter, page)
    prs.save(path)


# ----------------------------------------------------------------- Word
def _docx_font(run, size=None, bold=None, color=None, italic=None):
    run.font.name = FONT
    run._element.rPr.rFonts.set(qn("w:eastAsia"), FONT)
    if size:
        run.font.size = DPt(size)
    if bold is not None:
        run.font.bold = bold
    if italic is not None:
        run.font.italic = italic
    if color is not None:
        run.font.color.rgb = color


def _shade(paragraph_or_cell, hex_fill):
    pr = paragraph_or_cell._p.get_or_add_pPr() if hasattr(paragraph_or_cell, "_p") \
        else paragraph_or_cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), hex_fill)
    pr.append(shd)


def build_docx(path):
    doc = Document()
    for sec in doc.sections:
        sec.left_margin = sec.right_margin = Cm(2.2)
        sec.top_margin = sec.bottom_margin = Cm(2.0)
    st = doc.styles["Normal"]
    st.font.name = FONT
    st.element.rPr.rFonts.set(qn("w:eastAsia"), FONT)
    st.font.size = DPt(11)
    for name in ("Heading 1", "Heading 2", "Title"):
        s = doc.styles[name]
        s.font.name = FONT
        s.element.rPr.rFonts.set(qn("w:eastAsia"), FONT)
        s.font.color.rgb = DRGB(0x1F, 0x2A, 0x44)

    t = doc.add_paragraph(style="Title")
    _docx_font(t.add_run(TITLE), 22, True)
    sp = doc.add_paragraph()
    _docx_font(sp.add_run(SUBTITLE), 11, False, DRGB(0x6B, 0x72, 0x80))
    sp2 = doc.add_paragraph()
    _docx_font(sp2.add_run("说明：本文为 PPT《" + TITLE + "》的文字版，内容一致，便于转发和检索。"),
               10, False, DRGB(0x6B, 0x72, 0x80), True)

    for spec in SLIDES:
        if spec.get("chapter"):
            doc.add_heading(spec["chapter"], level=1)
        doc.add_heading(spec["title"], level=2)
        for kind, payload in spec["body"]:
            if kind == "bullets":
                for it in payload:
                    text, level = (it, 0) if isinstance(it, str) else it
                    p = doc.add_paragraph(style="List Bullet" if level == 0 else "List Bullet 2")
                    _docx_font(p.add_run(text), 11 if level == 0 else 10.5)
                    p.paragraph_format.space_after = DPt(3)
            elif kind == "table":
                rows, cols = len(payload), len(payload[0])
                tbl = doc.add_table(rows=rows, cols=cols)
                tbl.style = "Table Grid"
                tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
                tbl.autofit = False
                total_cm = 16.6
                widths = _table_widths(payload)
                cm_widths = [Cm(total_cm * w / BODY_W) for w in widths]
                for ci, cw in enumerate(cm_widths):
                    tbl.columns[ci].width = cw
                tblPr = tbl._tbl.tblPr
                layout = OxmlElement("w:tblLayout")
                layout.set(qn("w:type"), "fixed")
                tblPr.append(layout)
                for ri, row in enumerate(payload):
                    for ci, val in enumerate(row):
                        cell = tbl.cell(ri, ci)
                        cell.width = cm_widths[ci]
                        cell.text = ""
                        run = cell.paragraphs[0].add_run(val)
                        if ri == 0:
                            _docx_font(run, 10, True, DRGB(0xFF, 0xFF, 0xFF))
                            _shade(cell, "2F3E5C")
                        else:
                            _docx_font(run, 10, ci == 0 and cols > 2)
                            if ri % 2 == 0:
                                _shade(cell, "F8F9FB")
                doc.add_paragraph().paragraph_format.space_after = DPt(2)
            elif kind == "box":
                for seg in payload.split("\n"):
                    p = doc.add_paragraph()
                    p.paragraph_format.left_indent = Cm(0.6)
                    p.paragraph_format.space_after = DPt(0)
                    _shade(p, "F3F4F6")
                    _docx_font(p.add_run(seg), 10.5, False, DRGB(0x1F, 0x29, 0x37))
                doc.add_paragraph().paragraph_format.space_after = DPt(2)
            elif kind == "note":
                p = doc.add_paragraph()
                _docx_font(p.add_run("※ " + payload), 10, False, DRGB(0x6B, 0x72, 0x80), True)
    doc.save(path)


if __name__ == "__main__":
    out_dir = os.path.dirname(os.path.abspath(__file__))
    pptx_path = os.path.join(out_dir, "WorkBuddy仓库主管上手手册.pptx")
    docx_path = os.path.join(out_dir, "WorkBuddy仓库主管上手手册.docx")
    build_pptx(pptx_path)
    build_docx(docx_path)
    print("written:", pptx_path)
    print("written:", docx_path)

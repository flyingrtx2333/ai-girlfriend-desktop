"""Independent OOXML readback; no application editor APIs are used here."""
import json
import pathlib
import sys
import zipfile
from decimal import Decimal

from docx import Document
from openpyxl import load_workbook
from pptx import Presentation

originals, saved = map(pathlib.Path, sys.argv[1:3])
reviewer = sys.argv[3]
checks = {}
before = Document(originals / 'sample.docx')
after = Document(saved / 'sample.docx')
checks['wordAllParagraphs'] = [p.text.replace('审阅人：待填写', reviewer) for p in before.paragraphs] == [p.text for p in after.paragraphs]
checks['wordParagraphStyles'] = [p.style.style_id for p in before.paragraphs] == [p.style.style_id for p in after.paragraphs]
tables = lambda doc: [[[c.text for c in row.cells] for row in table.rows] for table in doc.tables]
checks['wordTable'] = tables(before) == tables(after)
checks['wordHeaderFooter'] = [(s.header.paragraphs[0].text, s.footer.paragraphs[0].text) for s in before.sections] == [(s.header.paragraphs[0].text, s.footer.paragraphs[0].text) for s in after.sections]
checks['wordImageGeometry'] = [(s.width, s.height) for s in before.inline_shapes] == [(s.width, s.height) for s in after.inline_shapes]
before_book = load_workbook(originals / 'sample.xlsx')
after_book = load_workbook(saved / 'sample.xlsx')
checks['excelSheets'] = before_book.sheetnames == after_book.sheetnames
checks['excelValuesFormulasAndFormats'] = all(
    (reviewer if sheet == '审阅' and cell.coordinate == 'A1' else cell.value, cell.number_format, cell.style_id)
    == (after_book[sheet][cell.coordinate].value, after_book[sheet][cell.coordinate].number_format, after_book[sheet][cell.coordinate].style_id)
    for sheet in before_book.sheetnames for row in before_book[sheet].rows for cell in row
)
checks['excelReviewer'] = after_book['审阅']['A1'].value == reviewer
source_total = sum(Decimal(str(before_book['销售'][f'B{i}'].value)) for i in range(2, 5))
cache = load_workbook(saved / 'sample.xlsx', data_only=True)['销售']['B5'].value
checks['excelFormulaCacheWhenPresent'] = cache is None or Decimal(str(cache)) == source_total
before_deck = Presentation(originals / 'sample.pptx')
after_deck = Presentation(saved / 'sample.pptx')
def shapes(deck, replacing=False):
    return [[(s.shape_type, s.text.replace('审阅人：待填写', reviewer) if replacing and s.has_text_frame else s.text if s.has_text_frame else None, s.left, s.top, s.width, s.height, s.rotation) for s in slide.shapes] for slide in deck.slides]
checks['slidesTextPicturesAndGeometry'] = shapes(before_deck, True) == shapes(after_deck)
checks['slideCountAndDimensions'] = len(after_deck.slides) == 2 and (before_deck.slide_width, before_deck.slide_height) == (after_deck.slide_width, after_deck.slide_height)
for ext, media in [('docx', 'word/media/'), ('xlsx', 'xl/media/'), ('pptx', 'ppt/media/')]:
    with zipfile.ZipFile(originals / ('sample.' + ext)) as a, zipfile.ZipFile(saved / ('sample.' + ext)) as b:
        checks[ext + 'OpaqueXML'] = a.read('customXml/preserve.xml') == b.read('customXml/preserve.xml')
        checks[ext + 'MediaBytes'] = all(name in b.namelist() and a.read(name) == b.read(name) for name in a.namelist() if name.startswith(media))
report = {'success': all(checks.values()), 'checks': checks, 'reviewer': reviewer, 'saved': str(saved), 'independentDecimalTotal': str(source_total), 'actualFormulaCache': cache}
print(json.dumps(report, ensure_ascii=False))
if not report['success']:
    raise SystemExit(1)

"""Public Office acceptance documents, independently authored with Python libraries."""
import hashlib
import json
import pathlib
import sys
import zipfile

from docx import Document
from docx.shared import Inches as WordInches
from openpyxl import Workbook
from PIL import Image
from pptx import Presentation
from pptx.util import Inches

root = pathlib.Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
if any((root / ('sample.' + ext)).exists() for ext in ('docx', 'xlsx', 'pptx')):
    raise SystemExit('Preserve existing Office inputs; do not replace them')
image = root / 'public-shape.png'
Image.new('RGB', (160, 90), '#0f766e').save(image)
doc = Document()
doc.add_heading('项目周报', 0)
doc.add_paragraph('审阅人：待填写')
doc.add_paragraph('本周完成销售核对与文档审阅。')
table = doc.add_table(rows=2, cols=2)
for row, values in zip(table.rows, [('项目', '金额'), ('合计', '43.65')]):
    for cell, value in zip(row.cells, values):
        cell.text = value
doc.add_picture(str(image), width=WordInches(1.5))
doc.sections[0].header.paragraphs[0].text = '公开项目资料'
doc.sections[0].footer.paragraphs[0].text = '保留此页脚'
doc.save(root / 'sample.docx')
book = Workbook()
sales = book.active
sales.title = '销售'
for row in [('项目', '金额'), ('A', 14.2), ('B', 8.35), ('C', 21.1), ('合计', '=SUM(B2:B4)')]:
    sales.append(row)
sales['B5'].number_format = '0.00'
book.create_sheet('审阅')['A1'] = '审阅人：待填写'
book.save(root / 'sample.xlsx')
deck = Presentation()
for title, body in [('销售周报', '审阅人：待填写'), ('核对结果', '合计：43.65')]:
    slide = deck.slides.add_slide(deck.slide_layouts[6])
    slide.shapes.add_textbox(Inches(1), Inches(1), Inches(8), Inches(1)).text = title
    slide.shapes.add_textbox(Inches(1), Inches(2.5), Inches(8), Inches(1)).text = body
    slide.shapes.add_picture(str(image), Inches(7), Inches(4), width=Inches(2))
deck.save(root / 'sample.pptx')
for ext in ('docx', 'xlsx', 'pptx'):
    with zipfile.ZipFile(root / ('sample.' + ext), 'a', zipfile.ZIP_DEFLATED) as package:
        package.writestr('customXml/preserve.xml', '<public-note>opaque-preservation-2086</public-note>')
hashes = {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in root.iterdir() if file.is_file()}
(root / 'source-sha256.json').write_text(json.dumps(hashes, ensure_ascii=False, indent=2))
print(json.dumps({'created': sorted(hashes), 'root': str(root)}, ensure_ascii=False))

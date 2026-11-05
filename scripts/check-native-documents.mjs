import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const parent = path.join(root, 'evidence/agent'); await mkdir(parent, { recursive: true });
const output = await mkdtemp(path.join(parent, 'documents-'));
const python = process.env.BLUEFATFISH_DOCUMENT_PYTHON || 'python3';
const fixture = spawnSync(python, ['-c', String.raw`
import sys,json,zipfile,xml.etree.ElementTree as ET
from pathlib import Path
from docx import Document
from openpyxl import Workbook,load_workbook
from pptx import Presentation
from pptx.util import Inches
root=Path(sys.argv[1])
d=Document();d.add_heading('公开退款资料',0);d.add_paragraph('订单金额 1499.00，人工队列 海盐-7319。')
t=d.add_table(rows=2,cols=2);t.cell(0,0).text='项目';t.cell(0,1).text='金额';t.cell(1,0).text='茶';t.cell(1,1).text='25.00'
d.save(root/'sample.docx')
w=Workbook();s=w.active;s.title='收入';s['A1']='收入';s['B2']=25;s['B3']=24;s['B4']='=SUM(B2:B3)';s['B5']=0.15;s['B5'].number_format='0%'
front=w.create_sheet('核对',0);front['A1']='核对名称';w.save(root/'sample.xlsx')
ns='http://schemas.openxmlformats.org/spreadsheetml/2006/main';ET.register_namespace('',ns)
with zipfile.ZipFile(root/'sample.xlsx') as src, zipfile.ZipFile(root/'cached.xlsx','w',zipfile.ZIP_DEFLATED) as dst:
 for name in src.namelist():
  data=src.read(name)
  if name.startswith('xl/worksheets/'):
   node=ET.fromstring(data)
   for c in node.iter('{'+ns+'}c'):
    if c.attrib.get('r')=='B4':
     c.find('{'+ns+'}v').text='49'
   data=ET.tostring(node,encoding='utf-8',xml_declaration=True)
  dst.writestr(name,data)
p=Presentation()
for text in ['First slide 7319','Second slide 4086']:
 slide=p.slides.add_slide(p.slide_layouts[6]);slide.shapes.add_textbox(Inches(1),Inches(1),Inches(8),Inches(2)).text_frame.text=text
ids=p.slides._sldIdLst;last=ids[-1];ids.remove(last);ids.insert(0,last);p.save(root/'sample.pptx')
marker=root/'must-not-read.txt';marker.write_text('ENTITY-SHOULD-NOT-APPEAR')
xml=('<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE doc [<!ENTITY xxe SYSTEM "'+marker.as_uri()+'">]><doc>&xxe;</doc>').encode('utf-16')
with zipfile.ZipFile(root/'sample.docx') as src,zipfile.ZipFile(root/'unsafe.docx','w',zipfile.ZIP_DEFLATED) as dst:
 for name in src.namelist():dst.writestr(name,xml if name=='word/document.xml' else src.read(name))
proof={'docxText':Document(root/'sample.docx').paragraphs[1].text,'sheetOrder':load_workbook(root/'sample.xlsx').sheetnames,'cachedTotal':load_workbook(root/'cached.xlsx',data_only=True)['收入']['B4'].value,'slideOrder':[s.shapes[0].text for s in Presentation(root/'sample.pptx').slides]}
(root/'independent.json').write_text(json.dumps(proof,ensure_ascii=False),encoding='utf-8')
`, output], { encoding: 'utf8' });
if (fixture.status !== 0) throw Error(fixture.stderr || 'Office fixture libraries are unavailable; set BLUEFATFISH_DOCUMENT_PYTHON to a Python with python-docx, openpyxl and python-pptx.');
const launched = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--document-check'], { encoding: 'utf8' });
if (launched.status !== 0) throw Error(launched.stderr || '文档检查未启动');
let report;
for (let i = 0; i < 160; i++) {
  report = await readFile(path.join(output, 'document-report.json'), 'utf8').then(JSON.parse).catch(() => null);
  if (report) break; await new Promise(resolve => setTimeout(resolve, 500));
}
if (!report) throw Error(`文档检查未完成：${output}`);
console.log(JSON.stringify({ ...report, report: path.join(output, 'document-report.json') }, null, 2));
process.exitCode = report.success ? 0 : 1;

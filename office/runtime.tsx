import React, { useCallback, useEffect, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import * as fonts from '@betteroffice/fonts';
import { configureDefaultFonts } from '@betteroffice/docx/layout';
import { sheetLocale, slidesLocale } from './locales';
import './style.css';

configureDefaultFonts({ fonts });
const rootElement = document.getElementById('office-root')!;
const root = createRoot(rootElement);
let editor: any, revision = 0, exportedRevision = -1, exported: Uint8Array | null = null;
let generation = 0, currentFormat = '', ready = false, dirty = false;
let readOnly = true, operationBusy = 0, lockGeneration = 0, fatal: Error | null = null;
const pendingOperations = new Set<(error: Error) => void>();
let pendingReady: { resolve: () => void; reject: (error: Error) => void } | null = null;
function updateInteraction() { rootElement.inert = !ready || readOnly || operationBusy > 0; }
async function perform<T>(operation: () => Promise<T>): Promise<T> {
  if (fatal) throw fatal;
  const token = generation;
  let rejectPending!: (error: Error) => void;
  const failed = new Promise<never>((_, reject) => { rejectPending = reject; pendingOperations.add(reject); });
  try {
    const value = await Promise.race([Promise.resolve().then(operation), failed]);
    if (token !== generation) throw new Error('文档已切换');
    if (fatal) throw fatal;
    return value;
  } finally { pendingOperations.delete(rejectPending); }
}
function rejectOperations(error: Error) { for (const reject of pendingOperations) reject(error); pendingOperations.clear(); }
function notify(action: string, fields: Record<string, unknown> = {}) {
  (window as any).webkit?.messageHandlers?.office?.postMessage({ action, ...fields });
}
function failure(error: unknown, info?: { recoverable?: boolean }) {
  const message = error instanceof Error ? error.message : String(error);
  if (!info?.recoverable) {
    fatal = new Error(message); pendingReady?.reject(fatal); pendingReady = null; rejectOperations(fatal);
    if (ready || operationBusy > 0) { dirty = true; notify('dirty', { value: true }); }
    ready = false; updateInteraction();
  }
  notify('error', { message: message.slice(0, 1000), recoverable: !!info?.recoverable });
}
function changed() {
  if (!ready) return;
  revision += 1;
  if (!dirty) { dirty = true; notify('dirty', { value: true }); }
}
async function presentationFonts() {
  const selected = fonts.BUNDLED_FONTS.filter(face => ['Carlito', 'Noto Sans SC'].includes(face.family));
  return Promise.all(selected.map(async face => ({ family: face.family, bytes: new Uint8Array(await fonts.loadBundledFontBytes(face)), bold: face.weight >= 600, italic: face.style === 'italic' })));
}
function LoadedEditor({ Component, properties, format, token }: { Component: React.ComponentType<any>; properties: any; format: string; token: number }) {
  const reference = useRef<any>(null);
  const preparing = useRef(false);
  const fitPage = useCallback(() => {
    if (format !== 'docx' || token !== generation || rootElement.clientWidth < 100) return;
    const value = reference.current;
    // Measure the actual page from the pinned SDK, including landscape/custom
    // paper. Changing the viewport must not change the document's page setup.
    const page = rootElement.querySelector('.paged-editor__page');
    const zoom = value?.getZoom(), width = page?.getBoundingClientRect().width;
    if (!zoom || !width) return;
    const next = Math.max(0.1, Math.min(1, (rootElement.clientWidth - 96) / (width / zoom)));
    if (Math.abs(next - zoom) > 0.005) value.setZoom(next);
  }, []);
  const assign = useCallback((value: any) => {
    reference.current = value;
    if (token === generation && value && ready) editor = value;
  }, []);
  const accept = useCallback((value: any) => {
    if (token !== generation || fatal) return;
    if (ready) { editor = value; return; }
    if (preparing.current) return;
    preparing.current = true;
    void (async () => {
      if (format === 'pptx') {
        const access = await perform<any>(() => value.handleAsync());
        for (const face of properties.fonts.filter((f: any) => f.family === 'Noto Sans SC')) await perform(() => access.registerFallbackFont(face));
      }
      if (token === generation) becameReady(value);
    })().catch(error => { if (token === generation) failure(error); });
  }, []);
  useEffect(() => {
    if (format !== 'docx') return;
    const observer = new ResizeObserver(fitPage); observer.observe(rootElement);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    if (format !== 'docx') return;
    let ended = false;
    // 0.5 exposes the ref before its worker is hydrated, without an onReady.
    // Wait on that same ref; a real parse error still reaches onError directly.
    void (async () => {
      const deadline = Date.now() + 30_000;
      let lastIssue = '编辑接口尚未就绪';
      while (!ended && token === generation && Date.now() < deadline) {
        const value = reference.current;
        if (value) {
          try { const answer = await value.readParagraphs({ view: 'accepted', paraIds: [] }); if (answer?.ok === true) { if (!ended) accept(value); return; } lastIssue = JSON.stringify(answer); }
          catch (error) { lastIssue = error instanceof Error ? error.message : String(error); if (!(error instanceof Error) || !/(editor is not ready|document worker is not initialized)/i.test(error.message)) { if (!ended) failure(error); return; } }
        }
        await new Promise(resolve => setTimeout(resolve, 200));
      }
      if (!ended && token === generation) failure(new Error('文档编辑器未在30秒内就绪：' + lastIssue));
    })();
    return () => { ended = true; };
  }, []);
  // Native policy guards every write; inert locks interaction without issuing
  // concurrent SDK read-only commands against a changing presentation version.
  return <Component {...properties} readOnly={false} {...(format === 'docx' ? { ref: assign, onFirstPagePainted: fitPage } : { onReady: accept })} />;
}
function becameReady(value: any) {
  if (fatal) return;
  editor = value; if (ready) return;
  ready = true; dirty = false; revision = 0; updateInteraction();
  notify('ready', { format: currentFormat }); pendingReady?.resolve(); pendingReady = null;
}
class EditorBoundary extends React.Component<{ children: React.ReactNode }, { message: string }> {
  state = { message: '' };
  static getDerivedStateFromError(error: Error) { return { message: error.message }; }
  componentDidCatch(error: Error) { failure(error); }
  render() { return this.state.message ? <div role="alert" className="office-error">{this.state.message}</div> : this.props.children; }
}
async function load(url: string, name: string, locked: boolean) {
  const token = ++generation, format = name.split('.').pop()?.toLowerCase() ?? '';
  if (!['docx', 'xlsx', 'pptx'].includes(format)) throw new Error('不支持此办公文件格式');
  pendingReady?.reject(new Error('文档已切换')); pendingReady = null; rejectOperations(new Error('文档已切换'));
  ready = false; dirty = false; readOnly = locked; operationBusy = 0; lockGeneration += 1; fatal = null; editor = null; exported = null; currentFormat = format; updateInteraction(); root.render(null);
  const response = await fetch(url, { cache: 'no-store' });
  if (!response.ok) throw new Error('文档读取失败');
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.length > 500 * 1024 * 1024 || bytes[0] !== 80 || bytes[1] !== 75) throw new Error('文档格式无效或超过500MiB');
  let Component: any, properties: any;
  const shared = { downloadOnSave: false, onDocumentChange: changed, onError: failure, onSaveRequest: () => { notify('save-request'); return false; }, loadingIndicator: <div className="office-loading" role="status">正在打开…</div>, style: { height: '100%', minHeight: 0, width: '100%' } };
  if (format === 'docx') {
    const [module, locale] = await Promise.all([import('@betteroffice/docx-react'), import('@betteroffice/docx-i18n/zh-CN')]);
    await import('@betteroffice/docx-react/styles.css');
    Component = module.DocxEditor; properties = { ...shared, documentBuffer: bytes, documentName: name, documentNameEditable: false, i18n: locale.default, showFileOpen: false, showHelpMenu: false, colorMode: 'system' };
  } else if (format === 'xlsx') {
    const [module, locale] = await Promise.all([import('@betteroffice/xlsx-react'), import('@betteroffice/xlsx-i18n/zh-CN')]);
    Component = module.XlsxEditor; properties = { ...shared, file: bytes, fileName: name, i18n: sheetLocale(locale.default) };
  } else {
    const [module, locale, faces] = await Promise.all([import('@betteroffice/pptx-react'), import('@betteroffice/pptx-i18n/zh-CN'), presentationFonts()]);
    Component = module.PptxEditor; properties = { ...shared, file: bytes, fileName: name, i18n: slidesLocale(locale.default), fonts: faces };
  }
  if (token !== generation) throw new Error('文档已切换');
  const loaded = new Promise<void>((resolve, reject) => { pendingReady = { resolve, reject }; });
  root.render(<EditorBoundary key={token}><LoadedEditor Component={Component} properties={properties} format={format} token={token} /></EditorBoundary>);
  const deadline = setTimeout(() => { if (token === generation && !ready) failure(new Error('办公文档未在45秒内打开')); }, 45_000);
  try { await loaded; } finally { clearTimeout(deadline); }
  return { format, bytes: bytes.length };
}
async function beginExport() {
  if (!ready || !editor) throw new Error('文档尚未打开');
  if (exported) throw new Error('上一份文档导出尚未结束');
  operationBusy += 1; updateInteraction();
  try {
    const bytes = await perform<any>(() => editor.save());
    if (!bytes) throw new Error('编辑器未返回文档文件');
    exported = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    if (exported.length > 500 * 1024 * 1024) { exported = null; throw new Error('文档超过500MiB'); }
    exportedRevision = revision;
    return { bytes: exported.length, revision: exportedRevision };
  } finally { operationBusy = Math.max(0, operationBusy - 1); updateInteraction(); }
}
function exportChunk(offset: number, length: number) {
  if (!exported || !Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 1 || length > 1024 * 1024 || offset >= exported.length) throw new Error('文档导出片段无效');
  const bytes = exported.subarray(offset, Math.min(offset + length, exported.length)); let text = '';
  for (let i = 0; i < bytes.length; i += 8192) text += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(text);
}
function finishExport(saved: boolean) {
  exported = null;
  if (saved && revision === exportedRevision) dirty = false;
  notify('dirty', { value: dirty }); return { dirty };
}
async function read(request: any = {}) {
  if (!ready || !editor) throw new Error('文档尚未打开');
  if (currentFormat === 'docx') return await perform(() => editor.readParagraphs({ view: 'accepted', ...request }));
  if (currentFormat === 'xlsx') return await perform(() => editor.readCells({ ranges: [], ...request }));
  return await perform(() => editor.readContent(request));
}
async function setInteractionLocked(value: boolean) {
  const token = ++lockGeneration;
  if (value && !readOnly && ready) await verifyClean();
  if (token === lockGeneration) { readOnly = !!value; updateInteraction(); }
  return true;
}
async function edit(request: any, agent = false) {
  if (!ready || !editor) throw new Error('文档尚未打开');
  if (readOnly && !agent) throw new Error('当前文档只读');
  operationBusy += 1; updateInteraction();
  try { return await perform(() => editor.applyEdits({ ...request, source: agent ? 'agent' : 'host', history: 'separate' })); }
  finally { operationBusy = Math.max(0, operationBusy - 1); updateInteraction(); }
}
async function verifyClean() {
  if (!ready || !editor) throw new Error('办公文件尚未打开');
  if (currentFormat === 'docx') await perform(() => editor.flushPendingInput());
  else await perform(() => editor.version());
  return { dirty, ready };
}
async function inspectContent(request: any = {}) {
  if (!ready || !editor) throw new Error('文档尚未打开');
  const offset = Math.max(0, Math.min(100_000, Number.isSafeInteger(request.offset) ? request.offset : 0));
  const limit = Math.max(1, Math.min(40, Number.isSafeInteger(request.limit) ? request.limit : 12));
  const text = (value: string) => ({ text: value.slice(0, 2000), ...(value.length > 2000 ? { truncated: true } : {}) });
  if (currentFormat === 'docx') {
    const identities = await editor.getParagraphIdentities(), all = identities.paragraphs.map((p: any) => p.session).filter(Boolean);
    const page = all.slice(offset, offset + limit), groups = new Map<string, string[]>();
    for (const p of page) groups.set(p.story, [...(groups.get(p.story) ?? []), p.paraId]);
    let version = '', paragraphs: any[] = [];
    for (const [story, paraIds] of groups) {
      const result = await editor.readParagraphs({ story, paraIds, view: 'accepted' });
      if (!result.ok) throw new Error(result.failure?.message ?? '段落读取失败');
      if (version && version !== result.version) throw new Error('文档已变化，请重新读取');
      version = result.version; paragraphs.push(...result.paragraphs.map((p: any) => ({ id: p.paraId, story: p.story, ...text(p.text) })));
    }
    if (!version) version = (await editor.readParagraphs({ view: 'accepted', paraIds: [] })).version;
    return { version, paragraphs, total: all.length, offset, next_offset: offset + limit < all.length ? offset + limit : null, unavailable_paragraphs: identities.paragraphs.length - all.length };
  }
  if (currentFormat === 'xlsx') {
    const catalog = await editor.readCells({ ranges: [] });
    if (!catalog.ok) throw new Error(catalog.failure?.message ?? '工作表读取失败');
    const sheet = request.sheet ? catalog.sheets.find((s: any) => s.name === request.sheet || s.sheetId === request.sheet) : catalog.sheets[0];
    if (!sheet) throw new Error('工作表不存在');
    const range = request.range ?? 'A1:H20', match = /^([A-Z]{1,3})([1-9][0-9]{0,6})(?::([A-Z]{1,3})([1-9][0-9]{0,6}))?$/.exec(range);
    const col = (letters: string) => [...letters].reduce((n, c) => n * 26 + c.charCodeAt(0) - 64, 0);
    if (!match || Number(match[4] ?? match[2]) < Number(match[2]) || col(match[3] ?? match[1]) < col(match[1]) || Number(match[4] ?? match[2]) > 1048576 || col(match[3] ?? match[1]) > 16384 || (Number(match[4] ?? match[2]) - Number(match[2]) + 1) * (col(match[3] ?? match[1]) - col(match[1]) + 1) > 256) throw new Error('请选择不超过256个单元格的A1范围');
    const result = await editor.readCells({ ranges: [{ sheetId: sheet.sheetId, range: { kind: 'a1', a1: range } }] });
    if (!result.ok) throw new Error(result.failure?.message ?? '单元格读取失败');
    const cells = result.ranges.flatMap((r: any) => r.cells.flat()).filter((c: any) => c.formula !== null || c.value.kind !== 'empty');
    return { version: result.version, sheets: catalog.sheets, sheet: sheet.sheetId, range, empty_cells_omitted: true, cells: cells.map((c: any) => ({ ...c, displayText: c.displayText.slice(0, 2000), ...(c.value.kind === 'text' ? { value: { kind: 'text', value: c.value.value.slice(0, 2000) }, ...(c.value.value.length > 2000 ? { truncated: true } : {}) } : {}) })), calculation: result.calculation };
  }
  const result = await editor.readContent();
  if (!result.ok) throw new Error(result.failure?.message ?? '幻灯片读取失败');
  return { version: result.version, slides: result.slides.map((s: any) => ({ id: s.id, title: s.title, hidden: s.hidden })), stories: result.stories.slice(offset, offset + limit).map((s: any) => ({ id: s.storyId, slideId: s.slideId, shapeId: s.shapeId, ...text(s.text) })), total: result.stories.length, offset, next_offset: offset + limit < result.stories.length ? offset + limit : null };
}
async function inspect(request: any = {}) { return await perform(() => inspectContent(request)); }
(window as any).BlueFatFishOffice = { load, beginExport, exportChunk, finishExport, read, inspect, edit, verifyClean, setInteractionLocked, state: () => ({ ready, dirty, format: currentFormat, revision, readOnly }), close: () => { generation += 1; lockGeneration += 1; pendingReady?.reject(new Error('文档已关闭')); pendingReady = null; rejectOperations(new Error('文档已关闭')); ready = false; editor = null; exported = null; updateInteraction(); root.render(null); } };
notify('shell-ready');

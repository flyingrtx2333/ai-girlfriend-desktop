import React, { useCallback, useEffect, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import * as fonts from '@betteroffice/fonts';
import { configureDefaultFonts } from '@betteroffice/docx/layout';
import './style.css';

configureDefaultFonts({ fonts });
const rootElement = document.getElementById('office-root')!;
const root = createRoot(rootElement);
let editor: any, revision = 0, exportedRevision = -1, exported: Uint8Array | null = null;
let generation = 0, currentFormat = '', ready = false, dirty = false;
let pendingReady: { resolve: () => void; reject: (error: Error) => void } | null = null;
function notify(action: string, fields: Record<string, unknown> = {}) {
  (window as any).webkit?.messageHandlers?.office?.postMessage({ action, ...fields });
}
function failure(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  pendingReady?.reject(new Error(message)); pendingReady = null;
  notify('error', { message: message.slice(0, 1000) });
}
function changed() {
  if (!ready) return;
  revision += 1;
  if (!dirty) { dirty = true; notify('dirty', { value: true }); }
}
async function presentationFonts() {
  const selected = fonts.BUNDLED_FONTS.filter(face => ['Carlito', 'Noto Sans SC'].includes(face.family));
  return Promise.all(selected.map(async face => ({ family: face.family, bytes: new Uint8Array(await fonts.loadBundledFontBytes(face)), weight: face.weight, style: face.style })));
}
function LoadedEditor({ Component, properties, format }: { Component: React.ComponentType<any>; properties: any; format: string }) {
  const reference = useRef<any>(null);
  const assign = useCallback((value: any) => {
    reference.current = value;
    if (value && ready) editor = value;
  }, []);
  useEffect(() => {
    if (format !== 'docx') return;
    let ended = false;
    // 0.5 exposes the ref before its worker is hydrated, without an onReady.
    // Wait on that same ref; a real parse error still reaches onError directly.
    void (async () => {
      const deadline = Date.now() + 30_000;
      let lastIssue = '编辑接口尚未就绪';
      while (!ended && Date.now() < deadline) {
        const value = reference.current;
        if (value) {
          try { const answer = await value.readParagraphs({ view: 'accepted' }); if (answer?.ok === true) { if (!ended) becameReady(value); return; } lastIssue = JSON.stringify(answer); }
          catch (error) { lastIssue = error instanceof Error ? error.message : String(error); if (!(error instanceof Error) || !/(editor is not ready|document worker is not initialized)/i.test(error.message)) { if (!ended) failure(error); return; } }
        }
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      if (!ended) failure(new Error('文档编辑器未在30秒内就绪：' + lastIssue));
    })();
    return () => { ended = true; };
  }, []);
  return <Component {...properties} {...(format === 'docx' ? { ref: assign } : { onReady: becameReady })} />;
}
function becameReady(value: any) {
  editor = value; ready = true; dirty = false; revision = 0;
  notify('ready', { format: currentFormat }); pendingReady?.resolve(); pendingReady = null;
}
class EditorBoundary extends React.Component<{ children: React.ReactNode }, { message: string }> {
  state = { message: '' };
  static getDerivedStateFromError(error: Error) { return { message: error.message }; }
  componentDidCatch(error: Error) { failure(error); }
  render() { return this.state.message ? <div role="alert" className="office-error">{this.state.message}</div> : this.props.children; }
}
async function load(url: string, name: string, readOnly: boolean) {
  const token = ++generation, format = name.split('.').pop()?.toLowerCase() ?? '';
  if (!['docx', 'xlsx', 'pptx'].includes(format)) throw new Error('不支持此办公文件格式');
  ready = false; editor = null; exported = null; currentFormat = format; root.render(null);
  const response = await fetch(url, { cache: 'no-store' });
  if (!response.ok) throw new Error('文档读取失败');
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.length > 500 * 1024 * 1024 || bytes[0] !== 80 || bytes[1] !== 75) throw new Error('文档格式无效或超过500MiB');
  let Component: any, properties: any;
  const shared = { readOnly, downloadOnSave: false, onDocumentChange: changed, onError: failure, onSaveRequest: () => { notify('save-request'); return false; }, loadingIndicator: <div className="office-loading" role="status">正在打开…</div>, style: { height: '100%', minHeight: 0, width: '100%' } };
  if (format === 'docx') {
    const [module, locale] = await Promise.all([import('@betteroffice/docx-react'), import('@betteroffice/docx-i18n/zh-CN')]);
    await import('@betteroffice/docx-react/styles.css');
    Component = module.DocxEditor; properties = { ...shared, documentBuffer: bytes, documentName: name, i18n: locale.default, showFileOpen: false, showHelpMenu: false, colorMode: 'light' };
  } else if (format === 'xlsx') {
    const [module, locale] = await Promise.all([import('@betteroffice/xlsx-react'), import('@betteroffice/xlsx-i18n/zh-CN')]);
    Component = module.XlsxEditor; properties = { ...shared, file: bytes, fileName: name, i18n: locale.default };
  } else {
    const [module, locale, faces] = await Promise.all([import('@betteroffice/pptx-react'), import('@betteroffice/pptx-i18n/zh-CN'), presentationFonts()]);
    Component = module.PptxEditor; properties = { ...shared, file: bytes, fileName: name, i18n: locale.default, fonts: faces };
  }
  if (token !== generation) throw new Error('文档已切换');
  const loaded = new Promise<void>((resolve, reject) => { pendingReady = { resolve, reject }; });
  root.render(<EditorBoundary key={token}><LoadedEditor Component={Component} properties={properties} format={format} /></EditorBoundary>);
  await loaded;
  return { format, bytes: bytes.length };
}
async function beginExport() {
  if (!ready || !editor) throw new Error('文档尚未打开');
  rootElement.inert = true;
  try {
    const bytes = await editor.save();
    if (!bytes) throw new Error('编辑器未返回文档文件');
    exported = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    if (exported.length > 500 * 1024 * 1024) { exported = null; throw new Error('文档超过500MiB'); }
    exportedRevision = revision;
    return { bytes: exported.length, revision: exportedRevision };
  } finally { rootElement.inert = false; }
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
  if (currentFormat === 'docx') return await editor.readParagraphs({ view: 'accepted', ...request });
  if (currentFormat === 'xlsx') return await editor.readCells(request);
  return await editor.readContent(request);
}
async function edit(request: any) {
  if (!ready || !editor) throw new Error('文档尚未打开');
  return await editor.applyEdits(request);
}
(window as any).BlueFatFishOffice = { load, beginExport, exportChunk, finishExport, read, edit, state: () => ({ ready, dirty, format: currentFormat, revision }), close: () => { generation += 1; ready = false; editor = null; exported = null; root.render(null); } };
notify('shell-ready');

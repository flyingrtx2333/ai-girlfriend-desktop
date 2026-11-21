import { createDocxReviewDrafts, type DocxReviewDraft } from './docx-review-drafts';
import { spreadsheetAddress, spreadsheetCell, validSpreadsheetNotesLocation, type SpreadsheetNotesLocation } from './spreadsheet-notes';
import { validSpreadsheetThreadsLocation, type SpreadsheetThreadsLocation } from './spreadsheet-threads';

// View coordinates belong to the exact document bytes stored by the native
// journal. Session IDs are resolved again after opening those bytes.
type Point = { part: string; ordinal: number; paragraphID: string | null; storyKind: string | null; itemID: string | null; offset: number; sourceHash?: string | null };
export type WordRange = { anchor: Point; focus: Point };
export type OfficeView = { version: 1; format: string; zoom: number | 'fit'; selection: any; scroll: { path: number[]; x: number; y: number }[];
  review?: DocxReviewDraft[]; notes?: SpreadsheetNotesLocation; threads?: SpreadsheetThreadsLocation };
const issue = () => new Error('办公位置记录无效，原草稿已保留');
const integer = (value: any, maximum = 100_000_000) => Number.isSafeInteger(value) && value >= 0 && value <= maximum;
const text = (value: any, maximum = 2048) => typeof value === 'string' && value.length > 0 && value.length <= maximum && !value.includes('\0');
function keys(value: any, names: string[]) { return value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === names.length && Object.keys(value).every(key => names.includes(key)); }
function path(value: any) { return Array.isArray(value) && value.length > 0 && value.length <= 40 && value.every((n: any) => integer(n, 1_000_000)); }
export function validateOfficeView(value: any, format: string): asserts value is OfficeView {
  const fields = ['version', 'format', 'zoom', 'selection', 'scroll'];
  const spreadsheetFields = [...fields];
  if (format === 'xlsx' && value?.notes) spreadsheetFields.push('notes');
  if (format === 'xlsx' && value?.threads) spreadsheetFields.push('threads');
  if (!(keys(value, fields) || format === 'docx' && keys(value, [...fields, 'review']) ||
      format === 'xlsx' && keys(value, spreadsheetFields) && (!value.notes || validSpreadsheetNotesLocation(value.notes)) &&
        (!value.threads || validSpreadsheetThreadsLocation(value.threads)) && !(value.notes && value.threads?.open)) ||
      value.version !== 1 || value.format !== format || !['docx', 'xlsx', 'pptx'].includes(format) ||
      !(typeof value.zoom === 'number' && Number.isFinite(value.zoom) && value.zoom >= 0.1 && value.zoom <= 5 || format === 'pptx' && value.zoom === 'fit') ||
      !Array.isArray(value.scroll) || value.scroll.length > 32 || value.scroll.some((s: any) => !keys(s, ['path', 'x', 'y']) || !path(s.path) || ![s.x, s.y].every(n => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1e9)) ||
      new Set(value.scroll.map((s: any) => JSON.stringify(s.path))).size !== value.scroll.length) throw issue();
  const selected = value.selection;
  if (format === 'docx') {
    const point = (p: any) => (keys(p, ['part', 'ordinal', 'paragraphID', 'storyKind', 'itemID', 'offset']) || keys(p, ['part', 'ordinal', 'paragraphID', 'storyKind', 'itemID', 'offset', 'sourceHash'])) && text(p.part) && p.part.startsWith('/') && integer(p.ordinal, 1_000_000) && integer(p.offset) &&
      (p.paragraphID === null || typeof p.paragraphID === 'string' && /^[a-fA-F0-9]{8}$/.test(p.paragraphID)) &&
      (p.storyKind === null || ['body', 'header', 'footer', 'footnote', 'endnote', 'comment'].includes(p.storyKind)) && (p.itemID === null || text(p.itemID)) &&
      (p.sourceHash == null || typeof p.sourceHash === 'string' && /^[0-9a-f]{64}$/.test(p.sourceHash));
    const range = (r: any) => keys(r, ['anchor', 'focus']) && point(r.anchor) && point(r.focus);
    if (selected !== null && !range(selected)) throw issue();
    if ('review' in value) {
      const common = ['kind', 'text', 'focused', 'start', 'end', 'direction', 'x', 'y'];
      if (!Array.isArray(value.review) || value.review.length < 1 || value.review.length > 2 ||
          value.review.some((d: any) => !(keys(d, [...common, 'range']) && d.kind === 'comment' && range(d.range) ||
            keys(d, [...common, 'commentID']) && d.kind === 'reply' && integer(d.commentID, Number.MAX_SAFE_INTEGER)) ||
            !text(d.text, 128_000) || typeof d.focused !== 'boolean' || !integer(d.start, d.text.length) ||
            !integer(d.end, d.text.length) || d.end < d.start || !['none', 'forward', 'backward'].includes(d.direction) ||
            ![d.x, d.y].every(n => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1e9)) ||
          new Set(value.review.map((d: any) => d.kind)).size !== value.review.length ||
          value.review.filter((d: any) => d.focused).length > 1) throw issue();
    }
  } else if (selected === null) {
    return;
  } else if (format === 'xlsx') {
    const cell = (p: any) => keys(p, ['row', 'col']) && integer(p.row, 1_048_575) && integer(p.col, 16_383);
    const cells = selected.cells;
    if (!keys(selected, ['sheetIndex', 'sheetName', 'cells']) || !integer(selected.sheetIndex, 16383) || !text(selected.sheetName, 256) || cells !== null &&
      (!(keys(cells, ['anchor', 'focus']) || keys(cells, ['anchor', 'focus', 'range'])) || !cell(cells.anchor) || !cell(cells.focus) || cells.range &&
        (!keys(cells.range, ['top', 'left', 'bottom', 'right']) || !cell({ row: cells.range.top, col: cells.range.left }) || !cell({ row: cells.range.bottom, col: cells.range.right }) || cells.range.top > cells.range.bottom || cells.range.left > cells.range.right))) throw issue();
  } else {
    const target = selected.target;
    if (!keys(selected, ['slide', 'part', 'target']) || !integer(selected.slide, 1_000_000) || selected.slide < 1 || !(selected.part === null || text(selected.part)) || target !== null &&
      (!(target.kind === 'shape' && keys(target, ['kind', 'shapePath', 'sourceID']) || target.kind === 'text' && keys(target, ['kind', 'shapePath', 'sourceID', 'storyIndex', 'anchor', 'focus'])) ||
        !path(target.shapePath) || !integer(target.sourceID, 4_294_967_295) || target.kind === 'text' && (!integer(target.storyIndex, 1_000_000) || !integer(target.anchor) || !integer(target.focus)))) throw issue();
  }
}

function scrollElements(root: HTMLElement) {
  return [...root.querySelectorAll<HTMLElement>('*')].filter(element => {
    if (element.clientWidth < 100 || element.clientHeight < 80 || element.closest('[role="menu"],[role="listbox"],[role="dialog"]')) return false;
    const style = getComputedStyle(element);
    return /(auto|scroll)/.test(style.overflowY) || /(auto|scroll)/.test(style.overflowX);
  });
}
function scrollPath(root: HTMLElement, element: HTMLElement) {
  const result: number[] = [];
  for (let current: Element | null = element; current && current !== root; current = current.parentElement) {
    if (!current.parentElement) throw issue();
    result.unshift([...current.parentElement.children].indexOf(current));
  }
  return result;
}
function shapeAt(shapes: any[], route: number[]) { let shape: any; for (const index of route) { shape = shapes[index]; if (!shape) return null; shapes = shape.children ?? []; } return shape; }
function shapePath(shapes: any[], id: string, prefix: number[] = []): number[] | null {
  for (const [index, shape] of shapes.entries()) { const route = [...prefix, index]; if (shape.id === id) return route; const child = shapePath(shape.children ?? [], id, route); if (child) return child; }
  return null;
}
function wordPoint(identities: any[], position: any, saved: boolean): Point {
  const paragraphs = identities.filter(p => p.session?.story === position.story), paragraph = paragraphs.find(p => p.session.paraId === position.paraId);
  const part = paragraph?.persisted?.story.partUri ?? paragraph?.source?.partUri ?? paragraphs.find(p => p.persisted || p.source)?.persisted?.story.partUri ?? paragraphs.find(p => p.source)?.source.partUri;
  if (!paragraph || !part) throw issue();
  const persistent = paragraph.persisted && (paragraph.idOrigin === 'source' || saved || !paragraph.source) ? paragraph.persisted : null;
  if (!persistent && !paragraph.source) throw issue();
  return { part, ordinal: persistent ? paragraphs.indexOf(paragraph) : paragraph.source.paragraphOrdinal, paragraphID: persistent?.paraId ?? null, storyKind: persistent?.story.kind ?? null, itemID: persistent?.story.itemId ?? null, offset: position.offset, sourceHash: persistent ? null : paragraph.source.packageSha256 };
}
async function resolveWordPoint(editor: any, identities: any[], point: Point) {
  if (point.paragraphID && point.storyKind) {
    const anchor = { kind: 'persisted', paraId: point.paragraphID, story: { partUri: point.part, kind: point.storyKind, ...(point.itemID === null ? {} : { itemId: point.itemID }) } };
    const answer = (await editor.resolveParagraphAnchors([anchor])).results[0];
    if (answer?.status === 'found' && answer.anchor.kind === 'session') return { story: answer.anchor.story, paraId: answer.anchor.paraId, offset: point.offset };
    throw issue();
  }
  if (point.sourceHash) {
    const answer = (await editor.resolveParagraphAnchors([{ kind: 'source', packageSha256: point.sourceHash, partUri: point.part, paragraphOrdinal: point.ordinal }])).results[0];
    if (answer?.status === 'found' && answer.anchor.kind === 'session') return { story: answer.anchor.story, paraId: answer.anchor.paraId, offset: point.offset };
    throw issue();
  }
  const matches = identities.filter(p => p.session && p.source?.partUri === point.part && p.source.paragraphOrdinal === point.ordinal);
  if (matches.length !== 1) throw issue();
  return { story: matches[0].session.story, paraId: matches[0].session.paraId, offset: point.offset };
}

export function createOfficeView(format: string, root: HTMLElement, editor: () => any, changed: () => void,
    definePlugin?: (value: any) => any, reviewChanged: (hasDraft: boolean) => void = () => {}) {
  const reviewDrafts = format === 'docx' ? createDocxReviewDrafts(root, editor, reviewChanged) : null;
  let context: any = null, unsubscribe: (() => void) | null = null, signature = '', savedParagraphs = false;
  const update = (value: any) => {
    context = value;
    const next = JSON.stringify([value.snapshot.selection, value.snapshot.layout?.zoom, value.snapshot.layout?.viewport]);
    if (next !== signature) { signature = next; changed(); }
  };
  const plugin = definePlugin?.({
    id: 'bluefatfish.workspace-view', createState: () => null,
    initialize(value: any) { update(value); value.onCleanup(() => { if (context?.lifetimeSignal === value.lifetimeSignal) context = null; }); },
    onEvent(value: any, event: any) { if (['selection-change', 'layout-change'].includes(event.type)) update(value); else context = value; },
  });
  root.addEventListener('scroll', changed, true);
  async function capture(): Promise<OfficeView> {
    const api = editor(); let selection: any = null;
    let review: DocxReviewDraft[] = [];
    if (format === 'docx') {
      const current = await api.readHostSelection();
      const identities = current || reviewDrafts?.pending() ? (await api.getParagraphIdentities()).paragraphs : [];
      const portable = (value: any) => ({ anchor: wordPoint(identities, value.anchor, savedParagraphs), focus: wordPoint(identities, value.focus, savedParagraphs) });
      if (current) selection = portable(current);
      review = await reviewDrafts!.capture(async value => portable(value));
    } else if (format === 'xlsx') {
      const catalog = await api.readCells({ ranges: [] }); if (!catalog.ok) throw issue();
      const current = context?.snapshot.selection, id = current?.sheetId ?? context?.snapshot.layout?.sheetId;
      const index = catalog.sheets.findIndex((s: any) => s.sheetId === id);
      if (index < 0) throw issue();
      selection = { sheetIndex: index, sheetName: catalog.sheets[index].name, cells: current?.cells ? JSON.parse(JSON.stringify(current.cells)) : null };
    } else {
      const catalog = await api.readContent(); if (!catalog.ok) throw issue();
      const current = context?.snapshot.selection, slideNumber = current?.slide ?? context?.snapshot.layout?.slide;
      const slide = catalog.slides[slideNumber - 1]; if (!slide) throw issue();
      let target: any = null;
      if (current?.target.kind !== 'slide' && current?.target.shapeId) {
        const route = shapePath(slide.shapes, current.target.shapeId), shape = route && shapeAt(slide.shapes, route); if (!shape) throw issue();
        target = { kind: current.target.kind, shapePath: route, sourceID: shape.sourceId };
        if (target.kind === 'text') {
          const storyIndex = shape.textStories.findIndex((s: any) => s.id === current.target.storyId); if (storyIndex < 0) throw issue();
          Object.assign(target, { storyIndex, anchor: current.target.anchor, focus: current.target.focus });
        }
      }
      selection = { slide: slideNumber, part: slide.sourcePartPath ?? null, target };
    }
    const zoom = format === 'docx' ? api.getZoom() : api.commands.getState('zoom').value;
    const value: OfficeView = { version: 1, format, zoom, selection, scroll: scrollElements(root).map(element => ({ path: scrollPath(root, element), x: element.scrollLeft, y: element.scrollTop })) };
    if (review.length) value.review = review;
    validateOfficeView(value, format); return value;
  }
  async function navigate(action: (value: any) => Promise<any>) {
    if (!context || context.lifetimeSignal.aborted) throw issue();
    let result: any;
    await context.run(async (fresh: any) => { result = await action(fresh); });
    if (result?.ok !== true) throw issue();
  }
  async function spreadsheetNoteTarget(sheetName: string, address: string) {
    const cell = spreadsheetCell(address);
    const catalog = await editor().readCells({ ranges: [] });
    const sheet = catalog.ok && catalog.sheets.find((item: any) => item.name === sheetName);
    if (!sheet) throw issue();
    return { sheetId: sheet.sheetId, ...cell };
  }
  async function activeSpreadsheetNoteCell() {
    const selection = context?.snapshot.selection, cells = selection?.cells;
    if (!cells || cells.anchor.row !== cells.focus.row || cells.anchor.col !== cells.focus.col) return null;
    const catalog = await editor().readCells({ ranges: [] });
    const sheet = catalog.ok && catalog.sheets.find((item: any) => item.sheetId === selection.sheetId);
    const current = context?.snapshot.selection;
    if (!sheet || current?.sheetId !== selection.sheetId ||
        current.cells?.anchor.row !== cells.anchor.row || current.cells.anchor.col !== cells.anchor.col ||
        current.cells.focus.row !== cells.focus.row || current.cells.focus.col !== cells.focus.col) return null;
    return { sheet: sheet.name as string, cell: spreadsheetAddress(cells.anchor.row, cells.anchor.col) };
  }
  async function isSpreadsheetNoteVisible(sheet: string, address: string) {
    const target = await spreadsheetNoteTarget(sheet, address);
    const rect = context?.geometry?.getCellRect(target);
    return !!rect && rect.width > 0 && rect.height > 0;
  }
  async function locateSpreadsheetNote(sheet: string, address: string, restore = false) {
    const target = await spreadsheetNoteTarget(sheet, address);
    if (restore) {
      const rect = context?.geometry?.getCellRect(target);
      if (rect && rect.width > 0 && rect.height > 0) return;
      await navigate(c => c.navigation.scrollToCell(target, { expectVersion: c.snapshot.version }));
    } else {
      const { sheetId, ...cell } = target;
      await navigate(c => c.navigation.selectCells({ sheetId, selection: { anchor: cell, focus: cell } }, { expectVersion: c.snapshot.version }));
    }
  }
  async function restore(value: OfficeView, focus = false) {
    validateOfficeView(value, format);
    const api = editor();
    if (format === 'docx') { await api.whenLayoutComplete({ timeoutMs: 30_000 }); api.setZoom(value.zoom); }
    else if (!(await api.commands.execute('zoom', { scale: value.zoom })).ok) throw issue();
    const selection = value.selection;
    if (format === 'docx' && (selection || value.review)) {
      const identities = (await api.getParagraphIdentities()).paragraphs;
      const select = async (range: WordRange) => {
        const requested = { anchor: await resolveWordPoint(api, identities, range.anchor), focus: await resolveWordPoint(api, identities, range.focus) };
        if (!await api.restoreHostSelection(requested)) throw issue();
        if (JSON.stringify(await api.readHostSelection()) !== JSON.stringify(requested)) throw issue();
      };
      if (selection) await select(selection);
      if (value.review) await reviewDrafts!.restore(value.review, select, selection);
    } else if (selection && format === 'xlsx') {
      const catalog = await api.readCells({ ranges: [] }), sheet = catalog.ok && catalog.sheets[selection.sheetIndex];
      if (!sheet || sheet.name !== selection.sheetName) throw issue();
      await navigate(c => selection.cells ? c.navigation.selectCells({ sheetId: sheet.sheetId, selection: selection.cells }, { expectVersion: c.snapshot.version }) : c.navigation.scrollToCell({ sheetId: sheet.sheetId, row: 0, col: 0 }, { expectVersion: c.snapshot.version }));
    } else if (selection && format === 'pptx') {
      const catalog = await api.readContent(), slide = catalog.ok && catalog.slides[selection.slide - 1];
      if (!slide || selection.part && slide.sourcePartPath !== selection.part) throw issue();
      const target = selection.target;
      if (!target) await navigate(c => c.navigation.goToSlide({ slideId: slide.id }, { expectVersion: c.snapshot.version }));
      else {
        let shape = shapeAt(slide.shapes, target.shapePath);
        if (!shape || target.sourceID > 0 && shape.sourceId !== target.sourceID) throw issue();
        const selected = { slideId: slide.id, shapeId: shape.id };
        if (target.kind === 'shape') await navigate(c => c.navigation.selectShape(selected, { expectVersion: c.snapshot.version }));
        else {
          const story = shape.textStories[target.storyIndex];
          if (!story || Math.max(target.anchor, target.focus) > story.length) throw issue();
          await navigate(c => c.navigation.selectText({ ...selected, storyId: story.id, anchor: target.anchor, focus: target.focus }, { expectVersion: c.snapshot.version }));
        }
      }
    }
    if (focus) api.focus();
    await applyScroll(value);
  }
  async function applyScroll(value: Pick<OfficeView, 'scroll'>) {
    await new Promise<void>(resolve => requestAnimationFrame(() => resolve()));
    const scrollable = new Set(scrollElements(root));
    for (const saved of value.scroll) {
      let element: Element | undefined = root; for (const index of saved.path) element = element?.children[index];
      if (!(element instanceof HTMLElement) || !scrollable.has(element)) throw issue();
      element.scrollLeft = saved.x; element.scrollTop = saved.y;
    }
  }
  async function focus() {
    const scroll = scrollElements(root).map(element => ({ path: scrollPath(root, element), x: element.scrollLeft, y: element.scrollTop }));
    if (!reviewDrafts?.focusDraft()) editor().focus();
    await applyScroll({ scroll });
  }
  return { plugin, capture, restore, applyScroll, focus, activeSpreadsheetNoteCell, locateSpreadsheetNote, isSpreadsheetNoteVisible,
    hasReviewDraft: () => reviewDrafts?.pending() === true, saved() { savedParagraphs = true; }, ready() {
    const zoom = () => format === 'docx' ? editor().getZoom() : editor().commands.getState('zoom').value;
    let previous = zoom();
    unsubscribe = editor().commands.subscribe(() => { const next = zoom(); if (next !== previous) { previous = next; changed(); } });
  }, dispose() { unsubscribe?.(); reviewDrafts?.dispose(); root.removeEventListener('scroll', changed, true); context = null; } };
}

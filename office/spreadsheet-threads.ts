import { spreadsheetCell, type Cell } from './spreadsheet-notes';

type Message = { id: string; parent?: string; author: string; time?: string; text: string };
type Thread = Cell & { id: string; version: string | null; resolved: boolean; editable: boolean; messages: Message[] };
type Catalog = { threads: Thread[]; incomplete: boolean; author: string; creation: Record<string, string[]> };
type Reply = { id: string; time: string; text: string };
type Edit = Pick<Thread, 'id' | 'sheet' | 'cell' | 'version' | 'resolved'> & { opening: Reply | null; replies: Reply[] };
type Draft = { id: string; text: string; start: number; end: number; target?: Cell };
export type SpreadsheetThreadsLocation = {
  open: boolean; selected: string | null; listY: number; bodyY: number; replyFocused: boolean; drafts: Draft[];
};

const maxReply = 32_767, maxDraftsLength = 128_000;
const threadID = /^\{[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\}$/;
const validText = (value: string) => !/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uD800-\uDFFF\uFFFE\uFFFF]/u.test(value);
const keys = (value: any, fields: string[]) => value && typeof value === 'object' && !Array.isArray(value) &&
  Object.keys(value).length === fields.length && Object.keys(value).every(key => fields.includes(key));
const offset = (n: any, max: number) => Number.isSafeInteger(n) && n >= 0 && n <= max;

function validCell(value: any): value is Cell {
  if (!keys(value, ['sheet', 'cell']) || typeof value.sheet !== 'string' || value.sheet.length < 1 || value.sheet.length > 256 ||
      value.sheet.includes('\0') || typeof value.cell !== 'string') return false;
  try { spreadsheetCell(value.cell); return true; } catch { return false; }
}

export function validSpreadsheetThreadsLocation(value: any): value is SpreadsheetThreadsLocation {
  if (!keys(value, ['open', 'selected', 'listY', 'bodyY', 'replyFocused', 'drafts']) ||
      typeof value.open !== 'boolean' || typeof value.replyFocused !== 'boolean' ||
      !(value.selected === null || typeof value.selected === 'string' && threadID.test(value.selected)) ||
      ![value.listY, value.bodyY].every(n => Number.isFinite(n) && n >= 0 && n <= 1e9) ||
      !Array.isArray(value.drafts) || value.drafts.length > 5_000) return false;
  const ids = new Set<string>();
  let length = 0;
  for (const draft of value.drafts) {
    const required = ['id', 'text', 'start', 'end'];
    if (!(keys(draft, required) || keys(draft, [...required, 'target']) && validCell(draft.target)) ||
        typeof draft.id !== 'string' || !threadID.test(draft.id) || ids.has(draft.id) ||
        typeof draft.text !== 'string' || !draft.text.length || draft.text.length > maxReply || !validText(draft.text) ||
        !offset(draft.start, draft.text.length) || !offset(draft.end, draft.text.length) || draft.end < draft.start) return false;
    ids.add(draft.id); length += draft.text.length;
  }
  return length <= maxDraftsLength;
}

const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: 'short', timeStyle: 'short' });
function replyDate(time: string | undefined) {
  if (!time) return '';
  const date = new Date(/(?:Z|[+-]\d\d:\d\d)$/.test(time) ? time : time + 'Z');
  return Number.isFinite(date.valueOf()) ? dateFormat.format(date) : '';
}

export function createSpreadsheetThreads(root: HTMLElement, locate: (cell: Cell) => Promise<void>, activeCell: () => Promise<Cell | null>,
  edited: () => void, viewed: () => void, draftChanged: (draft: boolean) => void, noteAt: (cell: Cell) => boolean) {
  const panel = document.createElement('aside');
  panel.className = 'spreadsheet-annotation spreadsheet-threads'; panel.hidden = true; panel.setAttribute('aria-label', '单元格评论');
  const header = document.createElement('header'), title = document.createElement('h2');
  title.textContent = '单元格评论';
  const close = document.createElement('button'); close.type = 'button'; close.textContent = '关闭';
  header.append(title, close);
  const add = document.createElement('button'); add.type = 'button'; add.textContent = '新建评论'; add.className = 'spreadsheet-note-add spreadsheet-thread-add';
  const list = document.createElement('div');
  list.className = 'spreadsheet-notes-list spreadsheet-thread-list'; list.setAttribute('aria-label', '评论列表');
  const threadView = document.createElement('div'); threadView.className = 'spreadsheet-thread-detail'; threadView.hidden = true;
  const threadHeader = document.createElement('div'); threadHeader.className = 'spreadsheet-thread-header';
  const cellLabel = document.createElement('strong');
  const toggleResolved = document.createElement('button'); toggleResolved.type = 'button'; toggleResolved.className = 'spreadsheet-thread-resolve';
  const cancel = document.createElement('button'); cancel.type = 'button'; cancel.textContent = '取消草稿'; cancel.className = 'spreadsheet-thread-cancel';
  threadHeader.append(cellLabel, toggleResolved, cancel);
  const messages = document.createElement('div'); messages.className = 'spreadsheet-thread-messages'; messages.tabIndex = 0;
  messages.setAttribute('aria-label', '评论正文');
  const composer = document.createElement('div'); composer.className = 'spreadsheet-thread-composer';
  const reply = document.createElement('textarea'); reply.rows = 2; reply.maxLength = maxReply; reply.placeholder = '输入回复…';
  reply.setAttribute('aria-label', '回复草稿');
  const send = document.createElement('button'); send.type = 'button'; send.textContent = '添加回复'; send.className = 'spreadsheet-thread-reply';
  composer.append(reply, send); threadView.append(threadHeader, messages, composer);
  const status = document.createElement('p'); status.className = 'spreadsheet-notes-status'; status.setAttribute('role', 'status');
  panel.append(header, add, list, threadView, status); root.after(panel);

  let loaded = false, locked = true, incomplete = false, author = '';
  let selected: Thread | null = null, threadList: Thread[] = [], navigation = 0;
  const drafts = new Map<string, Draft>();
  const edits = new Map<string, Edit>();
  const rows = new Map<string, HTMLButtonElement>();
  let creation = new Map<string, Set<string>>();

  const newID = () => '{' + crypto.randomUUID().toUpperCase() + '}';
  const atCell = (cell: Cell) => threadList.find(thread => thread.sheet === cell.sheet && thread.cell === cell.cell);
  const composing = (thread: Thread) => thread.version === null && !edits.get(thread.id)?.opening;
  const resolved = (thread: Thread) => edits.get(thread.id)?.resolved ?? thread.resolved;
  function editThread(thread: Thread) {
    let edit = edits.get(thread.id);
    if (!edit) {
      const { id, sheet, cell, resolved, version } = thread;
      edit = { id, sheet, cell, resolved, version, opening: null, replies: [] };
      edits.set(thread.id, edit);
    }
    return edit;
  }
  function updateControls() {
    const thread = selected;
    const resolvedThread = thread && resolved(thread);
    const newThread = !!thread && composing(thread);
    const canWrite = !!thread?.editable && !locked;
    add.disabled = !loaded || locked || creation.size === 0;
    toggleResolved.hidden = newThread;
    toggleResolved.disabled = !canWrite;
    toggleResolved.textContent = resolvedThread ? '重新打开' : '解决';
    cancel.hidden = !newThread;
    cancel.disabled = locked;
    messages.hidden = newThread;
    reply.placeholder = newThread ? '输入评论…' : '输入回复…';
    reply.setAttribute('aria-label', newThread ? '评论草稿' : '回复草稿');
    send.textContent = newThread ? '添加评论' : '添加回复';
    composer.hidden = !thread || !!resolvedThread && !drafts.has(thread.id);
    reply.readOnly = !canWrite || !!resolvedThread;
    send.disabled = reply.readOnly || !reply.value.trim();
  }
  function renderRow(thread: Thread) {
    const row = rows.get(thread.id)!;
    row.setAttribute('aria-pressed', String(thread === selected));
    row.dataset.resolved = String(resolved(thread));
    const detail = row.querySelector('span')!;
    const stage = composing(thread) ? ' · 草稿' : resolved(thread) ? ' · 已解决' : '';
    detail.textContent = thread.sheet + stage;
  }
  function renderMessage(value: Message) {
    const card = document.createElement('article');
    card.className = 'spreadsheet-thread-message'; card.dataset.id = value.id;
    if (value.parent) card.dataset.parent = value.parent;
    const heading = document.createElement('div'), name = document.createElement('strong'), time = document.createElement('time');
    name.textContent = value.author; time.textContent = replyDate(value.time);
    if (value.time) time.dateTime = value.time;
    heading.append(name, time);
    const text = document.createElement('p'); text.textContent = value.text.replace(/\r\n?/g, '\n');
    card.append(heading, text);
    return card;
  }
  function renderThread() {
    const thread = selected;
    threadView.hidden = !thread;
    for (const item of threadList) renderRow(item);
    const draft = thread && drafts.get(thread.id);
    reply.value = draft?.text ?? '';
    if (draft) reply.setSelectionRange(draft.start, draft.end);
    cellLabel.textContent = thread ? thread.sheet + ' · ' + thread.cell : '';
    const edit = thread && edits.get(thread.id);
    const opening = edit?.opening ? [{ ...edit.opening, author }] : [];
    const additional = (edit?.replies ?? []).map(item => ({ ...item, author, parent: edit?.id }));
    messages.replaceChildren(...[...(thread?.messages ?? []), ...opening, ...additional].map(renderMessage));
    messages.scrollTop = 0;
    status.textContent = incomplete ? '部分评论无法读取' : !threadList.length ? '暂无评论' : thread && !thread.editable ? '此评论只读' : '';
    updateControls();
  }
  function openThread(thread: Thread, seek: boolean) {
    bookmarkReply();
    const token = ++navigation;
    selected = thread; renderThread();
    if (!seek) return;
    viewed();
    void locate(thread).then(() => {
      if (token === navigation) viewed();
    }, () => {
      if (token === navigation) status.textContent = '无法定位原单元格，请核对工作表';
    });
  }
  function saveDraft() {
    if (!selected || reply.readOnly) return;
    const id = selected.id, previous = drafts.get(id)?.text ?? '';
    const total = Array.from(drafts.values()).reduce((sum, item) => sum + item.text.length, 0) - previous.length + reply.value.length;
    if (!validText(reply.value) || reply.value.length > maxReply || total > maxDraftsLength) {
      reply.value = previous; status.textContent = '回复过长或含不支持的字符'; updateControls(); return;
    }
    const { sheet, cell } = selected;
    if (reply.value) drafts.set(id, { id, text: reply.value, start: reply.selectionStart, end: reply.selectionEnd,
      ...(composing(selected) ? { target: { sheet, cell } } : {}) });
    else drafts.delete(id);
    status.textContent = '';
    updateControls(); draftChanged(drafts.size > 0);
  }
  function bookmarkReply() {
    const active = selected && drafts.get(selected.id);
    if (active) { active.start = reply.selectionStart; active.end = reply.selectionEnd; }
  }
  reply.addEventListener('input', saveDraft);
  for (const event of ['focus', 'blur', 'select']) reply.addEventListener(event, () => { bookmarkReply(); viewed(); });
  list.addEventListener('scroll', viewed);
  messages.addEventListener('scroll', viewed);
  function addRow(thread: Thread) {
    const button = document.createElement('button'); button.type = 'button'; button.title = thread.sheet + ' · ' + thread.cell;
    button.dataset.thread = thread.id;
    const cell = document.createElement('strong'), sheet = document.createElement('span');
    cell.textContent = thread.cell; button.append(cell, sheet);
    button.addEventListener('click', () => openThread(thread, true));
    rows.set(thread.id, button); list.append(button); list.hidden = false;
  }
  function newDraftThread(target: Cell, id: string) {
    const allowed = creation.get(target.sheet);
    const thread: Thread = { ...target, id, version: null, resolved: false, messages: [],
      editable: !!allowed && !allowed.has(target.cell) && !atCell(target) };
    threadList.push(thread); addRow(thread);
    return thread;
  }
  add.addEventListener('click', async () => {
    if (add.disabled) return;
    const token = ++navigation;
    try {
      const target = await activeCell();
      if (token !== navigation || panel.hidden || add.disabled) return;
      if (!target) { status.textContent = '请先选中一个单元格'; return; }
      const existing = atCell(target);
      if (existing) { openThread(existing, true); if (!reply.readOnly) reply.focus(); return; }
      const allowed = creation.get(target.sheet);
      if (!allowed) { status.textContent = '当前工作表暂不支持新建评论'; return; }
      if (allowed.has(target.cell) || noteAt(target)) { status.textContent = '此单元格已有备注'; return; }
      const thread = newDraftThread(target, newID());
      openThread(thread, true);
      rows.get(thread.id)?.scrollIntoView({ block: 'nearest' }); reply.focus();
    } catch {
      if (token === navigation) status.textContent = '无法读取当前单元格，请重新选择';
    }
  });
  cancel.addEventListener('click', () => {
    if (!selected || !composing(selected) || cancel.disabled) return;
    drafts.delete(selected.id); rows.get(selected.id)?.remove(); rows.delete(selected.id);
    threadList = threadList.filter(thread => thread !== selected);
    list.hidden = !threadList.length; selected = null; navigation += 1;
    renderThread(); add.focus(); draftChanged(drafts.size > 0); viewed();
  });
  toggleResolved.addEventListener('click', () => {
    if (!selected || toggleResolved.disabled || toggleResolved.hidden) return;
    const currentY = messages.scrollTop;
    const edit = editThread(selected);
    edit.resolved = !edit.resolved;
    if (edit.resolved === selected.resolved && !edit.opening && !edit.replies.length) edits.delete(selected.id);
    renderThread(); messages.scrollTop = currentY; edited();
  });
  send.addEventListener('click', () => {
    if (!selected || send.disabled) return;
    const text = drafts.get(selected.id)?.text;
    if (!text?.trim()) return;
    const edit = editThread(selected);
    const first = composing(selected);
    const message = { id: first ? selected.id : newID(), time: new Date().toISOString(), text };
    if (first) edit.opening = message;
    else edit.replies.push(message);
    drafts.delete(selected.id);
    renderThread(); messages.scrollTop = messages.scrollHeight;
    reply.focus(); edited(); draftChanged(drafts.size > 0);
  });
  function hide() {
    if (panel.hidden) return;
    panel.hidden = true; navigation += 1; viewed();
  }
  close.addEventListener('click', hide);
  panel.addEventListener('keydown', event => {
    if (event.key === 'Escape') { event.stopPropagation(); hide(); }
    if (event.target === reply && event.key === 'Enter' && event.metaKey) { event.preventDefault(); send.click(); }
  });

  return {
    configure(catalog: Catalog) {
      loaded = true; threadList = catalog.threads; incomplete = catalog.incomplete; author = catalog.author;
      creation = new Map(Object.entries(catalog.creation).map(([sheet, cells]) => [sheet, new Set(cells)]));
      rows.clear(); list.replaceChildren();
      for (const thread of threadList) addRow(thread);
      list.hidden = !threadList.length; renderThread();
    },
    hasDraft() { return drafts.size > 0; },
    setLocked(value: boolean) { locked = value; updateControls(); },
    hide,
    toggle() {
      if (!panel.hidden) { hide(); return false; }
      panel.hidden = false;
      (selected ? rows.get(selected.id) : rows.values().next().value ?? (add.disabled ? close : add))?.focus();
      viewed(); return true;
    },
    edits() { return [...edits.values()]; },
    capture(): SpreadsheetThreadsLocation | undefined {
      if (!loaded || panel.hidden && !drafts.size) return undefined;
      bookmarkReply();
      const retained = selected && (!composing(selected) || drafts.has(selected.id));
      return { open: !panel.hidden, selected: retained ? selected?.id ?? null : null, listY: list.scrollTop, bodyY: messages.scrollTop,
        replyFocused: document.activeElement === reply, drafts: [...drafts.values()] };
    },
    restore(location: SpreadsheetThreadsLocation, focus: boolean) {
      if (!loaded) throw new Error('评论列表尚未加载');
      drafts.clear();
      for (const item of location.drafts) {
        drafts.set(item.id, { ...item });
        if (item.target && !rows.has(item.id)) newDraftThread(item.target, item.id);
      }
      selected = threadList.find(thread => thread.id === location.selected) ?? null;
      panel.hidden = !location.open; renderThread();
      list.scrollTop = location.listY; messages.scrollTop = location.bodyY;
      if (focus && location.replyFocused && location.open && selected && !composer.hidden) reply.focus();
    },
    reset() {
      navigation += 1; panel.hidden = true; loaded = false; selected = null; threadList = []; incomplete = false; author = '';
      drafts.clear(); edits.clear(); rows.clear(); creation.clear(); list.replaceChildren(); renderThread();
    },
    hasThread(cell: Cell) { return !!atCell(cell); },
    selectedCell() { return panel.hidden ? null : selected; },
  };
}

type Message = { id: string; parent?: string; author: string; time?: string; text: string };
type Thread = { id: string; sheet: string; cell: string; version: string; resolved: boolean; editable: boolean; messages: Message[] };
type Catalog = { threads: Thread[]; incomplete: boolean; author: string };
type Reply = { id: string; time: string; text: string };
type Edit = Pick<Thread, 'id' | 'sheet' | 'cell' | 'version' | 'resolved'> & { replies: Reply[] };
type Draft = { id: string; text: string; start: number; end: number };
export type SpreadsheetThreadsLocation = {
  open: boolean; selected: string | null; listY: number; bodyY: number; replyFocused: boolean; drafts: Draft[];
};

const maxReply = 32_767, maxDraftsLength = 128_000;
const threadID = /^\{[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\}$/;
const validText = (value: string) => !/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uD800-\uDFFF\uFFFE\uFFFF]/u.test(value);
const keys = (value: any, fields: string[]) => value && typeof value === 'object' && !Array.isArray(value) &&
  Object.keys(value).length === fields.length && Object.keys(value).every(key => fields.includes(key));
const offset = (n: any, max: number) => Number.isSafeInteger(n) && n >= 0 && n <= max;

export function validSpreadsheetThreadsLocation(value: any): value is SpreadsheetThreadsLocation {
  if (!keys(value, ['open', 'selected', 'listY', 'bodyY', 'replyFocused', 'drafts']) ||
      typeof value.open !== 'boolean' || typeof value.replyFocused !== 'boolean' ||
      !(value.selected === null || typeof value.selected === 'string' && threadID.test(value.selected)) ||
      ![value.listY, value.bodyY].every(n => Number.isFinite(n) && n >= 0 && n <= 1e9) ||
      !Array.isArray(value.drafts) || value.drafts.length > 5_000) return false;
  const ids = new Set<string>();
  let length = 0;
  for (const draft of value.drafts) {
    if (!keys(draft, ['id', 'text', 'start', 'end']) || typeof draft.id !== 'string' || !threadID.test(draft.id) || ids.has(draft.id) ||
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

export function createSpreadsheetThreads(root: HTMLElement, locate: (cell: { sheet: string; cell: string }) => Promise<void>,
  edited: () => void, viewed: () => void, draftChanged: (draft: boolean) => void) {
  const panel = document.createElement('aside');
  panel.className = 'spreadsheet-annotation spreadsheet-threads'; panel.hidden = true; panel.setAttribute('aria-label', '单元格评论');
  const header = document.createElement('header'), title = document.createElement('h2');
  title.textContent = '单元格评论';
  const close = document.createElement('button'); close.type = 'button'; close.textContent = '关闭';
  header.append(title, close);
  const list = document.createElement('div');
  list.className = 'spreadsheet-notes-list spreadsheet-thread-list'; list.setAttribute('aria-label', '评论列表');
  const threadView = document.createElement('div'); threadView.className = 'spreadsheet-thread-detail'; threadView.hidden = true;
  const threadHeader = document.createElement('div'); threadHeader.className = 'spreadsheet-thread-header';
  const cellLabel = document.createElement('strong');
  const toggleResolved = document.createElement('button'); toggleResolved.type = 'button'; toggleResolved.className = 'spreadsheet-thread-resolve';
  threadHeader.append(cellLabel, toggleResolved);
  const messages = document.createElement('div'); messages.className = 'spreadsheet-thread-messages'; messages.tabIndex = 0;
  messages.setAttribute('aria-label', '评论正文');
  const composer = document.createElement('div'); composer.className = 'spreadsheet-thread-composer';
  const reply = document.createElement('textarea'); reply.rows = 2; reply.maxLength = maxReply; reply.placeholder = '输入回复…';
  reply.setAttribute('aria-label', '回复草稿');
  const send = document.createElement('button'); send.type = 'button'; send.textContent = '添加回复'; send.className = 'spreadsheet-thread-reply';
  composer.append(reply, send); threadView.append(threadHeader, messages, composer);
  const status = document.createElement('p'); status.className = 'spreadsheet-notes-status'; status.setAttribute('role', 'status');
  panel.append(header, list, threadView, status); root.after(panel);

  let loaded = false, locked = true, incomplete = false, author = '';
  let selected: Thread | null = null, threadList: Thread[] = [], navigation = 0;
  const drafts = new Map<string, Draft>();
  const edits = new Map<string, Edit>();
  const rows = new Map<string, HTMLButtonElement>();

  const resolved = (thread: Thread) => edits.get(thread.id)?.resolved ?? thread.resolved;
  function editThread(thread: Thread) {
    let edit = edits.get(thread.id);
    if (!edit) {
      const { id, sheet, cell, resolved, version } = thread;
      edit = { id, sheet, cell, resolved, version, replies: [] };
      edits.set(thread.id, edit);
    }
    return edit;
  }
  function updateControls() {
    const thread = selected;
    const resolvedThread = thread && resolved(thread);
    const canWrite = !!thread?.editable && !locked;
    toggleResolved.disabled = !canWrite;
    toggleResolved.textContent = resolvedThread ? '重新打开' : '解决';
    composer.hidden = !thread || !!resolvedThread && !drafts.has(thread.id);
    reply.readOnly = !canWrite || !!resolvedThread;
    send.disabled = reply.readOnly || !reply.value.trim();
  }
  function renderRow(thread: Thread) {
    const row = rows.get(thread.id)!;
    row.setAttribute('aria-pressed', String(thread === selected));
    row.dataset.resolved = String(resolved(thread));
    const detail = row.querySelector('span')!;
    detail.textContent = resolved(thread) ? thread.sheet + ' · 已解决' : thread.sheet;
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
    const additional = thread ? (edits.get(thread.id)?.replies ?? []).map(item => ({ ...item, author, parent: thread.id })) : [];
    messages.replaceChildren(...[...(thread?.messages ?? []), ...additional].map(renderMessage));
    messages.scrollTop = 0;
    status.textContent = incomplete ? '部分评论无法读取' : !threadList.length ? '暂无评论' : thread && !thread.editable ? '此评论只读' : '';
    updateControls();
  }
  function openThread(thread: Thread, seek: boolean) {
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
    if (reply.value) drafts.set(id, { id, text: reply.value, start: reply.selectionStart, end: reply.selectionEnd });
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
  toggleResolved.addEventListener('click', () => {
    if (!selected || toggleResolved.disabled) return;
    const currentY = messages.scrollTop;
    const edit = editThread(selected);
    edit.resolved = !edit.resolved;
    if (edit.resolved === selected.resolved && !edit.replies.length) edits.delete(selected.id);
    renderThread(); messages.scrollTop = currentY; edited();
  });
  send.addEventListener('click', () => {
    if (!selected || send.disabled) return;
    const text = drafts.get(selected.id)?.text;
    if (!text?.trim()) return;
    const edit = editThread(selected);
    edit.replies.push({ id: '{' + crypto.randomUUID().toUpperCase() + '}', time: new Date().toISOString(), text });
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
  });

  return {
    configure(catalog: Catalog) {
      loaded = true; threadList = catalog.threads; incomplete = catalog.incomplete; author = catalog.author;
      rows.clear();
      for (const thread of threadList) {
        const button = document.createElement('button'); button.type = 'button'; button.title = thread.sheet + ' · ' + thread.cell;
        button.dataset.thread = thread.id;
        const cell = document.createElement('strong'), sheet = document.createElement('span');
        cell.textContent = thread.cell; button.append(cell, sheet);
        button.addEventListener('click', () => openThread(thread, true));
        rows.set(thread.id, button);
      }
      list.replaceChildren(...rows.values()); list.hidden = !threadList.length; renderThread();
    },
    hasDraft() { return drafts.size > 0; },
    setLocked(value: boolean) { locked = value; updateControls(); },
    hide,
    toggle() {
      if (!panel.hidden) { hide(); return false; }
      panel.hidden = false;
      (selected ? rows.get(selected.id) : rows.values().next().value ?? close)?.focus();
      viewed(); return true;
    },
    edits() { return [...edits.values()]; },
    capture(): SpreadsheetThreadsLocation | undefined {
      if (!loaded || panel.hidden && !drafts.size) return undefined;
      bookmarkReply();
      return { open: !panel.hidden, selected: selected?.id ?? null, listY: list.scrollTop, bodyY: messages.scrollTop,
        replyFocused: document.activeElement === reply, drafts: [...drafts.values()] };
    },
    restore(location: SpreadsheetThreadsLocation, focus: boolean) {
      if (!loaded) throw new Error('评论列表尚未加载');
      drafts.clear(); for (const item of location.drafts) drafts.set(item.id, { ...item });
      selected = threadList.find(thread => thread.id === location.selected) ?? null;
      panel.hidden = !location.open; renderThread();
      list.scrollTop = location.listY; messages.scrollTop = location.bodyY;
      if (focus && location.replyFocused && location.open && selected && !composer.hidden) reply.focus();
    },
    reset() {
      navigation += 1; panel.hidden = true; loaded = false; selected = null; threadList = []; incomplete = false; author = '';
      drafts.clear(); edits.clear(); rows.clear(); list.replaceChildren(); renderThread();
    },
    selectedCell() { return panel.hidden ? null : selected; },
  };
}

import type { CommentSnapshot, DeckSnapshot } from '@betteroffice/pptx';

type SlideRef = { part: string | null; index: number };
type LegacyCommentID = { author: number; index: number };
type Anchor = { slide: SlideRef; thread: string | null; legacyID?: LegacyCommentID };
type Target = { slideId: string | null; commentId: string | null; anchor: Anchor };
type Draft = { text: string; start: number; end: number; direction: 'none' | 'forward' | 'backward' };
export type PresentationReview = {
  open: boolean; selected: Anchor | null; drafts: (Draft & { target: Anchor })[];
  focused: boolean; listY: number; messageY: number;
};
type Thread = { target: Target; opening: CommentSnapshot; replies: CommentSnapshot[] };
type Slide = { id: string; ref: SlideRef; title: string };
type Catalog = { slides: Slide[]; threads: Thread[]; modern: boolean };
export type PresentationCommentChange =
  | { kind: 'add'; slideId: string; text: string }
  | { kind: 'reply'; slideId: string; commentId: string; text: string }
  | { kind: 'resolve'; slideId: string; commentId: string; resolved: boolean };
type Services = {
  read: () => Promise<DeckSnapshot>;
  currentSlide: () => number | null;
  navigate: (slideId: string) => Promise<void>;
  write: (change: PresentationCommentChange) => Promise<string>;
  viewChanged: () => void;
  draftChanged: (hasDraft: boolean) => void;
};

const maxText = 32_767, maxDraftText = 128_000;
const int = (v: unknown, max: number) => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0 && v <= max;
const keys = (v: any, names: string[]) => v && typeof v === 'object' && !Array.isArray(v) &&
  Object.keys(v).length === names.length && names.every(name => Object.hasOwn(v, name));
const offset = (v: unknown) => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1e9;
const validAnchor = (v: any): v is Anchor => (keys(v, ['slide', 'thread']) ||
  keys(v, ['slide', 'thread', 'legacyID']) && v.thread !== null && keys(v.legacyID, ['author', 'index']) &&
  int(v.legacyID.author, 0xffffffff) && int(v.legacyID.index, 0xffffffff)) && keys(v.slide, ['part', 'index']) &&
  int(v.slide.index, 1_000_000) && v.slide.index > 0 &&
  (v.slide.part === null || typeof v.slide.part === 'string' && v.slide.part.length > 0 && v.slide.part.length <= 2048 && !v.slide.part.includes('\0')) &&
  (v.thread === null || typeof v.thread === 'string' && /^[a-f0-9]{64}$/.test(v.thread));
const anchorKey = (anchor: Anchor) => JSON.stringify([anchor.slide.part ?? anchor.slide.index, anchor.thread, anchor.legacyID]);
const targetKey = (target: Target) => target.slideId ? JSON.stringify([target.slideId, target.commentId]) : anchorKey(target.anchor);
export function validPresentationReview(v: any): v is PresentationReview {
  return keys(v, ['open', 'selected', 'drafts', 'focused', 'listY', 'messageY']) &&
    typeof v.open === 'boolean' && typeof v.focused === 'boolean' && (!v.focused || v.open && !!v.selected) &&
    (v.selected === null || validAnchor(v.selected)) && offset(v.listY) && offset(v.messageY) &&
    Array.isArray(v.drafts) && v.drafts.length <= 5000 && v.drafts.every((d: any) =>
      keys(d, ['target', 'text', 'start', 'end', 'direction']) && validAnchor(d.target) &&
      typeof d.text === 'string' && d.text.length > 0 && d.text.length <= maxText &&
      int(d.start, d.text.length) && int(d.end, d.text.length) && d.start <= d.end && ['none', 'forward', 'backward'].includes(d.direction)) &&
    v.drafts.reduce((n: number, d: Draft) => n + d.text.length, 0) <= maxDraftText &&
    new Set(v.drafts.map((d: Draft & { target: Anchor }) => anchorKey(d.target))).size === v.drafts.length;
}

async function digest(value: string) {
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
  return Array.from(hash, v => v.toString(16).padStart(2, '0')).join('');
}
function legacyCommentID(id: string): LegacyCommentID | undefined {
  const match = /^comment:\d+:(\d+):(\d+)$/.exec(id);
  if (!match) return;
  const author = Number(match[1]), index = Number(match[2]);
  if (int(author, 0xffffffff) && int(index, 0xffffffff)) return { author, index };
}
function fingerprint(comment: CommentSnapshot) {
  // The worker assigns new session IDs before save. Match the unchanged
  // opening message on the same slide after reopening the exported package.
  return digest(JSON.stringify([comment.author, comment.created, comment.xEmu, comment.yEmu, comment.text]));
}

export async function legacyReplyLinks(deck: DeckSnapshot, parents: ReadonlyMap<string, string>) {
  const comments = new Map((deck.comments ?? []).map(comment => [comment.id, comment]));
  const slides = new Map(deck.slides.map((slide, index) => [slide.id, index + 1]));
  const identify = async (comment: CommentSnapshot) => {
    const source = legacyCommentID(comment.id);
    return { signature: await digest([comment.author, comment.created ?? '', comment.text].join('\0')), ...(source ? { source } : {}) };
  };
  const links = [];
  for (const [replyID, parentID] of parents) {
    const reply = comments.get(replyID), parent = comments.get(parentID);
    // Slide deletion removes its comments from the document.
    if (!reply && parent && slides.has(parent.slideId)) throw new Error('待保存的回复不可用，原文件及草稿已保留');
    if (!reply) continue;
    const slide = slides.get(reply.slideId);
    if (slide === undefined) continue;
    if (!parent || parent.slideId !== reply.slideId || parent.parentId !== null) {
      throw new Error('旧版回复的原批注无法找到，原文件及草稿已保留');
    }
    links.push({ slide, reply: await identify(reply), parent: await identify(parent) });
  }
  return links;
}
function plainTarget(slide: Slide): Target {
  return { slideId: slide.id, commentId: null, anchor: { slide: slide.ref, thread: null } };
}
async function indexDeck(deck: DeckSnapshot): Promise<Catalog> {
  const slides = deck.slides.map((slide, index) => ({
    id: slide.id, ref: { part: slide.sourcePartPath ?? null, index: index + 1 }, title: slide.title ?? slide.name ?? '',
  }));
  const owners = new Map(slides.map(slide => [slide.id, slide]));
  const roots = (deck.comments ?? []).filter(comment => comment.parentId === null);
  const replies = new Map<string, CommentSnapshot[]>();
  for (const comment of deck.comments ?? []) {
    if (!comment.parentId) continue;
    const siblings = replies.get(comment.parentId) ?? [];
    siblings.push(comment); replies.set(comment.parentId, siblings);
  }
  const threads: Thread[] = [];
  for (const opening of roots) {
    const slide = owners.get(opening.slideId);
    if (!slide) continue;
    const legacyID = deck.commentFlavor === 'modern' ? undefined : legacyCommentID(opening.id);
    const target = { slideId: slide.id, commentId: opening.id,
      anchor: { slide: slide.ref, thread: await fingerprint(opening), ...(legacyID ? { legacyID } : {}) } };
    threads.push({ target, opening, replies: replies.get(opening.id) ?? [] });
  }
  return { slides, threads, modern: deck.commentFlavor === 'modern' };
}
function resolve(anchor: Anchor, catalog: Catalog): Target {
  const missing = { slideId: null, commentId: null, anchor };
  const slide = catalog.slides.find(item => anchor.slide.part === null ? item.ref.index === anchor.slide.index : item.ref.part === anchor.slide.part);
  if (!slide) return missing;
  if (anchor.thread === null) return plainTarget(slide);
  const matches = catalog.threads.filter(item => {
    const candidate = item.target.anchor;
    return item.target.slideId === slide.id && candidate.thread === anchor.thread &&
      (!anchor.legacyID || candidate.legacyID?.author === anchor.legacyID.author && candidate.legacyID.index === anchor.legacyID.index);
  });
  return matches.length === 1 ? matches[0].target : missing;
}

export function createPresentationComments(root: HTMLElement, service: Services) {
  function button(text: string, className = '') {
    const value = document.createElement('button');
    value.type = 'button'; value.textContent = text; value.className = className;
    return value;
  }
  const panel = document.createElement('aside');
  panel.className = 'spreadsheet-annotation spreadsheet-threads'; panel.id = 'presentation-comments';
  panel.hidden = true; panel.setAttribute('aria-label', 'PowerPoint 批注');
  const header = document.createElement('header'), title = document.createElement('h2'), close = button('关闭');
  title.textContent = '批注'; close.setAttribute('aria-label', '关闭 PowerPoint 批注'); header.append(title, close);
  const add = button('新建批注', 'spreadsheet-note-add');
  const list = document.createElement('div'); list.className = 'spreadsheet-notes-list spreadsheet-thread-list'; list.setAttribute('aria-label', '幻灯片批注列表');
  const detail = document.createElement('div'); detail.className = 'spreadsheet-thread-detail';
  const heading = document.createElement('div'); heading.className = 'spreadsheet-thread-header';
  const slideLabel = document.createElement('strong'), resolveButton = button('解决'), cancel = button('取消草稿');
  heading.append(slideLabel, resolveButton, cancel);
  const messages = document.createElement('div'); messages.className = 'spreadsheet-thread-messages'; messages.tabIndex = 0;
  messages.setAttribute('aria-label', 'PowerPoint 批注正文');
  const composer = document.createElement('div'); composer.className = 'spreadsheet-thread-composer';
  const input = document.createElement('textarea'); input.rows = 2; input.maxLength = maxText;
  input.setAttribute('aria-label', 'PowerPoint 批注草稿');
  const submit = button('添加批注', 'spreadsheet-thread-reply');
  composer.append(input, submit); detail.append(heading, messages, composer);
  const status = document.createElement('p'); status.className = 'spreadsheet-notes-status'; status.setAttribute('role', 'status');
  panel.append(header, add, list, detail, status); root.after(panel);

  const drafts = new Map<string, { target: Target; value: Draft }>();
  let selected: Target | null = null, locked = true, busy = false, focusOnAppear = false;
  let epoch = 0, version = 0;
  let catalog: Catalog = { slides: [], threads: [], modern: false }, loadedVersion = -1;
  async function refresh() {
    if (loadedVersion === version) return;
    const owner = epoch, requested = version, next = await indexDeck(await service.read());
    if (epoch !== owner) throw new Error('文档已切换');
    if (requested >= loadedVersion) { catalog = next; loadedVersion = requested; }
  }
  const findThread = (target: Target | null) => target?.commentId && catalog.threads.find(thread =>
    thread.opening.id === target.commentId && thread.target.slideId === target.slideId) || undefined;
  const findSlide = (target: Target | null) => catalog.slides.find(slide => slide.id === target?.slideId);
  function checkpoint(target: Target) {
    return findThread(target)?.target.anchor ?? (target.anchor.thread !== null ? target.anchor : { slide: findSlide(target)?.ref ?? target.anchor.slide, thread: null });
  }
  function rememberDraft() {
    if (!selected) return;
    const key = targetKey(selected);
    if (input.value) drafts.set(key, { target: selected, value: { text: input.value, start: input.selectionStart,
      end: input.selectionEnd, direction: input.selectionDirection } });
    else drafts.delete(key);
  }
  function writeDraft() {
    const total = [...drafts].reduce((n, [key, draft]) => n + (key === (selected && targetKey(selected)) ? 0 : draft.value.text.length), input.value.length);
    if (total > maxDraftText) {
      const saved = selected && drafts.get(targetKey(selected))?.value;
      input.value = saved?.text ?? '';
      if (saved) input.setSelectionRange(saved.start, saved.end, saved.direction);
      status.textContent = '批注草稿总量已达上限，请先提交或取消其他草稿';
      return;
    }
    rememberDraft(); service.draftChanged(drafts.size > 0); updateControls();
  }
  function available(target: Target | null) {
    return !!findSlide(target) && (target?.anchor.thread === null || !!findThread(target));
  }
  function updateControls() {
    const thread = findThread(selected);
    const writable = !locked && !busy && available(selected);
    add.disabled = locked || busy;
    input.readOnly = !writable || thread?.opening.resolved === true;
    submit.disabled = input.readOnly || !input.value.trim();
    resolveButton.hidden = !thread || !catalog.modern;
    resolveButton.disabled = !writable;
    cancel.hidden = !selected || !drafts.has(targetKey(selected)) && selected.anchor.thread !== null;
    cancel.disabled = busy;
  }
  function textFor(target: Target) {
    const slide = findSlide(target);
    return '第 ' + (slide?.ref.index ?? target.anchor.slide.index) + ' 张';
  }
  function cards(value: CommentSnapshot) {
    const card = document.createElement('article'); card.className = 'spreadsheet-thread-message';
    if (value.parentId) card.dataset.parent = value.parentId;
    const row = document.createElement('div'), author = document.createElement('strong'), date = document.createElement('time');
    author.textContent = value.author || '未知作者';
    const moment = new Date(value.created ?? '');
    if (Number.isFinite(moment.getTime())) { date.dateTime = moment.toISOString(); date.textContent = moment.toLocaleString(); }
    row.append(author, date);
    const text = document.createElement('p'); text.textContent = value.text;
    card.append(row, text); return card;
  }
  function render() {
    const thread = findThread(selected), draft = selected && drafts.get(targetKey(selected))?.value;
    const listY = list.scrollTop, messageY = messages.scrollTop;
    const targets = new Map(catalog.threads.map(row => [targetKey(row.target), row.target]));
    for (const { target } of drafts.values()) targets.set(targetKey(target), target);
    if (selected) targets.set(targetKey(selected), selected);
    list.replaceChildren(...[...targets.values()].map(target => {
      const entry = findThread(target), key = targetKey(target);
      const row = button('');
      row.setAttribute('aria-pressed', String(!!selected && key === targetKey(selected)));
      const slide = document.createElement('strong'); slide.textContent = textFor(target);
      const label = document.createElement('span');
      label.textContent = entry ? (entry.opening.text || entry.opening.author).split('\n')[0] : '批注草稿';
      if (entry?.opening.resolved) label.textContent += ' · 已解决';
      if (drafts.has(key) && entry) label.textContent += ' · 草稿';
      row.title = findSlide(target)?.title ?? '';
      row.append(slide, label);
      row.onclick = () => run(async () => {
        rememberDraft();
        selected = target; messages.scrollTop = 0; render();
        if (available(target) && target.slideId) await service.navigate(target.slideId);
        service.viewChanged();
      });
      return row;
    }));
    list.scrollTop = listY;
    detail.hidden = !selected;
    slideLabel.textContent = selected ? textFor(selected) : '';
    const first = selected?.anchor.thread === null;
    input.placeholder = first ? '输入批注…' : '输入回复…';
    input.value = draft?.text ?? '';
    if (draft) input.setSelectionRange(draft.start, draft.end, draft.direction);
    submit.textContent = first ? '添加批注' : '添加回复';
    resolveButton.textContent = thread?.opening.resolved ? '重新打开' : '解决';
    messages.replaceChildren(...(thread ? [thread.opening, ...thread.replies].map(cards) : []));
    messages.scrollTop = messageY;
    status.textContent = selected && !available(selected) ? '原幻灯片或批注不可用，草稿可复制' : targets.size ? '' : '暂无批注';
    updateControls();
  }
  function run(action: () => Promise<void>) {
    if (busy) return;
    const owner = epoch;
    busy = true; updateControls();
    void action().catch(error => { if (owner === epoch) status.textContent = error instanceof Error ? error.message : String(error); })
      .finally(() => { if (owner === epoch) { busy = false; updateControls(); } });
  }
  async function changeStatus() {
    const entry = findThread(selected);
    if (locked || !entry || !catalog.modern || !entry.target.slideId) return;
    await service.write({ kind: 'resolve', slideId: entry.target.slideId, commentId: entry.opening.id, resolved: !entry.opening.resolved });
    version += 1; await refresh(); render();
  }
  async function submitDraft() {
    if (locked || !selected?.slideId || !available(selected) || !input.value.trim()) return;
    rememberDraft();
    const original = selected, slideId = selected.slideId, text = input.value;
    const thread = findThread(original);
    const id = await service.write(thread ? { kind: 'reply', slideId, commentId: thread.opening.id, text }
      : { kind: 'add', slideId, text });
    drafts.delete(targetKey(original)); input.value = '';
    service.draftChanged(drafts.size > 0);
    version += 1; await refresh();
    selected = catalog.threads.find(value => value.opening.id === id)?.target ?? original;
    render(); messages.scrollTop = messages.scrollHeight;
  }
  function hide() { rememberDraft(); panel.hidden = true; focusOnAppear = false; service.viewChanged(); }
  async function toggle() {
    if (!panel.hidden) { hide(); return false; }
    await refresh();
    panel.hidden = false; render(); service.viewChanged();
    return true;
  }
  close.onclick = hide;
  add.onclick = () => run(async () => {
    if (locked) return;
    rememberDraft(); await refresh();
    const slide = catalog.slides.find(item => item.ref.index === service.currentSlide());
    if (!slide) throw new Error('请先选择一张幻灯片');
    selected = plainTarget(slide); messages.scrollTop = 0; render(); input.focus(); service.viewChanged();
  });
  submit.onclick = () => run(submitDraft);
  resolveButton.onclick = () => run(changeStatus);
  cancel.onclick = () => {
    if (!selected || busy) return;
    drafts.delete(targetKey(selected)); input.value = '';
    if (selected.anchor.thread === null || !available(selected)) selected = null;
    render(); service.draftChanged(drafts.size > 0);
  };
  input.addEventListener('input', writeDraft);
  input.addEventListener('select', () => { rememberDraft(); service.viewChanged(); });
  input.addEventListener('focus', service.viewChanged);
  input.addEventListener('blur', service.viewChanged);
  input.addEventListener('keydown', event => {
    if (event.key === 'Enter' && event.metaKey && !event.isComposing && !submit.disabled) { event.preventDefault(); run(submitDraft); }
  });
  for (const node of [list, messages]) node.addEventListener('scroll', service.viewChanged);
  return {
    toggle,
    setLocked(value: boolean) { locked = value; updateControls(); },
    invalidate() { version += 1; },
    hasDraft: () => drafts.size > 0,
    async capture(): Promise<PresentationReview | undefined> {
      rememberDraft();
      if (panel.hidden && !drafts.size) return;
      await refresh();
      const value = { open: !panel.hidden, selected: selected ? checkpoint(selected) : null,
        drafts: [...drafts.values()].map(({ target, value }) => ({ target: checkpoint(target), ...value })),
        focused: !panel.hidden && (focusOnAppear || document.activeElement === input), listY: list.scrollTop, messageY: messages.scrollTop };
      if (!validPresentationReview(value)) throw new Error('PowerPoint 批注位置无法保存，原草稿已保留');
      return value;
    },
    async restore(value: PresentationReview) {
      await refresh(); drafts.clear();
      for (const { target, ...draft } of value.drafts) {
        const location = resolve(target, catalog); drafts.set(targetKey(location), { target: location, value: draft });
      }
      selected = value.selected ? resolve(value.selected, catalog) : null;
      panel.hidden = !value.open; render();
      list.scrollTop = value.listY; messages.scrollTop = value.messageY;
      focusOnAppear = value.focused;
    },
    focusRestoredDraft() {
      if (panel.hidden || !selected) return false;
      if (document.activeElement === input) { focusOnAppear = false; return true; }
      if (!focusOnAppear) return false;
      input.focus({ preventScroll: true });
      if (document.activeElement !== input) return false;
      focusOnAppear = false;
      return true;
    },
    reset() {
      epoch += 1; version += 1; busy = false; locked = true; focusOnAppear = false;
      selected = null; drafts.clear(); input.value = ''; panel.hidden = true;
    },
  };
}

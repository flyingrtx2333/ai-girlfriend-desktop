export type MentionRecipient = { id?: string; name: string; email?: string };
export type ThreadMention = { id: string; start: number; length: number; recipient: MentionRecipient };
export type CommentInputRange = { start: number; end: number; inputType: string };
type Query = { start: number; end: number; text: string };

export const commentGUID = /^\{[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\}$/;
export const validCommentText = (value: string) => !/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uD800-\uDFFF\uFFFE\uFFFF]/u.test(value);
const addressPattern = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$/;
const validAddress = (value: string) => value.length <= 254 && !/\s/.test(value) && addressPattern.test(value);

export function validDraftMentions(value: any, text: string): value is ThreadMention[] {
  if (!Array.isArray(value) || value.length > text.length) return false;
  const ids = new Set<string>();
  let end = 0;
  for (const item of value) {
    if (!item || typeof item !== 'object' || Object.keys(item).length !== 4 ||
        typeof item.id !== 'string' || !commentGUID.test(item.id) || ids.has(item.id) ||
        !Number.isSafeInteger(item.start) || !Number.isSafeInteger(item.length) ||
        item.start < end || item.length < 2 || item.length > text.length - item.start) return false;
    const person = item.recipient;
    if (!person || typeof person !== 'object' || Object.keys(person).length !== (person.email === undefined ? 2 : 3) ||
        typeof person.id !== 'string' || !commentGUID.test(person.id) ||
        (person.email !== undefined && (typeof person.email !== 'string' || !validAddress(person.email))) ||
        typeof person.name !== 'string' || !person.name.trim() || person.name.length > 254 ||
        /[\r\n]/.test(person.name) || !validCommentText(person.name) ||
        text.slice(item.start, item.start + item.length) !== '@' + person.name) return false;
    ids.add(item.id); end = item.start + item.length;
  }
  return true;
}

export function moveMentions(previous: string, next: string, mentions: ThreadMention[], range?: CommentInputRange): ThreadMention[] {
  if (!mentions.length || previous === next) return mentions;
  const delta = next.length - previous.length;
  let left = 0, right = previous.length;
  if (range) {
    left = range.start; right = range.end;
    if (left === right && delta < 0) {
      if (range.inputType.endsWith('Backward')) left += delta;
      if (range.inputType.endsWith('Forward')) right -= delta;
    }
  }
  if (!range || range.inputType.startsWith('history') || left < 0 || right > previous.length || right + delta < left ||
      previous.slice(0, left) !== next.slice(0, left) || previous.slice(right) !== next.slice(right + delta)) {
    const shared = Math.min(previous.length, next.length);
    let prefix = 0, suffix = 0;
    while (prefix < shared && previous[prefix] === next[prefix]) prefix++;
    while (suffix < shared && previous[previous.length - suffix - 1] === next[next.length - suffix - 1]) suffix++;
    // A repeated span can make the edit ambiguous. Keep only unambiguous ranges.
    left = Math.min(prefix, shared - suffix);
    right = previous.length - Math.min(suffix, shared - prefix);
  }
  const result: ThreadMention[] = [];
  for (const item of mentions) {
    if (item.start + item.length <= left) result.push(item);
    else if (item.start >= right) result.push({ ...item, start: item.start + delta });
  }
  return result;
}

function queryAt(input: HTMLTextAreaElement): Query | null {
  if (input.selectionStart !== input.selectionEnd) return null;
  const end = input.selectionStart;
  const lineStart = input.value.lastIndexOf('\n', end - 1) + 1;
  const line = input.value.slice(lineStart, end);
  const marker = /(?:^|[^A-Za-z0-9._%+@-])[@＠]/g;
  const matches = [...line.matchAll(marker)];
  const last = matches.at(-1);
  if (!last) return null;
  const start = lineStart + last.index! + last[0].length - 1, text = input.value.slice(start + 1, end);
  return text.length <= 254 && !/[<>\[\]{}\t]/.test(text) ? { start, end, text } : null;
}

export function createMentionPicker(input: HTMLTextAreaElement, recipients: () => MentionRecipient[],
  bound: () => ThreadMention[], choose: (query: Query, recipient: MentionRecipient) => void) {
  const pane = document.createElement('div');
  pane.className = 'spreadsheet-mention-picker'; pane.id = 'spreadsheet-comment-mentions'; pane.hidden = true;
  pane.setAttribute('role', 'listbox'); pane.setAttribute('aria-label', '提及联系人');
  input.setAttribute('aria-controls', pane.id); input.setAttribute('aria-autocomplete', 'list');
  let query: Query | null = null, options: MentionRecipient[] = [], highlighted = 0, dismissed = '';

  function hide() {
    pane.hidden = true; query = null; options = []; highlighted = 0; pane.replaceChildren();
    input.removeAttribute('aria-activedescendant');
  }
  function select(index: number) {
    highlighted = index;
    for (const [i, item] of Array.from(pane.querySelectorAll('button')).entries()) {
      item.setAttribute('aria-selected', String(i === index));
      if (i === index) {
        input.setAttribute('aria-activedescendant', item.id);
        item.scrollIntoView({ block: 'nearest' });
      }
    }
  }
  function confirm(index: number) {
    const item = options[index], selection = query;
    if (item && selection && !input.readOnly) choose(selection, item);
    hide();
  }
  function refresh() {
    const next = !input.readOnly && document.activeElement === input ? queryAt(input) : null;
    const signature = next ? next.start + ':' + next.end + ':' + next.text : '';
    if (signature !== dismissed) dismissed = '';
    if (!next || signature === dismissed || bound().some(item => item.start === next.start)) { hide(); return; }
    const typed = next.text.trim(), lower = typed.toLowerCase();
    const matches = recipients().filter(person => person.name.toLowerCase().includes(lower) || person.email?.toLowerCase().includes(lower));
    if (validAddress(typed) && !matches.some(person => person.email?.toLowerCase() === lower)) matches.unshift({ name: typed, email: typed });
    const previous = options[highlighted];
    if (pane.hidden || query?.start !== next.start || query?.text !== next.text) highlighted = 0;
    else if (previous) {
      const key = (person: MentionRecipient) => person.id ?? person.email ?? person.name;
      highlighted = Math.max(0, matches.findIndex(candidate => key(candidate) === key(previous)));
    }
    query = next; options = matches.slice(0, 80);
    highlighted = Math.max(0, Math.min(highlighted, options.length - 1));
    pane.replaceChildren(); pane.hidden = false;
    if (!options.length) {
      input.removeAttribute('aria-activedescendant');
      const empty = document.createElement('p'); empty.setAttribute('role', 'status');
      empty.textContent = typed ? '可输入完整邮箱' : '输入姓名或邮箱'; pane.append(empty);
      return;
    }
    for (const [index, item] of options.entries()) {
      const button = document.createElement('button');
      button.type = 'button'; button.tabIndex = -1; button.id = pane.id + '-' + index;
      button.setAttribute('role', 'option'); button.dataset.recipient = item.id ?? item.email;
      const name = document.createElement('span'); name.textContent = item.name; button.append(name);
      if (item.email && item.email !== item.name) {
        const email = document.createElement('small'); email.textContent = item.email; button.append(email);
      }
      button.addEventListener('mousedown', event => event.preventDefault());
      button.addEventListener('click', () => confirm(index)); pane.append(button);
    }
    select(highlighted);
  }
  input.addEventListener('keydown', event => {
    if (!query || pane.hidden || event.isComposing) return;
    if (event.key === 'Escape') {
      dismissed = query.start + ':' + query.end + ':' + query.text; hide();
    } else if (options.length && (event.key === 'ArrowDown' || event.key === 'ArrowUp')) {
      select((highlighted + (event.key === 'ArrowDown' ? 1 : options.length - 1)) % options.length);
    } else if (options.length && (event.key === 'Enter' || event.key === 'Tab') && !event.metaKey && !event.ctrlKey && !event.shiftKey) {
      confirm(highlighted);
    } else { return; }
    event.preventDefault(); event.stopPropagation();
  });
  input.addEventListener('blur', hide);
  input.addEventListener('click', refresh);
  input.addEventListener('keyup', event => { if (!['Escape', 'ArrowDown', 'ArrowUp', 'Enter', 'Tab'].includes(event.key)) refresh(); });
  return { pane, refresh, hide };
}

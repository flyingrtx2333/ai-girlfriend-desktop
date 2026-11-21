type Cell = { sheet: string; cell: string };
type Note = Cell & { author: string; text: string; editable: boolean };
type NoteSelection = Cell & { start: number; end: number; focused: boolean };
export type SpreadsheetNotesLocation = { selected: NoteSelection | null; listY: number };

export function spreadsheetCell(address: string) {
  const match = /^([A-Z]{1,3})([1-9][0-9]{0,6})$/.exec(address);
  if (!match) throw new Error('单元格备注的位置无效');
  const row = Number(match[2]) - 1;
  const col = [...match[1]].reduce((n, c) => n * 26 + c.charCodeAt(0) - 64, 0) - 1;
  if (row >= 1_048_576 || col >= 16_384) throw new Error('单元格备注的位置无效');
  return { row, col };
}

export function validSpreadsheetNotesLocation(value: any): value is SpreadsheetNotesLocation {
  if (!value || Object.keys(value).length !== 2 || !Number.isFinite(value.listY) || value.listY < 0 || value.listY > 1e9) return false;
  const selected = value.selected;
  if (selected === null) return true;
  if (!selected || Object.keys(selected).length !== 5 || typeof selected.sheet !== 'string' ||
      !selected.sheet.length || selected.sheet.length > 256 || selected.sheet.includes('\0') ||
      typeof selected.cell !== 'string' || typeof selected.focused !== 'boolean' ||
      ![selected.start, selected.end].every(n => Number.isSafeInteger(n) && n >= 0 && n <= 32_767) || selected.start > selected.end) return false;
  try { spreadsheetCell(selected.cell); return true; } catch { return false; }
}

export function createSpreadsheetNotes(root: HTMLElement, locate: (cell: Cell) => Promise<void>, edited: () => void, viewed: () => void) {
  const panel = document.createElement('aside');
  panel.className = 'spreadsheet-notes'; panel.hidden = true; panel.setAttribute('aria-label', '单元格备注');
  const heading = document.createElement('header');
  const title = document.createElement('h2'); title.textContent = '单元格备注';
  const close = document.createElement('button'); close.type = 'button'; close.textContent = '关闭';
  heading.append(title, close);
  const list = document.createElement('div'); list.className = 'spreadsheet-notes-list'; list.setAttribute('aria-label', '备注列表');
  const status = document.createElement('p'); status.className = 'spreadsheet-notes-status'; status.setAttribute('role', 'status');
  const author = document.createElement('p'); author.className = 'spreadsheet-note-author'; author.hidden = true;
  const text = document.createElement('textarea');
  text.setAttribute('aria-label', '备注正文'); text.spellcheck = false; text.maxLength = 32_767; text.hidden = true;
  panel.append(heading, list, author, text, status); root.after(panel);
  let notes: Note[] = [], selected: Note | null = null, locked = true, issue = '';
  let loaded = false, navigation = 0;
  const replacements = new Map<Note, string>();
  const buttons = new Map<Note, HTMLButtonElement>();

  function refreshEditor() {
    const value = selected;
    author.hidden = !value?.author; author.textContent = value?.author ?? '';
    text.hidden = value === null;
    text.readOnly = locked || value?.editable !== true;
    text.value = value ? replacements.get(value) ?? value.text : '';
    status.textContent = issue || (!notes.length ? '暂无单元格备注' : value && !value.editable ? '此备注只读' : '');
    for (const [note, button] of buttons) button.setAttribute('aria-pressed', String(note === value));
  }

  function showNote(note: Note, seek: boolean) {
    const token = ++navigation;
    selected = note; refreshEditor(); viewed();
    if (seek) void locate(note).catch(() => {
      if (token === navigation) status.textContent = '无法定位原单元格，请核对工作表';
    });
  }

  close.addEventListener('click', () => { panel.hidden = true; navigation += 1; viewed(); });
  panel.addEventListener('keydown', event => { if (event.key === 'Escape') { event.stopPropagation(); close.click(); } });
  for (const event of ['select', 'focus', 'blur']) text.addEventListener(event, viewed);
  list.addEventListener('scroll', viewed);
  text.addEventListener('input', () => {
    if (!selected || text.readOnly) return;
    if (text.value === selected.text) replacements.delete(selected);
    else replacements.set(selected, text.value);
    edited();
  });

  return {
    configure(items: Note[], warning: string) {
      notes = items; issue = warning; loaded = true; selected = null;
      const rows = document.createDocumentFragment();
      for (const note of notes) {
        const button = document.createElement('button'); button.type = 'button';
        const address = document.createElement('strong'); address.textContent = note.cell;
        const sheet = document.createElement('span'); sheet.textContent = note.sheet;
        button.append(address, sheet); button.title = `${note.sheet} · ${note.cell}`;
        button.addEventListener('click', () => showNote(note, true));
        rows.append(button); buttons.set(note, button);
      }
      list.replaceChildren(rows); list.hidden = !notes.length; refreshEditor();
    },
    get loaded() { return loaded; },
    visible() { return !panel.hidden; },
    setLocked(value: boolean) { locked = value; text.readOnly = value || selected?.editable !== true; },
    toggle() {
      panel.hidden = !panel.hidden;
      if (!panel.hidden) (selected ? buttons.get(selected) : buttons.values().next().value ?? close)?.focus();
      viewed();
      return !panel.hidden;
    },
    edits() { return [...replacements].map(([{ sheet, cell, text: original }, text]) => ({ sheet, cell, original, text })); },
    capture(): SpreadsheetNotesLocation | undefined {
      if (panel.hidden || !loaded) return undefined;
      return { listY: list.scrollTop, selected: selected ? {
        sheet: selected.sheet, cell: selected.cell, start: Math.min(text.selectionStart, 32_767),
        end: Math.min(text.selectionEnd, 32_767), focused: document.activeElement === text
      } : null };
    },
    restore(bookmark: SpreadsheetNotesLocation, focus: boolean) {
      if (!loaded) throw new Error('备注列表尚未加载');
      panel.hidden = false;
      if (bookmark.selected) {
        const { sheet, cell, start, end, focused } = bookmark.selected;
        const item = notes.find(note => note.sheet === sheet && note.cell === cell);
        if (item) {
          showNote(item, false);
          if (focus && focused) text.focus();
          text.setSelectionRange(start, end);
        }
      }
      list.scrollTop = bookmark.listY;
    },
    reset() {
      navigation += 1; loaded = false; panel.hidden = true; notes = []; selected = null; issue = '';
      buttons.clear(); replacements.clear(); list.replaceChildren(); refreshEditor();
    }
  };
}

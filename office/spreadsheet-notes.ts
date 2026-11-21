import { createNoteEditor, type NoteRun, type NoteRunEdit } from './spreadsheet-note-editor';

type Cell = { sheet: string; cell: string };
type Note = Cell & { author: string; text: string; editable: boolean; runs?: NoteRun[]; formatVersion?: string; created?: true };
type NoteCatalog = { notes: Note[]; author: string; creationUnavailable: string[] };
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

export function spreadsheetAddress(row: number, column: number) {
  if (!Number.isSafeInteger(row) || !Number.isSafeInteger(column) || row < 0 || row >= 1_048_576 || column < 0 || column >= 16_384) {
    throw new Error('单元格备注的位置无效');
  }
  let letters = '';
  for (let index = column + 1; index > 0; index = Math.floor((index - 1) / 26)) {
    letters = String.fromCharCode(65 + (index - 1) % 26) + letters;
  }
  return letters + (row + 1);
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

export function createSpreadsheetNotes(root: HTMLElement, locate: (cell: Cell) => Promise<void>,
  activeCell: () => Promise<Cell | null>, edited: () => void, viewed: () => void) {
  const panel = document.createElement('aside');
  panel.className = 'spreadsheet-notes'; panel.hidden = true; panel.setAttribute('aria-label', '单元格备注');
  const heading = document.createElement('header');
  const title = document.createElement('h2'); title.textContent = '单元格备注';
  const close = document.createElement('button'); close.type = 'button'; close.textContent = '关闭';
  heading.append(title, close);
  const add = document.createElement('button'); add.type = 'button'; add.className = 'spreadsheet-note-add';
  add.textContent = '新建备注';
  const list = document.createElement('div'); list.className = 'spreadsheet-notes-list'; list.setAttribute('aria-label', '备注列表');
  const status = document.createElement('p'); status.className = 'spreadsheet-notes-status'; status.setAttribute('role', 'status');
  const author = document.createElement('p'); author.className = 'spreadsheet-note-author'; author.hidden = true;
  let notes: Note[] = [], selected: Note | null = null, locked = true, issue = '';
  let defaultAuthor = '', unavailable = new Set<string>();
  let loaded = false, navigation = 0;
  const replacements = new Map<Note, NoteRunEdit[]>();
  const buttons = new Map<Note, HTMLButtonElement>();
  const editor = createNoteEditor(updateDraft, viewed, message => { status.textContent = message; });
  panel.append(heading, add, list, author, editor.container, status); root.after(panel);

  function updateControls() {
    add.disabled = locked || !loaded || !!issue;
    editor.setLocked(locked || selected?.editable !== true);
  }
  function refreshEditor() {
    const value = selected;
    author.hidden = !value?.author; author.textContent = value?.author ?? '';
    editor.container.hidden = value === null;
    updateControls();
    editor.show(value?.text ?? '', value?.runs, value ? replacements.get(value) : undefined);
    status.textContent = issue || (!notes.length ? '暂无单元格备注' : value && !value.editable ? '此备注只读' : '');
    for (const [note, button] of buttons) button.setAttribute('aria-pressed', String(note === value));
  }

  function noteRow(note: Note) {
    const button = document.createElement('button'); button.type = 'button';
    const address = document.createElement('strong'); address.textContent = note.cell;
    const sheet = document.createElement('span'); sheet.textContent = note.sheet;
    button.append(address, sheet); button.title = `${note.sheet} · ${note.cell}`;
    button.addEventListener('click', () => showNote(note, true));
    buttons.set(note, button);
    return button;
  }

  add.addEventListener('click', async () => {
    if (add.disabled) return;
    const token = ++navigation;
    try {
      const target = await activeCell();
      if (navigation !== token || panel.hidden || add.disabled) return;
      if (!target) {
        status.textContent = '请先选中一个单元格';
        return;
      }
      const existing = notes.find(note => note.sheet === target.sheet && note.cell === target.cell);
      if (existing) {
        showNote(existing, true);
        editor.focus();
        return;
      }
      if (unavailable.has(target.sheet)) {
        status.textContent = '当前工作表暂不支持新建备注';
        return;
      }
      const note: Note = { ...target, author: defaultAuthor, text: '', editable: true, created: true };
      notes.push(note);
      const row = noteRow(note);
      list.append(row); list.hidden = false;
      showNote(note, true);
      row.scrollIntoView({ block: 'nearest' });
      editor.focus();
    } catch {
      if (navigation === token) status.textContent = '无法读取当前单元格，请重新选择';
    }
  });

  function showNote(note: Note, seek: boolean) {
    const token = ++navigation;
    selected = note; refreshEditor(); viewed();
    if (seek) void locate(note).catch(() => {
      if (token === navigation) status.textContent = '无法定位原单元格，请核对工作表';
    });
  }

  close.addEventListener('click', () => { panel.hidden = true; navigation += 1; viewed(); });
  panel.addEventListener('keydown', event => { if (event.key === 'Escape') { event.stopPropagation(); close.click(); } });
  list.addEventListener('scroll', viewed);
  function updateDraft(runs: NoteRunEdit[], modified: boolean) {
    if (!selected?.editable || locked) return;
    if (selected.created) {
      if (!replacements.has(selected) && !runs.some(run => run.text.trim())) return;
      replacements.set(selected, runs);
    } else if (modified) replacements.set(selected, runs);
    else replacements.delete(selected);
    status.textContent = '';
    edited();
  }

  return {
    configure(catalog: NoteCatalog, warning: string) {
      notes = catalog.notes; issue = warning; loaded = true; selected = null;
      defaultAuthor = catalog.author; unavailable = new Set(catalog.creationUnavailable);
      const rows = document.createDocumentFragment();
      for (const note of notes) {
        rows.append(noteRow(note));
      }
      list.replaceChildren(rows); list.hidden = !notes.length; refreshEditor();
    },
    get loaded() { return loaded; },
    visible() { return !panel.hidden; },
    setLocked(value: boolean) { locked = value; updateControls(); },
    toggle() {
      panel.hidden = !panel.hidden;
      if (!panel.hidden) (selected ? buttons.get(selected) : buttons.values().next().value ?? close)?.focus();
      viewed();
      return !panel.hidden;
    },
    edits() {
      return [...replacements].map(([note, runs]) => {
        const rich = note.formatVersion || runs.some(run => run.bold || run.italic || run.underline);
        return { sheet: note.sheet, cell: note.cell, original: note.created ? null : note.text, text: runs.map(run => run.text).join(''),
          ...(rich ? { rich: { version: note.formatVersion ?? null, runs } } : {}) };
      });
    },
    capture(): SpreadsheetNotesLocation | undefined {
      if (panel.hidden || !loaded) return undefined;
      const note = selected;
      const retained = note && (!note.created || replacements.has(note))
        ? { sheet: note.sheet, cell: note.cell, ...editor.selection() } : null;
      return { listY: list.scrollTop, selected: retained };
    },
    restore(bookmark: SpreadsheetNotesLocation, focus: boolean) {
      if (!loaded) throw new Error('备注列表尚未加载');
      panel.hidden = false;
      if (bookmark.selected) {
        const { sheet, cell, start, end, focused } = bookmark.selected;
        const item = notes.find(note => note.sheet === sheet && note.cell === cell);
        if (item) {
          showNote(item, false);
          editor.restore(start, end, focus && focused);
        }
      }
      list.scrollTop = bookmark.listY;
    },
    reset() {
      navigation += 1; loaded = false; panel.hidden = true; notes = []; selected = null; issue = '';
      defaultAuthor = ''; unavailable.clear();
      buttons.clear(); replacements.clear(); list.replaceChildren(); refreshEditor();
    }
  };
}

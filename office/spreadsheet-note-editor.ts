import { Schema, type Node as EditorNode } from 'prosemirror-model';
import { EditorState, Plugin, TextSelection, type Command } from 'prosemirror-state';
import { EditorView } from 'prosemirror-view';
import { baseKeymap, toggleMark } from 'prosemirror-commands';
import { history, redo, undo } from 'prosemirror-history';
import { keymap } from 'prosemirror-keymap';

export type NoteRun = {
  text: string; bold: boolean; italic: boolean; underline: boolean; doubleUnderline: boolean; strike: boolean;
  font?: string; size?: number; rgb?: string; vertical?: string;
};
// The native writer uses the source index to preserve the original Office properties.
export type NoteRunEdit = Pick<NoteRun, 'text' | 'bold' | 'italic' | 'underline'> & { source: number | null };

const formatActions = [
  { name: 'bold', key: 'b', title: '加粗' },
  { name: 'italic', key: 'i', title: '斜体' },
  { name: 'underline', key: 'u', title: '下划线' },
] as const;
const marks = { bold: false, italic: false, underline: false };
const maxLength = 32_767;

function runAppearance(run: NoteRun) {
  const span = document.createElement('span');
  if (run.font) span.style.fontFamily = JSON.stringify(run.font) + ', sans-serif';
  if (run.size) span.style.fontSize = Math.min(Math.max(run.size, 5), 72) + 'pt';
  if (run.rgb && /^[0-9a-f]{6}$/i.test(run.rgb)) span.style.setProperty('--note-run-color', '#' + run.rgb);
  if (run.strike) span.style.textDecorationLine = 'line-through';
  if (run.doubleUnderline) span.classList.add('spreadsheet-note-double');
  if (run.vertical === 'superscript') span.style.verticalAlign = 'super';
  if (run.vertical === 'subscript') span.style.verticalAlign = 'sub';
  return span;
}

export function createNoteEditor(changed: (runs: NoteRunEdit[], modified: boolean) => void, viewed: () => void,
  showIssue: (message: string) => void) {
  const container = document.createElement('div');
  container.className = 'spreadsheet-note-composer'; container.hidden = true;
  const toolbar = document.createElement('div');
  toolbar.className = 'spreadsheet-note-format'; toolbar.setAttribute('role', 'group'); toolbar.setAttribute('aria-label', '备注格式');
  const host = document.createElement('div');
  container.append(toolbar, host);
  let originalRuns: NoteRun[] = [];
  let locked = true;
  const sourceAttrs = (index: number) => ({ index, appearance: originalRuns[index] });
  const schema = new Schema({
    nodes: {
      doc: { content: 'body' },
      body: { content: 'text*', whitespace: 'pre', toDOM: () => ['div', 0], parseDOM: [{ tag: 'div', preserveWhitespace: 'full' }] },
      text: {},
    },
    marks: {
      source: {
        attrs: { index: {}, appearance: {} },
        toDOM(mark) {
          const span = runAppearance(mark.attrs.appearance);
          span.dataset.noteSource = String(mark.attrs.index);
          return { dom: span, contentDOM: span };
        },
        parseDOM: [{ tag: 'span[data-note-source]', getAttrs(node) {
          const index = Number(node.dataset.noteSource);
          return Number.isInteger(index) && originalRuns[index] ? sourceAttrs(index) : false;
        } }],
      },
      bold: { toDOM: () => ['strong', 0], parseDOM: [{ tag: 'strong' }, { tag: 'b' }] },
      italic: { toDOM: () => ['em', 0], parseDOM: [{ tag: 'em' }, { tag: 'i' }] },
      underline: { toDOM: () => ['u', 0], parseDOM: [{ tag: 'u' }] },
    },
  });
  function noteDocument(runs: NoteRunEdit[]) {
    const nodes = runs.filter(run => run.text.length).map(run => {
      const styling = formatActions.filter(action => run[action.name]).map(action => schema.marks[action.name].create());
      if (run.source !== null) styling.unshift(schema.marks.source.create(sourceAttrs(run.source)));
      return schema.text(run.text, styling);
    });
    return schema.nodes.doc.create(null, schema.nodes.body.create(null, nodes));
  }
  function noteRuns(doc: EditorNode): NoteRunEdit[] {
    const runs: NoteRunEdit[] = [];
    doc.firstChild!.forEach(node => {
      const source = schema.marks.source.isInSet(node.marks)?.attrs.index ?? null;
      runs.push({ text: node.text!, source, bold: !!schema.marks.bold.isInSet(node.marks),
        italic: !!schema.marks.italic.isInSet(node.marks), underline: !!schema.marks.underline.isInSet(node.marks) });
    });
    return runs;
  }
  const lineBreak: Command = (state, dispatch) => {
    dispatch?.(state.tr.insertText('\n').scrollIntoView());
    return true;
  };
  const keyboard: Record<string, Command> = {
    ...baseKeymap, Enter: lineBreak, 'Shift-Enter': lineBreak, 'Mod-z': undo, 'Shift-Mod-z': redo, 'Mod-y': redo,
  };
  const buttons = formatActions.map(({ name, key, title }) => {
    const command = toggleMark(schema.marks[name], null, { removeWhenPresent: false, includeWhitespace: true });
    keyboard['Mod-' + key] = command;
    const button = document.createElement('button');
    button.type = 'button'; button.dataset.format = name; button.textContent = key.toUpperCase();
    button.title = title; button.setAttribute('aria-label', title); button.setAttribute('aria-keyshortcuts', 'Meta+' + key.toUpperCase());
    button.addEventListener('mousedown', event => event.preventDefault());
    button.addEventListener('click', () => {
      if (locked) return;
      view.focus();
      command(view.state, view.dispatch, view);
    });
    toolbar.append(button);
    return { name, button };
  });
  const plugins = [
    history(),
    keymap(keyboard),
    new Plugin({ filterTransaction(tr) {
      if (!tr.docChanged) return true;
      if (locked) return false;
      const text = tr.doc.textContent;
      if (text.length <= maxLength && !/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uD800-\uDFFF\uFFFE\uFFFF]/u.test(text)) return true;
      showIssue('备注过长或含不支持的字符');
      return false;
    } }),
  ];
  let original = noteDocument([]);
  const view = new EditorView(host, {
    state: EditorState.create({ doc: original, plugins }),
    editable: () => !locked,
    attributes: () => ({ class: 'spreadsheet-note-body', role: 'textbox', 'aria-label': '备注正文', 'aria-multiline': 'true',
      'aria-readonly': String(locked), spellcheck: 'false', tabindex: '0' }),
    handleDOMEvents: {
      focus: () => { viewed(); return false; },
      blur: () => { viewed(); return false; },
      paste(editor, event) {
        const text = event.clipboardData?.getData('text/plain');
        if (!locked && text) editor.dispatch(editor.state.tr.insertText(text.replace(/\r\n?/g, '\n')).scrollIntoView());
        event.preventDefault();
        return true;
      },
      drop(_editor, event) { event.preventDefault(); return true; },
    },
    dispatchTransaction(transaction) {
      const previous = view.state;
      const next = previous.apply(transaction);
      if (next === previous) return;
      view.updateState(next); updateButtons();
      if (!next.doc.eq(previous.doc)) changed(noteRuns(next.doc), !next.doc.eq(original));
      if (!next.selection.eq(previous.selection)) viewed();
    },
  });
  function updateButtons() {
    const { doc, selection, storedMarks } = view.state;
    for (const { name, button } of buttons) {
      const mark = schema.marks[name];
      const active = selection.empty ? !!mark.isInSet(storedMarks ?? selection.$from.marks()) :
        doc.rangeHasMark(selection.from, selection.to, mark);
      button.disabled = locked; button.setAttribute('aria-pressed', String(active));
    }
  }
  updateButtons();

  return {
    container,
    show(text: string, formatted: NoteRun[] | undefined, draft: NoteRunEdit[] | undefined) {
      originalRuns = formatted ?? [];
      original = noteDocument(formatted ? formatted.map(({ text, bold, italic, underline }, source) => ({
        text, bold, italic, underline, source,
      })) : [{ text, ...marks, source: null }]);
      view.updateState(EditorState.create({ doc: draft ? noteDocument(draft) : original, plugins }));
      view.dom.scrollTop = 0; updateButtons();
    },
    setLocked(value: boolean) {
      if (locked === value) return;
      locked = value;
      view.setProps({ editable: () => !locked }); updateButtons();
    },
    focus() { view.focus(); },
    selection() {
      const { from, to } = view.state.selection;
      return { start: Math.min(from - 1, maxLength), end: Math.min(to - 1, maxLength), focused: view.hasFocus() };
    },
    restore(start: number, end: number, focus: boolean) {
      const last = view.state.doc.firstChild!.content.size + 1;
      view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, Math.min(start + 1, last), Math.min(end + 1, last))));
      if (focus) view.focus();
    },
  };
}

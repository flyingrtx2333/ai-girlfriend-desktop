import type { WordRange } from './view-state';

type Position = { start: number; end: number; direction: 'none' | 'forward' | 'backward'; x: number; y: number };
type TextDraft = Position & { text: string; focused: boolean };
export type DocxReviewDraft = TextDraft & (
  { kind: 'comment'; range: WordRange } | { kind: 'reply'; commentID: number }
);
type Field = HTMLInputElement | HTMLTextAreaElement;
type Target = { kind: 'comment' } | { kind: 'reply'; commentID: number };

const newComment = '.docx-unified-sidebar .docx-comment-composer textarea.docx-review-input';
const replyCards = '.docx-unified-sidebar .docx-comment-card[data-comment-id]';
const delay = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
const unavailable = () => new Error('无法恢复原批注输入，原草稿已保留');

export function createDocxReviewDrafts(root: HTMLElement, editor: () => any, changed: (hasDraft: boolean) => void) {
  let focused: Field | null = null, frame = 0, previous = '';
  let observing = false;
  const observer = new MutationObserver(() => schedule());

  function fields() {
    const items: { target: Target; field: Field }[] = [];
    const comment = root.querySelector<HTMLTextAreaElement>(newComment);
    if (comment?.value) items.push({ target: { kind: 'comment' }, field: comment });
    for (const card of root.querySelectorAll<HTMLElement>(replyCards)) {
      const field = card.querySelector<HTMLInputElement>('.docx-review-composer[data-active="true"] input.docx-review-input');
      const commentID = Number(card.dataset.commentId);
      if (field?.value && Number.isSafeInteger(commentID) && commentID >= 0) items.push({ target: { kind: 'reply', commentID }, field });
    }
    return items;
  }

  function textDraft(field: Field): TextDraft {
    const active = document.activeElement;
    const owner = active instanceof HTMLElement && active.matches('input.docx-review-input,textarea.docx-review-input') ? active : focused;
    return {
      text: field.value, start: field.selectionStart ?? 0, end: field.selectionEnd ?? 0,
      direction: field.selectionDirection ?? 'none', x: Math.max(0, field.scrollLeft), y: Math.max(0, field.scrollTop),
      focused: field === owner,
    };
  }

  function schedule(event?: Event) {
    if (event?.type === 'focusin') {
      const target = event.target;
      focused = target instanceof HTMLElement && target.matches('input.docx-review-input,textarea.docx-review-input') ? target as Field : null;
    }
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      const items = fields(), signature = JSON.stringify(items.map(({ target, field }) => [target, textDraft(field)]));
      if (items.length > 0 && !observing) { observer.observe(root, { childList: true, subtree: true }); observing = true; }
      if (!items.length && observing) { observer.disconnect(); observing = false; }
      if (signature !== previous) { previous = signature; changed(items.length > 0); }
    });
  }
  const events = ['input', 'select', 'focusin', 'keyup', 'pointerup', 'scroll'];
  for (const type of events) root.addEventListener(type, schedule, true);

  async function capture(portable: (value: any) => Promise<WordRange>): Promise<DocxReviewDraft[]> {
    const inputs = fields().map(({ target, field }) => ({ target, value: textDraft(field) }));
    const section = inputs.some(({ target }) => target.kind === 'comment') ? editor().hostCommentSelection() : null;
    return await Promise.all(inputs.map(async ({ target, value }) => {
      if (target.kind === 'reply') return { ...value, ...target };
      if (!section) throw unavailable();
      return { ...value, ...target, range: await portable(section) };
    }));
  }

  async function waitFor<T extends Field>(selector: string): Promise<T> {
    for (let attempt = 0; attempt < 80; attempt++) {
      const field = root.querySelector<T>(selector);
      if (field) return field;
      await delay(35);
    }
    throw unavailable();
  }

  async function restore(drafts: DocxReviewDraft[], select: (range: WordRange) => Promise<void>, body: WordRange | null) {
    let restoredFocus: Field | null = null;
    function update(field: Field, value: TextDraft) {
      const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), 'value')?.set;
      if (!setter) throw unavailable();
      setter.call(field, value.text);
      field.dispatchEvent(new Event('input', { bubbles: true }));
    }
    for (const draft of drafts) {
      let field: Field;
      if (draft.kind === 'comment') {
        await select(draft.range);
        await editor().openHostCommentDraft();
        field = await waitFor<HTMLTextAreaElement>(newComment);
        if (body && JSON.stringify(body) !== JSON.stringify(draft.range)) await select(body);
      } else {
        if (!editor().getComments().some((c: any) => c.id === draft.commentID && !c.done)) throw unavailable();
        editor().openHostReplyDraft(draft.commentID);
        const card = replyCards + `[data-comment-id="${draft.commentID}"]`;
        const input = await waitFor<HTMLInputElement>(card + ' input.docx-review-input');
        if (input.readOnly) input.click();
        field = await waitFor<HTMLInputElement>(card + ' .docx-review-composer[data-active="true"] input.docx-review-input');
      }
      update(field, draft);
      await delay(0);
      if (field.value !== draft.text) throw unavailable();
      field.setSelectionRange(draft.start, draft.end, draft.direction);
      field.scrollLeft = draft.x; field.scrollTop = draft.y;
      if (draft.focused) restoredFocus = field;
    }
    if (fields().length !== drafts.length) throw unavailable();
    focused = restoredFocus;
    schedule();
  }

  function focusDraft() {
    if (!focused?.isConnected || !focused.value) return false;
    focused.focus({ preventScroll: true });
    return document.activeElement === focused;
  }

  return {
    capture, restore, focusDraft, pending: () => fields().length > 0,
    dispose() {
      observer.disconnect(); cancelAnimationFrame(frame);
      for (const type of events) root.removeEventListener(type, schedule, true);
    },
  };
}

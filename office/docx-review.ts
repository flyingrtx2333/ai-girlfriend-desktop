import type { DocxEditorRef } from '@betteroffice/docx-react';

// BetterOffice 0.5 positions its review cards in the same scroller as the
// document. Bring those cards into view without changing their anchors.
const gutter = 12;
const sidebarSelector = '.docx-unified-sidebar';

export function createDocxReview(root: HTMLElement) {
  let origin: { host: HTMLElement; x: number; y: number } | null = null;
  let frame = 0;

  function scrollHost(element: Element | null) {
    for (let node = element?.parentElement; node && node !== root; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (node.clientWidth > 0 && [style.overflowX, style.overflowY].some(value => value === 'scroll' || value === 'auto')) return node;
    }
    return null;
  }

  function column() {
    const sidebar = root.querySelector<HTMLElement>(sidebarSelector);
    const host = scrollHost(sidebar);
    if (!sidebar || !host || !sidebar.offsetWidth) return null;
    return { sidebar, host };
  }

  function locate() {
    const target = column();
    if (!target) return null;
    const cards = Array.from(target.sidebar.firstElementChild?.children ?? []).filter(card =>
      card.getBoundingClientRect().height > 0 && getComputedStyle(card).visibility !== 'hidden');
    return cards.length ? { ...target, cards } : null;
  }

  function bounds(host: HTMLElement) {
    const { left, top } = host.getBoundingClientRect();
    return new DOMRect(left + host.clientLeft, top + host.clientTop, host.clientWidth, host.clientHeight);
  }

  function align(sidebar: HTMLElement, host: HTMLElement) {
    const view = bounds(host), card = sidebar.getBoundingClientRect();
    if (card.width > view.width - 2 * gutter || card.left < view.left + gutter) {
      host.scrollLeft += card.left - view.left - gutter;
    } else if (card.right > view.right - gutter) {
      host.scrollLeft += card.right - view.right + gutter;
    }
  }

  async function show(editor: DocxEditorRef) {
    let target = locate();
    if (!target && editor.getComments().length > 0 && !editor.commands.getState('commentsSidebar').active) {
      const result = await editor.commands.execute('commentsSidebar', null);
      if (!result.ok) throw new Error('批注暂未打开');
    }
    for (let attempt = 0; !target && attempt < 8; attempt++) {
      await new Promise(resolve => setTimeout(resolve, 40));
      target = locate();
    }
    if (!target) return '暂无可查看的批注。可选中文字后使用右键菜单添加。';
    const { sidebar, host, cards } = target;
    if (origin?.host !== host) origin = { host, x: host.scrollLeft, y: host.scrollTop };
    const view = bounds(host);
    const distances = cards.map(card => {
      const rect = card.getBoundingClientRect();
      return { rect, distance: Math.max(view.top + gutter - rect.top, rect.bottom - view.bottom + gutter, 0) };
    });
    const { rect } = distances.reduce((nearest, candidate) => candidate.distance < nearest.distance ? candidate : nearest);
    if (rect.top < view.top + gutter || rect.bottom > view.bottom - gutter) host.scrollTop += rect.top - view.top - gutter;
    align(sidebar, host);
    return '';
  }

  function showBody() {
    const saved = origin;
    reset();
    if (saved?.host.isConnected) {
      saved.host.scrollLeft = saved.x;
      saved.host.scrollTop = saved.y;
    } else {
      const host = scrollHost(root.querySelector('.paged-editor__page'));
      if (host) host.scrollLeft = 0;
    }
  }

  function refresh() {
    if (!origin || frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      const target = column();
      if (target && target.host === origin?.host) align(target.sidebar, target.host);
    });
  }

  function reset() {
    cancelAnimationFrame(frame);
    frame = 0;
    origin = null;
  }

  root.addEventListener('focusin', event => {
    const input = event.target;
    if (!(input instanceof HTMLElement) || !input.matches('textarea,input,[contenteditable="true"]')) return;
    const sidebar = input.closest<HTMLElement>(sidebarSelector), host = scrollHost(sidebar);
    if (!sidebar || !host) return;
    if (origin?.host !== host) origin = { host, x: host.scrollLeft, y: host.scrollTop };
    refresh();
  });

  function geometry() {
    const target = locate();
    if (!target) return { available: false };
    const { sidebar, host, cards } = target;
    const view = bounds(host), column = sidebar.getBoundingClientRect();
    return {
      available: true, x: host.scrollLeft, y: host.scrollTop,
      column: { left: column.left, right: column.right },
      view: { left: view.left, right: view.right, top: view.top, bottom: view.bottom },
      visibleCards: cards.filter(card => {
        const rect = card.getBoundingClientRect();
        return rect.right <= view.right + 1 && rect.left >= view.left - 1 && rect.bottom <= view.bottom + 1 && rect.top >= view.top - 1;
      }).length,
    };
  }

  return { show, showBody, refresh, reset, geometry };
}

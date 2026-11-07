import Foundation

enum AgentBrowserScript {
    // This runs in a separate JavaScript world. Page scripts cannot replace the
    // reference map or supply executable code to the native tool.
    static let body = #"""
    const clean = value => String(value || '').replace(/\s+/g, ' ').trim().slice(0, 240);
    const terms = [...new Set(String(query || '').toLocaleLowerCase().trim().split(/\s+/).filter(Boolean))];
    const matches = value => !terms.length || terms.some(term => String(value).toLocaleLowerCase().includes(term));
    const visible = el => {
      const r = el.getBoundingClientRect(), s = getComputedStyle(el);
      return el.isConnected && r.width > 0 && r.height > 0 && s.visibility === 'visible' && s.display !== 'none' && !el.closest('[inert],[aria-hidden="true"]');
    };
    const label = el => clean(el.getAttribute('aria-label') ||
      [...(el.labels || [])].map(x => x.innerText).join(' ') || (el.tagName === 'SELECT' ? '' : el.innerText) || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') ||
      (['submit','button','reset'].includes(el.type) ? el.value : '') || el.getAttribute('name') || el.id || el.value);
    const destination = el => {
      const submit = el.form && (el.tagName === 'BUTTON' && el.type === 'submit' || el.tagName === 'INPUT' && ['submit','image'].includes(el.type));
      const url = el.getAttribute('href') ?? (submit ? el.getAttribute('formaction') ?? el.form.getAttribute('action') ?? location.href : '');
      try { return url ? new URL(url, location.href).href : ''; } catch { return ''; }
    };
    const fingerprint = el => JSON.stringify([el.tagName, el.type, label(el), destination(el), el.matches(':disabled'), el.readOnly, el.getAttribute('role'), el.getAttribute('target'), el.value, el.checked,
      ['aria-pressed','aria-checked','aria-expanded','aria-selected','aria-disabled'].map(key => el.getAttribute(key)), el.form?.method, el.form?.target, el.form?.innerText,
      [...(el.form?.elements || [])].map(field => [field.name, field.type, field.value, field.checked, field.disabled]),
      [...(el.options || [])].map(option => [option.value, option.label, option.matches(':disabled')])]);
    let state = globalThis.__blueFatFishBrowser;
    if (operation !== 'read') {
      if (!state || state.revision !== revision || state.document !== document || state.url !== location.href) throw Error('页面已经变化，请用 browser_read 重新读取后操作');
      const item = state.nodes.get(ref);
      if (operation === 'click' || operation === 'fill' || operation === 'select') {
        if (!item || !visible(item.el) || fingerprint(item.el) !== item.fingerprint) throw Error('目标元素已经变化，请重新读取页面');
        const el = item.el;
        if (el.matches(':disabled') || el.readOnly || el.getAttribute('aria-disabled') === 'true') throw Error('目标元素不可操作');
        if (el.tagName === 'INPUT' && ['password','file','hidden'].includes(el.type)) throw Error('密码和文件上传请在浏览器中手动完成');
        if (operation === 'click') {
          const url = destination(el);
          if (url && !['http:','https:'].includes(new URL(url).protocol)) throw Error('浏览器仅支持 HTTP/HTTPS 网页操作');
          el.scrollIntoView({block:'center', inline:'center', behavior:'instant'});
          const rect = el.getBoundingClientRect(), hit = document.elementFromPoint(rect.x + rect.width/2, rect.y + rect.height/2);
          if (hit !== el && !el.contains(hit)) throw Error('目标被其他内容遮挡，请重新读取页面');
          globalThis.__blueFatFishBrowser = null; el.click();
        } else if (operation === 'fill') {
          if (!((el.tagName === 'INPUT' && ['text','search','email','url','tel','number'].includes(el.type)) || el.tagName === 'TEXTAREA')) throw Error('目标不是可填写的普通文本框');
          const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          globalThis.__blueFatFishBrowser = null;
          el.focus(); Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
          el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true}));
        } else {
          if (el.tagName !== 'SELECT' || ![...el.options].some(o => o.value === value && !o.matches(':disabled'))) throw Error('请选择列表中有效选项的 value');
          globalThis.__blueFatFishBrowser = null;
          el.value = value; el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true}));
        }
      } else if (operation === 'scroll') {
        globalThis.__blueFatFishBrowser = null;
        window.scrollBy({top: direction === 'up' ? -600 : 600, behavior:'instant'});
      } else if (operation === 'check') {
        globalThis.__blueFatFishBrowser = null;
      } else { throw Error('不支持的浏览器操作'); }
      return {performed: operation};
    }
    state = {revision, document, url:location.href, nodes:new Map()};
    globalThis.__blueFatFishBrowser = state;
    const score = el => {
      const text = (label(el) + ' ' + clean(el.closest('tr')?.innerText)).toLocaleLowerCase();
      return terms.filter(term => text.includes(term)).length;
    };
    const candidates = [...document.querySelectorAll('a[href],button,input,textarea,select,summary,[role="button"],[role="link"],[role="checkbox"],[role="switch"],[role="tab"],[role="combobox"],[role="option"],[role="menuitem"]')].slice(0, 10000).filter(visible)
      .map(el => ({el, score:score(el)})).sort((a, b) => b.score - a.score || Number(a.el.tagName === 'A') - Number(b.el.tagName === 'A')).map(item => item.el);
    const elements = []; let matched = 0;
    for (const el of candidates) {
      if (el.tagName === 'INPUT' && ['password','file','hidden'].includes(el.type)) continue;
      const name = label(el), context = clean(el.closest('tr')?.innerText);
      if (!matches(name + ' ' + context)) continue;
      matched++; if (matched <= elementOffset || elements.length >= 12) continue;
      const id = 'e' + (elements.length + 1), item = {ref:id, tag:el.tagName.toLowerCase(), name, type:el.type || el.getAttribute('role') || ''};
      if (el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true') item.disabled = true;
      if (context && ['INPUT','TEXTAREA','SELECT'].includes(el.tagName)) item.context = context;
      for (const attribute of ['aria-pressed','aria-checked','aria-expanded','aria-selected']) { if (el.hasAttribute(attribute)) item[attribute] = el.getAttribute(attribute); }
      if (el.tagName === 'INPUT' && ['checkbox','radio'].includes(el.type)) item.checked = el.checked;
      const url = destination(el); if (url) item.destination = url.slice(0, 2048);
      if (el.tagName === 'SELECT') item.options = [...el.options].slice(0, 60).map(o => ({label:clean(o.label),value:o.value,...(o.matches(':disabled') ? {disabled:true} : {})}));
      if (['INPUT','TEXTAREA','SELECT'].includes(el.tagName)) item.value = String(el.value).slice(0, 500);
      elements.push(item); state.nodes.set(id, {el, fingerprint:fingerprint(el)});
    }
    const lines = (document.body?.innerText || '').split('\n').map(x => x.trim()).filter(Boolean);
    const start = Math.max(0, offset - 1), rows = []; let size = 0, next = start;
    for (let i = start; i < lines.length; i++) {
      next = i + 1;
      if (!matches(lines[i])) continue;
      const match = terms.length ? lines[i].toLocaleLowerCase().indexOf(terms[0]) : 0, begin = Math.max(0, match - 200);
      const row = (i + 1) + ': ' + (begin ? '…' : '') + lines[i].slice(begin, begin + 800) + (lines[i].length > begin + 800 ? '…[长行截断]' : '');
      if (rows.length >= 30 || size + row.length > 1200) { next = i; break; }
      rows.push(row); size += row.length;
    }
    return {url:location.href, title:document.title.slice(0, 500), revision, query, text:rows.join('\n'), total_lines:lines.length, next_offset:next < lines.length ? next + 1 : null, elements, element_offset:elementOffset, total_elements:matched, next_element_offset:elementOffset + elements.length < matched ? elementOffset + elements.length : null, elements_truncated:matched > elementOffset + elements.length, frames:document.querySelectorAll('iframe,frame').length, scroll_y:Math.round(scrollY), ready_state:document.readyState};
    """#
}

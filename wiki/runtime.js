import { parseDocument, visit } from 'yaml';
import { parse, postprocess, preprocess } from 'micromark';
import { decodeString } from 'micromark-util-decode-string';
import { parseFragment } from 'parse5';

export function decode(source) {
  if (typeof source !== 'string' || source.length > 64000) throw Error('规划文件超过 64KB');
  const doc = parseDocument(source, { version: '1.2', schema: 'core', strict: true, uniqueKeys: true, stringKeys: true, prettyErrors: false });
  const problem = doc.errors[0] ?? doc.warnings[0];
  if (problem) throw Error(problem.message);
  let count = 0;
  visit(doc, (_key, _node, ancestors) => {
    if (++count > 4000 || ancestors.length > 64) throw Error('规划文件结构过大或层级过深');
  });
  return JSON.stringify(doc.toJS({ maxAliasCount: 20 }));
}

// Concrete parser offsets retain every byte outside actual URL destinations,
// including fenced/indented code, escaped punctuation and reference links.
export function linkDestinations(source) {
  if (typeof source !== 'string' || source.length > 300000) throw Error('Wiki 页面超过链接处理上限');
  const events = postprocess(parse().document().write(preprocess()(source, undefined, true)));
  if (events.length > 200000) throw Error('Wiki 页面结构超过链接处理上限');
  const links = [], html = [];
  for (const [event, token] of events) {
    if (event !== 'enter') continue;
    const start = token.start.offset, end = token.end.offset;
    if (['resourceDestinationString', 'definitionDestinationString', 'autolinkProtocol'].includes(token.type)) links.push({ start, end, url: decodeString(source.slice(start, end)), html: false });
    else if (['htmlFlow', 'htmlText'].includes(token.type)) html.push({ start, end });
  }
  const ranges = [];
  for (const span of html.sort((a, b) => a.start - b.start || a.end - b.end)) {
    const prior = ranges.at(-1);
    if (prior && span.start <= prior.end) prior.end = Math.max(prior.end, span.end);
    else ranges.push({ ...span });
  }
  const protectedRanges = [];
  if (ranges.length) {
    let masked = '', offset = 0;
    for (const span of ranges) { masked += ' '.repeat(span.start - offset) + source.slice(span.start, span.end); offset = span.end; }
    masked += ' '.repeat(source.length - offset);
    const pending = [parseFragment(masked, { sourceCodeLocationInfo: true, scriptingEnabled: false })];
    let count = 0;
    while (pending.length) {
      const node = pending.pop(), location = node.sourceCodeLocation;
      if (++count > 10000) throw Error('Wiki HTML 结构超过链接处理上限');
      if (location && ['script', 'style', 'code', 'pre', 'textarea', 'title', 'xmp', 'plaintext'].includes(node.tagName)) protectedRanges.push({ start: location.startTag?.endOffset ?? location.startOffset, end: location.endTag?.startOffset ?? location.endOffset });
      for (const attribute of node.attrs ?? []) {
        if (!['href', 'src', 'poster'].includes(attribute.name)) continue;
        const key = attribute.prefix ? attribute.prefix + ':' + attribute.name : attribute.name, span = location?.attrs?.[key];
        if (!span) continue;
        const raw = source.slice(span.startOffset, span.endOffset), equals = raw.indexOf('=');
        if (equals < 0) continue;
        let start = equals + 1; while (/\s/.test(raw[start] ?? '') && start < raw.length) start++;
        const quote = ['"', "'"].includes(raw[start]) ? raw[start++] : '';
        const end = quote && raw.endsWith(quote) ? raw.length - 1 : raw.length;
        links.push({ start: span.startOffset + start, end: span.startOffset + end, url: attribute.value, html: true });
      }
      pending.push(...(node.childNodes ?? [])); if (node.content) pending.push(node.content);
    }
  }
  const result = new Map();
  for (const link of links) {
    if (protectedRanges.some(range => link.start >= range.start && link.end <= range.end)) continue;
    if (link.start < 0 || link.end < link.start || link.end > source.length) throw Error('Wiki 链接位置无效');
    result.set(link.start + ':' + link.end, link);
  }
  if (result.size > 10000) throw Error('Wiki 页面链接超过10000条');
  return JSON.stringify([...result.values()].sort((a, b) => a.start - b.start));
}

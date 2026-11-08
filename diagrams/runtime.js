import mermaid from 'mermaid';
import 'katex/dist/katex.min.css';

const policy = {
  startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
  maxTextSize: 32_768, maxEdges: 500, htmlLabels: false,
  fontFamily: '-apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif',
  theme: 'neutral', flowchart: { htmlLabels: false },
  secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'suppressErrorRendering', 'htmlLabels', 'flowchart', 'themeCSS', 'fontFamily'],
};

export async function render(source, width) {
  if (new TextEncoder().encode(source).length > 32_768) throw new Error('图表源码超过 32KB');
  mermaid.initialize(policy);
  document.body.replaceChildren();
  document.body.style.cssText = `margin:0;background:white;width:${Math.max(320, Math.min(2048, width))}px`;
  const host = document.createElement('div'); document.body.append(host);
  const { svg } = await mermaid.render('markdown-diagram', source);
  host.innerHTML = svg;
  const graph = host.querySelector('svg');
  if (!graph) throw new Error('图表未生成');
  // Links and image URLs in a document never acquire browser or file access.
  for (const element of graph.querySelectorAll('*')) {
    for (const attribute of [...element.attributes]) {
      if (attribute.localName === 'href' && !attribute.value.startsWith('#')) element.removeAttributeNode(attribute);
    }
  }
  const viewBox = graph.viewBox.baseVal;
  const w = Math.ceil(viewBox.width || graph.getBoundingClientRect().width);
  const h = Math.ceil(viewBox.height || graph.getBoundingClientRect().height);
  if (!Number.isFinite(w * h) || w < 1 || h < 1 || w > 6000 || h > 12000 || w * h > 16_000_000) throw new Error('图表过大，请拆分后预览');
  graph.style.cssText = `display:block;max-width:none;width:${w}px;height:${h}px`;
  graph.setAttribute('width', w); graph.setAttribute('height', h);
  document.body.style.width = `${w}px`;
  await document.fonts.ready;
  return { width: w, height: h, svg: new XMLSerializer().serializeToString(graph), labels: graph.textContent };
}

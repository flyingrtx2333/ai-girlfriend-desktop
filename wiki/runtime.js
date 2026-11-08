import { parseDocument, visit } from 'yaml';

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

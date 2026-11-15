import { createHash } from 'node:crypto';

// The pinned worker editor publishes selection reads but not selection restore.
// Expose its existing fenced selection channel; never switch to the legacy engine.
const suffix = '/@betteroffice/docx-react/dist/chunk-4ZGDANBA.mjs';
const sourceHash = 'be9a8f6738e622a910521f8484af27c3b6e4448a0835389708ac036b83f8b6a8';
const anchor = 'readSelectionInfo:async()=>{let i=await ie();';
const bridge = `
readHostSelection:async()=>{
  const binding=await Xe();
  const selection=binding.viewStore.getSnapshot().workerSelection;
  if(!selection)return null;
  const point=value=>({story:value.story,paraId:value.paraId,offset:value.offset});
  return {anchor:point(selection.anchor),focus:point(selection.focus)};
},
restoreHostSelection:async selection=>{
  const valid=value=>value&&typeof value.story==='string'&&value.story.length>0&&value.story.length<=1024&&
    typeof value.paraId==='string'&&value.paraId.length>0&&value.paraId.length<=1024&&
    Number.isSafeInteger(value.offset)&&value.offset>=0;
  if(!valid(selection?.anchor)||!valid(selection?.focus))throw new Error('Invalid document selection');
  const binding=await Xe();
  const point=value=>({story:value.story,paraId:value.paraId,offset:value.offset});
  const command=binding.commands.submit({kind:'select',payload:{selection:{anchor:point(selection.anchor),focus:point(selection.focus)}}},{source:'selection',fence:true});
  if(command.status!=='submitted')return false;
  const [ack,presented]=await Promise.all([command.ticket.ack,command.ticket.presented]);
  return binding===n&&(ack.status==='applied'||ack.status==='noop')&&presented==='presented';
},`;

export function docxSelectionBridge() {
  let patched = false;
  return {
    name: 'office-docx-selection-bridge',
    transform(source, id) {
      if (!id.replaceAll('\\', '/').endsWith(suffix)) return;
      if (createHash('sha256').update(source).digest('hex') !== sourceHash || source.split(anchor).length !== 2) {
        this.error('The DOCX worker selection bridge needs review for this SDK build.');
      }
      patched = true;
      return { code: source.replace(anchor, bridge + anchor), map: null };
    },
    generateBundle() {
      if (!patched) this.error('The DOCX worker selection bridge was not installed.');
    },
  };
}

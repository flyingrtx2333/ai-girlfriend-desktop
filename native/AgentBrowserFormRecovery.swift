import Foundation

struct AgentBrowserFormRecovery: Codable, Equatable, Sendable {
    struct Value: Codable, Equatable, Sendable {
        var value: String?, checked: Bool?, selected: [Int]?
    }
    var version: Int, url: String, signature: String, values: [Value]
    func validate(for pageURL: String?) throws {
        guard version == 1, url == pageURL, signature.utf8.count <= 65_536,
              let identities = try? JSONSerialization.jsonObject(with: Data(signature.utf8)) as? [Any],
              (1...256).contains(values.count), identities.count == values.count,
              values.allSatisfy({ entry in
                  [entry.value != nil, entry.checked != nil, entry.selected != nil].filter { $0 }.count == 1 &&
                  entry.value.map { $0.utf8.count <= 65_536 && !$0.contains("\0") } != false &&
                  entry.selected.map { $0.count <= 512 && Set($0).count == $0.count && $0.allSatisfy { (0..<512).contains($0) } } != false
              }), try JSONEncoder().encode(self).count <= 256_000 else { throw PetError("网页填写过多或恢复格式无效，原记录已保留") }
    }
    static func capture(_ object: Any, url: String) throws -> Self {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= 256_000 else { throw PetError("网页填写过多，恢复备份尚未保存") }
        let result = try JSONDecoder().decode(Self.self, from: data); try result.validate(for: url); return result
    }
    func object() throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) }

    // WKWebView's history snapshot can still contain a previous form value.
    // Keep ordinary current controls separately, without submitting a form or
    // replaying website input/change handlers. Passwords and secrets stay out.
    private static let controls = #"""
    const controls=()=>Array.from(document.querySelectorAll('input,textarea,select')).filter(el=>{
      const autocomplete=(el.getAttribute('autocomplete')||'').toLowerCase().split(/\s+/);
      if(el.disabled||el.readOnly||autocomplete.some(v=>['off','one-time-code','current-password','new-password'].includes(v)||v.startsWith('cc-')))return false;
      if(/password|passphrase|token|secret|api[-_ ]?key|credential|(?:^|[-_ ])auth(?:$|[-_ ])/i.test([el.id,el.name,el.getAttribute('aria-label')||''].join(' ')))return false;
      return el.tagName!=='INPUT'||['text','search','email','url','tel','number','date','time','datetime-local','month','week','range','color','checkbox','radio'].includes(el.type);
    });
    const identity=el=>({tag:el.tagName,type:el.type,id:el.id,name:el.name,action:el.form?.getAttribute('action')||'',method:el.form?.method||'',options:el.tagName==='SELECT'?Array.from(el.options).map(o=>[o.value,o.text,o.disabled]):null});
    """#
    static let captureScript = controls + #"""
    const elements=controls();if(elements.length>256)throw new Error('网页填写过多，恢复备份尚未保存');
    const values=elements.map(el=>el.tagName==='SELECT'?{selected:Array.from(el.options).flatMap((o,i)=>o.selected?[i]:[])}:['checkbox','radio'].includes(el.type)?{checked:el.checked}:{value:el.value});
    return {url:location.href,x:scrollX,y:scrollY,forms:elements.length?{version:1,url:location.href,signature:JSON.stringify(elements.map(identity)),values}:null};
    """#
    static let restoreScript = controls + #"""
    const elements=controls();
    if(location.href!==state.url||JSON.stringify(elements.map(identity))!==state.signature||elements.length!==state.values.length)return false;
    for(let i=0;i<elements.length;i++){
      const el=elements[i],value=state.values[i];
      if('selected' in value&&!(el.tagName==='SELECT'&&value.selected.every(n=>Number.isInteger(n)&&n>=0&&n<el.options.length)))return false;
      if('checked' in value&&!['checkbox','radio'].includes(el.type))return false;
      if('value' in value&&(el.tagName==='SELECT'||['checkbox','radio'].includes(el.type)))return false;
    }
    for(let i=0;i<elements.length;i++){
      const el=elements[i],value=state.values[i];
      if('selected' in value)Array.from(el.options).forEach((o,n)=>{o.selected=value.selected.includes(n);});
      else if('checked' in value)el.checked=value.checked;else el.value=value.value;
    }
    return true;
    """#
}

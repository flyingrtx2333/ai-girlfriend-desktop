import AppKit
import ApplicationServices
import Carbon

@MainActor enum AgentDesktopAX {
    struct Node {
        var element: AXUIElement; var value: [String: Any]; var text: String; var secure: Bool
    }
    struct Snapshot {
        var window: AXUIElement; var frame: CGRect; var nodes: [Node]; var hash: String; var truncated: Bool
    }
    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
        if error == .cannotComplete || error == .invalidUIElement || error == .apiDisabled { throw PetError("目标应用暂时无法读取或权限已撤销（\(error.rawValue)）") }
        return error == .success ? result : nil
    }
    private static func string(_ element: AXUIElement, _ name: String) throws -> String { try attribute(element, name) as? String ?? "" }
    private static func frame(_ element: AXUIElement) throws -> CGRect? {
        guard let p = try attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(), let s = try attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2 }
    static func read(_ target: AgentDesktop.Target, window previous: AXUIElement? = nil) throws -> Snapshot {
        try Task.checkCancellation()
        let app = AXUIElementCreateApplication(target.pid); AXUIElementSetMessagingTimeout(app, 0.35)
        let windows = try attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let candidates = try windows.filter { element in
            AXUIElementSetMessagingTimeout(element, 0.35)
            if let previous { return CFEqual(element, previous) }
            guard let rect = try frame(element) else { return false }; return sameFrame(rect, target.frame)
        }
        guard candidates.count == 1, let window = candidates.first, let rect = try frame(window), sameFrame(rect, target.frame), try attribute(window, kAXMinimizedAttribute) as? Bool != true else { throw PetError("目标窗口已关闭、移动、缩放或无法唯一识别，请重新连接") }
        var nodes: [Node] = [], visited: Set<AXUIElement> = [], signatures: [[String: Any]] = [], truncated = false
        func walk(_ element: AXUIElement, depth: Int) throws {
            try Task.checkCancellation()
            guard !visited.contains(element) else { return }; visited.insert(element)
            guard nodes.count < 400, depth <= 24 else { truncated = true; return }
            AXUIElementSetMessagingTimeout(element, 0.35)
            let role = try string(element, kAXRoleAttribute), subrole = try string(element, kAXSubroleAttribute)
            let protected = try attribute(element, "AXProtectedContent") as? Bool == true
            let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField" || protected
            let title = try string(element, kAXTitleAttribute), description = try string(element, kAXDescriptionAttribute)
            let full = secure ? "[受保护输入]" : try attribute(element, kAXValueAttribute).map { String(describing: $0) } ?? ""
            let enabled = try attribute(element, kAXEnabledAttribute) as? Bool ?? true
            let focused = try attribute(element, kAXFocusedAttribute) as? Bool ?? false
            var actions: CFArray?; AXUIElementCopyActionNames(element, &actions)
            var settable = DarwinBoolean(false); AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            let bounds = try frame(element), ref = "e\(nodes.count + 1)"
            var value: [String: Any] = ["ref": ref, "role": role, "label": String((title.isEmpty ? description : title).prefix(180)), "value": String(full.prefix(1600)), "enabled": enabled, "focused": focused, "settable": !secure && settable.boolValue, "actions": actions as? [String] ?? [], "secure": secure]
            if let bounds { value["bounds"] = [bounds.minX - rect.minX, bounds.minY - rect.minY, bounds.width, bounds.height] }
            if full.count > 1600 { value["value_truncated"] = true }
            nodes.append(Node(element: element, value: value, text: title + " " + description + " " + String(full.prefix(1600)), secure: secure))
            var signature = value; signature["value_sha256"] = AgentFiles.hash(Data(full.utf8)); signatures.append(signature)
            if !secure { for child in try attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { try walk(child, depth: depth + 1) } }
        }
        try walk(window, depth: 0)
        let data = try JSONSerialization.data(withJSONObject: signatures, options: [.sortedKeys])
        return Snapshot(window: window, frame: rect, nodes: nodes, hash: AgentFiles.hash(data), truncated: truncated)
    }
    private static func check(_ error: AXError) throws { guard error == .success else { throw PetError("应用未接受此操作（\(error.rawValue)），请重读并核对实际状态") } }
    private static func focused(_ target: AgentDesktop.Target, snapshot: Snapshot, node: Node?) throws {
        if let node {
            guard !node.secure else { throw PetError("受保护输入须由用户手动处理") }
            try check(AXUIElementSetAttributeValue(node.element, kAXFocusedAttribute as CFString, kCFBooleanTrue))
        }
        let app = AXUIElementCreateApplication(target.pid)
        guard let window = try attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID(), CFEqual(window, snapshot.window),
              let element = try attribute(app, kAXFocusedUIElementAttribute), let item = snapshot.nodes.first(where: { CFEqual($0.element, element) }), !item.secure,
              !IsSecureEventInputEnabled() else { throw PetError("目标窗口或输入焦点已变化，或正在安全输入；请先在指定窗口选中控件并重新读取") }
    }
    static func act(_ args: [String: Any], snapshot: Snapshot, target: AgentDesktop.Target, validate: () throws -> Void) async throws {
        try Task.checkCancellation(); try validate()
        let action = args["action"] as? String ?? "", ref = args["ref"] as? String
        let node = ref.flatMap { id in snapshot.nodes.first { $0.value["ref"] as? String == id } }
        if ref != nil, node == nil { throw PetError("控件不属于当前窗口引用") }
        if let node, node.secure || node.value["enabled"] as? Bool == false { throw PetError("控件受保护或不可用") }
        if action == "press" || action == "click" && node != nil {
            guard let node, (node.value["actions"] as? [String] ?? []).contains(kAXPressAction) else { throw PetError("此控件没有按压动作；需要坐标操作时先获取实际截图") }
            try check(AXUIElementPerformAction(node.element, kAXPressAction as CFString)); return
        }
        if action == "set_value" {
            guard let node, node.value["settable"] as? Bool == true, let value = args["value"] as? String, value.utf8.count <= 16_000 else { throw PetError("请选择可写入控件，文本不超过16000字节") }
            try check(AXUIElementSetAttributeValue(node.element, kAXValueAttribute as CFString, value as CFString)); return
        }
        if action == "type" || action == "key" {
            try focused(target, snapshot: snapshot, node: node)
            if action == "type" {
                guard let text = args["value"] as? String, text.utf8.count <= 16_000 else { throw PetError("输入文本不超过16000字节") }
                for (index, character) in text.enumerated() {
                    if index % 32 == 0 { await Task.yield() }
                    try Task.checkCancellation(); try validate()
                    let utf16 = Array(String(character).utf16)
                    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw PetError("无法创建键盘事件") }
                    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16); up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                    down.postToPid(target.pid); up.postToPid(target.pid)
                }
            } else {
                let (code, flags) = try key(args["key"] as? String ?? "")
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw PetError("无法创建键盘事件") }
                down.flags = flags; up.flags = flags; down.postToPid(target.pid); up.postToPid(target.pid)
            }
            return
        }
        func point(_ x: String, _ y: String) throws -> CGPoint {
            guard let px = args[x] as? Double, let py = args[y] as? Double, px.isFinite, py.isFinite, px >= 0, py >= 0, px < snapshot.frame.width, py < snapshot.frame.height else { throw PetError("坐标必须位于指定窗口内，单位为窗口点数") }
            return CGPoint(x: snapshot.frame.minX + px, y: snapshot.frame.minY + py)
        }
        func mouse(_ type: CGEventType, _ location: CGPoint, count: Int64 = 1) throws {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left) else { throw PetError("无法创建鼠标事件") }
            event.setIntegerValueField(.mouseEventClickState, value: count)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
            event.postToPid(target.pid)
        }
        let app = AXUIElementCreateApplication(target.pid)
        guard let focusedWindow = try attribute(app, kAXFocusedWindowAttribute), CFEqual(focusedWindow, snapshot.window) else { throw PetError("目标应用已切换到另一个窗口，请重新选择并读取") }
        if action == "click" || action == "double_click" {
            let p = try point("x", "y")
            for i in 1...(action == "double_click" ? 2 : 1) { try mouse(.leftMouseDown, p, count: Int64(i)); try mouse(.leftMouseUp, p, count: Int64(i)) }; return
        }
        if action == "drag" {
            let start = try point("x", "y"), end = try point("to_x", "to_y"); var last = start
            try mouse(.leftMouseDown, start); defer { try? mouse(.leftMouseUp, last) }
            for i in 1...12 { try Task.checkCancellation(); try validate(); let t = CGFloat(i) / 12; last = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t); try mouse(.leftMouseDragged, last); try await Task.sleep(nanoseconds: 12_000_000) }; return
        }
        if action == "scroll" {
            let p = try point("x", "y"), direction = args["direction"] as? String ?? "", amount = min(700, max(40, args["amount"] as? Int ?? 400))
            guard ["up", "down", "left", "right"].contains(direction), let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: direction == "up" ? Int32(amount) : direction == "down" ? -Int32(amount) : 0, wheel2: direction == "left" ? Int32(amount) : direction == "right" ? -Int32(amount) : 0, wheel3: 0) else { throw PetError("请选择有效滚动方向") }
            event.location = p; event.postToPid(target.pid); return
        }
        throw PetError("未知桌面动作")
    }
    private static func key(_ value: String) throws -> (CGKeyCode, CGEventFlags) {
        var parts = value.lowercased().split(separator: "+").map(String.init); guard let name = parts.popLast() else { throw PetError("缺少按键") }
        let keys: [String: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"return":36,"enter":36,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"tab":48,"space":49,"`":50,"backspace":51,"escape":53,"home":115,"pageup":116,"delete":117,"end":119,"pagedown":121,"left":123,"right":124,"down":125,"up":126]
        guard let code = keys[name] else { throw PetError("不支持此按键名称") }
        var flags: CGEventFlags = []
        for part in parts {
            switch part { case "cmd", "command", "super": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); case "alt", "option": flags.insert(.maskAlternate); case "ctrl", "control": flags.insert(.maskControl); default: throw PetError("不支持此按键修饰符") }
        }
        return (code, flags)
    }
}

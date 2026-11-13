import AppKit
import QuartzCore

enum AgentThemeStyle: String, Codable, CaseIterable {
    case forest, mint, bee, parchment
    var title: String { switch self { case .forest: return "森林"; case .mint: return "薄荷"; case .bee: return "蜜蜂"; case .parchment: return "羊皮纸" } }
}

@MainActor final class AgentThemeStyles {
    struct Settings: Codable, Equatable {
        var version = 1
        var coding = AgentThemeStyle.forest, general = AgentThemeStyle.bee
        subscript(_ mode: AgentWorkMode) -> AgentThemeStyle {
            get { mode == .coding ? coding : general }
            set { if mode == .coding { coding = newValue } else { general = newValue } }
        }
    }
    static let changed = Notification.Name("BlueFatFishThemeStylesChanged")
    let directory: URL
    private(set) var settings = Settings(), error: String?
    private var revision: String?
    var onChange: (() -> Void)?
    init(directory: URL) { self.directory = directory; reload() }
    func reload() {
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("theme-styles.json"), entry = try files.entryMetadata(file)
            guard try files.resolve("theme-styles.json") == file, ["missing", "file"].contains(entry.kind) else { throw PetError("主题风格配置必须是普通文件") }
            if entry.kind == "missing" { settings = Settings(); revision = nil }
            else {
                let data = try files.readData(file, maximum: 4096)
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == ["version", "coding", "general"] else { throw PetError("主题风格配置包含不支持或缺少的字段") }
                guard let value = try? JSONDecoder().decode(Settings.self, from: data), value.version == 1 else { throw PetError("主题风格配置版本或风格无效") }
                settings = value; revision = AgentFiles.hash(data)
            }
            error = nil
        } catch { self.error = "主题风格未载入：" + error.localizedDescription }
    }
    func save(_ value: Settings) throws {
        guard error == nil else { throw PetError(error! + "；请重新载入") }
        guard value.version == 1 else { throw PetError("主题风格配置版本无效") }
        guard value != settings else { return }
        let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("theme-styles.json"), entry = try files.entryMetadata(file)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("主题风格配置只读，未保存") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(value)
        let write = try AgentKnowledgeFileWrite(files: files, path: "theme-styles.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "主题风格配置")
        try write.requireCurrent(); try files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        settings = value; revision = AgentFiles.hash(data); publish()
    }
    func publish() { onChange?(); NotificationCenter.default.post(name: Self.changed, object: self) }
}

enum AgentThemeColorRole: CaseIterable, Hashable { case sidebar, surface, settings, line, accent, accentText, selection, navigationSelection, hover, subtle, secondaryText, primary, primaryText, added, removed }

// Keep semantic colors immutable. Each style gets its own dynamic light/dark
// colors; two task windows never compete for an application-wide palette.
@MainActor enum AgentThemePalette {
    private struct Key: Hashable { var style: AgentThemeStyle; var role: AgentThemeColorRole }
    private static var colors: [Key: NSColor] = [:], roles: [ObjectIdentifier: AgentThemeColorRole] = [:]
    private static var tokens: [(AgentThemeColorRole, NSColor)] {
        [(.sidebar, AgentWorkbenchTheme.sidebar), (.surface, AgentWorkbenchTheme.surface), (.settings, AgentWorkbenchTheme.settings), (.line, AgentWorkbenchTheme.line),
         (.accent, AgentWorkbenchTheme.accent), (.accentText, AgentWorkbenchTheme.accentText), (.selection, AgentWorkbenchTheme.selection), (.navigationSelection, AgentWorkbenchTheme.navigationSelection),
         (.hover, AgentWorkbenchTheme.hover), (.subtle, AgentWorkbenchTheme.subtle), (.secondaryText, AgentWorkbenchTheme.secondaryText), (.primary, AgentWorkbenchTheme.primary), (.primaryText, AgentWorkbenchTheme.primaryText), (.added, AgentWorkbenchTheme.added), (.removed, AgentWorkbenchTheme.removed)]
    }
    static func role(of color: NSColor) -> AgentThemeColorRole? { roles[ObjectIdentifier(color)] ?? tokens.first { $0.1 === color }?.0 }
    static func color(_ role: AgentThemeColorRole, style: AgentThemeStyle) -> NSColor {
        let key = Key(style: style, role: role)
        if let value = colors[key] { return value }
        let light = literal(role, style: style, dark: false), dark = literal(role, style: style, dark: true)
        let value = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
        colors[key] = value; roles[ObjectIdentifier(value)] = role; return value
    }
    static func literal(_ role: AgentThemeColorRole, style: AgentThemeStyle, dark: Bool) -> NSColor {
        var hex: UInt32, alpha: CGFloat = 1
        switch role {
        case .sidebar:
            switch style { case .forest: hex = dark ? 0x1c2420 : 0xedf2ee; case .mint: hex = dark ? 0x182723 : 0xeaf6f0; case .bee: hex = dark ? 0x28281d : 0xf3efcd; case .parchment: hex = dark ? 0x29221e : 0xf1eae0 }
        case .accent:
            switch style { case .forest: hex = dark ? 0x99c5ad : 0x4b715c; case .mint: hex = dark ? 0x6bd4b6 : 0x14775f; case .bee: hex = dark ? 0xdfcd72 : 0x88700b; case .parchment: hex = dark ? 0xe8ad91 : 0xb15937 }
        case .accentText: hex = dark ? (style == .bee ? 0x332c0e : style == .parchment ? 0x382219 : 0x10352b) : 0xffffff
        case .selection:
            switch style { case .forest: hex = dark ? 0x2b4336 : 0xd4e5d9; case .mint: hex = dark ? 0x28453f : 0xd1e4e2; case .bee: hex = dark ? 0x494124 : 0xe9dfb6; case .parchment: hex = dark ? 0x48342a : 0xecdccd }
        case .surface: hex = dark ? 0x242629 : 0xfefefe
        case .settings: hex = dark ? 0x242629 : 0xfcfcfc
        case .line: hex = dark ? 0x3a3d42 : 0xd6dbe0
        case .navigationSelection: hex = dark ? 0xffffff : 0x000000; alpha = 0.07
        case .hover: hex = dark ? 0xffffff : 0x000000; alpha = 0.045
        case .subtle: hex = dark ? 0x303338 : 0xf2f3f5
        case .secondaryText: hex = dark ? 0xb6bbc4 : 0x59616b
        case .primary: hex = dark ? 0xe5e7eb : 0x1a1a1a
        case .primaryText: hex = dark ? 0x1c1e22 : 0xffffff
        case .added: hex = dark ? 0x203b2d : 0xebf7ed
        case .removed: hex = dark ? 0x492b2d : 0xfcebea
        }
        return rgb(hex, alpha: alpha)
    }
    static func sidebarGradient(style: AgentThemeStyle, dark: Bool) -> NSGradient? {
        guard style == .bee else { return nil }
        return NSGradient(starting: literal(.sidebar, style: style, dark: dark), ending: rgb(dark ? 0x202a31 : 0xdde8ed))
    }
    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}

@MainActor private final class AgentThemeScope: NSObject {
    weak var service: AgentThemeStyles?
    var mode: AgentWorkMode
    init(service: AgentThemeStyles, mode: AgentWorkMode) { self.service = service; self.mode = mode }
}

@MainActor enum AgentThemeContext {
    private static let scopes = NSMapTable<NSWindow, AgentThemeScope>.weakToStrongObjects()
    private static let layerColors = NSMapTable<CALayer, NSColor>.weakToStrongObjects()
    static func bind(_ window: NSWindow, service: AgentThemeStyles, mode: AgentWorkMode) {
        if let scope = scopes.object(forKey: window) { scope.service = service; scope.mode = mode }
        else { scopes.setObject(AgentThemeScope(service: service, mode: mode), forKey: window) }
    }
    static func style(for window: NSWindow?) -> AgentThemeStyle? {
        var current = window, visited = Set<ObjectIdentifier>()
        while let candidate = current, visited.insert(ObjectIdentifier(candidate)).inserted {
            if let scope = scopes.object(forKey: candidate), let service = scope.service { return service.settings[scope.mode] }
            current = candidate.sheetParent ?? candidate.parent
        }
        return nil
    }
    static func resolve(_ color: NSColor, in view: NSView?) -> NSColor { resolve(color, window: view?.window) }
    static func resolve(_ color: NSColor, window: NSWindow?) -> NSColor {
        guard let style = style(for: window), let role = AgentThemePalette.role(of: color) else { return color }
        return AgentThemePalette.color(role, style: style)
    }
    static func remember(_ layer: CALayer, color: NSColor) {
        if AgentThemePalette.role(of: color) != nil { layerColors.setObject(color, forKey: layer) }
        else { layerColors.removeObject(forKey: layer) }
    }
    static func refresh(_ root: NSView, invalidate: Bool = false) {
        func bind(_ view: NSView) {
            func color(_ value: NSColor?) -> NSColor? { value.map { resolve($0, in: view) } }
            if let control = view as? NSButton, let old = control.contentTintColor, let next = color(old), old !== next { control.contentTintColor = next }
            if let image = view as? NSImageView, let old = image.contentTintColor, let next = color(old), old !== next { image.contentTintColor = next }
            if let text = view as? NSTextField, let old = text.textColor, let next = color(old), old !== next { text.textColor = next }
            if let tabs = view as? NSSegmentedControl, let old = tabs.selectedSegmentBezelColor, let next = color(old), old !== next { tabs.selectedSegmentBezelColor = next }
            if let layer = view.layer, let token = layerColors.object(forKey: layer) {
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let next = resolve(token, in: view).cgColor
                    if layer.backgroundColor != next { CATransaction.begin(); CATransaction.setDisableActions(true); layer.backgroundColor = next; CATransaction.commit() }
                }
            }
            if invalidate { view.needsDisplay = true }
            view.subviews.forEach(bind)
        }
        bind(root)
    }
}

import AppKit
import UniformTypeIdentifiers

enum AgentFileIconStyle: String, Codable, CaseIterable {
    case native, material
    var title: String { self == .native ? "小鲸" : "Material File Icons" }
}

@MainActor final class AgentFileIcons {
    struct Settings: Codable, Equatable { var version = 1; var style = AgentFileIconStyle.native }
    struct Catalog: Decodable {
        let version: Int, package: String, packageVersion: String, defaultIcon: String
        let icons: [String: String], files: [String: String], extensions: [String: String]
    }
    private final class Binding: NSObject {
        let name: String, size: CGFloat
        init(_ name: String, size: CGFloat = 16) { self.name = (name as NSString).lastPathComponent; self.size = size }
    }
    static let changed = Notification.Name("BlueFatFishFileIconsChanged")
    static let marker = NSAttributedString.Key("BlueFatFishInlineFileIcon")
    static private(set) var style = AgentFileIconStyle.native
    static let catalog: Catalog? = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "file-icons"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Catalog.self, from: data),
              value.version == 1, value.package == "material-file-icons", value.icons[value.defaultIcon] != nil,
              value.files.values.allSatisfy({ value.icons[$0] != nil }), value.extensions.values.allSatisfy({ value.icons[$0] != nil }) else { return nil }
        return value
    }()
    private static let suffixes = catalog?.extensions.keys.sorted { $0.count > $1.count } ?? []
    private static var images: [String: NSImage] = [:]
    private static let views = NSMapTable<NSView, Binding>.weakToStrongObjects()
    private static let attachments = NSMapTable<NSTextAttachment, Binding>.weakToStrongObjects()
    private static let textViews = NSHashTable<NSView>.weakObjects()
    let directory: URL
    private(set) var settings = Settings(), error: String?
    private var revision: String?
    init(directory: URL) { self.directory = directory; reload() }
    func reload() {
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("file-icons.json"), entry = try files.entryMetadata(file)
            guard try files.resolve("file-icons.json") == file, ["missing", "file"].contains(entry.kind) else { throw PetError("文件图标配置必须是普通文件") }
            if entry.kind == "missing" { settings = Settings(); revision = nil }
            else {
                let data = try files.readData(file, maximum: 4096)
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == ["version", "style"],
                      let value = try? JSONDecoder().decode(Settings.self, from: data), value.version == 1 else { throw PetError("文件图标配置版本或选项无效") }
                try validate(value); settings = value; revision = AgentFiles.hash(data)
            }
            error = nil
        } catch { self.error = "文件图标未载入：" + error.localizedDescription }
    }
    private func validate(_ value: Settings) throws {
        guard value.version == 1 else { throw PetError("文件图标配置版本无效") }
        guard value.style != .material || Self.catalog != nil else { throw PetError("文件图标资源缺失，请重新安装应用") }
    }
    func save(_ value: Settings) throws {
        guard error == nil else { throw PetError(error! + "；请重新载入") }
        try validate(value); guard value != settings else { return }
        let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("file-icons.json"), entry = try files.entryMetadata(file)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("文件图标配置只读，未保存") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(value)
        let write = try AgentKnowledgeFileWrite(files: files, path: "file-icons.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "文件图标配置")
        try write.requireCurrent(); try files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        settings = value; revision = AgentFiles.hash(data); apply()
    }
    func apply() { Self.style = settings.style; Self.refresh(); NotificationCenter.default.post(name: Self.changed, object: self) }
    static func identifier(_ name: String, style: AgentFileIconStyle? = nil) -> String {
        let selected = style ?? Self.style, filename = (name as NSString).lastPathComponent.lowercased()
        if selected == .material, let catalog {
            if let exact = catalog.files[filename] { return exact }
            for suffix in suffixes where filename.hasSuffix("." + suffix) { return catalog.extensions[suffix]! }
            return catalog.defaultIcon
        }
        guard let type = UTType(filenameExtension: (filename as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }; if type.conforms(to: .movie) { return "film" }; if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }; if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }; if type.conforms(to: .pdf) { return "doc.richtext" }
        return type.conforms(to: .text) ? "doc.text" : "doc"
    }
    static func image(_ name: String, inline: Bool = false) -> NSImage {
        let id = identifier(name), dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = style.rawValue + ":" + id + (inline ? ":inline" + (style == .native && dark ? ":dark" : ":light") : "")
        if let image = images[key] { return image }
        let image: NSImage
        if style == .material, let svg = catalog?.icons[id], let value = NSImage(data: Data(svg.utf8)) { image = value; image.isTemplate = false }
        else {
            let symbol = NSImage(systemSymbolName: id, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!
            image = (inline ? symbol.withSymbolConfiguration(.init(paletteColors: [.labelColor])) ?? symbol : symbol).copy() as! NSImage
            image.isTemplate = !inline
        }
        image.size = NSSize(width: 16, height: 16); images[key] = image; return image
    }
    static func bind(_ view: NSView, filename: String) {
        let binding = Binding(filename); views.setObject(binding, forKey: view); update(view, binding)
    }
    static func unbind(_ view: NSView) { views.removeObject(forKey: view) }
    private static func update(_ view: NSView, _ binding: Binding) {
        if let button = view as? NSButton { button.image = image(binding.name); button.imagePosition = .imageLeading; button.imageScaling = .scaleProportionallyDown }
        else if let picture = view as? NSImageView { picture.image = image(binding.name) }
        view.needsDisplay = true
    }
    static func attachment(filename: String, font: NSFont) -> NSAttributedString {
        let size = max(12, min(20, font.pointSize)), binding = Binding(filename, size: size), attachment = NSTextAttachment()
        let picture = image(filename, inline: true).copy() as! NSImage; picture.size = NSSize(width: size, height: size)
        attachment.image = picture; attachment.bounds = NSRect(x: 0, y: font.descender, width: size, height: size)
        attachments.setObject(binding, forKey: attachment)
        let value = NSMutableAttributedString(attachment: attachment); value.addAttributes([marker: binding.name, AgentMarkdownDocument.selectedSource: "", .kern: 3], range: NSRange(location: 0, length: value.length)); return value
    }
    static func track(_ view: NSView) { textViews.add(view) }
    static func readback(in root: NSView) -> [String: Any] {
        guard ["--file-icons-check", "--manual-ui"].contains(where: CommandLine.arguments.contains) else { return [:] }
        func digest(_ image: NSImage?) -> String {
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return "" }; return AgentFiles.hash(data)
        }
        func belongs(_ view: NSView) -> Bool { view === root || view.isDescendant(of: root) }
        let bound: [[String: Any]] = views.keyEnumerator().allObjects.compactMap { object in
            guard let view = object as? NSView, belongs(view), let binding = views.object(forKey: view) else { return nil }
            let button = view as? NSButton
            return ["name": binding.name, "kind": String(describing: type(of: view)), "icon": identifier(binding.name), "imageHash": digest(button?.image ?? (view as? NSImageView)?.image), "label": button?.title ?? "", "visible": !view.isHiddenOrHasHiddenAncestor]
        }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        var inline: [[String: Any]] = []
        for view in textViews.allObjects where belongs(view) {
            let text: NSAttributedString?
            if let view = view as? NSTextView { text = view.textStorage } else { text = (view as? NSTextField)?.attributedStringValue }
            text?.enumerateAttribute(marker, in: NSRange(location: 0, length: text?.length ?? 0)) { name, range, _ in
                guard let name = name as? String else { return }; let attachment = text?.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
                inline.append(["name": name, "icon": identifier(name), "imageHash": digest(attachment?.image), "location": range.location, "width": attachment?.bounds.width ?? 0])
            }
        }
        return ["style": style.rawValue, "views": bound, "inline": inline]
    }
    static func plainText(_ value: NSAttributedString) -> String {
        let copy = NSMutableAttributedString(attributedString: value); var ranges: [NSRange] = []
        value.enumerateAttribute(marker, in: NSRange(location: 0, length: value.length)) { item, range, _ in if item != nil { ranges.append(range) } }
        for range in ranges.reversed() { copy.deleteCharacters(in: range) }; return copy.string
    }
    static func refresh() {
        for view in views.keyEnumerator().allObjects.compactMap({ $0 as? NSView }) { if let binding = views.object(forKey: view) { update(view, binding) } }
        for attachment in attachments.keyEnumerator().allObjects.compactMap({ $0 as? NSTextAttachment }) {
            if let binding = attachments.object(forKey: attachment) { let picture = image(binding.name, inline: true).copy() as! NSImage; picture.size = NSSize(width: binding.size, height: binding.size); attachment.image = picture }
        }
        for view in textViews.allObjects {
            view.needsDisplay = true
            if let text = view as? NSTextView { text.layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: text.string.utf16.count)) }
        }
    }
}

@MainActor final class AgentFileIconsSettingsView: NSStackView {
    private let service: AgentFileIcons, choice = NSPopUpButton(), status = NSTextField(wrappingLabelWithString: ""), reload = NSButton(title: "重新载入", target: nil, action: nil)
    init(service: AgentFileIcons) {
        self.service = service; super.init(frame: .zero); orientation = .vertical; alignment = .leading; spacing = 10
        choice.addItems(withTitles: AgentFileIconStyle.allCases.map(\.title)); choice.setAccessibilityLabel("文件图标"); choice.identifier = NSUserInterfaceItemIdentifier("file-icon-style")
        choice.target = self; choice.action = #selector(change); choice.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let row = AgentSettingsStyle.formRow("文件图标", choice, trailing: true); addArrangedSubview(row); row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        status.font = .systemFont(ofSize: 12); status.textColor = AgentWorkbenchTheme.secondaryText; reload.target = self; reload.action = #selector(reloadSettings)
        let footer = NSStackView(views: [status, NSView(), reload]); footer.spacing = 12; addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AgentFileIcons.changed, object: service); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func refresh() {
        choice.selectItem(at: AgentFileIconStyle.allCases.firstIndex(of: service.settings.style) ?? 0); choice.isEnabled = service.error == nil
        if let error = service.error { status.stringValue = error }; reload.isHidden = status.stringValue.isEmpty || status.stringValue == "已保存"; status.superview?.isHidden = status.stringValue.isEmpty
    }
    @objc private func change() {
        var value = service.settings; value.style = AgentFileIconStyle.allCases[max(0, choice.indexOfSelectedItem)]
        do { try service.save(value); status.stringValue = "已保存" } catch { status.stringValue = error.localizedDescription }; refresh()
    }
    @objc private func reloadSettings() { service.reload(); service.apply(); status.stringValue = service.error ?? "已重新载入"; refresh() }
}

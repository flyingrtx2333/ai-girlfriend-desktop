import AppKit
import ImageIO

struct AgentCanvasPreview: Codable {
    var sourceHash: String
    var imageHash: String
}

@MainActor extension AgentCanvas {
    func cachePreview(_ shot: AgentCanvasShot, taskID: String) throws {
        let id = shot.capture.canvasID, current = try source(id, taskID: taskID)
        guard current.record.hash == shot.capture.sourceHash else { throw PetError("画布已变化，预览未替换") }
        let data = try shot.annotationShot.png()
        guard data.count <= 20_000_000 else { throw PetError("画布预览超过20MB") }
        let files = try AgentFiles(workspace: directory(id, taskID: taskID).path)
        try files.writeData(data, to: files.literalURL("preview.png"), permissions: 0o600)
        try files.writeData(JSONEncoder().encode(AgentCanvasPreview(sourceHash: current.record.hash, imageHash: AgentFiles.hash(data))), to: files.literalURL("preview.json"), permissions: 0o600)
        onChange?(taskID)
    }
    func previewSignature(_ record: AgentCanvasRecord, taskID: String) -> String {
        guard let files = try? AgentFiles(workspace: directory(record.id, taskID: taskID).path),
              let data = try? files.readData(files.literalURL("preview.json"), maximum: 4096),
              let value = try? JSONDecoder().decode(AgentCanvasPreview.self, from: data), value.sourceHash == record.hash else { return "" }
        return value.imageHash
    }
    func previewImage(_ record: AgentCanvasRecord, taskID: String) -> NSImage? {
        guard let files = try? AgentFiles(workspace: directory(record.id, taskID: taskID).path),
              let source = try? files.readData(files.literalURL("document.canvas.tsx"), maximum: 256_000), AgentFiles.hash(source) == record.hash,
              let data = try? files.readData(files.literalURL("preview.png"), maximum: 20_000_000),
              AgentFiles.hash(data) == previewSignature(record, taskID: taskID) else { return nil }
        return Self.previewThumbnail(data)
    }
    static func capturePreviewImage(_ file: AgentAttachment, store: AgentStore, taskID: String) -> NSImage? {
        guard file.canvasCapture != nil, store.task(taskID)?.availableAttachmentIDs.contains(file.id) == true,
              let url = try? AgentAttachments.source(store: store, taskID: taskID, id: file.id),
              let files = try? AgentFiles(workspace: url.deletingLastPathComponent().path),
              let data = try? files.readData(url, maximum: 20_000_000), AgentFiles.hash(data) == file.sha256 else { return nil }
        return previewThumbnail(data)
    }
    private static func previewThumbnail(_ data: Data) -> NSImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
    }
}

@MainActor private final class AgentCanvasSnapshotView: NSImageView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

@MainActor final class AgentCanvasPreviewRow: AgentThemeView {
    var onOpen: (() -> Void)?
    init(record: AgentCanvasRecord, image: NSImage?, actionTitle: String = "打开画布") {
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 10; layer?.borderWidth = 1; stroke = NSColor.separatorColor.withAlphaComponent(0.45)
        let title = NSTextField(labelWithString: record.title), open = NSButton(title: actionTitle, target: self, action: #selector(openCanvas))
        title.font = .systemFont(ofSize: 12, weight: .medium); title.lineBreakMode = .byTruncatingTail; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        open.bezelStyle = .texturedRounded; open.controlSize = .regular; open.font = .systemFont(ofSize: 12); open.setAccessibilityLabel(actionTitle + " · " + record.title)
        let header = NSStackView(views: [title, NSView(), open]); header.spacing = 8
        addSubview(header); header.translatesAutoresizingMaskIntoConstraints = false
        var layout = [header.topAnchor.constraint(equalTo: topAnchor, constant: 10), header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), header.heightAnchor.constraint(equalToConstant: 24)]
        if let image {
            let snapshot = AgentCanvasSnapshotView(image: image); snapshot.imageScaling = .scaleProportionallyUpOrDown
            snapshot.setAccessibilityLabel("画布快照 · " + record.title + " · " + String(record.hash.prefix(12))); snapshot.toolTip = "源码版本 " + record.hash
            addSubview(snapshot); snapshot.translatesAutoresizingMaskIntoConstraints = false
            let aspect = snapshot.heightAnchor.constraint(equalTo: snapshot.widthAnchor, multiplier: image.size.height / max(1, image.size.width)); aspect.priority = .defaultHigh
            layout += [snapshot.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8), snapshot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), snapshot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), snapshot.heightAnchor.constraint(lessThanOrEqualToConstant: 460), aspect, snapshot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)]
        } else { layout.append(header.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)) }
        NSLayoutConstraint.activate(layout)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func openCanvas() { onOpen?() }
}

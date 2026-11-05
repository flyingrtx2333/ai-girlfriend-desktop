import AppKit

@MainActor extension AppDelegate {
    func runAgentDocumentCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            let scratch = output.appendingPathComponent("parser-tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            func read(_ name: String) async throws -> AgentDocumentContent { try await AgentDocument.extract(output.appendingPathComponent(name), scratch: scratch) }
            let independent = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("independent.json"))) as! [String: Any]
            let word = try await read("sample.docx"), sheet = try await read("sample.xlsx"), cached = try await read("cached.xlsx"), slides = try await read("sample.pptx")
            checks["wordReadsRealOfficeGeneratedParagraphsAndTable"] = word.parts.first?.text.contains(independent["docxText"] as? String ?? "invalid") == true && word.parts.first?.text.contains("项目\t金额\n茶\t25.00") == true
            checks["spreadsheetPreservesWorkbookOrderAndCells"] = sheet.parts.map(\.title) == independent["sheetOrder"] as? [String] && sheet.parts.last?.text.contains("B2: 25") == true && sheet.parts.last?.text.contains("B5: 0.15 [格式：0%]") == true
            checks["formulaWithoutCacheIsNotInvented"] = sheet.parts.last?.text.contains("B4:  [公式：=SUM(B2:B3)；无缓存结果]") == true
            checks["cachedFormulaMatchesIndependentOfficeReader"] = independent["cachedTotal"] as? Int == 49 && cached.parts.last?.text.contains("B4: 49 [公式：=SUM(B2:B3)]") == true
            let order = independent["slideOrder"] as? [String] ?? []
            checks["slidesFollowPresentationRelationshipsNotFilenames"] = slides.parts.map(\.text) == order && order.first == "Second slide 4086"
            do { _ = try await read("unsafe.docx"); checks["utf16DTDIsRejectedBeforeEntityResolution"] = false } catch { checks["utf16DTDIsRejectedBeforeEntityResolution"] = true }
            let width = 900, height = 320
            guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PetError("公开图像无法创建") }
            bitmap.setFillColor(NSColor.white.cgColor); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
            NSAttributedString(string: "PUBLIC RECEIPT\nTotal 1499.00\nQueue WHALE-7319", attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black]).draw(in: NSRect(x: 45, y: 55, width: 800, height: 230))
            NSGraphicsContext.restoreGraphicsState()
            guard let image = bitmap.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw PetError("公开图像无法写入") }
            let imageURL = output.appendingPathComponent("receipt.png"); try png.write(to: imageURL)
            var box = CGRect(x: 0, y: 0, width: 600, height: 400)
            guard let consumer = CGDataConsumer(url: output.appendingPathComponent("sample.pdf") as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PetError("公开 PDF 无法创建") }
            pdf.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            NSAttributedString(string: "PUBLIC RULES\nLimit 1800\nQueue WHALE-7319", attributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]).draw(in: NSRect(x: 45, y: 70, width: 500, height: 260))
            NSGraphicsContext.restoreGraphicsState(); pdf.endPDFPage()
            pdf.beginPDFPage(nil); pdf.draw(image, in: CGRect(x: 25, y: 70, width: 550, height: 196)); pdf.endPDFPage(); pdf.closePDF()
            let document = try await read("sample.pdf"), photo = try await read("receipt.png")
            let scanned = try await Task.detached(priority: .utility) { try AgentDocument.pdfPage(output.appendingPathComponent("sample.pdf"), number: 2, recognize: true) }.value
            checks["pdfTextPreservesPageBoundaries"] = document.totalParts == 2 && document.parts[0].text.contains("1800") && document.parts[1].text.isEmpty
            checks["localImageOCRReadsActualPixels"] = photo.parts[0].text.contains("1499.00") && photo.parts[0].text.contains("7319")
            checks["scannedPdfPageOCRReadsActualPixels"] = scanned.0.text.contains("1499.00") && scanned.1 != nil
            let normalized = try AgentDocument.image(imageURL)
            checks["imageUsesBoundedPreview"] = normalized.width <= 1536 && normalized.height <= 1536 && normalized.jpeg.count < 2_000_000
            ensureAgent(); guard let tasks = agentStore else { throw PetError("附件任务存储未初始化") }
            let owner = tasks.create(title: "附件私有副本验证", mode: .ask)
            let attachment = try await AgentAttachments.importFile(output.appendingPathComponent("sample.docx"), store: tasks, taskID: owner)
            let copied = try AgentAttachments.source(store: tasks, taskID: owner, id: attachment.id)
            let originalHash = AgentFiles.hash(try Data(contentsOf: output.appendingPathComponent("sample.docx"))), permissions = try FileManager.default.attributesOfItem(atPath: copied.path)[.posixPermissions] as? Int
            checks["attachmentImportPreservesOriginalInPrivateCopy"] = copied != output.appendingPathComponent("sample.docx") && attachment.sha256 == originalHash && permissions == 0o400
            let other = tasks.create(title: "另一项任务", mode: .ask)
            do { _ = try AgentAttachments.content(store: tasks, taskID: other, id: attachment.id); checks["attachmentIDsCannotCrossTaskBoundaries"] = false } catch { checks["attachmentIDsCannotCrossTaskBoundaries"] = true }
            tasks.update(owner) { $0.messages.append(AgentMessage(role: "user", content: "公开附件", attachmentIDs: [attachment.id])) }
            guard let fork = tasks.fork(owner) else { throw PetError("附件分支失败") }
            try FileManager.default.removeItem(at: copied.deletingLastPathComponent())
            let forkContent = try AgentAttachments.content(store: tasks, taskID: fork, id: attachment.id)
            checks["forkKeepsIndependentAttachmentAfterParentRemoval"] = forkContent.parts[0].text.contains("1499.00")
            try AgentAttachments.removeDraft(store: tasks, taskID: fork, id: attachment.id)
            checks["removingDraftPreservesAttachmentUsedByHistory"] = tasks.task(fork)?.draftAttachmentIDs?.isEmpty == true && (try? AgentAttachments.source(store: tasks, taskID: fork, id: attachment.id)) != nil
            report["actual"] = ["word": word.parts, "spreadsheet": sheet.parts, "cached": cached.parts, "slides": slides.parts].mapValues { $0.map { ["title": $0.title, "text": $0.text] } }
            report["ocr"] = ["image": photo.parts[0].text, "pdfPage": scanned.0.text]
        } catch { report["error"] = error.localizedDescription }
        report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil; report["checks"] = checks
        report["scope"] = "Native format-reader and attachment-storage verification only. Actual python-docx, openpyxl and python-pptx files with independent library readback; actual generated PDF/image pixels and local OCR; private copies, task boundaries and fork retention. No AI acceptance claim, model calls, microphone or TTS."
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("document-report.json")) }
    }
}

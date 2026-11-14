import AppKit

@MainActor extension AppDelegate {
    func runWorkspaceRecoveryCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            let profile = output.appendingPathComponent("recovery-profile"), source = output.appendingPathComponent("recovery-source")
            for url in [profile, source] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let journal = AgentWorkspaceRecovery(profile: profile), files = try AgentFiles(workspace: profile.path), sourceFiles = try AgentFiles(workspace: source.path)
            let sentinel = try files.resolve("original-user-data.bin"), original = Data("ORIGINAL_USER_DATA_PUBLIC_519".utf8)
            try files.writeData(original, to: sentinel, permissions: 0o600)
            checks["oldProfileStartsWithoutRecoveryRecords"] = try journal.list().windows.isEmpty && journal.list().issues.isEmpty && !FileManager.default.fileExists(atPath: profile.appendingPathComponent("workspace-recovery").path)
            let owner = UUID().uuidString, pageID = UUID().uuidString, windowID = UUID().uuidString
            let tab = AgentWorkspaceRecovery.Tab(id: pageID, root: "document:" + source.appendingPathComponent("public.txt").path, title: "public.txt")
            var window = AgentWorkspaceRecovery.Window(id: windowID, number: 1, taskID: owner, frame: .init(x: 100, y: 120, width: 1200, height: 774), tasks: [.init(taskID: owner, tabs: [tab], selected: tab.root, opened: true, expanded: false)])
            var savedWindow = try journal.saveWindow(window, expected: nil)
            checks["windowLayoutRoundTripsWithoutChangingTaskData"] = try journal.loadWindow(windowID)?.value == window && files.readData(sentinel) == original
            let firstAsset = try sourceFiles.resolve("first.data"), secondAsset = try sourceFiles.resolve("second.data")
            let firstBytes = Data("FIRST_RECOVERY_RESOURCE_PUBLIC_624".utf8), secondBytes = Data("SECOND_RECOVERY_RESOURCE_PUBLIC_835".utf8)
            try sourceFiles.writeData(firstBytes, to: firstAsset, permissions: 0o600); try sourceFiles.writeData(secondBytes, to: secondAsset, permissions: 0o600)
            let state = Data(#"{"draft":"公开的未保存编辑","openedHash":"source-version-public"}"#.utf8)
            var page = AgentWorkspaceRecovery.Page(taskID: owner, kind: "record", state: state, dirty: true, asset: nil)
            var savedPage = try journal.savePage(page, asset: firstAsset, windowID: windowID, pageID: pageID, expected: nil)
            var loaded = try journal.loadPage(windowID: windowID, pageID: pageID, taskID: owner)!
            checks["draftAndResourceRoundTripExactly"] = try loaded.saved.value.state == state && loaded.saved.value.dirty && Data(contentsOf: loaded.asset!) == firstBytes
            let layoutURL = try files.resolve("workspace-recovery/" + windowID + "/layout.json"), pageURL = try files.resolve("workspace-recovery/" + windowID + "/pages/" + pageID + ".json")
            let pageBefore = try files.readData(pageURL), firstAssetURL = loaded.asset!
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: pageURL.path)
            do { _ = try journal.savePage(page, asset: secondAsset, windowID: windowID, pageID: pageID, expected: savedPage.hash); checks["readOnlyDraftRejectsWriteBeforeChangingResources"] = false }
            catch { checks["readOnlyDraftRejectsWriteBeforeChangingResources"] = try files.readData(pageURL) == pageBefore && Data(contentsOf: firstAssetURL) == firstBytes && !FileManager.default.fileExists(atPath: firstAssetURL.deletingLastPathComponent().appendingPathComponent(pageID + ".1.data").path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pageURL.path)
            page.state = Data("SECOND_DRAFT_PUBLIC_046".utf8)
            savedPage = try journal.savePage(page, asset: secondAsset, windowID: windowID, pageID: pageID, expected: savedPage.hash)
            loaded = try journal.loadPage(windowID: windowID, pageID: pageID, taskID: owner)!
            checks["newResourceUsesOtherSlotAndRetainsPreviousSlot"] = try savedPage.value.asset?.slot == 1 && Data(contentsOf: loaded.asset!) == secondBytes && Data(contentsOf: firstAssetURL) == firstBytes
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: firstAssetURL.path)
            let activeBefore = try files.readData(pageURL)
            do { _ = try journal.savePage(page, asset: firstAsset, windowID: windowID, pageID: pageID, expected: savedPage.hash); checks["readOnlyInactiveSlotKeepsActiveDraftAndResource"] = false }
            catch { checks["readOnlyInactiveSlotKeepsActiveDraftAndResource"] = try files.readData(pageURL) == activeBefore && Data(contentsOf: loaded.asset!) == secondBytes }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: firstAssetURL.path)
            var wrongKind = page; wrongKind.kind = "office"
            do { _ = try journal.savePage(wrongKind, asset: nil, windowID: windowID, pageID: pageID, expected: savedPage.hash); checks["editorKindCannotReplaceAnotherDraft"] = false }
            catch { checks["editorKindCannotReplaceAnotherDraft"] = try files.readData(pageURL) == activeBefore }
            do { _ = try journal.loadPage(windowID: windowID, pageID: pageID, taskID: UUID().uuidString); checks["draftOwnershipRejectsAnotherTask"] = false }
            catch { checks["draftOwnershipRejectsAnotherTask"] = true }
            let layoutBefore = try files.readData(layoutURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: layoutURL.path)
            do { _ = try journal.saveWindow(window, expected: savedWindow.hash); checks["readOnlyLayoutPreservesItsBytesAndPermissions"] = false }
            catch { checks["readOnlyLayoutPreservesItsBytesAndPermissions"] = try files.readData(layoutURL) == layoutBefore && (FileManager.default.attributesOfItem(atPath: layoutURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o400 }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: layoutURL.path)
            let oldVersion = savedWindow.hash; window.tasks[0].expanded = true; savedWindow = try journal.saveWindow(window, expected: oldVersion)
            var stale = window; stale.tasks[0].opened = false
            do { _ = try AgentWorkspaceRecovery(profile: profile).saveWindow(stale, expected: oldVersion); checks["staleLayoutWriterCannotOverwriteNewerWindow"] = false }
            catch { checks["staleLayoutWriterCannotOverwriteNewerWindow"] = try journal.loadWindow(windowID)?.value == window }
            do { _ = try journal.savePage(page, asset: nil, windowID: windowID, pageID: pageID, expected: nil); checks["newWriterCannotReplaceUnreadDraft"] = false }
            catch { checks["newWriterCannotReplaceUnreadDraft"] = try files.readData(pageURL) == activeBefore }
            do { _ = try journal.loadWindow("../outside"); checks["windowIdentifiersRejectPathTraversal"] = false }
            catch { checks["windowIdentifiersRejectPathTraversal"] = true }
            do { _ = try journal.loadPage(windowID: windowID, pageID: "../outside", taskID: owner); checks["pageIdentifiersRejectPathTraversal"] = false }
            catch { checks["pageIdentifiersRejectPathTraversal"] = true }
            var invalid = window; invalid.frame?.width = .infinity
            do { _ = try journal.saveWindow(invalid, expected: savedWindow.hash); checks["invalidGeometryDoesNotReplaceValidLayout"] = false }
            catch { checks["invalidGeometryDoesNotReplaceValidLayout"] = try journal.loadWindow(windowID)?.value == window }
            invalid = window; invalid.tasks[0].tabs.append(.init(root: tab.root, title: tab.title))
            do { _ = try journal.saveWindow(invalid, expected: savedWindow.hash); checks["duplicateTabRootsRejectWholeLayout"] = false }
            catch { checks["duplicateTabRootsRejectWholeLayout"] = try journal.loadWindow(windowID)?.value == window }
            let linkID = UUID().uuidString, link = try files.literalURL("workspace-recovery/" + windowID + "/pages/" + linkID + ".json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
            do { _ = try journal.loadPage(windowID: windowID, pageID: linkID, taskID: owner); checks["draftSymlinkDoesNotReadOrWriteOriginalUserFile"] = false }
            catch { checks["draftSymlinkDoesNotReadOrWriteOriginalUserFile"] = try files.readData(sentinel) == original }
            let alternate = output.appendingPathComponent("linked-recovery-profile")
            try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: alternate.appendingPathComponent("workspace-recovery"), withDestinationURL: source)
            do { _ = try AgentWorkspaceRecovery(profile: alternate).saveWindow(window, expected: nil); checks["recoveryDirectorySymlinkCannotRedirectWrites"] = false }
            catch { checks["recoveryDirectorySymlinkCannotRedirectWrites"] = !FileManager.default.fileExists(atPath: source.appendingPathComponent(windowID).path) }
            for (name, key, value) in [("futureVersion", "version", 2 as Any), ("unknownField", "unrecognized-draft-state", true as Any)] {
                let id = UUID().uuidString; var future = window; future.id = id
                let baseline = try journal.saveWindow(future, expected: nil), path = try files.resolve("workspace-recovery/" + id + "/layout.json")
                var object = try JSONSerialization.jsonObject(with: files.readData(path)) as! [String: Any]; object[key] = value
                let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); try files.writeData(bytes, to: path, permissions: 0o600)
                do { _ = try journal.saveWindow(baseline.value, expected: AgentFiles.hash(bytes)); checks[name + "PreservedInsteadOfDowngraded"] = false }
                catch { checks[name + "PreservedInsteadOfDowngraded"] = try files.readData(path) == bytes }
            }
            let listing = try journal.list()
            checks["invalidWindowsAreReportedWhileValidWindowRemainsAvailable"] = listing.windows.count == 1 && listing.windows.first?.value == window && listing.issues.count == 2
            try files.writeData(Data("DAMAGED_RESOURCE_PUBLIC".utf8), to: loaded.asset!, permissions: 0o600)
            do { _ = try journal.loadPage(windowID: windowID, pageID: pageID, taskID: owner); checks["damagedResourceFailsChecksumWithoutRewritingDraft"] = false }
            catch { checks["damagedResourceFailsChecksumWithoutRewritingDraft"] = try files.readData(pageURL) == activeBefore }
            checks["privateRecoveryMetadataAndResourcePermissions"] = try [layoutURL, pageURL, firstAssetURL, loaded.asset!].allSatisfy { (try FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 }
            checks["originalUserAndSourceFilesRemainExact"] = try files.readData(sentinel) == original && sourceFiles.readData(firstAsset) == firstBytes && sourceFiles.readData(secondAsset) == secondBytes
            checks["storageCheckDoesNotStartModelRuntime"] = agentRuntime == nil
            report["profile"] = profile.path; report["windowID"] = windowID; report["pageID"] = pageID; report["taskID"] = owner
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = 0; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        report["scope"] = "Private recovery storage, real filesystem permissions, binary resources, conflicts and corrupted formats; no UI restoration or model effects claimed."
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("workspace-recovery-report.json"))
    }
}

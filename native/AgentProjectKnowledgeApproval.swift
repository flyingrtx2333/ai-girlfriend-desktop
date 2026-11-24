import AppKit

@MainActor final class AgentProjectKnowledgeApproval: AgentSettingsReviewPage {
    private var response: CheckedContinuation<Void, Error>?
    private var approved = false
    var isWaiting: Bool { response != nil }

    private init(project: URL, operation: String, reason: String, targets: Targets) {
        var body = "工作区\n\(project.path)"
        if let directory = targets.directory { body += "\n\nGit 元数据\n\(directory.path)" }
        if let checkout = targets.checkout, checkout.path != targets.directory?.path { body += "\n\n工作树元数据\n\(checkout.path)" }
        if !reason.hasPrefix("连接 Git 仓库元数据：") { body += "\n\n" + reason }
        super.init(title: "连接项目知识", metadata: project.lastPathComponent, notice: "将更新本机项目索引。",
                   sections: [("访问范围", body)], applyTitle: "连接")
        window?.title = operation
        useSafeConfirmation(destructive: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private struct Targets: Equatable {
        let project: URL, directory: URL?, checkout: URL?
        let identities: [URL: String]

        init(workspace: String?, gitDirectory: String?) throws {
            project = try AgentFiles(workspace: workspace).root
            directory = gitDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            checkout = gitDirectory == nil ? nil : URL(fileURLWithPath: try AgentGit.metadata(workspace: project.path, checkout: true).path, isDirectory: true)
            var identities: [URL: String] = [:]
            for url in Set([project, directory, checkout].compactMap { $0 }) {
                identities[url] = try AgentFiles.directoryIdentity(url)
            }
            self.identities = identities
        }
    }

    static func request(from owner: AgentSettingsPageController, operation: String, tools: AgentTools,
                        call: AgentToolCall, directory: String?, reason: String) async throws {
        try Task.checkCancellation()
        guard owner.isPageVisible, owner.presentingWindow?.hasBlockingDialog != true, owner.knowledgeApproval?.isWaiting != true,
              let original = tools.store.task(tools.taskID) else { throw PetError("请从原项目知识页面重新发起操作") }
        let targets = try Targets(workspace: original.workspace, gitDirectory: directory)
        let page = AgentProjectKnowledgeApproval(project: targets.project, operation: operation, reason: reason, targets: targets)
        let store = tools.store
        func currentTask(grant: String?, checkingReason: Bool) throws -> AgentTaskRecord {
            let changed = PetError("任务权限或项目目录已变化，请取消后重新审阅")
            guard let current = store.task(tools.taskID), current.archived == original.archived,
                  current.workspaceScope == original.workspaceScope, current.mode == original.mode, current.permission == original.permission,
                  current.agent?.profile.id == original.agent?.profile.id, current.gitDirectory == grant else { throw changed }
            guard try tools.gitDirectory(for: call) == directory,
                  (try? Targets(workspace: current.workspace, gitDirectory: directory)) == targets else { throw changed }
            if checkingReason {
                guard try tools.approvalReason(for: call, gitDirectory: directory) == reason else { throw changed }
            }
            return current
        }
        page.onApply = { [weak page] in
            guard let page, page.isPageVisible, page.isWaiting else { throw PetError("原项目知识审阅已关闭") }
            var task: AgentTaskRecord
            @MainActor func validate() throws -> AgentTaskRecord {
                do { return try currentTask(grant: original.gitDirectory, checkingReason: true) }
                catch { page.showPreviewFailure(error); throw error }
            }
            task = try validate()
            if let directory, task.gitDirectory != directory {
                let expected = try store.recordVersion(task.id)
                task.gitDirectory = directory; task.updated = Date()
                let backup = try store.backupDirectory(task.id).appendingPathComponent("knowledge-connection-" + UUID().uuidString)
                try store.commitTaskRecord(task, expectedHash: expected, transaction: backup, label: "连接项目知识") { _ = try validate() }
            }
            page.approved = true
        }
        owner.knowledgeApproval = page
        defer { if owner.knowledgeApproval === page { owner.knowledgeApproval = nil } }
        try await page.present(from: owner)
        try Task.checkCancellation()
        _ = try currentTask(grant: directory ?? original.gitDirectory, checkingReason: false)
    }

    private func present(from owner: AgentSettingsPageController) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                response = continuation
                guard !Task.isCancelled else { finish(.failure(CancellationError())); return }
                owner.presentSettingsChild(self)
                if !isPageVisible { finish(.failure(PetError("无法打开项目知识审阅"))) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isWaiting else { return }
                self.finish(.failure(CancellationError()))
                if self.isPageVisible { self.close() }
                else { self.showPreviewFailure(PetError("连接已取消，请返回项目知识页面")) }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = response; response = nil; continuation?.resume(with: result)
    }
    override func settingsWillLeave() { finish(approved ? .success(()) : .failure(PetError("已取消"))) }
    func windowWillClose(_ notification: Notification) { settingsWillLeave() }
}

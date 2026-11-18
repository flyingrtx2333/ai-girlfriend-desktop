import Foundation

@MainActor enum AgentMemoryCleanup {
    struct Entry: Equatable {
        let path: String
        let signature: String
    }

    struct Preview: Equatable {
        let workspace: String?
        let root: String
        let entries: [Entry]
    }

    struct Outcome {
        var moved = 0
        var failures: [String] = []
    }

    static func preview(workspace: String?, store: AgentStore) throws -> Preview {
        try scan(workspace: workspace, store: store).1
    }

    private static func scan(workspace: String?, store: AgentStore) throws -> (AgentFiles, Preview) {
        let (files, topics) = try AgentMemory.importDestination(store: store, workspace: workspace)
        let scope: AgentMemoryScope = workspace == nil ? .global : .project

        func inspect(_ path: String) throws -> Entry? {
            let file = try files.literalURL(path)
            let metadata = try files.entryMetadata(file)
            if metadata.kind == "missing" { return nil }
            guard metadata.kind == "file" else { throw PetError("记忆路径需要普通文件 · " + path) }
            guard (metadata.permissions ?? 0) & 0o222 != 0 else { throw PetError("记忆文件为只读 · " + path) }
            return Entry(path: path, signature: metadata.signature)
        }

        var entries: [Entry] = []
        if let main = try inspect(scope.primaryPath) { entries.append(main) }
        if try files.entryMetadata(topics).kind == "directory" {
            let names = try files.regularFiles(in: topics).map(\.name).filter(AgentMemoryDocument.validTopic)
            entries += try names.sorted().compactMap { try inspect(scope.topicDirectory + "/" + $0) }
        }
        return (files, Preview(workspace: workspace, root: files.root.path, entries: entries))
    }

    static func apply(_ previews: [Preview], store: AgentStore, moveToTrash: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) throws -> Outcome {
        let scopes = previews.map(\.workspace)
        guard !previews.isEmpty, scopes.count == Set(scopes).count, previews.allSatisfy({ !$0.entries.isEmpty }) else {
            throw PetError("请选择要清空的记忆范围")
        }
        // Revalidate every selected scope before moving any file.
        let targets = try previews.map { expected in
            let (files, current) = try scan(workspace: expected.workspace, store: store)
            guard current == expected else { throw PetError("记忆文件列表已变化，请重新检查 · " + expected.root) }
            return (files, current)
        }
        var result = Outcome()
        for (files, preview) in targets {
            for entry in preview.entries {
                do {
                    let source = try files.literalURL(entry.path)
                    guard try files.entryMetadata(source).signature == entry.signature else {
                        throw PetError("文件已变化，请重新检查")
                    }
                    try moveToTrash(source)
                    result.moved += 1
                } catch {
                    result.failures.append(files.root.appendingPathComponent(entry.path).path + "\n" + error.localizedDescription)
                }
            }
        }
        return result
    }
}

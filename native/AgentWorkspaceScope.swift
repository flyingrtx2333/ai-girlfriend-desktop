import Foundation

struct AgentWorkspaceScope: Codable, Equatable, Sendable {
    var group: String
    var folders: [String]
    var primary: String

    static func validateFolders(_ paths:[String], primary:String) throws -> [String] {
        guard (1...16).contains(paths.count), paths.contains(primary) else { throw PetError("请选择1至16个源文件夹，并指定其中一个为主文件夹") }
        let canonical = try paths.map { path -> String in
            guard path.hasPrefix("/"), path != "/", path.utf8.count < 8192, !path.contains("\0") else { throw PetError("请选择具体的项目文件夹") }
            return try AgentFiles(workspace:path).root.path
        }
        guard Set(canonical).count == canonical.count else { throw PetError("源文件夹重复，请保留一项") }
        for a in canonical { for b in canonical where a != b { guard !a.hasPrefix(b + "/") else { throw PetError("源文件夹不能互相包含，请选择独立目录") } } }
        return canonical
    }
    static func roots(_ task:AgentTaskRecord) throws -> [AgentFiles] {
        guard let scope = task.workspaceScope else { return try task.workspace.map { [try AgentFiles(workspace:$0)] } ?? [] }
        guard task.workspace == scope.primary, scope.group.hasPrefix("/"), scope.group.utf8.count < 8192, !scope.group.contains("\0"),
              try validateFolders(scope.folders,primary:scope.primary) == scope.folders else { throw PetError("任务的源文件夹范围已变化，请重新选择工作区") }
        return try scope.folders.map { try AgentFiles(workspace:$0) }
    }
    static func files(_ task:AgentTaskRecord, path:String = ".", literal:Bool = false) throws -> AgentFiles {
        try location(task,path:path,literal:literal).0
    }
    static func location(_ task:AgentTaskRecord, path:String = ".", literal:Bool = false) throws -> (AgentFiles,URL) {
        if task.workspaceScope == nil {
            let files = try AgentFiles(workspace:task.workspace)
            return (files,try literal ? files.literalURL(path) : files.resolve(path))
        }
        guard let primary = task.workspace else { throw PetError("请先选择项目文件夹") }
        guard !path.contains("\0"), path.utf8.count < 8192 else { throw PetError("文件路径无效") }
        let raw = (path.hasPrefix("/") ? URL(fileURLWithPath:path) : URL(fileURLWithPath:primary).appendingPathComponent(path.isEmpty ? "." : path)).standardizedFileURL
        let target = literal ? raw.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(raw.lastPathComponent) : raw.resolvingSymlinksInPath()
        guard let files = try roots(task).first(where: { target == $0.root || target.path.hasPrefix($0.root.path + "/") }) else { throw PetError("路径超出此任务的源文件夹范围") }
        return (files,try literal ? files.literalURL(raw.path) : files.resolve(target.path))
    }
    static func copy(_ source:AgentTaskRecord, to task:inout AgentTaskRecord) {
        task.workspace = source.workspace; task.workspaceScope = source.workspaceScope
    }
    static func contexts(_ task:AgentTaskRecord) throws -> [AgentTaskRecord] {
        guard task.workspaceScope != nil else { return [task] }
        let paths = try roots(task).map(\.root.path), ordered = task.workspace.map { main in [main] + paths.filter{$0 != main} } ?? paths
        return ordered.map { path in
            var value = task; value.workspace = path; value.workspaceScope = nil
            value.instructionGrants = task.instructionGrants?.filter{task.workspacePaths.contains($0.workspace)}.map{.init(workspace:path,path:$0.path)}
            return value
        }
    }
}

extension AgentTaskRecord {
    var organizationWorkspace: String? { workspaceScope?.group ?? workspace }
    var workspacePaths:[String] { workspaceScope?.folders ?? workspace.map{[$0]} ?? [] }
    func includesWorkspaceRoot(_ path:String) -> Bool {
        workspacePaths.contains { $0 == path || (try? AgentFiles(workspace:$0).root.path) == path }
    }
}

enum AgentWorkspaceIcon: String, Codable, CaseIterable {
    case folder, cup = "cup.and.saucer", glass = "wineglass", cake = "birthday.cake", moon, sailboat, game = "gamecontroller", chip = "cpu", bug = "ladybug", flame, cat, paw = "pawprint", person, bell, flask, globe
    var title:String { switch self { case .folder:return "文件夹"; case .cup:return "咖啡"; case .glass:return "酒杯"; case .cake:return "蛋糕"; case .moon:return "月亮"; case .sailboat:return "帆船"; case .game:return "游戏"; case .chip:return "芯片"; case .bug:return "瓢虫"; case .flame:return "火焰"; case .cat:return "小猫"; case .paw:return "爪印"; case .person:return "人物"; case .bell:return "铃铛"; case .flask:return "烧瓶"; case .globe:return "地球" } }
}
enum AgentWorkspaceColor: String, Codable, CaseIterable {
    case forest, green, blue, amber, red, pink, purple, yellow, orange, teal, sky, gray, ink, lavender, sage, slate
    var hex:UInt32 { switch self { case .forest:return 0x537565; case .green:return 0x5b9c7b; case .blue:return 0x3b82f6; case .amber:return 0xf1b337; case .red:return 0xef5b5b; case .pink:return 0xd653a2; case .purple:return 0x7157e8; case .yellow:return 0xf4cd4f; case .orange:return 0xf08736; case .teal:return 0x60b8a8; case .sky:return 0x4b94f2; case .gray:return 0x90949c; case .ink:return 0x262835; case .lavender:return 0xb6a0f0; case .sage:return 0x84af9a; case .slate:return 0x6a8092 } }
    var title:String { switch self { case .forest:return "森林"; case .green:return "绿色"; case .blue:return "蓝色"; case .amber:return "琥珀"; case .red:return "红色"; case .pink:return "粉色"; case .purple:return "紫色"; case .yellow:return "黄色"; case .orange:return "橙色"; case .teal:return "青绿"; case .sky:return "天蓝"; case .gray:return "灰色"; case .ink:return "墨色"; case .lavender:return "淡紫"; case .sage:return "灰绿"; case .slate:return "灰蓝" } }
}

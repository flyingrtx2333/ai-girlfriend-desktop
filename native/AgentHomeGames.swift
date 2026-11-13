import AppKit

enum AgentHomeGameChoice: String, Codable, CaseIterable {
    case random, snake, blocks
    var title: String { switch self { case .random: return "随机"; case .snake: return "贪吃蛇"; case .blocks: return "俄罗斯方块" } }
    func resolve() -> AgentHomeGameKind { switch self { case .random: return Bool.random() ? .snake : .blocks; case .snake: return .snake; case .blocks: return .blocks } }
}
enum AgentHomeGameKind: String, CaseIterable {
    case snake, blocks
    var title: String { self == .snake ? "像素贪吃蛇" : "横向俄罗斯方块" }
    var instruction: String { self == .snake ? "方向键或 W / A / S / D 控制方向" : "↑ ↓ 移动 · → 加速 · ← 旋转 · 空格暂停／继续" }
}
struct AgentGamePoint: Hashable {
    var x: Int, y: Int
    static func + (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
}
enum AgentGameEvent: Equatable { case moved, food, cleared(Int), lost, won }

struct AgentPixelSnake {
    enum Direction {
        case up, down, left, right
        var delta: AgentGamePoint { switch self { case .up: return .init(x: 0, y: -1); case .down: return .init(x: 0, y: 1); case .left: return .init(x: -1, y: 0); case .right: return .init(x: 1, y: 0) } }
    }
    let columns: Int, rows: Int
    private(set) var body: [AgentGamePoint], direction = Direction.right, food: AgentGamePoint?
    var rewards: [AgentGamePoint: Int] { bonuses }
    private(set) var score = 0, ended = false
    private var pending: Direction?, bonuses: [AgentGamePoint: Int]
    var randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    init(columns: Int = 53, rows: Int = 7, food: AgentGamePoint? = nil, bonuses: [AgentGamePoint: Int] = [:]) {
        self.columns = columns; self.rows = rows; self.bonuses = bonuses
        let head = AgentGamePoint(x: max(2, columns / 2), y: rows / 2)
        body = [head, head + .init(x: -1, y: 0), head + .init(x: -2, y: 0)]
        self.food = food; if food == nil || body.contains(food!) { placeFood() }
    }
    mutating func turn(_ next: Direction) {
        let a = direction.delta, b = next.delta
        guard pending == nil, a.x + b.x != 0 || a.y + b.y != 0 else { return }; pending = next
    }
    private mutating func placeFood() {
        let occupied = Set(body), available = (0..<columns).flatMap { x in (0..<rows).map { AgentGamePoint(x: x, y: $0) } }.filter { !occupied.contains($0) }
        food = available.isEmpty ? nil : available[min(available.count - 1, max(0, randomIndex(available.count)))]
    }
    mutating func step() -> AgentGameEvent {
        guard !ended else { return .lost }
        if let pending { direction = pending }; pending = nil
        let head = body[0] + direction.delta, eating = head == food || bonuses[head] != nil
        let occupied = eating ? body : Array(body.dropLast())
        guard head.x >= 0, head.x < columns, head.y >= 0, head.y < rows, !occupied.contains(head) else { ended = true; return .lost }
        body.insert(head, at: 0)
        if eating {
            score = min(AgentHomeGames.maximumScore, score + (head == food ? 1 : 0) + min(1_000_000, max(0, bonuses.removeValue(forKey: head) ?? 0)))
            if head == food { placeFood() }
            if body.count == columns * rows { ended = true; food = nil; return .won }; return .food
        }
        body.removeLast(); return .moved
    }
}

struct AgentSidewaysBlocks {
    enum Piece: Int, CaseIterable {
        case i = 1, o, t, l, j, s, z
        var points: [AgentGamePoint] {
            let pairs: [(Int, Int)]
            switch self {
            case .i: pairs = [(0,0),(0,1),(0,2),(0,3)]
            case .o: pairs = [(0,0),(1,0),(0,1),(1,1)]
            case .t: pairs = [(0,0),(0,1),(1,1),(0,2)]
            case .l: pairs = [(0,0),(0,1),(0,2),(1,2)]
            case .j: pairs = [(1,0),(1,1),(1,2),(0,2)]
            case .s: pairs = [(1,0),(1,1),(0,1),(0,2)]
            case .z: pairs = [(0,0),(0,1),(1,1),(1,2)]
            }
            return pairs.map { .init(x: $0.0, y: $0.1) }
        }
    }
    let columns: Int, rows: Int
    private(set) var settled: [AgentGamePoint: Int] = [:], shape: [AgentGamePoint] = []
    private(set) var piece = Piece.i, origin = AgentGamePoint(x: 0, y: 2), score = 0, clearedColumns = 0, ended = false
    private(set) var ducks: [AgentGamePoint: Int]
    private var bag: [Piece] = []
    init(columns: Int = 53, rows: Int = 7, ducks: [AgentGamePoint: Int] = [:]) {
        self.columns = columns; self.rows = rows; self.ducks = ducks; spawn()
    }
    var cells: [AgentGamePoint] { shape.map { $0 + origin } }
    private func fits(_ points: [AgentGamePoint], at location: AgentGamePoint) -> Bool {
        points.allSatisfy { let p = $0 + location; return p.x >= 0 && p.x < columns && p.y >= 0 && p.y < rows && settled[p] == nil }
    }
    private mutating func spawn() {
        if bag.isEmpty { bag = Piece.allCases.shuffled() }
        piece = bag.removeFirst(); shape = piece.points
        origin = .init(x: 0, y: max(0, (rows - ((shape.map(\.y).max() ?? 0) + 1)) / 2))
        if !fits(shape, at: origin) { ended = true }
    }
    @discardableResult mutating func move(dy: Int) -> Bool {
        guard !ended else { return false }; let next = origin + .init(x: 0, y: dy)
        guard fits(shape, at: next) else { return false }; origin = next; return true
    }
    @discardableResult mutating func rotate() -> Bool {
        guard !ended else { return false }
        let width = shape.map(\.x).max() ?? 0
        let rotated = shape.map { AgentGamePoint(x: $0.y, y: width - $0.x) }
        for kick in [AgentGamePoint(x: 0,y: 0), .init(x: 0,y: -1), .init(x: 0,y: 1), .init(x: 0,y: -2), .init(x: 0,y: 2), .init(x: -1,y: 0)] {
            let next = origin + kick
            if fits(rotated, at: next) { shape = rotated; origin = next; return true }
        }; return false
    }
    mutating func step() -> AgentGameEvent {
        guard !ended else { return .lost }
        let next = origin + .init(x: 1, y: 0)
        if fits(shape, at: next) { origin = next; return .moved }
        for p in cells { settled[p] = piece.rawValue }
        let full = (0..<columns).filter { x in (0..<rows).allSatisfy { settled[.init(x: x,y: $0)] != nil } }
        if !full.isEmpty {
            let cleared = Set(full)
            let bonus = ducks.filter { cleared.contains($0.key.x) }.values.reduce(0) { min(1_000_000, $0 + max(0, $1)) }
            ducks = ducks.filter { !cleared.contains($0.key.x) }
            settled = Dictionary(uniqueKeysWithValues: settled.filter { !cleared.contains($0.key.x) }.map { point, color in
                (AgentGamePoint(x: point.x + full.filter { $0 > point.x }.count, y: point.y), color)
            })
            clearedColumns += full.count; score = min(AgentHomeGames.maximumScore, score + full.count * 100 + bonus)
        }
        spawn(); if ended { return .lost }; return full.isEmpty ? .moved : .cleared(full.count)
    }
    mutating func checkBoard(_ values: [AgentGamePoint: Int], next: Piece) {
        guard CommandLine.arguments.contains("--home-games-check") else { return }
        settled = values; bag = [next]; spawn()
    }
}

@MainActor final class AgentHomeGames {
    nonisolated static let maximumScore = 99_999_999
    static let changed = Notification.Name("BlueFatFishHomeGamesChanged")
    static let searchTerms = "首页小游戏 随机 贪吃蛇 俄罗斯方块 Home Game Snake Blocks"
    struct Settings: Codable, Equatable { var version = 1; var sound = true; var snakeBest = 0; var blocksBest = 0 }
    private(set) var settings = Settings(), error: String?
    private let directory: URL
    private var revision: String?
    private var activityTask: Task<Void, Never>?, activityVersions: [String: Date]?
    private(set) var activity: [Date: Int] = [:], activityLoading = false, activityIssue: String?
    private var activityDay: Date?
    init(directory: URL) { self.directory = directory; reload() }
    func reload() {
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("home-games.json"), entry = try files.entryMetadata(file)
            guard try files.resolve("home-games.json") == file, ["missing", "file"].contains(entry.kind) else { throw PetError("小游戏配置必须是普通文件") }
            if entry.kind == "missing" { settings = .init(); revision = nil }
            else {
                let bytes = try files.readData(file, maximum: 4096)
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(object.keys) == ["version","sound","snakeBest","blocksBest"] else { throw PetError("小游戏配置字段无效") }
                let value = try JSONDecoder().decode(Settings.self, from: bytes)
                guard value.version == 1, [value.snakeBest,value.blocksBest].allSatisfy({ (0...Self.maximumScore).contains($0) }) else { throw PetError("小游戏配置选项无效") }
                settings = value; revision = AgentFiles.hash(bytes)
            }; error = nil
        } catch { self.error = "小游戏配置未载入：" + error.localizedDescription }; notify()
    }
    private func save(_ value: Settings) throws {
        guard error == nil else { throw PetError(error! + "；请重新载入") }; guard value != settings else { return }
        let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("home-games.json"), entry = try files.entryMetadata(file)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("小游戏配置只读，未保存") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; let data = try encoder.encode(value)
        let write = try AgentKnowledgeFileWrite(files: files, path: "home-games.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "小游戏配置")
        try write.requireCurrent(); try files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        settings = value; revision = AgentFiles.hash(data); notify()
    }
    func best(_ kind: AgentHomeGameKind) -> Int { kind == .snake ? settings.snakeBest : settings.blocksBest }
    func record(_ score: Int, kind: AgentHomeGameKind) throws {
        guard (0...Self.maximumScore).contains(score) else { throw PetError("游戏得分无效") }
        var next = settings
        if kind == .snake { next.snakeBest = max(next.snakeBest,score) } else { next.blocksBest = max(next.blocksBest,score) }
        try save(next)
    }
    func setSound(_ value: Bool) throws { var next = settings; next.sound = value; try save(next) }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
    func refreshActivity(_ store: AgentStore) {
        let day = Calendar.current.startOfDay(for: Date())
        let records = store.tasks.filter { $0.kind != "hook" && !$0.isProjectDocumentation && $0.agent?.ownerID == nil && $0.automation == nil }
        // Saving an unsent draft does not change activityAt or require rereading the entire history.
        let versions = Dictionary(uniqueKeysWithValues: records.map { ($0.id,$0.activityAt ?? $0.updated) })
        guard activityTask == nil, activityVersions != versions || activityDay != day else { return }
        let ids = records.map(\.id)
        activityLoading = true
        activityTask = Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            defer { activityTask = nil; activityLoading = false; refreshActivity(store) }
            var counts: [Date:Int] = [:], unreadable = false
            for id in ids {
                if Task.isCancelled { return }
                if let dates = store.recordedActivityDates(id) {
                    for date in Set(dates.map { Calendar.current.startOfDay(for: $0) }) where date <= day { counts[date,default:0] += 1 }
                } else { unreadable = true }
                await Task.yield()
            }
            activity = counts; activityVersions = versions; activityDay = day; activityLoading = false
            activityIssue = unreadable ? "部分活动记录不可读" : nil; notify()
        }
    }
}

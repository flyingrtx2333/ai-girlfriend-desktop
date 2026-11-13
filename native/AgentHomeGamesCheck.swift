import AppKit
import Darwin

@MainActor extension AppDelegate {
    @discardableResult func prepareHomeGamesUI(_ output: URL, seed: Bool) throws -> [String:String] {
        ensureAgent(); guard let tasks = agentStore else { throw PetError("缺少首页小游戏验收环境") }
        let file = output.appendingPathComponent("home-games-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:file))
            guard let id = ids["coding"], tasks.task(id) != nil else { throw PetError("首页小游戏原样例不可用") }; control.showAgentTask(id); control.show(tab:"chat"); return ids
        }
        guard !FileManager.default.fileExists(atPath:file.path) else { throw PetError("公开样例已存在，请重开原目录") }
        let project = output.appendingPathComponent("public-project"); try FileManager.default.createDirectory(at:project,withIntermediateDirectories:false)
        try Data("# Public home games fixture\n\nNo model responses or billable usage.\n".utf8).write(to:project.appendingPathComponent("README.md"))
        let coding = tasks.create(title:"首页小游戏公开样例",workspace:project.path,mode:.agent)
        let general = tasks.create(title:"无工作区小游戏样例",mode:.ask,workMode:.general)
        let history = tasks.create(title:"活动热图公开样例",workspace:project.path,mode:.ask)
        tasks.update(history) {
            $0.messages = [AgentMessage(role:"user",content:"公开原生活动样例"),AgentMessage(role:"assistant",content:"原生界面样例，不是模型输出。")]; $0.status = .completed
            $0.events = (0..<8).map { offset in var event = AgentEvent(kind:"read",title:"公开活动样例"); event.created = Calendar.current.date(byAdding:.day,value:-offset * 3,to:Date())!; return event }
        }
        let ids = ["coding":coding,"general":general,"history":history]; try JSONEncoder().encode(ids).write(to:file)
        control.showAgentTask(coding); control.show(tab:"chat"); return ids
    }
    func runHomeGamesCheck(_ output: URL) async {
        var checks: [String:Bool] = [:], report: [String:Any] = [:], attempts = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少首页小游戏验收环境") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("首页小游戏禁止模型请求") }; defer { runtime.stopAll() }
            checks["independentHomeAndNotificationsBlocked"] = tasks.hooks.sharedHome == output.appendingPathComponent("shared-home") && !automationNotifications.allowsSystemDelivery
            checks["defaultRandomAndSoundOnWithoutCreatingFiles"] = generalSettings.settings.homeGame == .random && homeGames.settings.sound && !FileManager.default.fileExists(atPath:store.directory.appendingPathComponent("home-games.json").path)
            let ids = try prepareHomeGamesUI(output,seed:true), coding = ids["coding"]!, general = ids["general"]!, history = ids["history"]!
            let original = try [coding,general,history].map { try Data(contentsOf:tasks.directory.appendingPathComponent($0 + ".json")) }
            let p = AgentGamePoint(x:3,y:2)
            var snake = AgentPixelSnake(columns:5,rows:5,food:p)
            checks["snakeGrowsAndScoresFood"] = snake.step() == .food && snake.score == 1 && snake.body.count == 4 && snake.body.first == p
            snake.turn(.left); _ = snake.step(); checks["snakeRejectsReversal"] = snake.direction == .right
            checks["snakeWallCollisionEndsWithoutMovingOutsideBoard"] = snake.step() == .lost && snake.ended && snake.body.first == .init(x:4,y:2)
            let score = snake.score; checks["endedSnakeCannotScoreAgain"] = snake.step() == .lost && snake.score == score
            var queued = AgentPixelSnake(columns:8,rows:7,food:.init(x:7,y:6)); queued.turn(.up); queued.turn(.left); _ = queued.step()
            checks["snakeAcceptsOnlyOneTurnPerTick"] = queued.direction == .up && queued.body.first == .init(x:4,y:2)
            var bonus = AgentPixelSnake(columns:7,rows:5,food:.init(x:6,y:4),bonuses:[.init(x:4,y:2):3]); _ = bonus.step()
            checks["recordedActivityBonusConsumedOnlyOnce"] = bonus.score == 3 && bonus.rewards.isEmpty && bonus.body.count == 4
            var blocks = AgentSidewaysBlocks(columns:8,rows:7)
            let start = blocks.origin; _ = blocks.step(); checks["blocksGravityMovesRight"] = blocks.origin == start + .init(x:1,y:0)
            for _ in 0..<20 { _ = blocks.move(dy:-1) }; checks["blocksCannotLeaveTopEdge"] = blocks.cells.allSatisfy { $0.y >= 0 }
            let before = Set(blocks.cells); _ = blocks.rotate(); checks["blocksRotationKeepsFourDistinctCellsInsideBoard"] = Set(blocks.cells).count == 4 && blocks.cells.allSatisfy { (0..<8).contains($0.x) && (0..<7).contains($0.y) } && before.count == 4
            // A vertical I fills the missing center four cells in the rightmost column.
            var full: [AgentGamePoint:Int] = [:]; for y in [0,5,6] { full[.init(x:3,y:y)] = 2 }
            full[.init(x:2,y:6)] = 3
            var clear = AgentSidewaysBlocks(columns:4,rows:7,ducks:[.init(x:3,y:6):9]); clear.checkBoard(full,next:.i)
            for _ in 0..<5 { _ = clear.step(); if clear.clearedColumns > 0 { break } }
            checks["fullColumnsClearAndLeftCellsShiftRight"] = clear.clearedColumns == 1 && clear.score == 109 && clear.settled[.init(x:3,y:6)] == 3 && clear.ducks.isEmpty
            var blocked = AgentSidewaysBlocks(columns:4,rows:7); blocked.checkBoard(Dictionary(uniqueKeysWithValues:(0..<7).map { (AgentGamePoint(x:0,y:$0),1) }),next:.i)
            checks["blockedSpawnEndsGame"] = blocked.ended && blocked.step() == .lost
            let gamesFile = store.directory.appendingPathComponent("home-games.json")
            try homeGames.record(12,kind:.snake); try homeGames.record(4,kind:.snake); try homeGames.record(200,kind:.blocks); try homeGames.setSound(false)
            let reloaded = AgentHomeGames(directory:store.directory)
            checks["scoresAreSeparateMonotonicAndMutePersists"] = reloaded.best(.snake) == 12 && reloaded.best(.blocks) == 200 && !reloaded.settings.sound && reloaded.error == nil
            checks["gameSettingsArePrivate"] = (try FileManager.default.attributesOfItem(atPath:gamesFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            let bytes = try Data(contentsOf:gamesFile); try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:gamesFile.path)
            var refused = false; do { try homeGames.record(13,kind:.snake) } catch { refused = true }
            checks["readOnlyScoresPreserveBytesAndLastValidState"] = try refused && homeGames.best(.snake) == 12 && Data(contentsOf:gamesFile) == bytes
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:gamesFile.path)
            var changed = bytes; changed.append(Data("\n".utf8)); try changed.write(to:gamesFile); refused = false
            do { try homeGames.setSound(true) } catch { refused = true }
            checks["externalChangeCannotBeOverwritten"] = try refused && Data(contentsOf:gamesFile) == changed && !homeGames.settings.sound
            try bytes.write(to:gamesFile); homeGames.reload()
            let malformed = output.appendingPathComponent("malformed-games"); try FileManager.default.createDirectory(at:malformed,withIntermediateDirectories:false)
            let malformedFile = malformed.appendingPathComponent("home-games.json")
            for (label,text) in ["negative":"{\"version\":1,\"sound\":true,\"snakeBest\":-1,\"blocksBest\":0}","extra":"{\"version\":1,\"sound\":true,\"snakeBest\":0,\"blocksBest\":0,\"extra\":1}","version":"{\"version\":2,\"sound\":true,\"snakeBest\":0,\"blocksBest\":0}","type":"{\"version\":1,\"sound\":\"yes\",\"snakeBest\":0,\"blocksBest\":0}"] {
                try Data(text.utf8).write(to:malformedFile); let bad = AgentHomeGames(directory:malformed); refused = false; do { try bad.setSound(false) } catch { refused = true }; checks["invalidGameSettings-" + label] = try bad.error != nil && refused && Data(contentsOf:malformedFile) == Data(text.utf8)
            }
            let legacy = output.appendingPathComponent("legacy-general"); try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:false)
            let old = Data("{\"version\":1,\"completionNotifications\":\"unfocused\",\"approvalNotifications\":true,\"questionNotifications\":true,\"menuBarIcon\":true}".utf8); let legacyFile = legacy.appendingPathComponent("general.json"); try old.write(to:legacyFile)
            checks["legacyGeneralDefaultsRandomWithoutRewrite"] = try AgentGeneralSettings(directory:legacy).settings.homeGame == .random && AgentGeneralSettings(directory:legacy).error == nil && Data(contentsOf:legacyFile) == old
            var preferences = generalSettings.settings; preferences.homeGame = .blocks; try generalSettings.save(preferences)
            checks["choicePersistsAndReachesBothWorkModes"] = AgentGeneralSettings(directory:store.directory).settings.homeGame == .blocks && runtime.taskSettings().homeGame == .blocks
            control.showAgentTask(coding); control.show(tab:"chat"); control.window?.makeKeyAndOrderFront(nil); await wait(0.1)
            homeGames.refreshActivity(tasks); for _ in 0..<50 where homeGames.activityLoading { await wait(0.01) }
            report["activityReadback"] = ["loading":homeGames.activityLoading,"issue":homeGames.activityIssue ?? "","counts":homeGames.activity.sorted { $0.key < $1.key }.map { ["day":ISO8601DateFormatter().string(from:$0.key),"tasks":$0.value] }]
            checks["heatmapUsesRecordedDatesAndExcludesEmptyDrafts"] = homeGames.activity.count == 8 && homeGames.activity.values.allSatisfy { $0 == 1 } && homeGames.activityIssue == nil
            let cold = AgentStore(directory:output.appendingPathComponent("cold-activity"),legacy:[],extensionHome:output.appendingPathComponent("shared-home"))
            var interrupted = tasks.task(history)!; interrupted.id = UUID().uuidString; interrupted.status = .running
            interrupted.pendingCalls = [AgentToolCall(id:UUID().uuidString,name:"read_file",arguments:"{\"path\":\"README.md\"}")]
            let coldFile = cold.directory.appendingPathComponent(interrupted.id + ".json"), coldBytes = try JSONEncoder().encode(interrupted)
            try coldBytes.write(to:coldFile); try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:coldFile.path)
            let coldIndex = cold.directory.appendingPathComponent("index.json"), indexBefore = try Data(contentsOf:coldIndex), searchBefore = cold.taskSearchRevision
            let coldDates = cold.recordedActivityDates(interrupted.id) ?? []
            checks["coldRunningTaskStatisticsNeverRecoverWriteOrChangeIndex"] = try Set(coldDates.map { Calendar.current.startOfDay(for:$0) }).count == 8 && Data(contentsOf:coldFile) == coldBytes && Data(contentsOf:coldIndex) == indexBefore && cold.taskSearchRevision == searchBefore && cold.writeError == nil
            try FileManager.default.moveItem(at:coldFile,to:coldFile.appendingPathExtension("original")); try FileManager.default.createSymbolicLink(at:coldFile,withDestinationURL:tasks.directory.appendingPathComponent(history + ".json"))
            checks["statisticsRejectLinkedRecordsWithoutChangingSource"] = try cold.recordedActivityDates(interrupted.id) == nil && Data(contentsOf:tasks.directory.appendingPathComponent(history + ".json")) == original[2]
            checks["emptyCodingShowsHeatmapWithNoGameTimer"] = control.homeGamesReadback()["visible"] as? Bool == true && control.homeGamesReadback()["timer"] as? Bool == false && control.homeGamesReadback()["cells"] as? Int == 371
            control.showAgentTask(general); control.show(tab:"chat"); checks["askWithoutWorkspaceShowsSameHomeGames"] = tasks.task(general)?.workspace == nil && control.homeGamesReadback()["visible"] as? Bool == true
            control.showAgentTask(history); control.show(tab:"chat"); checks["conversationHidesGamesAndStopsTimer"] = control.homeGamesReadback()["visible"] as? Bool == false && control.homeGamesReadback()["timer"] as? Bool == false
            _ = control.showSettingsCategory("general")
            func descendants(_ v:NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
            guard let root = control.window?.contentView, let popup = descendants(root).first(where:{$0.identifier?.rawValue == "general-home-game"}) as? NSPopUpButton else { throw PetError("常规设置缺少首页小游戏") }
            popup.selectItem(at:1); _ = popup.sendAction(popup.action,to:popup.target)
            checks["nativeChoiceSavesWithoutModal"] = generalSettings.settings.homeGame == .snake && control.window?.attachedSheet == nil
            checks["gamePreferenceDoesNotModifyTasks"] = try [coding,general,history].enumerated().allSatisfy { try Data(contentsOf:tasks.directory.appendingPathComponent($0.element + ".json")) == original[$0.offset] }
            control.showAgentTask(coding); control.show(tab:"chat")
            for (label,size) in [("normal",NSSize(width:1200,height:774)),("narrow",NSSize(width:780,height:540))] {
                control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); await wait(0.03)
                let state = control.homeGamesReadback(), board = state["board"] as? [CGFloat] ?? []
                checks[label + "HeatmapFitsWindow"] = board.count == 2 && board[0] >= 400 && board[1] == 100 && state["visible"] as? Bool == true && control.window?.contentView?.bounds.size == size
            }
            checks["noProviderRequestsOrForgedUsage"] = attempts == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil; report["appPID"] = getpid(); report["modelRequests"] = 0; report["blockedModelAttempts"] = attempts
        do { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("home-games-report.json"),options:.atomic) } catch { diagnostics.append(error.localizedDescription) }
    }
}

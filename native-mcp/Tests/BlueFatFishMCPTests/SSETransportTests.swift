import XCTest
@testable import BlueFatFishMCP

@MainActor final class SSETransportTests: XCTestCase {
    func testActualLegacyServer() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = ProcessInfo.processInfo.environment["BLUEFATFISH_MCP_TEST_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("evidence/agent/mcp-sse-protocol-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BLUEFATFISH_NODE"] ?? "/opt/homebrew/bin/node")
        process.arguments = [Bundle.module.url(forResource: "legacy-sse", withExtension: "mjs")!.path, directory.path]
        let log = directory.appendingPathComponent("server.log"); fm.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log); process.standardOutput = output; process.standardError = output
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? output.close() }
        let ready = directory.appendingPathComponent("ready.json")
        for _ in 0..<100 { if fm.fileExists(atPath: ready.path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as! [String: Any], base = data["base"] as! String
        func records() throws -> [[String: Any]] { try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] } }
        func connect(_ mode: String, timeout: Double = 2) async throws -> MCPConnection {
            let connection = MCPConnection()
            do { _ = try await connection.connectSSE(endpoint: URL(string: base + "/events/" + mode)!, bearerToken: "public-test-token", headers: ["X-Public-Value": "public-header"], timeout: timeout); return connection }
            catch { await connection.disconnect(); throw error }
        }
        for mode in ["normal", "absolute", "split"] {
            let connection = try await connect(mode)
            let tools = try await connection.tools(timeout: 2)
            XCTAssertTrue(String(decoding: tools, as: UTF8.self).contains("public_echo"), mode)
            let result = try await connection.call(name: "public_echo", arguments: Data(#"{"value":"公开原文 🧭"}"#.utf8), timeout: 2)
            let text = String(decoding: result, as: UTF8.self)
            XCTAssertTrue(text.contains("公开原文 🧭"), mode)
            await connection.disconnect()
        }
        let idle = try await connect("normal", timeout: 0.25)
        try await Task.sleep(for: .milliseconds(400))
        let afterIdle = try await idle.tools(timeout: 1)
        XCTAssertTrue(String(decoding: afterIdle, as: UTF8.self).contains("public_echo"))
        await idle.disconnect()
        let closedWhileIdle = try await connect("idle-disconnect")
        _ = try await closedWhileIdle.tools(timeout: 2)
        try await Task.sleep(for: .milliseconds(300))
        let readyAfterDisconnect = await closedWhileIdle.isReady()
        XCTAssertFalse(readyAfterDisconnect)
        await closedWhileIdle.disconnect()
        for mode in ["status", "content-type", "foreign-endpoint", "scheme-endpoint", "credentials-endpoint", "fragment-endpoint", "redirect-get", "redirect-post", "before-endpoint", "version", "no-endpoint"] {
            let start = ContinuousClock.now
            do { let connection = try await connect(mode, timeout: 0.5); await connection.disconnect(); XCTFail("Unexpected handshake: " + mode) }
            catch { XCTAssertLessThan(start.duration(to: .now), .seconds(2), mode) }
        }
        for mode in ["disconnect", "malformed", "post-failure", "timeout", "oversized"] {
            let connection = try await connect(mode)
            _ = try await connection.tools(timeout: 2)
            let start = ContinuousClock.now
            do { _ = try await connection.call(name: "public_echo", arguments: Data(#"{"value":"no-replay"}"#.utf8), timeout: mode == "oversized" ? 10 : 0.5); XCTFail("Unexpected result: " + mode) }
            catch { XCTAssertLessThan(start.duration(to: .now), .seconds(mode == "oversized" ? 12 : 2), mode) }
            await connection.disconnect()
        }
        let cancelled = MCPConnection(), start = ContinuousClock.now
        let task = Task { try await cancelled.connectSSE(endpoint: URL(string: base + "/events/no-endpoint")!, bearerToken: "", timeout: 10) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled handshake returned") } catch { XCTAssertLessThan(start.duration(to: .now), .seconds(2)) }
        await cancelled.disconnect()
        let cancelCall = try await connect("cancel-call")
        _ = try await cancelCall.tools(timeout: 2)
        let callStart = ContinuousClock.now
        let pending = Task { try await cancelCall.call(name: "public_echo", arguments: Data(#"{"value":"cancel-public-call"}"#.utf8), timeout: 10) }
        try await Task.sleep(for: .milliseconds(100)); pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled call returned") } catch { XCTAssertLessThan(callStart.duration(to: .now), .seconds(2)) }
        await cancelCall.disconnect()
        try await Task.sleep(for: .milliseconds(150))
        let requests = try records()
        XCTAssertFalse(requests.contains { $0["kind"] as? String == "unapproved" })
        let posts = requests.filter { $0["kind"] as? String == "request" && $0["method"] as? String == "POST" }
        XCTAssertFalse(posts.isEmpty)
        XCTAssertTrue(posts.allSatisfy { ($0["headers"] as? [String: String])?["authorization"] == "Bearer public-test-token" && ($0["headers"] as? [String: String])?["x-public-value"] == "public-header" && ($0["headers"] as? [String: String])?["cookie"] == nil })
        for mode in ["disconnect", "malformed", "post-failure", "timeout", "oversized", "cancel-call"] {
            XCTAssertEqual(requests.filter { $0["mode"] as? String == mode && ($0["message"] as? [String: Any])?["method"] as? String == "tools/call" }.count, 1, mode)
        }
        XCTAssertEqual(requests.filter { $0["kind"] as? String == "opened" }.count, requests.filter { $0["kind"] as? String == "closed" }.count)
        print("SSE protocol evidence: " + directory.path)
    }
}

import AppKit
import Darwin
import SwiftTerm
import TerminalPTY

private final class WorkbenchTerminalView: TerminalView {
    var onFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onFocus?()
    }
}

/// A user-controlled terminal. The terminal emulator only receives PTY bytes.
/// Application credentials and the task conversation are never part of its environment.
@MainActor public final class TerminalSurface: @preconcurrency TerminalViewDelegate {
    private let terminal: WorkbenchTerminalView
    private var channel: DispatchIO?
    private var exitSource: DispatchSourceProcess?
    private var descriptor: Int32 = -1
    private var pendingInput = 0
    private var stopping = false
    public private(set) var pid: pid_t = 0
    public var onExit: ((Int32) -> Void)?
    public var onIssue: ((String) -> Void)?
    public var onFocus: (() -> Void)?
    public var view: NSView { terminal }

    public init() {
        let options = TerminalOptions(cursorStyle: .steadyBlock, scrollback: 2000,
                                      enableSixelReported: false, kittyImageCacheLimitBytes: 8 * 1024 * 1024)
        terminal = WorkbenchTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240),
                                         font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: options)
        terminal.terminalDelegate = self
        terminal.setAccessibilityLabel("终端输入")
        terminal.onFocus = { [weak self] in self?.onFocus?() }
        setDark(false)
    }

    public func setDark(_ dark: Bool) {
        terminal.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        terminal.nativeBackgroundColor = dark ? NSColor(srgbRed: 0.075, green: 0.092, blue: 0.10, alpha: 1) : NSColor(white: 0.985, alpha: 1)
        terminal.nativeForegroundColor = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.13, alpha: 1)
        terminal.caretColor = dark ? NSColor(srgbRed: 0.46, green: 0.82, blue: 0.72, alpha: 1) : NSColor(srgbRed: 0.08, green: 0.42, blue: 0.36, alpha: 1)
        terminal.needsDisplay = true
    }

    public func start(in directory: URL, checkHome: URL? = nil) throws {
        precondition(pid == 0 && channel == nil && !stopping)
        let configured = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
        let executable = checkHome == nil ? configured.flatMap { FileManager.default.isExecutableFile(atPath: $0) && $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh" : "/bin/zsh"
        let home = checkHome?.path ?? NSHomeDirectory()
        let login = NSUserName()
        let arguments = checkHome == nil ? ["-" + URL(fileURLWithPath: executable).lastPathComponent] : [executable, "-dfi"]
        var environment = [
            "HOME": home, "USER": login, "LOGNAME": login, "SHELL": executable, "TERM": "xterm-256color",
            "COLORTERM": "truecolor", "TERM_PROGRAM": "BlueFatFish", "LANG": "en_US.UTF-8",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": checkHome?.path ?? NSTemporaryDirectory(),
        ]
        if checkHome != nil {
            environment["ZDOTDIR"] = home
            environment["PS1"] = "whale%# "
            environment["HISTFILE"] = "/dev/null"
        } else if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], agent.hasPrefix("/") {
            environment["SSH_AUTH_SOCK"] = agent
        }
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        guard !argv.dropLast().contains(nil), !envp.dropLast().contains(nil) else {
            throw POSIXError(.ENOMEM)
        }
        var master: Int32 = -1
        let size = windowSize(cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)
        let child = argv.withUnsafeMutableBufferPointer { argv in
            envp.withUnsafeMutableBufferPointer { envp in
                bluefatfish_open_terminal(&master, directory.path, executable, argv.baseAddress, envp.baseAddress, size)
            }
        }
        guard child > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        pid = child
        descriptor = master

        let openedDescriptor = master
        let io = DispatchIO(type: .stream, fileDescriptor: openedDescriptor, queue: .main) { _ in close(openedDescriptor) }
        io.setLimit(lowWater: 1)
        io.setLimit(highWater: 16 * 1024)
        channel = io
        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        // Keep the reaper alive if its view has already been removed.
        exit.setEventHandler { self.didExit() }
        exitSource = exit
        exit.activate()
        readNext(from: io)
    }

    public func stop() {
        if pid > 0 && !stopping {
            stopping = true
            bluefatfish_stop_terminal_session(pid)
        }
        closeChannel()
    }

    private func didExit() {
        guard pid > 0 else { return }
        if !stopping { bluefatfish_stop_terminal_session(pid) }
        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
        pid = 0
        exitSource?.cancel()
        exitSource = nil
        let signal = status & 0x7f
        let code = reaped < 0 ? 1 : signal == 0 ? (status >> 8) & 0xff : 128 + signal
        onExit?(code)
        // The final PTY bytes can arrive after NOTE_EXIT. A detached process
        // holding the slave descriptor must not keep this terminal open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.closeChannel() }
    }

    private func readNext(from io: DispatchIO) {
        io.read(offset: 0, length: 16 * 1024, queue: .main) { [weak self] done, data, error in
            guard let self, self.channel === io else { return }
            if let data, !data.isEmpty { self.terminal.feed(byteArray: Array(data)[...]) }
            if done {
                if error != 0 || data?.isEmpty != false { self.closeChannel() }
                else { self.readNext(from: io) }
            }
        }
    }

    private func closeChannel() {
        descriptor = -1
        channel?.close(flags: .stop)
        channel = nil
    }

    private func windowSize(cols: Int, rows: Int) -> winsize {
        winsize(ws_row: UInt16(clamping: max(1, rows)), ws_col: UInt16(clamping: max(1, cols)), ws_xpixel: 0, ws_ypixel: 0)
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard descriptor >= 0, newCols > 0, newRows > 0 else { return }
        var size = windowSize(cols: newCols, rows: newRows)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: descriptor, windowSize: &size)
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard pid > 0, let channel, !data.isEmpty else { return }
        let count = data.count
        guard count <= 256 * 1024 - pendingInput else { onIssue?("输入过大，请分段粘贴"); return }
        let bytes = Data(data).withUnsafeBytes { DispatchData(bytes: $0) }
        pendingInput += count
        channel.write(offset: 0, data: bytes, queue: .main) { [weak self] done, _, _ in
            if done { self?.pendingInput -= count }
        }
    }

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil,
              url.user == nil, url.password == nil else { return }
        NSWorkspace.shared.open(url)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    public func textForVerification() -> String {
        String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
    }
}

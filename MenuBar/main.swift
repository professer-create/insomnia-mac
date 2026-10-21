// Insomnia menu bar app: an eye icon that keeps this Mac awake with the lid
// closed. All privileged work goes through the `insomnia` command line tool,
// so this app itself never needs a password.
//
// It also watches the lid. With sleep disabled, closing the lid no longer
// locks the screen by itself, so when the lid closes this app locks the
// screen the same way Control-Command-Q does. Processes keep running; the
// next person to open the lid sees the password screen.
import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt

let cli = "/usr/local/bin/insomnia"
let bundleID = "com.usman.insomnia"
let stateFile = NSString(string: "~/Library/Application Support/Insomnia/session").expandingTildeInPath
let logFile = NSString(string: "~/Library/Logs/Insomnia/insomnia.log").expandingTildeInPath
let lockOnLidCloseKey = "lockOnLidClose"

struct CommandResult {
    let status: Int32
    let output: String
}

func run(_ executable: String, _ arguments: [String]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return CommandResult(status: 127, output: "could not run \(executable): \(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

func appendLog(_ message: String) {
    let dir = (logFile as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(formatter.string(from: Date())) app: \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: logFile) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logFile, contents: data)
    }
}

func sleepDisabled() -> Bool {
    let result = run("/usr/bin/pmset", ["-g"])
    for line in result.output.split(separator: "\n") {
        // pmset separates the key and value with tabs, e.g. " SleepDisabled\t\t1"
        let parts = line.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.count >= 2, parts[0] == "SleepDisabled" {
            return parts[1] == "1"
        }
    }
    return false
}

func sessionEnd() -> Date? {
    guard let text = try? String(contentsOfFile: stateFile, encoding: .utf8),
          let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

/// Locks the screen through the login framework, exactly what Control-Command-Q
/// and the Lock Screen menu item do. Nothing is put to sleep.
@discardableResult
func lockScreen() -> Bool {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
          let symbol = dlsym(handle, "SACLockScreenImmediate") else {
        appendLog("lock failed: SACLockScreenImmediate not found")
        return false
    }
    typealias LockFunction = @convention(c) () -> Int32
    let lock = unsafeBitCast(symbol, to: LockFunction.self)
    let result = lock()
    appendLog("screen lock requested (result \(result))")
    return true
}

/// Lid open/close events. IOPMrootDomain posts kIOPMMessageClamshellStateChange
/// to its general-interest clients (not to IORegisterForSystemPower clients,
/// which only get sleep/wake messages). As a fallback the AppleClamshellState
/// property is also polled every two seconds, so a missed notification still
/// produces an event. Each transition fires exactly once.
final class LidWatcher {
    // Function-like C macros, which Swift cannot import; values checked
    // against the IOKit headers on macOS 15.
    static let clamshellChange: UInt32 = 0xE003_4100    // kIOPMMessageClamshellStateChange
    static let clamshellClosedBit: UInt = 0x1           // kClamshellStateBit

    var onLidClosed: (() -> Void)?
    var onLidOpened: (() -> Void)?
    private var rootDomain: io_service_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var pollTimer: Timer?
    private var lastClosed: Bool?

    /// Returns which of the two sources could be started.
    func start() -> (notifications: Bool, polling: Bool) {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return (false, false) }
        lastClosed = readClosed()

        var notifications = false
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            notifyPort = port
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let kr = IOServiceAddInterestNotification(port, rootDomain, "IOGeneralInterest", { refcon, _, messageType, argument in
                guard let refcon = refcon else { return }
                let watcher = Unmanaged<LidWatcher>.fromOpaque(refcon).takeUnretainedValue()
                watcher.handle(messageType: messageType, argument: argument)
            }, refcon, &notifier)
            if kr == KERN_SUCCESS {
                let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                notifications = true
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, let closed = self.readClosed() else { return }
            self.update(closed: closed, source: "poll")
        }
        return (notifications, pollTimer != nil)
    }

    private func readClosed() -> Bool? {
        guard rootDomain != 0,
              let unmanaged = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        let value = unmanaged.takeRetainedValue()
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        guard messageType == Self.clamshellChange else { return }
        let closed = (UInt(bitPattern: argument) & Self.clamshellClosedBit) != 0
        update(closed: closed, source: "notification")
    }

    private func update(closed: Bool, source: String) {
        guard closed != lastClosed else { return }
        lastClosed = closed
        appendLog("lid \(closed ? "closed" : "opened") (\(source))")
        if closed {
            onLidClosed?()
        } else {
            onLidOpened?()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let lidWatcher = LidWatcher()
    private let statusLine = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
    private let endLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Keep Awake With Lid Closed", action: #selector(toggle), keyEquivalent: "")
    private let lockOnLidItem = NSMenuItem(title: "Lock Screen When Lid Closes", action: #selector(toggleLockOnLidClose), keyEquivalent: "")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, HH:mm"
        return f
    }()

    private var lockOnLidClose: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: lockOnLidCloseKey) == nil { return true }
        return defaults.bool(forKey: lockOnLidCloseKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Insomnia: keep this Mac awake with the lid closed"

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        endLine.isEnabled = false
        endLine.isHidden = true
        menu.addItem(statusLine)
        menu.addItem(endLine)
        menu.addItem(.separator())

        toggleItem.target = self
        menu.addItem(toggleItem)

        let timed = NSMenu()
        let choices: [(String, String)] = [
            ("1 Hour", "1h"), ("2 Hours", "2h"), ("4 Hours", "4h"),
            ("8 Hours", "8h"), ("12 Hours", "12h"), ("24 Hours", "24h"),
        ]
        for (title, arg) in choices {
            let item = NSMenuItem(title: title, action: #selector(startTimed(_:)), keyEquivalent: "")
            item.representedObject = arg
            item.target = self
            timed.addItem(item)
        }
        let timedItem = NSMenuItem(title: "Keep Awake For…", action: nil, keyEquivalent: "")
        timedItem.submenu = timed
        menu.addItem(timedItem)
        menu.addItem(.separator())

        lockOnLidItem.target = self
        menu.addItem(lockOnLidItem)
        let lockNowItem = NSMenuItem(title: "Lock Screen Now", action: #selector(lockNow), keyEquivalent: "l")
        lockNowItem.target = self
        menu.addItem(lockNowItem)
        menu.addItem(.separator())

        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        let quitItem = NSMenuItem(title: "Quit Insomnia", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        lidWatcher.onLidClosed = { [weak self] in
            guard let self = self else { return }
            if self.lockOnLidClose {
                appendLog("locking screen")
                lockScreen()
            } else {
                appendLog("lock on lid close is off, not locking")
            }
        }
        let sources = lidWatcher.start()
        appendLog("started, lid watcher: notifications \(sources.notifications ? "on" : "FAILED"), polling \(sources.polling ? "on" : "FAILED")")
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc func refresh() {
        let on = sleepDisabled()
        let symbol = on ? "eye.fill" : "eye.slash"
        let description = on ? "Insomnia: awake with lid closed" : "Insomnia: normal sleep"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = on ? "👁" : "zz"
        }
        toggleItem.state = on ? .on : .off
        lockOnLidItem.state = lockOnLidClose ? .on : .off
        if on {
            statusLine.title = "Awake: lid closed, Mac keeps running"
            if let end = sessionEnd() {
                endLine.title = "Ends \(formatter.string(from: end))"
            } else {
                endLine.title = "Ends when you turn it off"
            }
            endLine.isHidden = false
        } else {
            statusLine.title = "Normal: lid closed, Mac sleeps"
            endLine.isHidden = true
        }
    }

    private func runCLI(_ arguments: [String]) {
        statusLine.title = "Working…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(cli, arguments)
            DispatchQueue.main.async {
                self.refresh()
                if result.status != 0 {
                    self.showError(result.output)
                }
            }
        }
    }

    private func showError(_ output: String) {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        alert.messageText = "Insomnia could not change the sleep setting"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        let setupLine = text.split(separator: "\n").map(String.init).first { $0.contains("sudo install") }
        if setupLine != nil {
            alert.addButton(withTitle: "Copy Setup Command")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn, let line = setupLine {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(line.trimmingCharacters(in: .whitespaces), forType: .string)
        }
    }

    @objc func toggle() {
        runCLI(sleepDisabled() ? ["off"] : ["on"])
    }

    @objc func startTimed(_ sender: NSMenuItem) {
        guard let arg = sender.representedObject as? String else { return }
        runCLI(["on", arg])
    }

    @objc func toggleLockOnLidClose() {
        let newValue = !lockOnLidClose
        UserDefaults.standard.set(newValue, forKey: lockOnLidCloseKey)
        lockOnLidItem.state = newValue ? .on : .off
        appendLog("lock on lid close turned \(newValue ? "on" : "off")")
    }

    @objc func lockNow() {
        lockScreen()
    }

    @objc func openLog() {
        let dir = (logFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile) {
            FileManager.default.createFile(atPath: logFile, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logFile))
    }

    @objc func quit() {
        guard sleepDisabled() else {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "This Mac is set to stay awake with the lid closed"
        alert.informativeText = "Quitting closes the menu bar icon and stops lock-on-lid-close. The timer and battery floor keep working in the background. Do you want sleep back to normal before quitting?"
        alert.addButton(withTitle: "Restore Normal Sleep and Quit")
        alert.addButton(withTitle: "Keep Awake and Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let result = run(cli, ["off"])
            if result.status != 0 {
                showError(result.output)
                return
            }
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

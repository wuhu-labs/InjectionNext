//
//  AppDelegate.swift
//  InjectionNext
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/AppDelegate.swift#76 $
//
//  Implementation Toolbar menu "UI".
//

import Cocoa
import Popen
import SwiftRegex

enum InjectionState: String {
    case ok = "OK" // Orange
    case idle = "Idle" // Blue
    case busy = "Busy" // Green
    case ready = "Ready" // Purple
    case error = "Error" // Yellow
}

@objc(AppDelegate)
class AppDelegate: NSObject, NSApplicationDelegate {

    static var ui: AppDelegate!

    // Status menu
    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet var statusItem: NSStatusItem!
    // Codesigning identity
    @IBOutlet var identityField: NSTextField!
    // Enable injection on devices
    @IBOutlet var deviceTesting: NSButton!
    // Testing libraries to link with
    @IBOutlet var librariesField: NSTextField!
    // Place to display last error that occured
    @IBOutlet var lastErrorField: NSTextView!
    // Restart XCode if crashed.
    @IBOutlet weak var launchXcodeItem: NSMenuItem!
    @IBOutlet weak var selectXcodeItem: NSMenuItem!
    @IBOutlet weak var restartDeviceItem: NSMenuItem!
    @IBOutlet weak var patchCompilerItem: NSMenuItem!
    @IBOutlet weak var enableDevicesItem: NSMenuItem!
    @IBOutlet weak var watchDirectoryItem: NSMenuItem!

    // Interface to app's persistent state.
    @objc let defaults = Defaults.userDefaults

    @IBOutlet weak var codeSignBox: NSComboBox!

    /// Code signing ID as parsed from the code signing box. If the content of the box is not
    /// parsable as SHA1 code signing ID, an empty string.
    var codeSigningID: String { codeSignBox.stringValue.containedSHA1 ?? "" }

    let userIDComboBoxDataSaver = UserIDComboBoxDataSaver()

    @objc func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
        Self.ui = self

        let appName = "InjectionNext"

        if Bundle.main.infoDictionary?["LSUIElement"] as? Bool != true {
            NSApp.mainMenu?.item(withTitle: "File")?.submenu = statusMenu
        } else {
            let statusBar = NSStatusBar.system
            statusItem = statusBar.statusItem(withLength: statusBar.thickness)
            statusItem.highlightMode = true
            statusItem.menu = statusMenu
            statusItem.isEnabled = true
            statusItem.title = appName
            setMenuIcon(.idle)
        }

        signal(SIGPIPE, { which in
            print(APP_PREFIX+"⚠️ SIGPIPE #\(which)\n" +
                  Thread.callStackSymbols.map { var frame = $0
                        frame[#"(?:\S+\s+){3}(\S+)"#, 1] = {
                            (groups: [String], stop) in
                            return groups[1].swiftDemangle ?? groups[1] }
                        return frame
                    }.joined(separator: "\n")) })

        if let quit = statusMenu.item(at: statusMenu.items.count-1) {
            quit.title = "Quit "+appName
            if let build = Bundle.main
                .infoDictionary?[kCFBundleVersionKey as String] {
                quit.toolTip = "Quit (build #\(build))"
            }
        }

        librariesField.stringValue = Defaults.deviceLibraries
        let enableDevicesSticky = false
        if !enableDevicesSticky || Defaults.codesigningIdentity == nil {
            enableDevicesItem.state = .on
        }
        deviceEnable(nil)
        if let xcodePath = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dt.Xcode")
            .first?.bundleURL?.path {
            if Defaults.xcodeDefault == nil {
                Defaults.xcodeDefault = xcodePath
            }
            selectXcodeItem.toolTip = Defaults.xcodePath
            if updatePatchUnpatch() == .unpatched {
                InjectionServer.alert("""
                    Please quit Xcode and
                    use this app to launch it
                    (unless you are using a file watcher).
                    """)
            }
        }
 
        setupCodeSigningComboBox()
        restartDeviceItem.state = Defaults.xcodeRestart ? .on : .off
        selectXcodeItem.toolTip = Defaults.xcodePath

//        #if DEBUG
//        if NSHomeDirectory() == "/Users/johnholdsworth",
//           let path = Bundle.main.path(forResource: "macOSInjection", ofType: "bundle"),
//           let bundle = Bundle(path: path),
//           bundle.load() {
//        }
//        #endif

        if let project = Defaults.projectPath {
            _ = MonitorXcode(args: " '\(project)'")
        }
    }

    func setMenuIcon(_ state: InjectionState) {
        DispatchQueue.main.async {
            guard self.statusItem != nil else { return }
            let tiffName = "Injection"+state.rawValue
            if let path = Bundle.main.path(forResource: tiffName, ofType: "tif"),
                let image = NSImage(contentsOfFile: path) {
    //            image.template = TRUE;
                self.statusItem.image = image
                self.statusItem.alternateImage = image
            }
        }
    }

    @IBAction func runXcode(_ sender: Any) {
        if MonitorXcode.runningXcode == nil {
            _ = MonitorXcode()
        }
    }

    @IBAction func selectXcode(_ sender: NSMenuItem) {
        let open = NSOpenPanel()
        open.prompt = "Select Xcode"
        open.directoryURL = URL(fileURLWithPath: Defaults.xcodePath)
        open.canChooseDirectories = false
        open.canChooseFiles = true
        if open.runModal() == .OK, let path = open.url?.path {
            selectXcodeItem.toolTip = path
            Defaults.xcodeDefault = path
            updatePatchUnpatch()
            if Defaults.xcodeRestart {
                runXcode(sender)
            }
        }
    }

    lazy var startHostLocatingServerOnce: () = {
        InjectionServer.multicastServe(HOTRELOADING_MULTICAST,
                                       port: HOTRELOADING_PORT)
    }()

    @IBAction func deviceEnable(_ sender: NSMenuItem?) {
        var openPort = ""
        if enableDevicesItem.state.toggle() == .on {
            if sender != nil {
                NSApplication.shared.activate(ignoringOtherApps: true)
                codeSignBox.window?.makeKeyAndOrderFront(sender)
            }
            _ = startHostLocatingServerOnce
            openPort = "*"
        }
        if sender != nil { InjectionServer.stopLastServer() }
        InjectionServer.startServer(openPort+INJECTION_ADDRESS)
    }

    @IBAction func testingEnable(_ sender: NSButton) {
        if sender.state == .on, let script = Bundle.main
            .url(forResource: "copy_bundle", withExtension: "sh") {
            let buildPhase = """
                export RESOURCES="\(script.deletingLastPathComponent().path)"
                if [ -f "$RESOURCES/\(script.lastPathComponent)" ]; then
                    "$RESOURCES/\(script.lastPathComponent)"
                fi
                """
            let pasteBoard = NSPasteboard.general
            pasteBoard.declareTypes([.string], owner:nil)
            pasteBoard.setString(buildPhase, forType:.string)
            InjectionServer.error("Run Script, Build Phase to " +
                  "copy testing libraries added to clipboard.")
        }
    }

    @IBAction func updateLibraries(_ sender: NSTextField) {
        Defaults.deviceLibraries = librariesField.stringValue
    }


    @IBAction func updateXcodeRestart(_ sender: NSMenuItem) {
        Defaults.xcodeRestart = sender.state.toggle() == .on
    }

    @IBAction func unhideSymbols(_ sender: NSMenuItem) {
        Unhider.startUnhide()
    }

    @IBAction func resetUnhiding(_ sender: NSMenuItem) {
        Unhider.unhiddens.removeAll()
    }

    @IBAction func showlastError(_ sender: NSMenuItem) {
        lastErrorField.string = NextCompiler.lastError ?? "No error."
        lastErrorField.window?.makeKeyAndOrderFront(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func setupCodeSigningComboBox() {
        codeSignBox.removeAllItems()

        codeSignBox.addItems(withObjectValues: userIDComboBoxDataSaver.validCodeSigningIDs)

        if let savedID = userIDComboBoxDataSaver.savedID {
            codeSignBox.stringValue = savedID
        } else if let firstIdentity = userIDComboBoxDataSaver.validCodeSigningIDs.first {
            codeSignBox.stringValue = firstIdentity
        } else {
            codeSignBox.stringValue = "No valid code signing IDs found"
        }

        codeSignBox.target = userIDComboBoxDataSaver
        codeSignBox.action = #selector(UserIDComboBoxDataSaver.comboBoxValueDidChange(_:))
    }
}

private extension String {
    /// Returns the sha1 string contained in this string, or `nil` if no such string is contained.
    var containedSHA1: String? { self[#"([0-9A-F]{40})"#] }
}

class UserIDComboBoxDataSaver {

    /// List of valid IDs.
    let validCodeSigningIDs: [String] = {
        var identities: [String] = []

        let security = Topen(exec: "/usr/bin/security",
                             arguments: ["find-identity", "-v", "-p", "codesigning"])

        while let line = security.readLine() {
            let components = line.split(separator: ")", maxSplits: 1)
            if components.count >= 2 {
                let identity = components[1]
                identities.append(String(identity))
            }
        }

        return identities
    }()

    /// Last savedID, if valid. `nil` otherwise.
    var savedID: String? {
        guard let savedValue = Defaults.codesigningIdentity else { return nil }

        return validCodeSigningIDs.first(where: { $0.containedSHA1 == savedValue.containedSHA1} )
    }

    @objc func comboBoxValueDidChange(_ sender: NSComboBox) {
        if let newValueSHA1 = sender.stringValue.containedSHA1,
           validCodeSigningIDs.contains(where: { $0.containedSHA1 == newValueSHA1 }) {
            Defaults.codesigningIdentity = newValueSHA1
        } else {
            NSLog("Selected value does not contain a valid ID")
            return
        }
    }
}

private extension NSControl.StateValue {
    @discardableResult
    mutating func toggle() -> Self {
        switch self {
        case .on:
            self = .off
        case .off:
            self = .on
        case .mixed:
            self = .mixed
        default:
            break
        }
        return self
    }
}

enum InjectionNextCommandLine {
    static var isRunning = false
    static var harness: HeadlessHarness?

    final class HeadlessHarness {
        let delegate = AppDelegate()
        let launchXcodeItem = NSMenuItem()
        let selectXcodeItem = NSMenuItem()
        let restartDeviceItem = NSMenuItem()
        let patchCompilerItem = NSMenuItem()
        let enableDevicesItem = NSMenuItem()
        let watchDirectoryItem = NSMenuItem()
        let librariesField = NSTextField(string: Defaults.deviceLibraries)
        let lastErrorField = NSTextView()
        let deviceTesting = NSButton(checkboxWithTitle: "Enable devices", target: nil, action: nil)
        let codeSignBox = NSComboBox()

        init() {
            delegate.launchXcodeItem = launchXcodeItem
            delegate.selectXcodeItem = selectXcodeItem
            delegate.restartDeviceItem = restartDeviceItem
            delegate.patchCompilerItem = patchCompilerItem
            delegate.enableDevicesItem = enableDevicesItem
            delegate.watchDirectoryItem = watchDirectoryItem
            delegate.librariesField = librariesField
            delegate.lastErrorField = lastErrorField
            delegate.deviceTesting = deviceTesting
            delegate.codeSignBox = codeSignBox
            enableDevicesItem.state = .off
            deviceTesting.state = .on
            codeSignBox.stringValue = Defaults.codesigningIdentity ?? ""
            AppDelegate.ui = delegate
        }
    }

    struct Options {
        var projectRoot: String?
        var bazelTarget: String?
        var xcodeApp: String?
        var multicast = true
        var listenAddress = "*" + String(cString: INJECTION_ADDRESS)
    }

    static func usage(_ executable: String) -> String {
        """
        Usage: \(executable) serve [options]

        Starts InjectionNext as a headless hot-reload coordinator. It listens for
        InjectionNext runtime connections from simulator apps, watches the project
        directory reported by the app, recompiles changed Swift sources using the
        Bazel target supplied by INJECTION_BAZEL_TARGET, and injects the resulting
        dylib back into the running app.

        Options:
          --project-root <path>   Watch this project immediately, before a client connects.
          --bazel-target <label>  Cache the Bazel app target used for aquery recompiles.
          --xcode-app <path>      Xcode.app to use for toolchain and simulator SDK paths.
          --listen <address>      Listen address, default: *:8887.
          --no-multicast          Disable the simulator host-locating multicast responder.
          -h, --help              Show this help.
        """
    }

    static func parse(argv: [String]) throws -> Options? {
        var options = Options()
        var index = 2

        while index < argv.count {
            let argument = argv[index]
            func requireValue() throws -> String {
                let valueIndex = index + 1
                guard valueIndex < argv.count else {
                    throw CommandError("Missing value for \(argument)")
                }
                index = valueIndex
                return argv[valueIndex]
            }

            switch argument {
            case "-h", "--help":
                return nil
            case "--project-root":
                options.projectRoot = try requireValue()
            case "--bazel-target":
                options.bazelTarget = try requireValue()
            case "--xcode-app":
                options.xcodeApp = try requireValue()
            case "--listen":
                options.listenAddress = try requireValue()
            case "--no-multicast":
                options.multicast = false
            default:
                throw CommandError("Unknown argument: \(argument)")
            }
            index += 1
        }

        return options
    }

    static func inferXcodeApp() -> String? {
        let developerDir = Popen.system("xcode-select -p")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let developerDir, !developerDir.isEmpty else { return nil }
        return URL(fileURLWithPath: developerDir)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    static func run(argc: Int32, argv: UnsafePointer<UnsafePointer<CChar>?>) -> Int32 {
        let arguments = (0 ..< Int(argc)).compactMap { index in
            argv[index].map { String(cString: $0) }
        }
        let executable = URL(fileURLWithPath: arguments.first ?? "injection-next")
            .lastPathComponent

        do {
            guard let options = try parse(argv: arguments) else {
                print(usage(executable))
                return 0
            }

            isRunning = true
            NSApplication.shared.setActivationPolicy(.prohibited)
            harness = HeadlessHarness()

            if let xcodeApp = options.xcodeApp ?? inferXcodeApp() {
                Defaults.xcodeDefault = xcodeApp
            }
            Reloader.xcodeDev = Defaults.xcodePath + "/Contents/Developer"

            if let bazelTarget = options.bazelTarget {
                BazelActionQueryHandler.cachedAppTarget = bazelTarget
                setenv(INJECTION_BAZEL_TARGET, bazelTarget, 1)
            }

            if options.multicast {
                InjectionServer.multicastServe(HOTRELOADING_MULTICAST, port: HOTRELOADING_PORT)
            }
            InjectionServer.startServer(options.listenAddress)

            if let projectRoot = options.projectRoot {
                harness?.delegate.watch(path: projectRoot)
            }

            print("🔥 InjectionNext CLI listening on \(options.listenAddress)")
            print("🔥 Xcode: \(Defaults.xcodePath)")
            if let bazelTarget = options.bazelTarget {
                print("🔥 Bazel target: \(bazelTarget)")
            }
            if let projectRoot = options.projectRoot {
                print("🔥 Watching: \(projectRoot)")
            }

            RunLoop.main.run()
            return 0
        } catch {
            fputs("\(error)\n\n\(usage(executable))\n", stderr)
            return 64
        }
    }

    struct CommandError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) {
            self.description = description
        }
    }
}

@_cdecl("InjectionNextCommandMain")
public func InjectionNextCommandMain(
    _ argc: Int32,
    _ argv: UnsafePointer<UnsafePointer<CChar>?>
) -> Int32 {
    InjectionNextCommandLine.run(argc: argc, argv: argv)
}

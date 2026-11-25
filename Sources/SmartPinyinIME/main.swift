import ApplicationServices
import Carbon
import Cocoa
import InputMethodKit
import SharedIPC

// 极速探测与注册入口：供 SmartPinyinSetup/postinstall 查询 TCC 权限或以 root 刷新系统级 IntlDataCache，不启动 IMKServer
let launchArgs = CommandLine.arguments
if launchArgs.contains("--check-accessibility") {
    let key = "AXTrustedCheckOptionPrompt" as CFString
    let opts = [key: kCFBooleanFalse!] as CFDictionary
    exit(AXIsProcessTrustedWithOptions(opts) ? 0 : 1)
}
if launchArgs.contains("--request-accessibility") {
    let key = "AXTrustedCheckOptionPrompt" as CFString
    let opts = [key: kCFBooleanTrue!] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    exit(0)
}
if launchArgs.contains("--register-system-cache") {
    let url = Bundle.main.bundleURL
    _ = TISRegisterInputSource(url as CFURL)
    _ = TISCreateInputSourceList(nil, true)
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? SmartPinyinIdentifiers.appBundleID
        let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
            ?? SmartPinyinIdentifiers.connectionName

        self.server = IMKServer(name: connectionName, bundleIdentifier: bundleID)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server = nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

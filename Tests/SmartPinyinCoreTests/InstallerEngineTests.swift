import Foundation
import LocalInferenceCore
import SmartPinyinInstallerCore
import XCTest

final class InstallerEngineTests: XCTestCase {
    func testDeletionPathValidatorAllowsOnlyWhitelistedPaths() {
        let fakeHome = URL(fileURLWithPath: "/tmp/sp_home_test", isDirectory: true)
        let validator = DeletionPathValidator(homeDirectory: fakeHome, sandboxRoot: fakeHome)

        // 合法白名单路径必须放行
        XCTAssertTrue(validator.isAllowedToDelete(fakeHome.appendingPathComponent("Library/Input Methods/SmartPinyin.app")))
        XCTAssertTrue(validator.isAllowedToDelete(fakeHome.appendingPathComponent("Applications/SmartPinyin Setup.app")))
        XCTAssertTrue(validator.isAllowedToDelete(fakeHome.appendingPathComponent("Library/Application Support/SmartPinyin/Models")))
        XCTAssertTrue(validator.isAllowedToDelete(fakeHome.appendingPathComponent("Library/Application Support/SmartPinyin/LexiconPacks")))
        XCTAssertTrue(validator.isAllowedToDelete(URL(fileURLWithPath: "/Library/Input Methods/SmartPinyin.app")))

        // 危险路径和穿越路径必须 100% 拦截
        XCTAssertFalse(validator.isAllowedToDelete(URL(fileURLWithPath: "/")))
        XCTAssertFalse(validator.isAllowedToDelete(fakeHome))
        XCTAssertFalse(validator.isAllowedToDelete(URL(fileURLWithPath: "/Applications")))
        XCTAssertFalse(validator.isAllowedToDelete(URL(fileURLWithPath: "/Library/Input Methods")))
        XCTAssertFalse(validator.isAllowedToDelete(fakeHome.appendingPathComponent("Desktop")))
        XCTAssertFalse(validator.isAllowedToDelete(fakeHome.appendingPathComponent("Library/Input Methods/SmartPinyin.app/../../Desktop")))
    }

    func testSandboxInstallPreserveModelsAndSelfDeleteUninstall() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("SmartPinyinInstallerTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: sandbox) }

        // 构造模拟载荷 SmartPinyin.app 和 Setup App
        let payloadApp = sandbox.appendingPathComponent("Payload/SmartPinyin.app", isDirectory: true)
        let helperApp = payloadApp.appendingPathComponent("Contents/Helpers/SmartPinyinSetup.app", isDirectory: true)
        try fm.createDirectory(at: helperApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: payloadApp.appendingPathComponent("Contents/MacOS_Dummy"))
        try Data(repeating: 0x42, count: 2048).write(to: helperApp.appendingPathComponent("Contents/MacOS/SmartPinyinSetup"))

        let fakeHome = sandbox.appendingPathComponent("Home", isDirectory: true)
        let fakeSysIME = sandbox.appendingPathComponent("SysInputMethods", isDirectory: true)
        let fakeSysApps = sandbox.appendingPathComponent("SysApplications", isDirectory: true)
        try fm.createDirectory(at: fakeHome, withIntermediateDirectories: true)

        let engine = InstallerEngine(
            homeDirectory: fakeHome,
            systemInputMethodsDirectory: fakeSysIME,
            systemApplicationsDirectory: fakeSysApps,
            sandboxRootForValidation: fakeHome,
            skipSystemIntegration: true
        )

        // 1. 沙箱安装
        let installedURL = try engine.install(
            payloadAppURL: payloadApp,
            scope: .currentUser,
            setupAppBundleURL: helperApp
        )
        XCTAssertEqual(installedURL.standardizedFileURL, engine.userInputMethodURL.standardizedFileURL)
        XCTAssertTrue(fm.fileExists(atPath: engine.userInputMethodURL.path))
        XCTAssertTrue(fm.fileExists(atPath: engine.userSetupAppURL.path))

        // 放入模拟用户词库与模型文件
        let rimeDir = engine.appSupportDirectory.appendingPathComponent("RimeUserData", isDirectory: true)
        let modelsDir = engine.appSupportDirectory.appendingPathComponent("Models", isDirectory: true)
        try fm.createDirectory(at: rimeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let modelFile = modelsDir.appendingPathComponent("Qwen3-0.6B-Q4_K_M.gguf")
        var ggufData = Data("GGUF".utf8)
        ggufData.append(Data(repeating: 0x01, count: 1024))
        try ggufData.write(to: modelFile)
        try Data("user_dict".utf8).write(to: rimeDir.appendingPathComponent("custom.txt"))

        // 验证磁盘占用扫描
        let usage = engine.inspectDiskUsage()
        XCTAssertGreaterThan(usage.inputMethodBytes, 0)
        XCTAssertGreaterThan(usage.setupAppBytes, 0)
        XCTAssertGreaterThan(usage.localModelsBytes, 0)

        // 2. 模拟「正在运行中的 SmartPinyin Setup.app 卸载自己」（保留本地模型与词库）
        let result = try engine.uninstall(
            options: UninstallOptions(
                removeUserDictionaries: false,
                removeLocalModels: false,
                removePreferencesAndLogs: true
            ),
            currentProcessBundleURL: engine.userSetupAppURL,
            launchDeferredScript: false
        )

        // 输入法本体应已立即删除；模型与词库应保留；运行中的 Setup App 应进入延迟自删队列
        XCTAssertFalse(fm.fileExists(atPath: engine.userInputMethodURL.path))
        XCTAssertTrue(fm.fileExists(atPath: modelFile.path))
        XCTAssertTrue(fm.fileExists(atPath: rimeDir.appendingPathComponent("custom.txt").path))
        XCTAssertEqual(result.deferredSelfDeletePaths, [engine.userSetupAppURL.standardizedFileURL])
        let scriptURL = try XCTUnwrap(result.selfDeleteScriptURL)
        XCTAssertTrue(fm.fileExists(atPath: scriptURL.path))

        // 3. 用 /bin/sh -n 检验生成的自删脚本语法（含空格路径转义）
        let checkProc = Process()
        checkProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        checkProc.arguments = ["-n", scriptURL.path]
        try checkProc.run()
        checkProc.waitUntilExit()
        XCTAssertEqual(checkProc.terminationStatus, 0)

        // 4. 在测试中把脚本里等待当前测试 PID 的循环改为空转并真实执行，确认自删生效且脚本自我销毁
        let content = try String(contentsOf: scriptURL, encoding: .utf8)
        let immediateContent = content.replacingOccurrences(of: "while kill -0 ", with: "while false && kill -0 ")
        try immediateContent.write(to: scriptURL, atomically: true, encoding: .utf8)

        let runProc = Process()
        runProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        runProc.arguments = [scriptURL.path]
        try runProc.run()
        runProc.waitUntilExit()
        XCTAssertEqual(runProc.terminationStatus, 0)

        XCTAssertFalse(fm.fileExists(atPath: engine.userSetupAppURL.path), "自删脚本必须干净清除自身 .app")
        XCTAssertFalse(fm.fileExists(atPath: scriptURL.path), "自删脚本执行完毕后必须自我删除")
    }

    func testModelProvisionerValidatesGGUFHeader() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("SmartPinyinGGUFTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let validFile = tmp.appendingPathComponent("good.gguf")
        var good = Data("GGUF".utf8)
        good.append(Data(repeating: 0x00, count: 256))
        try good.write(to: validFile)

        let badFile = tmp.appendingPathComponent("bad.gguf")
        try Data("HTML<html>not gguf</html>".utf8).write(to: badFile)

        XCTAssertNotNil(ModelProvisioner.validateGGUFFile(at: validFile, minBytes: 64))
        XCTAssertNil(ModelProvisioner.validateGGUFFile(at: badFile, minBytes: 8))
    }

    /// 回归测试：覆盖升级必须就地同步保留 .app 目录 inode（避免辅助功能 TCC 授权失效），
    /// 且卸载勾选清除用户词库时必须同步清理 LexiconPacks 扩展词库与元数据目录。
    func testInPlaceUpgradePreservesInodeAndUninstallRemovesLexiconPacks() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("SmartPinyinUpgradeTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: sandbox) }

        let payloadV1 = sandbox.appendingPathComponent("PayloadV1/SmartPinyin.app", isDirectory: true)
        let payloadV2 = sandbox.appendingPathComponent("PayloadV2/SmartPinyin.app", isDirectory: true)
        try fm.createDirectory(at: payloadV1.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: payloadV2.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: payloadV1.appendingPathComponent("Contents/version.txt"))
        try Data("obsolete".utf8).write(to: payloadV1.appendingPathComponent("Contents/old_only.txt"))
        try Data("v2".utf8).write(to: payloadV2.appendingPathComponent("Contents/version.txt"))

        let fakeHome = sandbox.appendingPathComponent("Home", isDirectory: true)
        try fm.createDirectory(at: fakeHome, withIntermediateDirectories: true)

        let engine = InstallerEngine(
            homeDirectory: fakeHome,
            systemInputMethodsDirectory: sandbox.appendingPathComponent("SysIME", isDirectory: true),
            systemApplicationsDirectory: sandbox.appendingPathComponent("SysApps", isDirectory: true),
            sandboxRootForValidation: fakeHome,
            skipSystemIntegration: true
        )

        // 1. 首次安装 V1 并记录目录 inode
        let installedV1 = try engine.install(payloadAppURL: payloadV1, scope: .currentUser)
        let inodeV1 = (try fm.attributesOfItem(atPath: installedV1.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        XCTAssertNotNil(inodeV1)
        XCTAssertTrue(fm.fileExists(atPath: installedV1.appendingPathComponent("Contents/old_only.txt").path))

        // 2. 覆盖安装 V2：目录 inode 必须不变，文件内容同步更新且旧文件被清理
        let installedV2 = try engine.install(payloadAppURL: payloadV2, scope: .currentUser)
        let inodeV2 = (try fm.attributesOfItem(atPath: installedV2.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        XCTAssertEqual(inodeV1, inodeV2, "覆盖升级应保留 SmartPinyin.app 目录 inode 以维持 TCC 权限")
        XCTAssertEqual(try String(contentsOf: installedV2.appendingPathComponent("Contents/version.txt"), encoding: .utf8), "v2")
        XCTAssertFalse(fm.fileExists(atPath: installedV2.appendingPathComponent("Contents/old_only.txt").path))

        // 3. 放入 LexiconPacks 模拟扩展词库与状态文件，确认占用统计和卸载清理覆盖完整
        let lexiconDir = engine.appSupportDirectory.appendingPathComponent("LexiconPacks/Tags", isDirectory: true)
        try fm.createDirectory(at: lexiconDir, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: lexiconDir.appendingPathComponent("user_domain_tags.bin"))

        let usageBefore = engine.inspectDiskUsage()
        XCTAssertGreaterThanOrEqual(usageBefore.userDictionaryBytes, 8192)

        _ = try engine.uninstall(
            options: UninstallOptions(
                removeUserDictionaries: true,
                removeLocalModels: false,
                removePreferencesAndLogs: true
            ),
            currentProcessBundleURL: nil,
            launchDeferredScript: false
        )
        XCTAssertFalse(
            fm.fileExists(atPath: engine.appSupportDirectory.appendingPathComponent("LexiconPacks").path),
            "卸载勾选移除用户词库时必须一并清理 LexiconPacks"
        )
    }

    /// 回归测试：确保从后台线程调用 Carbon TIS 查询接口不会触发主线程队列断言崩溃
    func testInputSourceManagerIsSafeFromBackgroundThread() {
        let exp = expectation(description: "Background TIS query completed safely")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = InputSourceManager.currentStatus()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    /// 回归测试：Lite 安装包在模型尚未下载时，InferenceBudgetConfig 必须回落至 Application Support 目录并开启自动重探，
    /// 绝不能固化到只读 XPC Bundle 路径导致下载模型后仍无法加载。
    func testDefaultInferenceBudgetConfigFallsBackToAppSupportAndEnablesRediscovery() throws {
        let fm = FileManager.default
        let tmpModels = fm.temporaryDirectory.appendingPathComponent("SmartPinyinEmptyModels_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmpModels) }
        try fm.createDirectory(at: tmpModels, withIntermediateDirectories: true)

        let cfg = InferenceBudgetConfig.defaultConfig(
            projectModelsDir: nil,
            appSupportModelsDir: tmpModels.path,
            workingDirectory: tmpModels.path
        )
        XCTAssertTrue(cfg.autoRediscoverMissingModels)
        XCTAssertEqual(cfg.lightModelPath, tmpModels.appendingPathComponent("Qwen3-0.6B-Q4_K_M.gguf").path)
        XCTAssertEqual(cfg.translationModelPath, tmpModels.appendingPathComponent("HY-MT1.5-1.8B-Q4_K_M.gguf").path)
    }

    /// 回归测试：PermissionChecker 对指定已安装 SmartPinyin.app 严格以子进程探针退出码为准，绝不回落至 Setup App 产生假阳性绿勾
    func testPermissionCheckerRespectsInstalledAppProbeResultWithoutFalsePositiveFallback() throws {
        let fm = FileManager.default
        let tmpApp = fm.temporaryDirectory.appendingPathComponent("FakeSmartPinyin_\(UUID().uuidString).app", isDirectory: true)
        defer { try? fm.removeItem(at: tmpApp) }
        let exe = tmpApp.appendingPathComponent("Contents/MacOS/SmartPinyin")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)

        try "#!/bin/sh\nexit 1\n".write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        XCTAssertFalse(PermissionChecker.isAccessibilityTrusted(installedAppURL: tmpApp))

        try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        XCTAssertTrue(PermissionChecker.isAccessibilityTrusted(installedAppURL: tmpApp))
    }

    /// 回归测试：系统级路径优先排在 inspectDiskUsage 首位；特权自删脚本同步清理 IntlDataCache 且通过 sh -n；白名单放行 BundledModels 暂存目录
    func testSystemScopeOrderingAndPrivilegedSelfDeleteScriptValidity() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("SmartPinyinScopeOrder_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: sandbox) }

        let fakeHome = sandbox.appendingPathComponent("Home", isDirectory: true)
        let fakeSysIME = sandbox.appendingPathComponent("SysIME", isDirectory: true)
        let fakeSysApps = sandbox.appendingPathComponent("SysApps", isDirectory: true)
        try fm.createDirectory(at: fakeHome.appendingPathComponent("Library/Input Methods/SmartPinyin.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeSysIME.appendingPathComponent("SmartPinyin.app"), withIntermediateDirectories: true)

        let engine = InstallerEngine(
            homeDirectory: fakeHome,
            systemInputMethodsDirectory: fakeSysIME,
            systemApplicationsDirectory: fakeSysApps,
            sandboxRootForValidation: fakeHome,
            skipSystemIntegration: true
        )

        let usage = engine.inspectDiskUsage()
        XCTAssertEqual(usage.installedAppPaths.count, 2)
        XCTAssertEqual(
            usage.installedAppPaths.first?.standardizedFileURL,
            engine.systemInputMethodURL.standardizedFileURL,
            "存在双副本时应优先以系统级 SmartPinyin.app 为主路径"
        )
        XCTAssertTrue(engine.validator.isAllowedToDelete(URL(fileURLWithPath: "/Library/Application Support/SmartPinyin/BundledModels")))
        XCTAssertTrue(engine.validator.isAllowedToDelete(fakeHome.appendingPathComponent("Library/Caches/com.smartpinyin.inputmethod.SmartPinyin.Setup")))
        XCTAssertTrue(engine.validator.isAllowedToDelete(fakeHome.appendingPathComponent("Library/HTTPStorages/com.smartpinyin.inputmethod.SmartPinyin.Setup")))

        let scriptURL = try engine.createSelfDeleteScript(
            targets: [
                URL(fileURLWithPath: "/Applications/SmartPinyin Setup.app"),
                URL(fileURLWithPath: "/Library/Input Methods/SmartPinyin.app")
            ],
            requiresAdmin: true
        )
        defer { try? fm.removeItem(at: scriptURL) }
        let content = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(content.contains("com.apple.IntlDataCache*"), "特权自删脚本应同步清理系统级 IntlDataCache")
        XCTAssertTrue(content.contains("/Applications/SmartPinyin Setup.app"))
        XCTAssertTrue(content.contains("/Library/Input Methods/SmartPinyin.app"))

        let checkProc = Process()
        checkProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        checkProc.arguments = ["-n", scriptURL.path]
        try checkProc.run()
        checkProc.waitUntilExit()
        XCTAssertEqual(checkProc.terminationStatus, 0)
    }

    /// 回归测试：卸载必须同步清理 Setup 缓存与 HTTPStorages，且 Logs 计入 preferencesAndLogsBytes 而非 userDictionaryBytes
    func testUninstallRemovesSetupCachesAndHTTPStoragesWithAccurateDiskAccounting() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("SmartPinyinUninstallAudit_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: sandbox) }

        let fakeHome = sandbox.appendingPathComponent("Home", isDirectory: true)
        let engine = InstallerEngine(
            homeDirectory: fakeHome,
            systemInputMethodsDirectory: sandbox.appendingPathComponent("SysIME", isDirectory: true),
            systemApplicationsDirectory: sandbox.appendingPathComponent("SysApps", isDirectory: true),
            sandboxRootForValidation: fakeHome,
            skipSystemIntegration: true
        )

        let logsDir = engine.appSupportDirectory.appendingPathComponent("Logs", isDirectory: true)
        let setupCacheDir = fakeHome.appendingPathComponent("Library/Caches/com.smartpinyin.inputmethod.SmartPinyin.Setup", isDirectory: true)
        let httpStorageDir = fakeHome.appendingPathComponent("Library/HTTPStorages/com.smartpinyin.inputmethod.SmartPinyin.Setup", isDirectory: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: setupCacheDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: httpStorageDir, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 4096).write(to: logsDir.appendingPathComponent("rime.log"))
        try Data(repeating: 0x22, count: 2048).write(to: setupCacheDir.appendingPathComponent("Cache.db"))
        try Data(repeating: 0x33, count: 1024).write(to: httpStorageDir.appendingPathComponent("httpstorages.sqlite"))

        let usage = engine.inspectDiskUsage()
        XCTAssertEqual(usage.userDictionaryBytes, 0, "Logs 绝不应被误计入个人词库大小")
        XCTAssertGreaterThanOrEqual(usage.preferencesAndLogsBytes, 7168)

        let result = try engine.uninstall(
            options: UninstallOptions(
                removeUserDictionaries: false,
                removeLocalModels: false,
                removePreferencesAndLogs: true
            ),
            currentProcessBundleURL: nil,
            launchDeferredScript: false
        )
        XCTAssertFalse(result.shouldTerminateAfterUninstall)
        XCTAssertFalse(fm.fileExists(atPath: logsDir.path))
        XCTAssertFalse(fm.fileExists(atPath: setupCacheDir.path))
        XCTAssertFalse(fm.fileExists(atPath: httpStorageDir.path))
    }
}

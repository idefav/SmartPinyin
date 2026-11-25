@_implementationOnly import CLibRimeBridge
import Foundation
import SharedIPC

/// 基于 librime 1.17 + 万象词库/语法模型的 L1 确定性拼音引擎适配器。
/// 所有调用经由内部串行锁保护，确保在毫秒级主线程内安全执行。
public final class RimeEngineAdapter: PinyinEngineProtocol {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    public let sharedDataDir: String
    public let userDataDir: String
    public let logDir: String
    private let preferredSchemaID: String
    private var currentPageSize: Int
    private var currentFuzzyNasal: Bool
    private var currentFuzzyRetroflex: Bool
    private var currentFuzzyNLAndFH: Bool

    public init(
        bundledDataDirectory: URL? = nil,
        userDataDirectory: URL? = nil,
        preferredSchemaID: String = "wanxiang",
        initialPreferences: SmartPinyinPreferences = .default
    ) {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(SmartPinyinIdentifiers.appSupportFolderName, isDirectory: true)

        let resolvedShared = Self.resolveSharedDataDir(bundled: bundledDataDirectory)
        let resolvedUser = userDataDirectory ?? appSupport.appendingPathComponent("RimeUserData", isDirectory: true)
        let resolvedLog = appSupport.appendingPathComponent("Logs", isDirectory: true)

        try? fm.createDirectory(at: resolvedUser, withIntermediateDirectories: true)
        try? fm.createDirectory(at: resolvedLog, withIntermediateDirectories: true)

        self.sharedDataDir = resolvedShared.path
        self.userDataDir = resolvedUser.path
        self.logDir = resolvedLog.path
        self.preferredSchemaID = preferredSchemaID
        self.currentPageSize = initialPreferences.candidatePageSize
        self.currentFuzzyNasal = initialPreferences.fuzzyNasalPinyin
        self.currentFuzzyRetroflex = initialPreferences.fuzzyRetroflexPinyin
        self.currentFuzzyNLAndFH = initialPreferences.fuzzyNLAndFHPinyin

        let yamlChanged = Self.writeCustomYAMLIfNeeded(
            in: resolvedUser,
            schemaID: preferredSchemaID,
            preferences: initialPreferences
        )

        self.handle = spm_rime_create(
            self.sharedDataDir,
            self.userDataDir,
            self.logDir,
            preferredSchemaID
        )
        if yamlChanged, let h = self.handle {
            _ = spm_rime_reload_user_config(h, preferredSchemaID)
        }
        applyRuntimeOptions(initialPreferences)
    }

    deinit {
        lock.lock()
        if let h = handle {
            spm_rime_destroy(h)
            handle = nil
        }
        lock.unlock()
    }

    public var activeSchemaID: String {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle, let ptr = spm_rime_current_schema(h) else { return "" }
        defer { free(ptr) }
        return String(cString: ptr)
    }

    public func processKey(keyval: Int32, mask: Int32) -> (handled: Bool, snapshot: PinyinEngineSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return (false, .idle) }
        let handled = spm_rime_process_key(h, keyval, mask)
        return (handled, captureSnapshotLocked(h))
    }

    public func selectCandidateOnCurrentPage(index: Int) -> PinyinEngineSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return .idle }
        _ = spm_rime_select_candidate_on_page(h, Int32(index))
        return captureSnapshotLocked(h)
    }

    public func selectCandidate(globalIndex: Int) -> PinyinEngineSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return .idle }
        _ = spm_rime_select_candidate(h, Int32(globalIndex))
        return captureSnapshotLocked(h)
    }

    public func changePage(forward: Bool) -> PinyinEngineSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return .idle }
        _ = spm_rime_change_page(h, !forward)
        return captureSnapshotLocked(h)
    }

    public func moveHighlight(delta: Int) -> PinyinEngineSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return .idle }
        let current = captureSnapshotLocked(h)
        guard !current.candidates.isEmpty else { return current }
        let nextIdx = max(0, min(current.candidates.count - 1, current.highlightedIndex + delta))
        _ = spm_rime_highlight_candidate_on_page(h, Int32(nextIdx))
        return captureSnapshotLocked(h)
    }

    public func commitComposition() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return nil }
        _ = spm_rime_commit_composition(h)
        let snap = captureSnapshotLocked(h)
        return snap.committedText
    }

    public func clearComposition() {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return }
        spm_rime_clear_composition(h)
    }

    public func currentSnapshot() -> PinyinEngineSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return .idle }
        return captureSnapshotLocked(h)
    }

    public func setOption(_ name: String, value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return }
        spm_rime_set_option(h, name, value)
    }

    public func probeCandidates(forPinyin pinyin: String, limit: Int) -> [PinyinCandidate] {
        let clean = pinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard !clean.isEmpty, limit > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return [] }
        var outCount: Int32 = 0
        guard let ptr = spm_rime_probe_candidates(h, clean, Int32(limit), &outCount), outCount > 0 else {
            return []
        }
        defer { spm_rime_free_candidates(ptr, outCount) }
        var out: [PinyinCandidate] = []
        out.reserveCapacity(Int(outCount))
        for i in 0..<Int(outCount) {
            let item = ptr[i]
            let text = item.text.map { String(cString: $0) } ?? ""
            guard !text.isEmpty else { continue }
            let comment = item.comment.map { String(cString: $0) }
            out.append(PinyinCandidate(index: i, text: text, comment: comment, source: .typoCorrected))
        }
        return out
    }

    public func probeSingleChars(forSyllable syllable: String, limit: Int = 63) -> [PinyinCandidate] {
        let clean = syllable.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard !clean.isEmpty, limit > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return [] }
        var outCount: Int32 = 0
        guard let ptr = spm_rime_probe_single_chars(h, clean, Int32(limit), &outCount), outCount > 0 else {
            return []
        }
        defer { spm_rime_free_candidates(ptr, outCount) }
        var out: [PinyinCandidate] = []
        out.reserveCapacity(Int(outCount))
        for i in 0..<Int(outCount) {
            let item = ptr[i]
            let text = item.text.map { String(cString: $0) } ?? ""
            guard !text.isEmpty else { continue }
            let comment = item.comment.map { String(cString: $0) }
            out.append(PinyinCandidate(index: i, text: text, comment: comment, source: .rime))
        }
        return out
    }

    /// 实时应用用户常用配置（开关项零延迟立即生效，每页候选数/模糊音变更时同步更新 YAML 并热重载会话）
    public func applyPreferences(_ prefs: SmartPinyinPreferences) {
        var needsReload = false
        lock.lock()
        if prefs.candidatePageSize != currentPageSize
            || prefs.fuzzyNasalPinyin != currentFuzzyNasal
            || prefs.fuzzyRetroflexPinyin != currentFuzzyRetroflex
            || prefs.fuzzyNLAndFHPinyin != currentFuzzyNLAndFH {
            currentPageSize = prefs.candidatePageSize
            currentFuzzyNasal = prefs.fuzzyNasalPinyin
            currentFuzzyRetroflex = prefs.fuzzyRetroflexPinyin
            currentFuzzyNLAndFH = prefs.fuzzyNLAndFHPinyin
            needsReload = true
        }
        lock.unlock()

        if needsReload {
            let userURL = URL(fileURLWithPath: userDataDir, isDirectory: true)
            _ = Self.writeCustomYAMLIfNeeded(
                in: userURL,
                schemaID: preferredSchemaID,
                preferences: prefs
            )
            lock.lock()
            if let h = handle {
                _ = spm_rime_reload_user_config(h, preferredSchemaID)
            }
            lock.unlock()
        }
        applyRuntimeOptions(prefs)
    }

    /// 词库更新/启停/导入后热重载用户词典配置（重新编译 RimeUserData 中的 wanxiang.dict.yaml 并恢复运行时选项）
    @discardableResult
    public func reloadUserDictionaries(preferences: SmartPinyinPreferences) -> Bool {
        let userURL = URL(fileURLWithPath: userDataDir, isDirectory: true)
        _ = Self.writeCustomYAMLIfNeeded(
            in: userURL,
            schemaID: preferredSchemaID,
            preferences: preferences
        )
        lock.lock()
        let ok: Bool
        if let h = handle {
            ok = spm_rime_reload_user_config(h, preferredSchemaID)
        } else {
            ok = false
        }
        lock.unlock()
        if ok {
            applyRuntimeOptions(preferences)
        }
        return ok
    }

    private func applyRuntimeOptions(_ prefs: SmartPinyinPreferences) {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return }
        spm_rime_set_option(h, "ascii_punct", !prefs.chinesePunctuation)
        spm_rime_set_option(h, "s2t", prefs.traditionalChinese)
        spm_rime_set_option(h, "s2s", !prefs.traditionalChinese)
        spm_rime_set_option(h, "emoji", prefs.enableEmojiCandidates)
        spm_rime_set_option(h, "abbrev", prefs.enableAbbrevPinyin)
    }

    // MARK: - 私有辅助

    private func captureSnapshotLocked(_ h: OpaquePointer) -> PinyinEngineSnapshot {
        var raw = spm_rime_get_snapshot(h)
        defer { spm_rime_free_snapshot(&raw) }

        let preedit = raw.preedit.map { String(cString: $0) } ?? ""
        let rawInput = raw.raw_input.map { String(cString: $0) } ?? ""
        let selectedPrefix = raw.selected_prefix.map { String(cString: $0) } ?? ""
        let commitText = raw.commit_text.map { String(cString: $0) }

        var list: [PinyinCandidate] = []
        if let ptr = raw.candidates, raw.num_candidates > 0 {
            let count = Int(raw.num_candidates)
            list.reserveCapacity(count)
            for i in 0..<count {
                let item = ptr[i]
                let text = item.text.map { String(cString: $0) } ?? ""
                let comment = item.comment.map { String(cString: $0) }
                list.append(PinyinCandidate(index: i, text: text, comment: comment, source: .rime))
            }
        }

        var extendedList: [PinyinCandidate] = []
        if let extPtr = raw.extended_candidates, raw.num_extended_candidates > 0 {
            let extCount = Int(raw.num_extended_candidates)
            extendedList.reserveCapacity(extCount)
            for i in 0..<extCount {
                let item = extPtr[i]
                let text = item.text.map { String(cString: $0) } ?? ""
                let comment = item.comment.map { String(cString: $0) }
                extendedList.append(
                    PinyinCandidate(
                        index: Int(item.global_index),
                        text: text,
                        comment: comment,
                        source: .rime
                    )
                )
            }
        }

        return PinyinEngineSnapshot(
            isComposing: raw.is_composing,
            preedit: preedit,
            rawInput: rawInput,
            selectedPrefix: selectedPrefix,
            candidates: list,
            extendedCandidates: extendedList,
            highlightedIndex: Int(raw.highlighted_index),
            pageNo: Int(raw.page_no),
            hasNextPage: !raw.is_last_page,
            committedText: commitText
        )
    }

    private static func resolveSharedDataDir(bundled: URL?) -> URL {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SMARTPINYIN_RIME_DATA_DIR"],
           fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if let bundled, fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        let cwdData = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/RimeData", isDirectory: true)
        if fm.fileExists(atPath: cwdData.path) {
            return cwdData
        }
        return appSupportFallback()
    }

    private static func appSupportFallback() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("\(SmartPinyinIdentifiers.appSupportFolderName)/RimeData", isDirectory: true)
    }

    /// 按当前偏好生成/增量更新 default.custom.yaml 与 wanxiang.custom.yaml（仅内容变化时写入并触发重建）：
    /// 激活万象全拼/简拼方案、用户词典动态调频、librime 原生自动纠错（enable_correction）与可配置模糊音规则
    @discardableResult
    private static func writeCustomYAMLIfNeeded(
        in userDir: URL,
        schemaID: String,
        preferences: SmartPinyinPreferences
    ) -> Bool {
        let clamped = min(9, max(5, preferences.candidatePageSize))
        var changed = false

        let defaultURL = userDir.appendingPathComponent("default.custom.yaml")
        let defaultContent = """
        patch:
          schema_list:
            - schema: \(schemaID)
          menu/page_size: \(clamped)
        """
        if (try? String(contentsOf: defaultURL, encoding: .utf8)) != defaultContent {
            try? defaultContent.write(to: defaultURL, atomically: true, encoding: .utf8)
            changed = true
        }

        var algebraRules: [String] = []
        if preferences.fuzzyNasalPinyin {
            // 前后鼻音模糊（作用于万象去声调后的全拼音节：an↔ang、ian↔iang、uan↔uang、en↔eng、in↔ing）
            algebraRules.append(contentsOf: [
                "    - derive/^([a-z]*)ang$/$1an/",
                "    - derive/^([a-z]*)an$/$1ang/",
                "    - derive/^([a-z]*)eng$/$1en/",
                "    - derive/^([a-z]*)en$/$1eng/",
                "    - derive/^([a-z]+)ing$/$1in/",
                "    - derive/^([a-z]+)in$/$1ing/"
            ])
        }
        if preferences.fuzzyRetroflexPinyin {
            // 平翘舌模糊（zh↔z、ch↔c、sh↔s，仅对去声调全拼音节派生，避免膨胀声调索引）
            algebraRules.append(contentsOf: [
                "    - derive/^zh([a-z]+)$/z$1/",
                "    - derive/^z([aeiouv][a-z]*)$/zh$1/",
                "    - derive/^ch([a-z]+)$/c$1/",
                "    - derive/^c([aeiouv][a-z]*)$/ch$1/",
                "    - derive/^sh([a-z]+)$/s$1/",
                "    - derive/^s([aeiouv][a-z]*)$/sh$1/"
            ])
        }
        if preferences.fuzzyNLAndFHPinyin {
            // n↔l 与 f↔h 模糊（仅对去声调全拼音节派生）
            algebraRules.append(contentsOf: [
                "    - derive/^n([a-z]+)$/l$1/",
                "    - derive/^l([a-z]+)$/n$1/",
                "    - derive/^f([a-z]+)$/h$1/",
                "    - derive/^h([a-z]+)$/f$1/"
            ])
        }

        let algebraBlock = algebraRules.isEmpty
            ? ""
            : "\n  speller/algebra/+:\n" + algebraRules.joined(separator: "\n")

        let schemaCustomURL = userDir.appendingPathComponent("\(schemaID).custom.yaml")
        // 注：关闭 librime 暴力全局 enable_correction（在万象大词库上会令 L1 P99 飙升 5× 且污染正常输入），
        // 改由「万象内建 50+ 零开销转置规则 + 上述模糊音 + SmartPinyinCore 音节级 DP 纠偏 + Shadow Probe」三层协同实现 < 1.5ms 精准纠偏。
        let schemaPatch = """
        patch:
          translator/enable_user_dict: true
          translator/enable_sentence: true
          translator/enable_encoder: true
          translator/encode_commit_history: true
          translator/contextual_suggestions: true
          translator/enable_correction: false
          super_processor/limit_repeated: "8,80"
          menu/page_size: \(clamped)\(algebraBlock)
        """
        if (try? String(contentsOf: schemaCustomURL, encoding: .utf8)) != schemaPatch {
            try? schemaPatch.write(to: schemaCustomURL, atomically: true, encoding: .utf8)
            changed = true
        }
        return changed
    }
}

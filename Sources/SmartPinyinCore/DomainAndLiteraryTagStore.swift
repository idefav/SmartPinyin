import Foundation
import SharedIPC

/// 高速离线语义与领域标签索引（128-bit 双 FNV-1a 排序哈希表）：
/// - 内置 `literary_tags.bin`（SMLT v1：约 32,000+ 成语 + 18,000+ 经典古诗词名句）
/// - 内置 `domain_tags.bin`（SMDM v1：游戏/数学/计算机/美术/科学/医学/财经法律多领域位掩码）
/// - 自动热加载用户在「词库与场景」启用/导入的外部领域侧车索引（`LexiconPacks/Tags/*.bin`）
/// - 整页 16 个候选查询耗时 < 0.015 ms，常驻内存 ~1.4 MB，支持繁体按需归一化兜底
public final class DomainAndLiteraryTagStore: @unchecked Sendable {
    public struct Hash128: Comparable, Hashable, Sendable {
        public let hi: UInt64
        public let lo: UInt64

        public init(hi: UInt64, lo: UInt64) {
            self.hi = hi
            self.lo = lo
        }

        public static func < (lhs: Hash128, rhs: Hash128) -> Bool {
            lhs.hi != rhs.hi ? lhs.hi < rhs.hi : lhs.lo < rhs.lo
        }
    }

    public struct DomainEntry: Sendable {
        public let hash: Hash128
        public let mask: UInt16
    }

    private let lock = NSLock()
    private var idiomHashes: [Hash128] = []
    private var poetryHashes: [Hash128] = []
    private var baseDomainEntries: [DomainEntry] = []
    /// 用户动态启用/导入词库生成的额外领域映射（支持 0ms 热更新，不重写内置表）
    private var userDomainMap: [Hash128: UInt16] = [:]
    private var traditionalToSimplifiedCache: [String: String] = [:]
    private let userTagsDirectory: URL?

    public var idiomCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return idiomHashes.count
    }

    public var poetryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return poetryHashes.count
    }

    public var domainEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return baseDomainEntries.count + userDomainMap.count
    }

    /// 内存构造器（供单元测试与轻量注入使用）
    public init(
        idioms: [String] = [],
        poetry: [String] = [],
        domainTerms: [String: UInt16] = [:],
        userTagsDirectory: URL? = nil
    ) {
        self.userTagsDirectory = userTagsDirectory
        self.idiomHashes = Array(Set(idioms.map(Self.hash128))).sorted()
        self.poetryHashes = Array(Set(poetry.map(Self.hash128))).sorted()
        var merged: [Hash128: UInt16] = [:]
        for (term, mask) in domainTerms where mask != 0 {
            let h = Self.hash128(term)
            merged[h, default: 0] |= mask
        }
        self.baseDomainEntries = merged
            .map { DomainEntry(hash: $0.key, mask: $0.value) }
            .sorted { $0.hash < $1.hash }
        if userTagsDirectory != nil {
            reloadUserSidecarTags()
        }
    }

    /// 从二进制索引目录加载（优先 Bundle.main/Resources/Lexicon -> 环境变量 -> 源码 Resources/Lexicon）
    public static func loadBundled(
        lexiconDirectory: URL? = nil,
        userTagsDirectory: URL? = nil
    ) -> DomainAndLiteraryTagStore {
        let resolvedDir = resolveLexiconDirectory(explicit: lexiconDirectory)
        let resolvedUserTags = userTagsDirectory ?? defaultUserTagsDirectory()
        let store = DomainAndLiteraryTagStore(userTagsDirectory: resolvedUserTags)
        if let dir = resolvedDir {
            let litURL = dir.appendingPathComponent("literary_tags.bin")
            let domURL = dir.appendingPathComponent("domain_tags.bin")
            store.loadLiteraryBinary(from: litURL)
            store.loadBaseDomainBinary(from: domURL)
        }
        store.reloadUserSidecarTags()
        return store
    }

    /// 与 scripts/build-literary-lexicon.py bit-exact 一致的 128-bit 双 FNV-1a 哈希
    public static func hash128(_ text: String) -> Hash128 {
        let bytes = Array(text.utf8)
        let prime: UInt64 = 0x100000001b3
        var hi: UInt64 = 0xcbf29ce484222325
        for b in bytes {
            hi = (hi ^ UInt64(b)) &* prime
        }
        var lo: UInt64 = 0x84222325cbf29ce4
        for b in bytes.reversed() {
            lo = (lo ^ UInt64(b)) &* prime
        }
        lo ^= UInt64(bytes.count) &* 0x9e3779b97f4a7c15
        return Hash128(hi: hi, lo: lo)
    }

    /// 查词是否属于经典诗词或标准成语（0 误标，2–3 字日常词 O(1) 跳过）
    public func literaryCategory(
        for text: String,
        allowTraditionalFallback: Bool = false
    ) -> CandidateCategory? {
        let len = text.count
        guard len >= 4 && len <= 14 else { return nil }
        if let direct = lookupLiteraryHash(Self.hash128(text)) {
            return direct
        }
        guard allowTraditionalFallback else { return nil }
        let simplified = toSimplifiedCached(text)
        guard simplified != text else { return nil }
        return lookupLiteraryHash(Self.hash128(simplified))
    }

    /// 查询词条的多领域位掩码（0 表示通用词条；支持一词多领域，如「光追」同时命中 gaming | artDesign）
    public func domainMask(
        for text: String,
        allowTraditionalFallback: Bool = false
    ) -> UInt16 {
        let len = text.count
        guard len >= 2 && len <= 14 else { return 0 }
        let direct = lookupDomainHash(Self.hash128(text))
        if direct != 0 { return direct }
        guard allowTraditionalFallback else { return 0 }
        let simplified = toSimplifiedCached(text)
        guard simplified != text else { return 0 }
        return lookupDomainHash(Self.hash128(simplified))
    }

    /// 为当前页 5–9 个可见候选附加正交语义/领域分类（不改变 CandidateSource、不改变排序）
    public func annotate(
        _ candidates: [PinyinCandidate],
        activeScene: InputSceneDomain,
        showLiteraryBadges: Bool,
        showDomainBadges: Bool,
        allowTraditionalFallback: Bool
    ) -> [PinyinCandidate] {
        guard showLiteraryBadges || (showDomainBadges && activeScene != .general) else {
            return candidates
        }
        var result: [PinyinCandidate] = []
        result.reserveCapacity(candidates.count)
        for cand in candidates {
            if cand.category != nil {
                result.append(cand)
                continue
            }
            var resolved: CandidateCategory?
            if showLiteraryBadges {
                resolved = literaryCategory(for: cand.text, allowTraditionalFallback: allowTraditionalFallback)
            }
            if resolved == nil, showDomainBadges, activeScene != .general, activeScene != .literature {
                let mask = domainMask(for: cand.text, allowTraditionalFallback: allowTraditionalFallback)
                if (mask & activeScene.bitMask) != 0 {
                    resolved = CandidateCategory.fromSceneDomain(activeScene)
                }
            }
            if let resolved {
                result.append(PinyinCandidate(
                    index: cand.index,
                    text: cand.text,
                    comment: cand.comment,
                    source: cand.source,
                    category: resolved
                ))
            } else {
                result.append(cand)
            }
        }
        return result
    }

    /// 热重载用户通过「词库与场景」下载或导入的领域侧车标签索引（支持 `.bin` SMDM v1）
    public func reloadUserSidecarTags() {
        guard let dir = userTagsDirectory else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            lock.lock()
            userDomainMap.removeAll(keepingCapacity: true)
            lock.unlock()
            return
        }
        var merged: [Hash128: UInt16] = [:]
        for fileURL in files where fileURL.pathExtension == "bin" {
            if let entries = Self.parseDomainBinary(at: fileURL) {
                for e in entries where e.mask != 0 {
                    merged[e.hash, default: 0] |= e.mask
                }
            }
        }
        lock.lock()
        userDomainMap = merged
        lock.unlock()
    }

    /// 将词表写出为标准 SMDM v1 二进制侧车文件（供 LexiconManager 启用/导入领域词库时调用）
    public static func writeDomainBinary(terms: [String], domainMask: UInt16, to url: URL) throws {
        guard domainMask != 0 else { return }
        var byHash: [Hash128: UInt16] = [:]
        byHash.reserveCapacity(terms.count)
        for t in terms {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 && trimmed.count <= 14 else { continue }
            let h = hash128(trimmed)
            byHash[h, default: 0] |= domainMask
        }
        let sorted = byHash.sorted { $0.key < $1.key }
        var data = Data(capacity: 16 + sorted.count * 20)
        data.append(contentsOf: [0x53, 0x4D, 0x44, 0x4D]) // "SMDM"
        appendLE(UInt32(1), to: &data)
        appendLE(UInt32(sorted.count), to: &data)
        appendLE(UInt32(0), to: &data)
        for (h, mask) in sorted {
            appendLE(h.hi, to: &data)
            appendLE(h.lo, to: &data)
            appendLE(mask, to: &data)
            appendLE(UInt16(0), to: &data)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 私有查找与二进制解析

    private func lookupLiteraryHash(_ h: Hash128) -> CandidateCategory? {
        lock.lock()
        defer { lock.unlock() }
        if binarySearch(idiomHashes, target: h) {
            return .idiom
        }
        if binarySearch(poetryHashes, target: h) {
            return .poetry
        }
        return nil
    }

    private func lookupDomainHash(_ h: Hash128) -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        var mask: UInt16 = 0
        if let base = binarySearchDomain(baseDomainEntries, target: h) {
            mask |= base
        }
        if let extra = userDomainMap[h] {
            mask |= extra
        }
        // 文学场景无缝联动诗词/成语索引（无需在 domain_tags.bin 重复存储 5 万词！）
        if binarySearch(idiomHashes, target: h) || binarySearch(poetryHashes, target: h) {
            mask |= InputSceneDomain.literature.bitMask
        }
        return mask
    }

    private func binarySearch(_ arr: [Hash128], target: Hash128) -> Bool {
        var lo = 0
        var hi = arr.count - 1
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            let cur = arr[mid]
            if cur == target { return true }
            if cur < target {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return false
    }

    private func binarySearchDomain(_ arr: [DomainEntry], target: Hash128) -> UInt16? {
        var lo = 0
        var hi = arr.count - 1
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            let cur = arr[mid].hash
            if cur == target { return arr[mid].mask }
            if cur < target {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return nil
    }

    private func toSimplifiedCached(_ text: String) -> String {
        lock.lock()
        if let hit = traditionalToSimplifiedCache[text] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
        let simplified = mutable as String

        lock.lock()
        if traditionalToSimplifiedCache.count >= 256 {
            traditionalToSimplifiedCache.removeAll(keepingCapacity: true)
        }
        traditionalToSimplifiedCache[text] = simplified
        lock.unlock()
        return simplified
    }

    private func loadLiteraryBinary(from url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 16
        else { return }
        guard data[0] == 0x53, data[1] == 0x4D, data[2] == 0x4C, data[3] == 0x54 else { return } // "SMLT"
        let version = Self.readUInt32LE(data, at: 4)
        guard version == 1 else { return }
        let idiomCount = Int(Self.readUInt32LE(data, at: 8))
        let poetryCount = Int(Self.readUInt32LE(data, at: 12))
        let expectedBytes = 16 + (idiomCount + poetryCount) * 16
        guard data.count >= expectedBytes else { return }

        var idioms: [Hash128] = []
        idioms.reserveCapacity(idiomCount)
        var offset = 16
        for _ in 0..<idiomCount {
            let hi = Self.readUInt64LE(data, at: offset)
            let lo = Self.readUInt64LE(data, at: offset + 8)
            idioms.append(Hash128(hi: hi, lo: lo))
            offset += 16
        }

        var poems: [Hash128] = []
        poems.reserveCapacity(poetryCount)
        for _ in 0..<poetryCount {
            let hi = Self.readUInt64LE(data, at: offset)
            let lo = Self.readUInt64LE(data, at: offset + 8)
            poems.append(Hash128(hi: hi, lo: lo))
            offset += 16
        }

        lock.lock()
        self.idiomHashes = idioms
        self.poetryHashes = poems
        lock.unlock()
    }

    private func loadBaseDomainBinary(from url: URL) {
        guard let entries = Self.parseDomainBinary(at: url) else { return }
        lock.lock()
        self.baseDomainEntries = entries
        lock.unlock()
    }

    private static func parseDomainBinary(at url: URL) -> [DomainEntry]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 16
        else { return nil }
        guard data[0] == 0x53, data[1] == 0x4D, data[2] == 0x44, data[3] == 0x4D else { return nil } // "SMDM"
        let version = readUInt32LE(data, at: 4)
        guard version == 1 else { return nil }
        let count = Int(readUInt32LE(data, at: 8))
        let expectedBytes = 16 + count * 20
        guard data.count >= expectedBytes else { return nil }

        var entries: [DomainEntry] = []
        entries.reserveCapacity(count)
        var offset = 16
        for _ in 0..<count {
            let hi = readUInt64LE(data, at: offset)
            let lo = readUInt64LE(data, at: offset + 8)
            let mask = readUInt16LE(data, at: offset + 16)
            entries.append(DomainEntry(hash: Hash128(hi: hi, lo: lo), mask: mask))
            offset += 20
        }
        return entries
    }

    private static func resolveLexiconDirectory(explicit: URL?) -> URL? {
        let fm = FileManager.default
        if let explicit, fm.fileExists(atPath: explicit.path) {
            return explicit
        }
        if let env = ProcessInfo.processInfo.environment["SMARTPINYIN_LEXICON_DIR"],
           !env.isEmpty, fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Lexicon", isDirectory: true),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        let cwdLex = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/Lexicon", isDirectory: true)
        if fm.fileExists(atPath: cwdLex.path) {
            return cwdLex
        }
        // 源码测试包路径回落
        let sourceFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Lexicon", isDirectory: true)
        if fm.fileExists(atPath: sourceFallback.path) {
            return sourceFallback
        }
        return nil
    }

    public static func defaultUserTagsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(SmartPinyinIdentifiers.appSupportFolderName, isDirectory: true)
            .appendingPathComponent("LexiconPacks/Tags", isDirectory: true)
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        var val: UInt64 = 0
        for i in 0..<8 {
            val |= UInt64(data[offset + i]) << (UInt64(i) * 8)
        }
        return val
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}

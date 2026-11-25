import Foundation

/// 离线中文拼音与简拼首字母归一化器：
/// - 基于 macOS CoreFoundation `CFStringTransform`（零模型内存、100% 离线）
/// - 内置高频多音字映射表，确保「重排/银行/音乐/调度/长度」等词在全拼与简拼下均可精准命中
/// - 支持英文驼峰与下划线标识符简拼提取（如 `SmartPinyinInputController` → `spic`、`smart`）
public final class PinyinNormalizer: @unchecked Sendable {
    public struct TermPinyinKeys: Sendable {
        /// 全部可能的全拼变体（去空格小写，如 ["chongpai", "zhongpai"]）
        public let fullVariants: [String]
        /// 全部可能的声母/首字母简拼变体（如 ["cp", "zp"]）
        public let initialVariants: [String]
        /// 主拼音音节序列（用于音节前缀模糊匹配，如 ["pian", "hao", "ji", "yi"]）
        public let primarySyllables: [String]
    }

    /// 统一中文拼音/简拼/混合音节链匹配结果（DocumentContextIndex 与 SessionWorkingMemory 的单一真相源）
    public struct ChinesePinyinMatch: Equatable, Sendable {
        /// 匹配强度（0 表示未命中，最高 1.90）
        public let strength: Double
        /// 词条是否合理覆盖当前整段查询拼音（防止短/失配合成候选触发 clearComposition 误吞长句尾段）
        public let coversFullQuery: Bool

        public static let none = ChinesePinyinMatch(strength: 0, coversFullQuery: false)

        public init(strength: Double, coversFullQuery: Bool) {
            self.strength = strength
            self.coversFullQuery = coversFullQuery
        }
    }

    /// 评估一段纯小写拼音查询对中文词条拼音键的匹配度与覆盖度
    public static func matchChinese(query: String, keys: TermPinyinKeys) -> ChinesePinyinMatch {
        guard !query.isEmpty, !keys.fullVariants.isEmpty else { return .none }

        // 1. 精确全拼命中
        if keys.fullVariants.contains(query) {
            return ChinesePinyinMatch(strength: 1.90, coversFullQuery: true)
        }
        // 2. 精确简拼命中（如 phjy -> 偏好记忆，cp -> 重排，xtwt -> 系统问题）
        if query.count >= 2 && keys.initialVariants.contains(query) {
            return ChinesePinyinMatch(strength: 1.60, coversFullQuery: true)
        }
        // 3. 全拼前缀匹配（如 shenm -> shenme「什么」），增加覆盖率门槛防 2 字母误命中 6 字长短语
        if query.count >= 2 {
            var bestFull: ChinesePinyinMatch?
            for full in keys.fullVariants where full.hasPrefix(query) {
                let coverage = Double(query.count) / Double(max(query.count, full.count))
                guard coverage >= 0.45 || (query.count >= 4 && coverage >= 0.35) else { continue }
                let candidate = ChinesePinyinMatch(
                    strength: 0.95 + 0.65 * coverage,
                    coversFullQuery: coverage >= 0.55
                )
                if bestFull == nil || candidate.strength > bestFull!.strength {
                    bestFull = candidate
                }
            }
            if let bestFull { return bestFull }
        }
        // 4. 简拼前缀匹配（单字母仅用于配合强锚点接续且限 2~3 字词；多字母要求 >= 50% 覆盖）
        var bestInit: ChinesePinyinMatch?
        for initKey in keys.initialVariants where initKey.hasPrefix(query) {
            if query.count == 1 {
                let candidate = ChinesePinyinMatch(strength: 0.70, coversFullQuery: initKey.count <= 3)
                if bestInit == nil || candidate.strength > bestInit!.strength {
                    bestInit = candidate
                }
                continue
            }
            let coverage = Double(query.count) / Double(max(query.count, initKey.count))
            guard coverage >= 0.50 else { continue }
            let candidate = ChinesePinyinMatch(
                strength: 0.85 + 0.50 * coverage,
                coversFullQuery: coverage >= 0.65
            )
            if bestInit == nil || candidate.strength > bestInit!.strength {
                bestInit = candidate
            }
        }
        if let bestInit { return bestInit }

        // 5. 逐音节混合缩写匹配（如 pianhj -> ["pian","hao","ji","yi"]），要求覆盖 >= 60% 音节
        if query.count >= 3,
           !keys.primarySyllables.isEmpty,
           let consumed = matchedSyllableCount(query: query, syllables: keys.primarySyllables) {
            let ratio = Double(consumed) / Double(keys.primarySyllables.count)
            if ratio >= 0.60 {
                return ChinesePinyinMatch(
                    strength: 1.00 + 0.38 * ratio,
                    coversFullQuery: consumed == keys.primarySyllables.count || ratio >= 0.75
                )
            }
        }
        return .none
    }

    private static func matchedSyllableCount(query: String, syllables: [String]) -> Int? {
        let qChars = Array(query)
        let sylArrays = syllables.map { Array($0) }
        var bestConsumed: Int?

        func dfs(qi: Int, si: Int) {
            if qi == qChars.count {
                if bestConsumed == nil || si > bestConsumed! {
                    bestConsumed = si
                }
                return
            }
            if si == sylArrays.count { return }
            let syl = sylArrays[si]
            guard !syl.isEmpty, qChars[qi] == syl[0] else { return }
            let remaining = qChars.count - qi
            // 可消费完整音节
            if remaining >= syl.count && Array(qChars[qi..<(qi + syl.count)]) == syl {
                dfs(qi: qi + syl.count, si: si + 1)
            }
            // 可消费该音节的不完整前缀（作为整串查询的结尾，如 "xitongwent" 末尾 "went"）
            if remaining > 1 && remaining < syl.count && Array(syl[0..<remaining]) == Array(qChars[qi..<qChars.count]) {
                dfs(qi: qChars.count, si: si + 1)
            }
            // 或消费单个首字母
            dfs(qi: qi + 1, si: si + 1)
        }

        dfs(qi: 0, si: 0)
        return bestConsumed
    }

    private let lock = NSLock()
    private var charCache: [Character: [String]] = [:]

    /// 高频易误判多音字表（按日常与技术场景出现频次排列）
    private static let polyphones: [Character: [String]] = [
        "重": ["chong", "zhong"],
        "行": ["hang", "xing"],
        "乐": ["yue", "le"],
        "长": ["chang", "zhang"],
        "调": ["tiao", "diao"],
        "数": ["shu"],
        "参": ["can", "shen"],
        "校": ["xiao", "jiao"],
        "传": ["chuan", "zhuan"],
        "率": ["lv", "shuai"],
        "差": ["cha", "chai"],
        "朝": ["chao", "zhao"],
        "称": ["cheng", "chen"],
        "处": ["chu"],
        "单": ["dan", "shan"],
        "的": ["de", "di"],
        "得": ["de", "dei"],
        "地": ["di", "de"],
        "都": ["dou", "du"],
        "度": ["du", "duo"],
        "查": ["cha", "zha"],
        "秘": ["mi", "bi"],
        "发": ["fa"],
        "干": ["gan"],
        "给": ["gei", "ji"],
        "更": ["geng"],
        "供": ["gong"],
        "观": ["guan"],
        "还": ["hai", "huan"],
        "好": ["hao"],
        "号": ["hao"],
        "和": ["he", "huo"],
        "划": ["hua"],
        "会": ["hui", "kuai"],
        "混": ["hun"],
        "积": ["ji"],
        "奇": ["qi", "ji"],
        "系": ["xi", "ji"],
        "假": ["jia"],
        "间": ["jian"],
        "将": ["jiang"],
        "降": ["jiang", "xiang"],
        "角": ["jiao", "jue"],
        "觉": ["jue", "jiao"],
        "解": ["jie"],
        "尽": ["jin"],
        "禁": ["jin"],
        "据": ["ju"],
        "卡": ["ka", "qia"],
        "看": ["kan"],
        "空": ["kong"],
        "累": ["lei"],
        "量": ["liang"],
        "了": ["le", "liao"],
        "落": ["luo", "la"],
        "没": ["mei", "mo"],
        "模": ["mo", "mu"],
        "难": ["nan"],
        "宁": ["ning"],
        "排": ["pai"],
        "便": ["bian", "pian"],
        "切": ["qie"],
        "区": ["qu"],
        "曲": ["qu"],
        "圈": ["quan"],
        "任": ["ren"],
        "塞": ["sai", "se"],
        "散": ["san"],
        "舍": ["she"],
        "省": ["sheng", "xing"],
        "盛": ["sheng", "cheng"],
        "识": ["shi"],
        "似": ["si", "shi"],
        "宿": ["su", "xiu"],
        "弹": ["tan", "dan"],
        "提": ["ti"],
        "通": ["tong"],
        "吐": ["tu"],
        "为": ["wei"],
        "相": ["xiang"],
        "兴": ["xing"],
        "削": ["xue", "xiao"],
        "血": ["xue", "xie"],
        "压": ["ya"],
        "要": ["yao"],
        "应": ["ying"],
        "与": ["yu"],
        "载": ["zai"],
        "藏": ["cang", "zang"],
        "择": ["ze", "zhai"],
        "增": ["zeng"],
        "占": ["zhan"],
        "着": ["zhe", "zhao", "zhuo"],
        "正": ["zheng"],
        "只": ["zhi"],
        "中": ["zhong"],
        "种": ["zhong"],
        "转": ["zhuan"],
        "综": ["zong"]
    ]

    public init() {}

    public func keys(forChineseTerm term: String) -> TermPinyinKeys {
        var perCharOptions: [[String]] = []
        perCharOptions.reserveCapacity(term.count)

        for ch in term {
            let readings = readingsForChar(ch)
            if !readings.isEmpty {
                perCharOptions.append(readings)
            }
        }
        guard !perCharOptions.isEmpty else {
            return TermPinyinKeys(fullVariants: [], initialVariants: [], primarySyllables: [])
        }

        let primarySyllables = perCharOptions.map { $0[0] }

        // 控制多音字笛卡尔积上限（最多 8 种组合），防止长词组合爆炸
        var fullCombos: [String] = [""]
        var initCombos: [String] = [""]

        for options in perCharOptions {
            let cappedOptions = Array(options.prefix(2))
            if fullCombos.count * cappedOptions.count <= 8 {
                var nextFull: [String] = []
                var nextInit: [String] = []
                for idx in 0..<fullCombos.count {
                    for opt in cappedOptions {
                        nextFull.append(fullCombos[idx] + opt)
                        if let first = opt.first {
                            nextInit.append(initCombos[idx] + String(first))
                        } else {
                            nextInit.append(initCombos[idx])
                        }
                    }
                }
                fullCombos = nextFull
                initCombos = nextInit
            } else {
                let firstOpt = cappedOptions[0]
                let firstChar = firstOpt.first.map(String.init) ?? ""
                fullCombos = fullCombos.map { $0 + firstOpt }
                initCombos = initCombos.map { $0 + firstChar }
            }
        }

        return TermPinyinKeys(
            fullVariants: Self.uniqueOrdered(fullCombos),
            initialVariants: Self.uniqueOrdered(initCombos),
            primarySyllables: primarySyllables
        )
    }

    /// 提取中英混合或纯中文词条的统一拼音键（如 `"git地址"` -> `fullVariants: ["gitdizhi"]`, `initialVariants: ["gitdz"]`, `primarySyllables: ["git", "di", "zhi"]`）：
    /// - 连续 ASCII 英文段作为完整音节保留（全拼与简拼中英文段均保留原英文串，以便 `gitdz` / `gitdiz` / `reactzj` 精准命中）
    /// - 汉字按 `readingsForChar` 展开（含多音字）
    public func keys(forMixedTerm term: String) -> TermPinyinKeys {
        let hasASCII = term.unicodeScalars.contains {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }
        guard hasASCII else {
            return keys(forChineseTerm: term)
        }

        var unitOptions: [(readings: [String], isASCII: Bool)] = []
        var asciiBuf = ""
        func flushASCII() {
            guard !asciiBuf.isEmpty else { return }
            unitOptions.append(([asciiBuf.lowercased()], true))
            asciiBuf = ""
        }

        for ch in term {
            if let scalar = ch.unicodeScalars.first,
               (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) {
                asciiBuf.append(ch)
            } else {
                flushASCII()
                let isCJK = ch.unicodeScalars.contains {
                    (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
                }
                if isCJK {
                    let readings = readingsForChar(ch)
                    if !readings.isEmpty {
                        unitOptions.append((readings, false))
                    }
                }
            }
        }
        flushASCII()

        guard !unitOptions.isEmpty else {
            return TermPinyinKeys(fullVariants: [], initialVariants: [], primarySyllables: [])
        }

        let primarySyllables = unitOptions.map { $0.readings[0] }
        var fullCombos: [String] = [""]
        var initCombos: [String] = [""]

        for unit in unitOptions {
            let capped = Array(unit.readings.prefix(2))
            if fullCombos.count * capped.count <= 8 {
                var nextFull: [String] = []
                var nextInit: [String] = []
                for idx in 0..<fullCombos.count {
                    for opt in capped {
                        nextFull.append(fullCombos[idx] + opt)
                        if unit.isASCII {
                            // 混输简拼保留英文段本身（如 git地址 -> gitdz、React组件 -> reactzj）
                            nextInit.append(initCombos[idx] + opt)
                        } else if let first = opt.first {
                            nextInit.append(initCombos[idx] + String(first))
                        } else {
                            nextInit.append(initCombos[idx])
                        }
                    }
                }
                fullCombos = nextFull
                initCombos = nextInit
            } else {
                let firstOpt = capped[0]
                let initPart = unit.isASCII ? firstOpt : (firstOpt.first.map(String.init) ?? "")
                fullCombos = fullCombos.map { $0 + firstOpt }
                initCombos = initCombos.map { $0 + initPart }
            }
        }

        return TermPinyinKeys(
            fullVariants: Self.uniqueOrdered(fullCombos),
            initialVariants: Self.uniqueOrdered(initCombos),
            primarySyllables: primarySyllables
        )
    }

    private static func uniqueOrdered(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(items.count)
        for item in items where seen.insert(item).inserted {
            result.append(item)
        }
        return result
    }

    /// 提取英文/代码标识符的匹配键（全小写 + 驼峰/下划线首字母简拼）
    public func keys(forEnglishIdentifier token: String) -> (lower: String, initials: String) {
        let lower = token.lowercased()
        var parts: [String] = []
        var current = ""

        for ch in token {
            if ch == "_" || ch == "-" || ch == "." || ch == "/" {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                continue
            }
            if ch.isUppercase && !current.isEmpty && current.last?.isLowercase == true {
                parts.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            parts.append(current)
        }
        let initials = parts.compactMap { $0.first?.lowercased() }.joined()
        return (lower, initials)
    }

    private func readingsForChar(_ ch: Character) -> [String] {
        if let known = Self.polyphones[ch] {
            return known
        }
        lock.lock()
        if let cached = charCache[ch] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let mutable = NSMutableString(string: String(ch)) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let cleaned = (mutable as String)
            .lowercased()
            .filter { $0 >= "a" && $0 <= "z" }
        let result = cleaned.isEmpty ? [] : [cleaned]

        lock.lock()
        if charCache.count > 6000 {
            charCache.removeAll(keepingCapacity: true)
        }
        charCache[ch] = result
        lock.unlock()
        return result
    }
}

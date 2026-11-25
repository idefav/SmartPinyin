import Foundation

/// Rime preedit 切分健康度诊断结果（用于精准识别错拼碎裂，避免误伤正常全拼与短简拼）
public struct PinyinSegmentationDiagnosis: Equatable, Sendable {
    public let segmentCount: Int
    public let singleCharFragmentCount: Int
    public let hasIllegalDoubleLetter: Bool
    /// 是否存在明显错拼碎裂（如 shaighai -> "s hai g hai" 含悬空辅音碎片 s、g）
    public let isFragmented: Bool
    /// 是否为纯全简拼（如 zgr / xtwt / phjy，每个片段都是单字母，绝不破坏性改写）
    public let isPureAbbreviation: Bool

    public init(
        segmentCount: Int,
        singleCharFragmentCount: Int,
        hasIllegalDoubleLetter: Bool,
        isFragmented: Bool,
        isPureAbbreviation: Bool
    ) {
        self.segmentCount = segmentCount
        self.singleCharFragmentCount = singleCharFragmentCount
        self.hasIllegalDoubleLetter = hasIllegalDoubleLetter
        self.isFragmented = isFragmented
        self.isPureAbbreviation = isPureAbbreviation
    }
}

/// 音节级拼音纠偏建议
public struct PinyinCorrectionSuggestion: Equatable, Sendable {
    public let correctedPinyin: String
    public let syllables: [String]
    /// 编辑代价（越低越可信：0.40 去连键 / 0.50 转置 / 0.60 邻键 / 0.85 补漏键 / 0.95 跨排误触）
    public let editCost: Double
    /// 是否由原输入的明显碎裂切分触发（true 时高置信纠偏候选可直接置顶第 1 位）
    public let isFragmentedSource: Bool

    public init(
        correctedPinyin: String,
        syllables: [String],
        editCost: Double,
        isFragmentedSource: Bool
    ) {
        self.correctedPinyin = correctedPinyin
        self.syllables = syllables
        self.editCost = editCost
        self.isFragmentedSource = isFragmentedSource
    }
}

/// 音节级动态规划拼音自动纠偏器（纯 Swift 内存计算，< 0.5ms，零模型内存）：
/// - 内置完整 ~410 个现代汉语合法拼音音节表 + QWERTY 键盘坐标距离表
/// - 精准覆盖 librime 原生 enable_correction 无法覆盖的错拼：
///   1. 跨排/同手误触替换（如 shaighai [i→n] → shanghai）
///   2. 相邻字母倒序（shnaghai / shagnhai → shanghai，nihoa → nihao，womne → women）
///   3. 多敲重复连键（shanghaii / sshanghai → shanghai）
///   4. 漏敲鼻音尾/元音（shnghai → shanghai，shanhai → shanghai）
/// - 严格通过 DP 完整无碎片音节切分剪枝，确保 0 噪声且不误伤短简拼（nh / zgr / wsm / xtwt）
public final class PinyinTypoCorrector: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: [PinyinCorrectionSuggestion]] = [:]
    private var cacheOrder: [String] = []
    private let cacheCapacity = 128

    public init() {}

    /// 现代汉语完整合法无调拼音音节表（~410 个标准音节）
    public static let validSyllables: Set<String> = [
        "a", "ai", "an", "ang", "ao",
        "ba", "bai", "ban", "bang", "bao", "bei", "ben", "beng", "bi", "bian", "biao", "bie", "bin", "bing", "bo", "bu",
        "ca", "cai", "can", "cang", "cao", "ce", "cen", "ceng",
        "cha", "chai", "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong", "chou", "chu", "chua", "chuai", "chuan", "chuang", "chui", "chun", "chuo",
        "ci", "cong", "cou", "cu", "cuan", "cui", "cun", "cuo",
        "da", "dai", "dan", "dang", "dao", "de", "dei", "den", "deng", "di", "dia", "dian", "diao", "die", "ding", "diu", "dong", "dou", "du", "duan", "dui", "dun", "duo",
        "e", "ei", "en", "eng", "er",
        "fa", "fan", "fang", "fei", "fen", "feng", "fo", "fou", "fu",
        "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong", "gou", "gu", "gua", "guai", "guan", "guang", "gui", "gun", "guo",
        "ha", "hai", "han", "hang", "hao", "he", "hei", "hen", "heng", "hong", "hou", "hu", "hua", "huai", "huan", "huang", "hui", "hun", "huo",
        "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiong", "jiu", "ju", "juan", "jue", "jun",
        "ka", "kai", "kan", "kang", "kao", "ke", "kei", "ken", "keng", "kong", "kou", "ku", "kua", "kuai", "kuan", "kuang", "kui", "kun", "kuo",
        "la", "lai", "lan", "lang", "lao", "le", "lei", "leng", "li", "lia", "lian", "liang", "liao", "lie", "lin", "ling", "liu", "lo", "long", "lou", "lu", "luan", "lue", "lun", "luo", "lv", "lve",
        "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi", "mian", "miao", "mie", "min", "ming", "miu", "mo", "mou", "mu",
        "na", "nai", "nan", "nang", "nao", "ne", "nei", "nen", "neng", "ni", "nian", "niang", "niao", "nie", "nin", "ning", "niu", "nong", "nou", "nu", "nuan", "nue", "nun", "nuo", "nv", "nve",
        "o", "ou",
        "pa", "pai", "pan", "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie", "pin", "ping", "po", "pou", "pu",
        "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiong", "qiu", "qu", "quan", "que", "qun",
        "ran", "rang", "rao", "re", "ren", "reng", "ri", "rong", "rou", "ru", "rua", "ruan", "rui", "run", "ruo",
        "sa", "sai", "san", "sang", "sao", "se", "sen", "seng",
        "sha", "shai", "shan", "shang", "shao", "she", "shei", "shen", "sheng", "shi", "shou", "shu", "shua", "shuai", "shuan", "shuang", "shui", "shun", "shuo",
        "si", "song", "sou", "su", "suan", "sui", "sun", "suo",
        "ta", "tai", "tan", "tang", "tao", "te", "tei", "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu", "tuan", "tui", "tun", "tuo",
        "wa", "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu",
        "xi", "xia", "xian", "xiang", "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun",
        "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yo", "yong", "you", "yu", "yuan", "yue", "yun",
        "za", "zai", "zan", "zang", "zao", "ze", "zei", "zen", "zeng",
        "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhei", "zhen", "zheng", "zhi", "zhong", "zhou", "zhu", "zhua", "zhuai", "zhuan", "zhuang", "zhui", "zhun", "zhuo",
        "zi", "zong", "zou", "zu", "zuan", "zui", "zun", "zuo"
    ]

    /// QWERTY 键盘二维坐标（用于计算物理邻键与跨排同手误触代价）
    private static let keyCoords: [Character: (row: Double, col: Double)] = [
        "q": (0, 0.0), "w": (0, 1.0), "e": (0, 2.0), "r": (0, 3.0), "t": (0, 4.0),
        "y": (0, 5.0), "u": (0, 6.0), "i": (0, 7.0), "o": (0, 8.0), "p": (0, 9.0),
        "a": (1, 0.25), "s": (1, 1.25), "d": (1, 2.25), "f": (1, 3.25), "g": (1, 4.25),
        "h": (1, 5.25), "j": (1, 6.25), "k": (1, 7.25), "l": (1, 8.25),
        "z": (2, 0.75), "x": (2, 1.75), "c": (2, 2.75), "v": (2, 3.75), "b": (2, 4.75),
        "n": (2, 5.75), "m": (2, 6.75)
    ]

    /// 高频盲打替换候选映射（邻键 + 右手/左手高频跨排误触，如 i↔n、u↔n、a↔e、o↔i 等）
    private static let substitutionMap: [Character: [(Character, Double)]] = {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        // 高频非物理邻键手滑对（如截图 3 中的 shaighai: i↔n）
        let extraPairs: [Character: [(Character, Double)]] = [
            "i": [("n", 0.90), ("a", 1.05)],
            "n": [("i", 0.90), ("u", 1.00), ("l", 0.85)],
            "u": [("n", 1.00), ("o", 0.95)],
            "a": [("e", 0.95), ("o", 1.05)],
            "e": [("a", 0.95), ("i", 0.95)],
            "o": [("u", 0.95), ("a", 1.05)],
            "l": [("n", 0.85)],
            "f": [("h", 0.90)],
            "h": [("f", 0.90)]
        ]
        var table: [Character: [(Character, Double)]] = [:]
        for c in alphabet {
            guard let p1 = keyCoords[c] else { continue }
            var list: [(Character, Double)] = []
            var seen = Set<Character>([c])
            for other in alphabet where other != c {
                guard let p2 = keyCoords[other] else { continue }
                let dr = p1.row - p2.row
                let dc = p1.col - p2.col
                let dist = sqrt(dr * dr + dc * dc)
                if dist <= 1.45 {
                    list.append((other, 0.60 + 0.12 * dist))
                    seen.insert(other)
                }
            }
            if let extras = extraPairs[c] {
                for (ex, cost) in extras where seen.insert(ex).inserted {
                    list.append((ex, cost))
                }
            }
            table[c] = list.sorted { $0.1 < $1.1 }
        }
        return table
    }()

    /// DP 完整音节切分：仅当整串拼音能被 100% 切分为合法汉语全拼音节（0 悬空碎片）时返回最少音节切分
    public static func segmentFullSyllables(_ pinyin: String) -> [String]? {
        let chars = Array(pinyin)
        let n = chars.count
        guard n > 0 else { return [] }

        // dp[i] = (音节数, 上一断点, 当前音节文本)，优先最少音节数（最大匹配优先），音节数相同优先长首音节
        var dpCount = [Int](repeating: Int.max, count: n + 1)
        var dpPrev = [Int](repeating: -1, count: n + 1)
        var dpSyl = [String](repeating: "", count: n + 1)
        dpCount[0] = 0

        for i in 0..<n where dpCount[i] != Int.max {
            let maxLen = min(6, n - i)
            for len in 1...maxLen {
                let slice = String(chars[i..<(i + len)])
                if validSyllables.contains(slice) {
                    let nextCount = dpCount[i] + 1
                    let j = i + len
                    if nextCount < dpCount[j] {
                        dpCount[j] = nextCount
                        dpPrev[j] = i
                        dpSyl[j] = slice
                    }
                }
            }
        }
        guard dpCount[n] != Int.max else { return nil }

        var result: [String] = []
        var cur = n
        while cur > 0 {
            result.append(dpSyl[cur])
            cur = dpPrev[cur]
        }
        return result.reversed()
    }

    /// 诊断 Rime 的 preedit 切分是否出现错拼碎裂或异常连键
    public static func diagnose(rawPinyin: String, preedit: String) -> PinyinSegmentationDiagnosis {
        let cleanRaw = rawPinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        let parts = preedit
            .lowercased()
            .split { $0 == " " || $0 == "'" }
            .map { $0.filter { $0 >= "a" && $0 <= "z" } }
            .filter { !$0.isEmpty }

        let standaloneVowels: Set<String> = ["a", "o", "e"]
        var singleFragments = 0
        for p in parts where p.count == 1 && !standaloneVowels.contains(p) {
            singleFragments += 1
        }
        let isPureAbbrev = !parts.isEmpty && parts.allSatisfy { $0.count == 1 }

        // 汉语拼音合法连续同字母仅存在于极少数跨音节边界（如 "an'n" / "g'g" 罕见，而 "ii/uu/ss/hh/tt/bb/pp/dd/kk" 几乎必然是连键误触）
        let chars = Array(cleanRaw)
        var hasIllegalDouble = false
        let allowedCrossDoubles: Set<Character> = ["n", "g", "a", "e", "o"]
        if chars.count >= 2 {
            for i in 0..<(chars.count - 1) where chars[i] == chars[i + 1] {
                if !allowedCrossDoubles.contains(chars[i]) {
                    hasIllegalDouble = true
                    break
                }
            }
            // 若末尾连续双写同字母（如 shanghaii / nihaoo），也几乎必为多敲连键
            if chars.count >= 4 && chars[chars.count - 1] == chars[chars.count - 2] {
                hasIllegalDouble = true
            }
        }

        // 若未纯简拼且出现了悬空单字母辅音碎片，或者无法被完整全拼音节切分（且长度 >= 4），判定为碎裂错拼！
        let fullSeg = segmentFullSyllables(cleanRaw)
        let isFragmented: Bool
        if isPureAbbrev || cleanRaw.count < 4 {
            isFragmented = false
        } else if singleFragments >= 1 {
            isFragmented = true
        } else if fullSeg == nil && cleanRaw.count >= 4 {
            isFragmented = true
        } else {
            isFragmented = false
        }

        return PinyinSegmentationDiagnosis(
            segmentCount: max(parts.count, fullSeg?.count ?? parts.count),
            singleCharFragmentCount: singleFragments,
            hasIllegalDoubleLetter: hasIllegalDouble,
            isFragmented: isFragmented,
            isPureAbbreviation: isPureAbbrev
        )
    }

    /// 生成经过 DP 完整音节切分严格校验的纠偏拼音建议（按可信度降序，最多 maxSuggestions 条）
    public func suggestCorrections(
        rawPinyin: String,
        preedit: String,
        enableNasalCompletion: Bool = true,
        maxSuggestions: Int = 4
    ) -> [PinyinCorrectionSuggestion] {
        let clean = rawPinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard clean.count >= 4 && clean.count <= 20, maxSuggestions > 0 else { return [] }

        let diag = Self.diagnose(rawPinyin: clean, preedit: preedit)
        // 纯简拼（如 xtwt / phjy）绝不改写
        guard !diag.isPureAbbreviation else { return [] }

        let cacheKey = "\(clean)|\(diag.isFragmented ? 1 : 0)|\(enableNasalCompletion ? 1 : 0)|\(maxSuggestions)"
        lock.lock()
        if let hit = cache[cacheKey] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let baseFullSeg = Self.segmentFullSyllables(clean)
        let baselineSegCount = diag.segmentCount > 0 ? diag.segmentCount : (baseFullSeg?.count ?? clean.count)

        var bestByPinyin: [String: (syllables: [String], cost: Double)] = [:]

        func consider(_ candidate: String, cost: Double, requireFewerSegments: Bool) {
            guard candidate != clean, candidate.count >= 3 else { return }
            if let existing = bestByPinyin[candidate], existing.cost <= cost {
                return
            }
            guard let segs = Self.segmentFullSyllables(candidate), !segs.isEmpty else { return }
            if requireFewerSegments {
                // 纠偏必须真正减少破碎音节数（或从无法完整切分变为可完整切分）
                if baseFullSeg != nil && segs.count >= baselineSegCount {
                    return
                }
                if diag.isFragmented && segs.count > max(1, baselineSegCount - 1) && baseFullSeg == nil && diag.singleCharFragmentCount == 0 {
                    return
                }
            }
            bestByPinyin[candidate] = (segs, cost)
        }

        let chars = Array(clean)
        let n = chars.count

        // 策略 A：若输入已碎裂或存在非法连键，执行全量低代价单步编辑搜索（删连键 / 转置 / 邻键及跨排替换 / 补漏元音 / 删杂键）
        if diag.isFragmented || diag.hasIllegalDoubleLetter {
            // 1. 去连续重复字母（shanghaii -> shanghai, sshanghai -> shanghai）
            for i in 0..<(n - 1) where chars[i] == chars[i + 1] {
                var arr = chars
                arr.remove(at: i)
                consider(String(arr), cost: 0.40, requireFewerSegments: false)
            }

            // 2. 相邻字母倒序转置（shnaghai -> shanghai, nihoa -> nihao, womne -> women）
            for i in 0..<(n - 1) where chars[i] != chars[i + 1] {
                var arr = chars
                arr.swapAt(i, i + 1)
                consider(String(arr), cost: 0.50, requireFewerSegments: false)
            }

            // 3. QWERTY 邻键 + 高频跨排替换（如 shaighai 中 i -> n 得 shanghai！）
            let nasalVowels: Set<Character> = ["a", "e", "i", "o"]
            for i in 0..<n {
                guard let replacements = Self.substitutionMap[chars[i]] else { continue }
                for (rep, rawCost) in replacements {
                    var cost = rawCost
                    // 高频后鼻音韵尾误触加权：a/e/i/o + [误键] + g -> ang/eng/ing/ong（如 shaighai -> shanghai）
                    if rep == "n", i > 0, i + 1 < n, chars[i + 1] == "g", nasalVowels.contains(chars[i - 1]) {
                        cost = min(cost, 0.62)
                    } else if rep == "g", i >= 2, chars[i - 1] == "n", nasalVowels.contains(chars[i - 2]) {
                        cost = min(cost, 0.64)
                    }
                    var arr = chars
                    arr[i] = rep
                    consider(String(arr), cost: cost, requireFewerSegments: true)
                }
            }

            // 4. 补常见漏键（shnghai -> shanghai，漏元音或漏鼻音 g / 翘舌 h）
            let commonOmissions: [Character] = ["a", "e", "i", "o", "u", "n", "g", "h"]
            for i in 0...n {
                for ins in commonOmissions {
                    var arr = chars
                    arr.insert(ins, at: i)
                    consider(String(arr), cost: 0.85, requireFewerSegments: false)
                }
            }

            // 5. 删单误触杂键（如 shangzhai -> shanghai）
            if n >= 5 {
                for i in 0..<n {
                    var arr = chars
                    arr.remove(at: i)
                    consider(String(arr), cost: 0.95, requireFewerSegments: true)
                }
            }
        } else if enableNasalCompletion, let segs = baseFullSeg, segs.count >= 2 && segs.count <= 4 {
            // 策略 B：输入本身虽是合法全拼（如 shanhai -> shan hai），但存在单步前后鼻音对称变体（shanghai），
            // 生成 1 步鼻音纠偏供与记忆库 / Qwen3 语境联合评估！
            for idx in 0..<segs.count {
                let s = segs[idx]
                var alt: String?
                if s.hasSuffix("ang") || s.hasSuffix("eng") || s.hasSuffix("ing") {
                    alt = String(s.dropLast())
                } else if s.hasSuffix("an") || s.hasSuffix("en") || s.hasSuffix("in") {
                    let cand = s + "g"
                    if Self.validSyllables.contains(cand) {
                        alt = cand
                    }
                }
                if let alt, Self.validSyllables.contains(alt) {
                    var copy = segs
                    copy[idx] = alt
                    let joined = copy.joined()
                    consider(joined, cost: 0.72, requireFewerSegments: false)
                }
            }
        }

        // 综合排序：音节数更少（合并碎片收益最高）+ 编辑代价更低 + 防止 5+ 字母误删塌缩成单音节
        let ranked = bestByPinyin
            .map { key, val -> (suggestion: PinyinCorrectionSuggestion, sortScore: Double) in
                let segReduction = Double(min(2, max(0, baselineSegCount - val.syllables.count)))
                let singleSylCollapsePenalty = (val.syllables.count == 1 && clean.count >= 5) ? 0.90 : 0.0
                // 优先音节精简且编辑代价低，且保持首字母一致有额外亲和加分
                let sameInitialBonus = (key.first == clean.first) ? 0.25 : 0.0
                let score = segReduction * 0.95 + sameInitialBonus - val.cost - singleSylCollapsePenalty
                return (
                    PinyinCorrectionSuggestion(
                        correctedPinyin: key,
                        syllables: val.syllables,
                        editCost: val.cost,
                        isFragmentedSource: diag.isFragmented || diag.hasIllegalDoubleLetter
                    ),
                    score
                )
            }
            .sorted { lhs, rhs in
                if abs(lhs.sortScore - rhs.sortScore) > 1e-6 {
                    return lhs.sortScore > rhs.sortScore
                }
                if abs(lhs.suggestion.editCost - rhs.suggestion.editCost) > 1e-6 {
                    return lhs.suggestion.editCost < rhs.suggestion.editCost
                }
                return lhs.suggestion.correctedPinyin < rhs.suggestion.correctedPinyin
            }
            .prefix(maxSuggestions)
            .map(\.suggestion)

        lock.lock()
        cache[cacheKey] = ranked
        cacheOrder.append(cacheKey)
        if cacheOrder.count > cacheCapacity {
            let old = cacheOrder.removeFirst()
            cache.removeValue(forKey: old)
        }
        lock.unlock()

        return ranked
    }
}

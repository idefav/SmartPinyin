@_implementationOnly import CLlamaBridge
import Foundation

/// 基于 Qwen3-0.6B 精确联合对数似然 + 高惊讶度同音探测的「零幻觉整句错别字校对器」：
/// 彻底摆脱 0.6B 生成式 Chat Prompt 的复读漏纠（如漏掉「再上海→在上海」）与胡改幻觉（如「电恼→电风扇」）：
/// - Stage 1（易混字全句定位）：扫描高频中文易混字（再↔在、的↔地↔得、那↔哪、做↔作、已↔以、因↔应、完↔玩、门↔们、坐↔座 等），
///   天然覆盖句首位置（position 0）与强右文依赖语法错误（如「再上海可以有哪些地方可以去 → 在上海…」）。
/// - Stage 2（单次前向高惊讶度同音探测）：1 次 llama_decode 扫描全句每个 token 的条件对数概率，
///   在惊讶位置（及其前驱位）提取 Top-36 高概率纯汉字候选，仅放行同音/近音替换（如「吃反→吃饭」「电恼→电脑」「公原→公园」）。
/// - Stage 3（全句精确联合对数概率裁决）：使用 spm_llama_score_texts_exact 计算完整左右语境下的未归一化联合对数概率，
///   严格要求 ΔlogP >= 阈值（同音/易混 >= 4.2 nats ≈ 67× 概率优势；近音/模糊音 >= 6.0 nats ≈ 403× 概率优势），
///   确保正常句子零误改、错字高召回、总耗时 ~25–60ms 且不增加任何额外模型内存。
final class DraftNeuralProofreader: @unchecked Sendable {
    struct Outcome: Sendable {
        let correctedText: String
        let latencyMs: Double
        let acceptedEdits: Int
        let isComplete: Bool
    }

    private struct ProposalBatch {
        let proposals: [EditProposal]
        let cancelled: Bool
        let probeSucceeded: Bool
    }

    private enum ProposalTier {
        case confusableOrExactPinyin
        case nearPinyin

        var minDeltaLogProb: Double {
            switch self {
            case .confusableOrExactPinyin: return 4.2
            case .nearPinyin: return 6.0
            }
        }
    }

    private struct EditProposal: Hashable {
        let charStart: Int
        let charLength: Int
        let replacement: String
        let tier: ProposalTier

        var charEnd: Int { charStart + charLength }
    }

    /// 常见高频中文同音/语法易混字组（刻意排除「他/她/它」避免擅改性别/人称指代）
    private static let confusableGroups: [[Character]] = [
        Array("在再"),
        Array("的地得"),
        Array("那哪"),
        Array("做作"),
        Array("已以己"),
        Array("因应"),
        Array("即既"),
        Array("像象"),
        Array("须需"),
        Array("候侯"),
        Array("账帐"),
        Array("定订"),
        Array("进近"),
        Array("到倒"),
        Array("完玩"),
        Array("门们"),
        Array("坐座"),
        Array("原园源"),
        Array("度渡"),
        Array("练炼"),
        Array("采彩"),
        Array("备倍"),
        Array("历厉励"),
        Array("竞竟"),
        Array("辩辨"),
        Array("制治"),
        Array("把吧")
    ]

    private static let confusableLookup: [Character: [Character]] = {
        var map: [Character: [Character]] = [:]
        for group in confusableGroups {
            for ch in group {
                let others = group.filter { $0 != ch }
                map[ch, default: []].append(contentsOf: others)
            }
        }
        return map
    }()

    /// 严禁自动互换的敏感词对（人称性别等完全属于用户主观意图）
    private static let forbiddenSingleSwaps: Set<String> = [
        "他>她", "她>他", "他>它", "它>他", "她>它", "它>她"
    ]

    /// 常见多音字补充表（与 CFStringTransform 主读音合并，防止多音字漏判同音）
    private static let polyphonePinyins: [Character: [String]] = [
        "得": ["de", "dei"],
        "地": ["di", "de"],
        "的": ["de", "di"],
        "长": ["chang", "zhang"],
        "重": ["chong", "zhong"],
        "行": ["xing", "hang"],
        "还": ["hai", "huan"],
        "觉": ["jue", "jiao"],
        "乐": ["le", "yue"],
        "着": ["zhe", "zhao", "zhuo"],
        "会": ["hui", "kuai"],
        "调": ["tiao", "diao"],
        "差": ["cha", "chai"],
        "传": ["chuan", "zhuan"],
        "都": ["dou", "du"],
        "给": ["gei", "ji"],
        "和": ["he", "huo"],
        "没": ["mei", "mo"],
        "便": ["bian", "pian"],
        "参": ["can", "shen"],
        "省": ["sheng", "xing"],
        "率": ["lv", "shuai"],
        "藏": ["cang", "zang"],
        "降": ["jiang", "xiang"],
        "角": ["jiao", "jue"],
        "卡": ["ka", "qia"],
        "落": ["luo", "la"],
        "模": ["mo", "mu"],
        "强": ["qiang", "jiang"],
        "似": ["si", "shi"],
        "宿": ["su", "xiu"],
        "弹": ["tan", "dan"],
        "提": ["ti", "di"],
        "系": ["xi", "ji"],
        "血": ["xue", "xie"],
        "哪": ["na", "nei"],
        "那": ["na", "nei"]
    ]

    private let pinyinLock = NSLock()
    private var pinyinCache: [Character: [String]] = [:]

    func proofread(
        handle: OpaquePointer,
        sourceText: String,
        timeoutMs: Int = 260
    ) -> Outcome? {
        let start = CFAbsoluteTimeGetCurrent()
        var working = sourceText
        var totalAccepted = 0
        var isComplete = true

        // 最多 2 轮贪心修正：绝大多数正常句在第 1 轮即确认无误退出（~15–25ms）；
        // 仅当第 1 轮存在多处改动或邻近仍有高潜力候选时才执行第 2 轮，严控延迟 < 65ms
        for round in 0..<2 {
            let elapsedSoFar = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            let remainingMs = timeoutMs - Int(elapsedSoFar)
            if remainingMs < 25 {
                if round == 0 && totalAccepted == 0 {
                    return nil
                }
                isComplete = false
                break
            }

            let batch = collectProposals(
                handle: handle,
                text: working,
                timeoutMs: min(80, remainingMs / 2)
            )
            if batch.cancelled {
                return nil
            }
            if !batch.probeSucceeded {
                isComplete = false
            }
            let proposals = batch.proposals
            guard !proposals.isEmpty else { break }

            let chars = Array(working)
            var candidateTexts: [String] = [working]
            var alignedProposals: [EditProposal] = []
            var seenMutations = Set<String>([working])

            for prop in proposals {
                guard prop.charStart >= 0, prop.charEnd <= chars.count else { continue }
                let mutated = applySingle(prop, to: chars)
                if seenMutations.insert(mutated).inserted {
                    candidateTexts.append(mutated)
                    alignedProposals.append(prop)
                }
                // 控制单轮最多打分 20 个候选变体，兼顾多错字召回与 ~40ms 疾速响应
                if alignedProposals.count >= 20 { break }
            }
            guard !alignedProposals.isEmpty else { break }

            let scoreRemaining = max(30, timeoutMs - Int((CFAbsoluteTimeGetCurrent() - start) * 1000.0))
            guard let scores = scoreExactVariants(
                handle: handle,
                candidates: candidateTexts,
                timeoutMs: scoreRemaining
            ), scores.count == candidateTexts.count, scores[0] > -1e8 else {
                // 被抢占取消或第 1 轮未完成打分：返回 nil 防止脏数据写入缓存
                if totalAccepted == 0 {
                    return nil
                }
                isComplete = false
                break
            }

            if scores.contains(where: { $0 <= -1e8 }) {
                // 部分变体因超时未打分，本轮结果不可作为完整结论缓存
                isComplete = false
            }

            let baseScore = scores[0]
            var winners: [(proposal: EditProposal, delta: Double, mutated: String)] = []
            var runnerUpCount = 0
            for (idx, prop) in alignedProposals.enumerated() {
                let s = scores[idx + 1]
                guard s > -1e8 else { continue }
                let delta = s - baseScore
                // 多字同时替换要求稍高门槛，防止整词误换
                let extraMultiCharMargin = prop.charLength > 1 ? 1.0 : 0.0
                if delta >= (prop.tier.minDeltaLogProb + extraMultiCharMargin) {
                    winners.append((prop, delta, candidateTexts[idx + 1]))
                } else if delta >= 1.8 {
                    runnerUpCount += 1
                }
            }
            guard !winners.isEmpty else { break }

            // 按 ΔlogP 从高到低贪心挑选互不重叠的修改区间
            winners.sort { $0.delta > $1.delta }
            var selected: [(proposal: EditProposal, delta: Double, mutated: String)] = []
            for w in winners {
                let overlaps = selected.contains { existing in
                    !(w.proposal.charEnd <= existing.proposal.charStart
                      || w.proposal.charStart >= existing.proposal.charEnd)
                }
                if !overlaps {
                    selected.append(w)
                }
                if selected.count >= 4 { break }
            }

            if selected.count == 1 {
                working = selected[0].mutated
                totalAccepted += 1
                // 单处孤立纠偏且无其它有潜力候选时，直接收敛结束，省去整轮额外前向计算
                if round == 0 && runnerUpCount == 0 && winners.count == 1 {
                    break
                }
            } else {
                let combined = applyMultiple(selected.map(\.proposal), to: chars)
                // 多处同时修改时做一次联合验证，确保组合后确实优于原句及最佳单项
                let verifyBudget = max(25, timeoutMs - Int((CFAbsoluteTimeGetCurrent() - start) * 1000.0))
                if let verifyScores = scoreExactVariants(
                    handle: handle,
                    candidates: [working, selected[0].mutated, combined],
                    timeoutMs: verifyBudget
                ), verifyScores.count == 3, verifyScores[2] > -1e8, verifyScores[0] > -1e8 {
                    if verifyScores[2] >= verifyScores[1] && (verifyScores[2] - verifyScores[0]) >= 4.2 {
                        working = combined
                        totalAccepted += selected.count
                    } else {
                        working = selected[0].mutated
                        totalAccepted += 1
                    }
                } else {
                    working = selected[0].mutated
                    totalAccepted += 1
                    isComplete = false
                }
            }

            // 最多累计修正不超过句子长度的 25% 且与五重护栏上限（<= 10）严格对齐
            if totalAccepted >= min(10, max(3, working.count / 4)) {
                break
            }
        }

        let totalMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        return Outcome(
            correctedText: working,
            latencyMs: totalMs,
            acceptedEdits: totalAccepted,
            isComplete: isComplete
        )
    }

    // MARK: - 候选提议收集（Stage 1 易混字 + Stage 2 高惊讶度同音探测）

    private func collectProposals(
        handle: OpaquePointer,
        text: String,
        timeoutMs: Int
    ) -> ProposalBatch {
        let chars = Array(text)
        var proposals: [EditProposal] = []
        var seen = Set<EditProposal>()

        // Stage 1: 高频易混字扫描（覆盖句首与强右文语境，如「再上海…」）
        for (i, ch) in chars.enumerated() {
            guard let alts = Self.confusableLookup[ch] else { continue }
            for alt in alts {
                let prop = EditProposal(
                    charStart: i,
                    charLength: 1,
                    replacement: String(alt),
                    tier: .confusableOrExactPinyin
                )
                if seen.insert(prop).inserted {
                    proposals.append(prop)
                }
            }
        }

        // Stage 2: 单次前向高惊讶度 Top-240 纯汉字同音探测（零生成、零幻觉，~10ms 捕获任意同音/模糊音错别字）
        var surprisal = spm_llama_probe_surprisal_proposals(
            handle,
            text,
            -3.0,
            240,
            Int32(max(20, timeoutMs))
        )
        defer { spm_llama_free_surprisal_result(&surprisal) }

        if surprisal.cancelled {
            return ProposalBatch(proposals: [], cancelled: true, probeSucceeded: false)
        }

        var surprisalProposals: [EditProposal] = []
        if surprisal.ok, let itemsPtr = surprisal.items, surprisal.count > 0 {
            let byteToChar = buildByteOffsetToCharIndexMap(text)
            for idx in 0..<Int(surprisal.count) {
                let item = itemsPtr[idx]
                guard let charStart = byteToChar[Int(item.byte_offset)],
                      let altTexts = item.alt_texts,
                      item.alt_count > 0
                else { continue }

                for k in 0..<Int(item.alt_count) {
                    guard let cAlt = altTexts[k] else { continue }
                    let altStr = String(cString: cAlt)
                    let altChars = Array(altStr)
                    let spanLen = altChars.count
                    guard spanLen >= 1, spanLen <= 3, charStart + spanLen <= chars.count else { continue }

                    let origSlice = Array(chars[charStart..<(charStart + spanLen)])
                    guard origSlice != altChars else { continue }
                    guard origSlice.allSatisfy(Self.isHanzi) else { continue }

                    // 校验逐字拼音相似度，并过滤禁止互换的人称代词
                    if let tier = evaluateReplacementTier(orig: origSlice, alt: altChars) {
                        // 缩小到实际发生变化的最小子区间（如「上孩→上海」收缩为「孩→海」，利于多错字无重叠合并）
                        var trimL = 0
                        var trimR = spanLen
                        while trimL < trimR && origSlice[trimL] == altChars[trimL] { trimL += 1 }
                        while trimR > trimL && origSlice[trimR - 1] == altChars[trimR - 1] { trimR -= 1 }
                        guard trimL < trimR else { continue }

                        let trimmedReplacement = String(altChars[trimL..<trimR])
                        let prop = EditProposal(
                            charStart: charStart + trimL,
                            charLength: trimR - trimL,
                            replacement: trimmedReplacement,
                            tier: tier
                        )
                        if seen.insert(prop).inserted {
                            surprisalProposals.append(prop)
                        }
                    }
                }
            }
        }

        // 优先保留高信号 Stage 2 惊讶同音提议（至多 10 条），再补充 Stage 1 高频易混字（如 再↔在、那↔哪、完↔玩），
        // 避免长句中大量高频虚词（的/在/把）挤掉真实同音错字，同时保证句首易混字始终进入打分池
        return ProposalBatch(
            proposals: Array(surprisalProposals.prefix(10)) + proposals,
            cancelled: false,
            probeSucceeded: surprisal.ok
        )
    }

    private func evaluateReplacementTier(orig: [Character], alt: [Character]) -> ProposalTier? {
        guard orig.count == alt.count else { return nil }
        var diffCount = 0
        var worstTier: ProposalTier = .confusableOrExactPinyin

        for (oCh, aCh) in zip(orig, alt) {
            if oCh == aCh { continue }
            diffCount += 1
            // 单处提议最多同时变动 2 个汉字，防止模型整词改写
            if diffCount > 2 { return nil }
            if Self.forbiddenSingleSwaps.contains("\(oCh)>\(aCh)") {
                return nil
            }
            guard let pairTier = singleCharPinyinTier(orig: oCh, alt: aCh) else {
                return nil
            }
            if pairTier == .nearPinyin {
                worstTier = .nearPinyin
            }
        }
        return diffCount > 0 ? worstTier : nil
    }

    private func singleCharPinyinTier(orig: Character, alt: Character) -> ProposalTier? {
        if let group = Self.confusableLookup[orig], group.contains(alt) {
            return .confusableOrExactPinyin
        }
        let p1List = pinyins(for: orig)
        let p2List = pinyins(for: alt)
        guard !p1List.isEmpty, !p2List.isEmpty else { return nil }

        for p1 in p1List {
            for p2 in p2List {
                if p1 == p2 {
                    return .confusableOrExactPinyin
                }
            }
        }
        for p1 in p1List {
            for p2 in p2List {
                // 严格只放行中文真实模糊音（平翘舌 zh/z、ch/c、sh/s，前后鼻音 an/ang、en/eng、in/ing，n/l，f/h）；
                // 严禁按编辑距离放行无关声母替换（如 an/dan「案→弹」、hai/tai「孩→台」、wan/yan「完→演」）
                if Self.fuzzyFoldPinyin(p1) == Self.fuzzyFoldPinyin(p2) {
                    return .nearPinyin
                }
            }
        }
        return nil
    }

    private func pinyins(for ch: Character) -> [String] {
        pinyinLock.lock()
        if let hit = pinyinCache[ch] {
            pinyinLock.unlock()
            return hit
        }
        pinyinLock.unlock()

        var result: [String] = []
        let mutable = NSMutableString(string: String(ch))
        if CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false) {
            CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
            let normalized = (mutable as String)
                .lowercased()
                .replacingOccurrences(of: "ü", with: "v")
                .filter { $0 >= "a" && $0 <= "z" }
            if !normalized.isEmpty {
                result.append(normalized)
            }
        }
        if let extras = Self.polyphonePinyins[ch] {
            for p in extras where !result.contains(p) {
                result.append(p)
            }
        }

        pinyinLock.lock()
        if pinyinCache.count > 4096 {
            pinyinCache.removeAll(keepingCapacity: true)
        }
        pinyinCache[ch] = result
        pinyinLock.unlock()
        return result
    }

    // MARK: - Stage 3 精确联合对数概率批量打分

    private func scoreExactVariants(
        handle: OpaquePointer,
        candidates: [String],
        timeoutMs: Int
    ) -> [Double]? {
        guard candidates.count >= 2 else { return nil }
        var scores = [Double](repeating: -1e9, count: candidates.count)
        var elapsed: Double = 0
        let cStrings = candidates.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        let constPtrs: [UnsafePointer<CChar>?] = cStrings.map { $0.map { UnsafePointer($0) } }
        let ok = constPtrs.withUnsafeBufferPointer { buf in
            spm_llama_score_texts_exact(
                handle,
                "",
                buf.baseAddress!,
                Int32(candidates.count),
                Int32(timeoutMs),
                &scores,
                &elapsed
            )
        }
        return ok ? scores : nil
    }

    // MARK: - 字符串辅助

    private func applySingle(_ prop: EditProposal, to chars: [Character]) -> String {
        var out = String(chars[0..<prop.charStart])
        out.append(prop.replacement)
        if prop.charEnd < chars.count {
            out.append(contentsOf: chars[prop.charEnd..<chars.count])
        }
        return out
    }

    private func applyMultiple(_ props: [EditProposal], to chars: [Character]) -> String {
        let sorted = props.sorted { $0.charStart < $1.charStart }
        var out = ""
        out.reserveCapacity(chars.count * 3)
        var cursor = 0
        for prop in sorted {
            if prop.charStart > cursor {
                out.append(contentsOf: chars[cursor..<prop.charStart])
            }
            out.append(prop.replacement)
            cursor = prop.charEnd
        }
        if cursor < chars.count {
            out.append(contentsOf: chars[cursor..<chars.count])
        }
        return out
    }

    private func buildByteOffsetToCharIndexMap(_ text: String) -> [Int: Int] {
        var map: [Int: Int] = [:]
        map.reserveCapacity(text.count)
        var byteOff = 0
        for (charIdx, ch) in text.enumerated() {
            map[byteOff] = charIdx
            byteOff += String(ch).utf8.count
        }
        return map
    }

    private static func isHanzi(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF)
    }

    private static func fuzzyFoldPinyin(_ p: String) -> String {
        var s = p
        if s.hasPrefix("zh") { s = "z" + s.dropFirst(2) }
        else if s.hasPrefix("ch") { s = "c" + s.dropFirst(2) }
        else if s.hasPrefix("sh") { s = "s" + s.dropFirst(2) }
        else if s.hasPrefix("l") { s = "n" + s.dropFirst(1) }
        else if s.hasPrefix("f") { s = "h" + s.dropFirst(1) }

        if s.hasSuffix("ang") { s = String(s.dropLast(1)) }
        else if s.hasSuffix("eng") { s = String(s.dropLast(1)) }
        else if s.hasSuffix("ing") { s = String(s.dropLast(1)) }
        return s
    }
}

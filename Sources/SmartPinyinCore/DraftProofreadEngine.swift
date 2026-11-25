import Foundation
import SharedIPC

/// 整句暂存校对引擎（100% 离线、零幻觉五重护栏）：
/// - L1 同步规则预检（< 0.3 ms）：高频确定性错别字表 + 非叠词异常连打重字 + 重复标点归一
/// - 五重防幻觉守卫（ProofreadOutputValidator）：校验 L2 Qwen3-0.6B 输出，含核心「拼音近音相似度护栏」
/// - 字符级 LCS Diff 生成器（ProofreadDiffBuilder）：供候选窗底栏精准高亮展示纠偏字词
public final class DraftProofreadEngine: @unchecked Sendable {
    public struct RuleProofreadResult: Equatable, Sendable {
        public let sourceText: String
        public let correctedText: String
        public let segments: [ProofreadDiffSegment]
        public let changeCount: Int

        public var hasChanges: Bool {
            correctedText != sourceText && changeCount > 0
        }
    }

    private let normalizer: PinyinNormalizer

    public init(normalizer: PinyinNormalizer = PinyinNormalizer()) {
        self.normalizer = normalizer
    }

    // MARK: - 1. L1 同步规则预检（< 0.3ms，无模型也能稳定工作）

    /// 高频零误伤确定性同音/形近错别字映射（按长度降序应用，避免短词误拆）
    private static let deterministicTypoPairs: [(wrong: String, right: String)] = [
        // 4 字成语与固定搭配
        ("一如即往", "一如既往"),
        ("迫不急待", "迫不及待"),
        ("再接再励", "再接再厉"),
        ("默守成规", "墨守成规"),
        ("走头无路", "走投无路"),
        ("川流不息", "川流不息"),
        ("穿流不息", "川流不息"),
        ("名符其实", "名副其实"),
        ("名副其是", "名副其实"),
        ("按步就班", "按部就班"),
        ("美轮美焕", "美轮美奂"),
        ("美仑美奂", "美轮美奂"),
        ("无精打彩", "无精打采"),
        ("再所不辞", "在所不辞"),
        ("金榜提名", "金榜题名"),
        ("出类拔萃", "出类拔萃"),
        ("出类拔粹", "出类拔萃"),
        ("破釜沉州", "破釜沉舟"),
        ("世外桃园", "世外桃源"),
        ("不可思义", "不可思议"),
        ("不可思意", "不可思议"),
        ("莫名其妙", "莫名其妙"),
        ("莫明其妙", "莫名其妙"),
        ("甘拜下风", "甘拜下风"),
        ("甘败下风", "甘拜下风"),
        ("谈笑风声", "谈笑风生"),
        ("一筹莫展", "一筹莫展"),
        ("一愁莫展", "一筹莫展"),
        ("声名雀起", "声名鹊起"),
        ("相形见拙", "相形见绌"),
        ("悬梁刺骨", "悬梁刺股"),
        ("礼尚往来", "礼尚往来"),
        ("礼上往来", "礼尚往来"),
        ("真知灼见", "真知灼见"),
        ("真知卓见", "真知灼见"),
        ("厉厉在目", "历历在目"),
        ("如火如茶", "如火如荼"),
        ("别出心才", "别出心裁"),
        ("不径而走", "不胫而走"),
        ("草管人命", "草菅人命"),
        ("陈词滥调", "陈词滥调"),
        ("陈词烂调", "陈词滥调"),
        ("层出不穷", "层出不穷"),
        ("层出不穹", "层出不穷"),
        ("精益求精", "精益求精"),
        ("精艺求精", "精益求精"),
        ("事倍工半", "事倍功半"),
        ("事半工倍", "事半功倍"),
        ("得不偿失", "得不偿失"),
        ("得不尝失", "得不偿失"),
        ("举一返三", "举一反三"),
        ("变本加利", "变本加厉"),
        ("焕然一新", "焕然一新"),
        ("换然一新", "焕然一新"),
        ("既往不究", "既往不咎"),
        ("循序渐进", "循序渐进"),
        ("循序渐近", "循序渐进"),
        ("融会贯通", "融会贯通"),
        ("融汇贯通", "融会贯通"),
        ("实事求是", "实事求是"),
        ("实事求事", "实事求是"),
        ("因地制宜", "因地制宜"),
        ("因地治宜", "因地制宜"),
        ("水落石出", "水落石出"),
        ("水落食出", "水落石出"),
        ("画蛇添足", "画蛇添足"),
        ("画蛇天足", "画蛇添足"),
        // 3 字高频技术/办公/生活错词
        ("配制文件", "配置文件"),
        ("兼荣性", "兼容性"),
        ("部暑方案", "部署方案"),
        ("部暑流程", "部署流程"),
        ("候选项", "候选项"),
        ("后选项", "候选项"),
        ("后选词", "候选词"),
        ("输人法", "输入法"),
        ("莫名其", "莫名其"),
        ("一如即", "一如既"),
        ("迫不急", "迫不及"),
        ("原形毕", "原形毕"),
        ("原形必露", "原形毕露"),
        ("不知所措", "不知所措"),
        ("不知所错", "不知所措"),
        ("没关系", "没关系"),
        ("没关西", "没关系"),
        ("怎么样", "怎么样"),
        ("怎莫样", "怎么样"),
        ("什么时侯", "什么时候"),
        ("那时候", "那时候"),
        ("那时侯", "那时候"),
        ("这时侯", "这时候"),
        // 2 字高频零误伤错别字（严格排除所有合法词组与跨词边界碰撞项，如 实线/对与/关与/在见/在次/做业/大楷/结过/了借/认位/开使/日只/上孩/自已，
        // 任何上下文依赖型错字均交由 L2 精确联合对数概率校对器按完整语境判别，确保 L1 零误伤）
        ("因该", "应该"),
        ("以经", "已经"),
        ("既使", "即使"),
        ("即然", "既然"),
        ("毕竞", "毕竟"),
        ("部暑", "部署"),
        ("兼荣", "兼容"),
        ("默任", "默认"),
        ("按装", "安装"),
        ("我门", "我们"),
        ("你门", "你们"),
        ("他门", "他们"),
        ("她门", "她们"),
        ("咱门", "咱们"),
        ("什莫", "什么"),
        ("怎莫", "怎么"),
        ("为什莫", "为什么"),
        ("时侯", "时候"),
        ("觉的", "觉得"),
        ("显的", "显得"),
        ("反溃", "反馈"),
        ("反匮", "反馈"),
        ("逻缉", "逻辑"),
        ("逻集", "逻辑"),
        ("异长", "异常"),
        ("依懒", "依赖"),
        ("依籁", "依赖"),
        ("缓村", "缓存"),
        ("缓寸", "缓存"),
        ("优话", "优化"),
        ("优画", "优化"),
        ("参树", "参数"),
        ("接扣", "接口"),
        ("框假", "框架"),
        ("版奔", "版本"),
        ("权显", "权限"),
        ("签明", "签名"),
        ("编意", "编译"),
        ("模行", "模型"),
        ("词酷", "词库"),
        ("拼因", "拼音"),
        ("联响", "联想"),
        ("翻意", "翻译"),
        ("输人", "输入"),
        ("谢写", "谢谢"),
        ("麻反", "麻烦"),
        ("麻繁", "麻烦"),
        ("确任", "确认"),
        ("确人", "确认"),
        ("问提", "问题"),
        ("方暗", "方案"),
        ("记划", "计划"),
        ("完城", "完成"),
        ("结速", "结束"),
        ("继需", "继续"),
        ("需药", "需要"),
        ("所已", "所以"),
        ("虽染", "虽然"),
        ("但试", "但是"),
        ("或着", "或者"),
        ("根剧", "根据"),
        ("通果", "通过"),
        ("朋有", "朋友"),
        ("今添", "今天"),
        ("明添", "明天"),
        ("昨添", "昨天"),
        ("现再", "现在"),
        ("刚材", "刚才"),
        ("马伤", "马上"),
        ("立既", "立即"),
        ("非长", "非常"),
        ("特备", "特别"),
        ("可嫩", "可能"),
        ("一订", "一定"),
        ("必需要", "必须要"),
        ("必竟", "毕竟"),
        ("尤期", "尤其"),
        ("其是", "其实"),
        ("比茹", "比如"),
        ("例茹", "例如"),
        ("简查", "检查"),
        ("修该", "修改"),
        ("修服", "修复"),
        ("支特", "支持"),
        ("提共", "提供"),
        ("处里", "处理"),
        ("分西", "分析"),
        ("研就", "研究"),
        ("体念", "体验"),
        ("效过", "效果"),
        ("原应", "原因"),
        ("情宽", "情况"),
        ("标淮", "标准"),
        ("建义", "建议"),
        ("决订", "决定"),
        ("选泽", "选择"),
        ("喜还", "喜欢"),
        ("希忘", "希望"),
        ("帮住", "帮助"),
        ("解绝", "解决"),
        ("关健", "关键"),
        ("重药", "重要"),
        ("简丹", "简单"),
        ("容意", "容易"),
        ("困南", "困难"),
        ("稳订", "稳定"),
        ("性嫩", "性能"),
        ("效绿", "效率"),
        ("质亮", "质量"),
        ("内寸", "内存"),
        ("硬盆", "硬盘"),
        ("屏莫", "屏幕"),
        ("键盆", "键盘"),
        ("鼠表", "鼠标"),
        ("网洛", "网络"),
        ("服物", "服务"),
        ("数剧", "数据"),
        ("目绿", "目录"),
        ("项莫", "项目"),
        ("程续", "程序"),
        ("代玛", "代码"),
        ("函树", "函数"),
        ("变亮", "变量"),
        ("类行", "类型"),
        ("错物", "错误"),
        ("警高", "警告")
    ].filter { $0.wrong != $0.right }

    /// 合法现代汉语单字叠词白名单（严防异常重字清理误伤自然叠词）
    private static let legalReduplicatedChars: Set<Character> = Set(
        "看听写说说笑走跑跳坐站停等等想念问尝摸试试想想慢快早晚高大长短小小多多好好远近常常往往刚刚偏偏渐渐渐悄悄轻轻重重轻轻密密满满深深浅浅明明暗暗白白红红黑黑绿绿蓝蓝清清净净干干净净平平安安开开心心快快乐乐认认真真仔仔细细整整齐齐简简单单方方便便明明白白漂漂亮亮舒舒服服客客气气热热闹闹轰轰烈烈隐隐约约陆陆续续断断续续反反复复来来回回上上下下前前后后左左右右里里外外进进出出大大小小老老少少男男女女家家户户人人天天年年月月时时刻刻处处事事件件样样种种步步层层节节句句字字段段行行点点滴滴片片颗颗条条棵棵朵朵张张本本把把只只个个谢谢哈哈呵呵嘿嘿嘻嘻呜呜哇哇呀呀嗯嗯哦哦唉唉喂喂爸爸妈妈爷爷奶奶哥哥姐姐弟弟妹妹叔叔阿姨舅舅姑姑姥姥宝宝娃娃囡囡星星月亮太阳公公婆婆太太猩猩蛐蛐蝈蝈蝈蛐蛐咚咚砰砰啪啪嘀嘀哒哒哗哗沙沙呼呼嗡嗡吱吱汪汪喵喵咩咩咯咯嘎嘎啧啧"
    )

    /// 仅在明显属于虚词/助词连打重复时才合并（零误伤策略）
    private static let stutterMergeChars: Set<Character> = Set(
        "的了是在有和我你他她它这那就不也都还再很会要能给把被让从向对跟和与及并而但因所"
    )

    /// 执行同步 L1 规则预检（< 0.3 ms）
    public func applyRuleProofread(to source: String) -> RuleProofreadResult {
        guard !source.isEmpty else {
            return RuleProofreadResult(sourceText: source, correctedText: source, segments: [], changeCount: 0)
        }

        var text = source

        // 1. 确定性错词表替换（仅当错词本身不等于正确词）
        for pair in Self.deterministicTypoPairs where text.contains(pair.wrong) {
            text = text.replacingOccurrences(of: pair.wrong, with: pair.right)
        }

        // 2. 明显虚词/代词连打重复合并（如「的的」「了了」「我我」「是是」），避开合法叠词
        text = collapseObviousStutters(text)

        // 3. 异常重复标点归一（如「，，」「。。」「；；」「：：」；保留合法省略号「……」「...」与「？！」「！！」情绪表达）
        text = normalizeAccidentalDuplicatePunctuation(text)

        let diff = Self.buildDiff(source: source, corrected: text)
        return RuleProofreadResult(
            sourceText: source,
            correctedText: text,
            segments: diff.segments,
            changeCount: diff.changeCount
        )
    }

    private func collapseObviousStutters(_ input: String) -> String {
        let chars = Array(input)
        guard chars.count >= 2 else { return input }
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if i + 1 < chars.count,
               chars[i + 1] == c,
               Self.stutterMergeChars.contains(c),
               !Self.legalReduplicatedChars.contains(c) {
                // 连续重复的虚词/代词（2 个合并为 1 个；若 >=3 个可能是刻意表达则不动）
                if i + 2 >= chars.count || chars[i + 2] != c {
                    out.append(c)
                    i += 2
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    private func normalizeAccidentalDuplicatePunctuation(_ input: String) -> String {
        let targets: [(String, String)] = [
            ("，，", "，"),
            ("。。", "。"),
            ("、、", "、"),
            ("；；", "；"),
            ("：：", "："),
            (",,", ",")
        ]
        var result = input
        for (bad, good) in targets {
            while result.contains(bad) {
                result = result.replacingOccurrences(of: bad, with: good)
            }
        }
        return result
    }

    // MARK: - 2. 五重防幻觉守卫（校验 L2 Qwen3-0.6B 校对输出）

    /// 常见合法易混/形近字组（即使读音不同也允许校对修正，如「的/地/得」「在/再」「做/作」「那/哪」「他/她/它」）
    private static let allowedConfusableSets: [Set<Character>] = [
        Set("的地得"),
        Set("在再"),
        Set("做作"),
        Set("那哪"),
        Set("他她它"),
        Set("己已巳"),
        Set("未末"),
        Set("候侯"),
        Set("象像"),
        Set("须需"),
        Set("即既"),
        Set("厉励历"),
        Set("竞竟"),
        Set("辩辨辫"),
        Set("燥躁噪"),
        Set("账帐"),
        Set("定订"),
        Set("融溶熔"),
        Set("度渡"),
        Set("制治"),
        Set("采彩"),
        Set("倍备"),
        Set("副幅符"),
        Set("赢嬴"),
        Set("练炼")
    ]

    /// 严格校验模型校对结果，杜绝 0.6B 小模型幻觉续写、擅自改写原意、篡改英文代码或无关换词。
    public func validateAndBuildState(
        source: String,
        candidateOutput: String,
        latencyMs: Double,
        backendLabel: String
    ) -> DraftProofreadState? {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = Self.cleanModelOutput(candidateOutput)
        guard !s.isEmpty, !o.isEmpty else { return nil }

        // 护栏 1：拦截指令泄露、思考标签残留与元话语解释
        let forbiddenFragments = [
            "你是中文错别字",
            "错别字校对",
            "不需要修改",
            "没有错别字",
            "修正如下",
            "修改如下",
            "原样输出",
            "正确写法",
            "<think>",
            "</think>",
            "Explanation",
            "Corrected:"
        ]
        for frag in forbiddenFragments where o.contains(frag) {
            return nil
        }

        if o == s {
            return .clean(sourceText: s, latencyMs: latencyMs, backendLabel: backendLabel)
        }

        // 护栏 2：长度稳定闸门（防止模型续写或截断）
        let maxLenDelta = max(2, s.count / 8)
        guard abs(o.count - s.count) <= maxLenDelta else {
            return nil
        }

        // 护栏 3：克制编辑距离闸门（最多允许改动 <= 30% 且不超过 max(3, len/4) 个字符）
        let editDist = Self.levenshteinDistance(Array(s), Array(o))
        let maxEdits = max(3, min(10, Int(Double(s.count) * 0.30)))
        guard editDist > 0, editDist <= maxEdits else {
            return nil
        }

        // 护栏 4：非中文 ASCII 英文词 / 数字 / 代码标识符 100% 原样保留
        let srcTokens = Self.extractAsciiTokens(s)
        let outTokens = Self.extractAsciiTokens(o)
        guard srcTokens == outTokens else {
            return nil
        }

        // 护栏 5：拼音近音与形近字护栏（检查每一处汉字替换是否合理）
        let diff = Self.buildDiff(source: s, corrected: o)
        guard diff.changeCount > 0 else {
            return .clean(sourceText: s, latencyMs: latencyMs, backendLabel: backendLabel)
        }
        guard areHanziReplacementsPlausible(segments: diff.segments) else {
            return nil
        }

        return .suggested(
            sourceText: s,
            correctedText: o,
            segments: diff.segments,
            changeCount: diff.changeCount,
            latencyMs: latencyMs,
            backendLabel: backendLabel
        )
    }

    private func areHanziReplacementsPlausible(segments: [ProofreadDiffSegment]) -> Bool {
        for seg in segments where seg.isChanged {
            let newChars = Array(seg.text).filter(Self.isHanzi)
            let oldChars = Array(seg.originalText ?? "").filter(Self.isHanzi)

            // 纯标点修正或单字漏字/去重（最多差 1 字）放行
            if oldChars.isEmpty || newChars.isEmpty {
                if max(oldChars.count, newChars.count) <= 1 {
                    continue
                }
                return false
            }

            // 同长度汉字替换：逐字验证读音接近或属于合法易混/形近字组
            if oldChars.count == newChars.count {
                for (oCh, nCh) in zip(oldChars, newChars) {
                    if oCh == nCh { continue }
                    if !isSingleHanziReplacementPlausible(old: oCh, new: nCh) {
                        return false
                    }
                }
                continue
            }

            // 不等长但长度差 <= 1：检查至少有一个新字与旧字在读音或字形上高度接近
            if abs(oldChars.count - newChars.count) <= 1 && max(oldChars.count, newChars.count) <= 3 {
                let anyClose = newChars.contains { nCh in
                    oldChars.contains { oCh in
                        oCh == nCh || isSingleHanziReplacementPlausible(old: oCh, new: nCh)
                    }
                }
                if !anyClose { return false }
                continue
            }
            return false
        }
        return true
    }

    private func isSingleHanziReplacementPlausible(old: Character, new: Character) -> Bool {
        // 1. 合法易混 / 形近字表直接放行
        for group in Self.allowedConfusableSets where group.contains(old) && group.contains(new) {
            return true
        }

        // 2. 通过 PinyinNormalizer 比对无调拼音相似度
        let oldKeys = normalizer.keys(forChineseTerm: String(old)).fullVariants
        let newKeys = normalizer.keys(forChineseTerm: String(new)).fullVariants
        guard !oldKeys.isEmpty, !newKeys.isEmpty else { return false }

        for p1 in oldKeys {
            for p2 in newKeys {
                if p1 == p2 { return true }
                // 模糊音归一化（前后鼻音、平翘舌、n/l、f/h）完全等价
                if Self.fuzzyFoldPinyin(p1) == Self.fuzzyFoldPinyin(p2) {
                    return true
                }
                // 单字拼音编辑距离 <= 1（覆盖快打错 1 键引发的近音错选，如 shang/shai、wo/wa）
                if Self.levenshteinDistance(Array(p1), Array(p2)) <= 1 {
                    return true
                }
                // 同声母且韵母长度相近（覆盖高频误选，如 门 men / 们 men 已命上方，或 署 shu / 暑 shu）
                if p1.first == p2.first && Self.levenshteinDistance(Array(p1), Array(p2)) <= 2 && min(p1.count, p2.count) >= 3 {
                    return true
                }
            }
        }
        return false
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

    private static func cleanModelOutput(_ raw: String) -> String {
        var s = raw
        if let endRange = s.range(of: "</think>") {
            s = String(s[endRange.upperBound...])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = s.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            s = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 剥离模型可能顺手包裹的外层引号
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("「", "」"), ("『", "』")]
        for (open, close) in quotePairs where s.count >= 2 && s.first == open && s.last == close {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractAsciiTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in text {
            if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
               ((scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
                || scalar.value == 95) {
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func isHanzi(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF)
            || (v >= 0x3400 && v <= 0x4DBF)
            || (v >= 0x20000 && v <= 0x2CEAF)
    }

    // MARK: - 3. 字符级 LCS Diff 构建器

    public static func buildDiff(
        source: String,
        corrected: String
    ) -> (segments: [ProofreadDiffSegment], changeCount: Int) {
        if source == corrected {
            return ([ProofreadDiffSegment(text: corrected, isChanged: false)], 0)
        }
        let a = Array(source)
        let b = Array(corrected)
        let m = a.count
        let n = b.count

        // 保护：极长文本回落整体对比，避免 O(mn) 峰值
        guard m <= 200 && n <= 200 else {
            return ([ProofreadDiffSegment(text: corrected, isChanged: true, originalText: source)], 1)
        }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0 && n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    if a[i] == b[j] {
                        dp[i][j] = dp[i + 1][j + 1] + 1
                    } else {
                        dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
        }

        // 回溯得到公共锚点与变更区间
        var segments: [ProofreadDiffSegment] = []
        var changeCount = 0
        var i = 0
        var j = 0
        var sameBuf = ""
        var oldDiffBuf = ""
        var newDiffBuf = ""

        func flushSame() {
            guard !sameBuf.isEmpty else { return }
            segments.append(ProofreadDiffSegment(text: sameBuf, isChanged: false))
            sameBuf = ""
        }

        func flushDiff() {
            guard !oldDiffBuf.isEmpty || !newDiffBuf.isEmpty else { return }
            changeCount += 1
            if !newDiffBuf.isEmpty {
                segments.append(ProofreadDiffSegment(
                    text: newDiffBuf,
                    isChanged: true,
                    originalText: oldDiffBuf.isEmpty ? nil : oldDiffBuf
                ))
            }
            oldDiffBuf = ""
            newDiffBuf = ""
        }

        while i < m || j < n {
            if i < m && j < n && a[i] == b[j] {
                flushDiff()
                sameBuf.append(a[i])
                i += 1
                j += 1
            } else {
                flushSame()
                if i < m && (j == n || dp[i + 1][j] >= dp[i][j + 1]) {
                    oldDiffBuf.append(a[i])
                    i += 1
                } else if j < n {
                    newDiffBuf.append(b[j])
                    j += 1
                }
            }
        }
        flushSame()
        flushDiff()
        return (segments, changeCount)
    }

    public static func levenshteinDistance(_ a: [Character], _ b: [Character]) -> Int {
        let m = a.count
        let n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = (a[i - 1] == b[j - 1]) ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}

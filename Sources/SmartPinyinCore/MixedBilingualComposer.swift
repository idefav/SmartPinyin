import Foundation
import PinyinEngineCore
import SharedIPC

/// 中英混输 / 英文联想 / 英文拼写纠错合成候选
public struct MixedBilingualCandidate: Equatable, Sendable {
    public let text: String
    /// 供个人记忆与工作记忆回写的规范键（如 gitdizhi / docker / reactzujian）
    public let canonicalKey: String
    public let rank: Int
    /// 原输入无法被 Rime 作为合法中文整串覆盖（true 时高置信候选可直接置顶第 1 位；false 时作为次选绝不误抢纯中文首位）
    public let isFragmentedSource: Bool
    /// 是否由英文拼写纠错产生（用于标注「纠」微标及按编辑代价动态降权）
    public let isSpellCorrected: Bool
    public let editCost: Double

    public init(
        text: String,
        canonicalKey: String,
        rank: Int,
        isFragmentedSource: Bool,
        isSpellCorrected: Bool = false,
        editCost: Double = 0.0
    ) {
        self.text = text
        self.canonicalKey = canonicalKey
        self.rank = rank
        self.isFragmentedSource = isFragmentedSource
        self.isSpellCorrected = isSpellCorrected
        self.editCost = editCost
    }
}

/// 动态中英混输切分、英文词典补全与英文拼写纠错合成引擎（< 0.6ms，纯离线）：
/// - Path B-exact：英文精确前缀 + 中文全拼/前缀/2字简拼（gitdiz -> git地址、reactzj -> React组件、dockerjx -> Docker镜像、apiwd -> API文档）
/// - Path A：纯英文精确/精选技术前缀联想 + 1/2-edit QWERTY 拼写纠错（git / dock / dokcer / recat / enviroment / typescritp）
/// - Path B-typo：英文错拼前缀恢复 + 中文拼音/简拼（gtidiz -> git地址、dokcerjx -> Docker镜像、recatzj -> React组件）
/// - Path C：中文全拼前缀 + 英文后缀（含前缀补全与错拼恢复）（wodegit -> 我的git、yongreac -> 用React、yongdokcer -> 用Docker）
/// - Path D：中文 + 精选非拼音技术词 + 中文三段合成（wodegitdizhi -> 我的git地址、kanxiareactzujian -> 看下React组件）
public final class MixedBilingualComposer: @unchecked Sendable {
    private let lexicon: EnglishLexiconStore
    private let normalizer: PinyinNormalizer
    private let lock = NSLock()
    private var probeCache: [String: [String]] = [:]
    private let probeCacheLimit = 128

    /// 懒加载缓存的技术中文搭配词及其拼音键（仅初始化一次，< 1ms）
    private var indexedTechFollowups: [(word: String, keys: PinyinNormalizer.TermPinyinKeys)]?

    /// 仅允许参与中英混合切分的 2 字母技术缩写（严格排除 sh/zh/ch/he/de/re/ge 等中文声母或单音节，杜绝 shaighai -> sh爱国还）
    private static let mixedTwoLetterAllowlist: Set<String> = [
        "ai", "pr", "ui", "ux", "go", "ci", "cd", "js", "ts",
        "db", "os", "ip", "id", "vr", "ar", "qr", "ml", "dl",
        "pm", "hr", "md", "py"
    ]

    /// 高频技术前缀（即便整串偶然可按中文全拼切分，如 apiwendang = a'pi'wen'dang，也允许生成次选混输候选）
    private static let highPriorityTechPrefixes: Set<String> = [
        "api", "ai", "ui", "ux", "pr", "go", "ci", "cd", "js", "ts",
        "db", "os", "ip", "id", "app", "mac", "ios", "web", "dev",
        "doc", "log", "key", "bug", "git", "url", "ssh", "sql", "llm",
        "gpt", "sdk", "cli", "ide", "mcp", "vpn", "cpu", "gpu", "pdf", "png", "svg"
    ]

    /// 针对核心英文技术词的专属高频中文搭配（优先于通用 Rime 简拼排序，解决 gitck->git仓库、reactzj->React组件、dockerjx->Docker镜像、apiwd->API文档）
    private static let specificTechCollocations: [String: [String]] = [
        "git": ["地址", "仓库", "分支", "提交", "合并", "拉取", "推送", "克隆", "配置", "日志", "历史", "忽略", "冲突", "版本", "账号", "命令"],
        "github": ["地址", "仓库", "账号", "项目", "主页", "链接", "开源", "源码", "配置", "令牌", "镜像", "代码"],
        "gitlab": ["地址", "仓库", "账号", "项目", "流水线", "配置", "分支", "合并"],
        "docker": ["镜像", "容器", "部署", "配置", "网络", "日志", "命令", "服务", "环境", "启动", "构建", "文件"],
        "react": ["组件", "状态", "页面", "路由", "项目", "框架", "源码", "渲染", "性能", "代码", "插件", "生态"],
        "vue": ["组件", "页面", "路由", "状态", "项目", "框架", "源码", "指令", "模板", "插件"],
        "api": ["文档", "接口", "地址", "密钥", "请求", "调用", "参数", "网关", "服务", "测试", "规范", "权限", "返回"],
        "url": ["地址", "链接", "参数", "路径", "编码", "解析", "跳转", "配置"],
        "ssh": ["密钥", "连接", "登录", "配置", "端口", "代理", "隧道", "证书", "权限"],
        "http": ["请求", "协议", "服务", "接口", "代理", "端口", "响应", "状态"],
        "https": ["证书", "请求", "协议", "地址", "链接", "代理", "加密"],
        "pr": ["合并", "评审", "评论", "链接", "提交", "分支", "标题", "描述"],
        "bug": ["修复", "排查", "复现", "定位", "列表", "记录", "反馈", "原因"],
        "python": ["脚本", "代码", "环境", "版本", "依赖", "项目", "教程", "服务", "性能"],
        "swift": ["代码", "项目", "版本", "编译", "并发", "框架", "语法", "测试"],
        "rust": ["代码", "项目", "编译", "性能", "内存", "工具", "生态", "语言"],
        "go": ["语言", "代码", "项目", "服务", "并发", "模块", "框架", "编译"],
        "node": ["版本", "环境", "服务", "项目", "模块", "依赖", "脚本"],
        "npm": ["依赖", "镜像", "配置", "命令", "安装", "构建", "脚本"],
        "sql": ["语句", "查询", "优化", "索引", "注入", "脚本", "数据库"],
        "ai": ["模型", "工具", "助手", "对话", "生成", "编程", "能力", "应用", "搜索", "翻译", "校对"],
        "llm": ["模型", "推理", "微调", "部署", "评测", "应用", "接口"],
        "ui": ["界面", "设计", "组件", "样式", "布局", "交互", "规范", "测试"],
        "ux": ["体验", "设计", "交互", "流程", "优化"],
        "k8s": ["集群", "部署", "容器", "配置", "节点", "服务", "网络", "日志"],
        "ci": ["流程", "流水线", "构建", "测试", "配置", "部署"],
        "cd": ["部署", "发布", "流水线", "配置"],
        "mcp": ["服务", "工具", "协议", "配置", "接口", "插件"]
    ]

    /// 通用开发者/办公中英混输高频中文搭配词库（约 110 词）
    private static let generalTechChineseFollowups: [String] = [
        "地址", "仓库", "分支", "提交", "合并", "拉取", "推送", "克隆",
        "组件", "镜像", "容器", "文档", "接口", "请求", "响应", "配置",
        "脚本", "代码", "项目", "工程", "服务", "环境", "版本", "依赖",
        "插件", "模块", "页面", "样式", "状态", "变量", "函数", "方法",
        "参数", "类型", "测试", "单测", "日志", "报错", "错误", "异常",
        "修复", "调试", "部署", "构建", "打包", "编译", "运行", "安装",
        "更新", "升级", "启动", "重启", "密钥", "令牌", "证书", "端口",
        "域名", "路径", "目录", "文件", "数据", "数据库", "服务器", "客户端",
        "权限", "账号", "密码", "模型", "工具", "命令", "终端", "界面",
        "设计", "流程", "规范", "教程", "问题", "方案", "原理", "性能",
        "内存", "缓存", "队列", "线程", "协议", "框架", "架构", "网络",
        "代理", "链接", "登录", "注册", "同步", "备份", "迁移", "回滚",
        "发布", "上线", "监控", "告警", "指标", "工作流", "流水线", "语言",
        "系统", "应用", "软件", "官网", "社区", "生态", "源码", "内核",
        "引擎", "驱动", "集群", "节点", "调用", "渲染", "路由", "排查"
    ]

    public init(
        lexicon: EnglishLexiconStore = .shared,
        normalizer: PinyinNormalizer = PinyinNormalizer()
    ) {
        self.lexicon = lexicon
        self.normalizer = normalizer
    }

    public func suggest(
        rawPinyin: String,
        preedit: String,
        rimeTopCandidate: String?,
        isCodingMode: Bool,
        scene: InputSceneDomain,
        allowSpellCorrection: Bool,
        hasChineseTypoCorrection: Bool,
        documentIndex: DocumentContextIndex?,
        workingMemory: SessionWorkingMemory?,
        engine: PinyinEngineProtocol,
        maxResults: Int = 4
    ) -> [MixedBilingualCandidate] {
        let clean = rawPinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard clean.count >= 2, clean.count <= 22, maxResults > 0 else { return [] }

        let fullPinyinSyllables = PinyinTypoCorrector.segmentFullSyllables(clean)
        let isValidFullPinyin = (fullPinyinSyllables != nil)
        let rimeTopIsPureASCII = rimeTopCandidate.map {
            !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0.value < 128 }
        } ?? false
        let rimeCovered = Self.rimeCoversInput(
            raw: clean,
            rimeTop: rimeTopCandidate,
            fullSyllables: fullPinyinSyllables
        )
        let isFragmented = !isValidFullPinyin && !rimeCovered
        let preferTech = isCodingMode || scene == .computerScience

        // 若输入本身是合法纯中文全拼（且 Rime 未返回纯英文），且既非精选高频技术词也非精选技术词前缀，0ms 直接跳过！
        if isValidFullPinyin && !rimeTopIsPureASCII {
            let exactTech = lexicon.lookupExact(clean)?.isCuratedTech == true
            let startsWithTech = Self.startsWithHighPriorityTechPrefix(clean)
            guard exactTech || startsWithTech else { return [] }
        }

        var collected: [MixedBilingualCandidate] = []
        var seen = Set<String>()

        func appendCandidate(
            text: String,
            canonicalKey: String,
            isFragmentedSource: Bool,
            isSpellCorrected: Bool = false,
            editCost: Double = 0.0
        ) {
            guard !text.isEmpty, seen.insert(text).inserted else { return }
            collected.append(MixedBilingualCandidate(
                text: text,
                canonicalKey: canonicalKey,
                rank: collected.count,
                isFragmentedSource: isFragmentedSource,
                isSpellCorrected: isSpellCorrected,
                editCost: editCost
            ))
        }

        // ------------------------------------------------------------------
        // 1. Path B-exact：英文精确前缀 + 中文全拼/前缀/2字简拼（如 gitdiz -> git地址、reactzj -> React组件、apiwd -> API文档）
        // ------------------------------------------------------------------
        if clean.count >= 4 && !hasChineseTypoCorrection {
            let exactENCN = resolveExactEnglishPrefixPlusChinese(
                clean: clean,
                isFragmented: isFragmented,
                preferTech: preferTech,
                engine: engine
            )
            for item in exactENCN {
                appendCandidate(
                    text: item.text,
                    canonicalKey: item.canonicalKey,
                    isFragmentedSource: item.isFragmentedSource,
                    isSpellCorrected: item.isSpellCorrected,
                    editCost: item.editCost
                )
            }
        }

        // ------------------------------------------------------------------
        // 2. Path A：纯英文精确匹配 + 精选技术前缀补全（git -> git / GitHub, dock -> Docker）
        // ------------------------------------------------------------------
        let exactHit = lexicon.lookupExact(clean)
        if let exactHit, Self.isTrustedStandaloneEnglish(exactHit, rawLen: clean.count) {
            // 合法纯中文全拼（如 shanghai）下只放行精选技术词（AI / API / Go），绝不注入普通英文地名/外来词！
            if !isValidFullPinyin || exactHit.isCuratedTech || rimeTopIsPureASCII {
                let promoteTop = isFragmented || (preferTech && exactHit.isCuratedTech && clean.count >= 3 && !isValidFullPinyin)
                appendCandidate(
                    text: exactHit.display,
                    canonicalKey: exactHit.lower,
                    isFragmentedSource: promoteTop
                )
            }
        }

        // 前缀补全：碎裂输入（如 vsco -> VSCode）或 Rime 首位已是纯英文（如 git -> GitHub, dock -> Docker）时补充精选技术词
        if (isFragmented || rimeTopIsPureASCII) && clean.count >= 3 {
            let prefixes = lexicon.prefixCompletions(for: clean, limit: 4, preferCapitalized: false)
            let alreadyHasMixedChinese = collected.contains {
                $0.text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) })
            }
            if !alreadyHasMixedChinese {
                for entry in prefixes {
                    guard entry.lower != clean else { continue }
                    if rimeTopIsPureASCII && !isFragmented && !entry.isCuratedTech {
                        continue
                    }
                    appendCandidate(
                        text: entry.display,
                        canonicalKey: entry.lower,
                        isFragmentedSource: isFragmented
                    )
                }
            }
        }

        // ------------------------------------------------------------------
        // 3. Path A2：纯英文 1/2-edit 拼写纠错（优先于混输错拼与 CN+EN 切分，确保 dokcer -> Docker、recat -> React、typescritp -> TypeScript！）
        // ------------------------------------------------------------------
        let hasExactOrMixedMatch = collected.contains { !$0.isSpellCorrected }
        var hasStrongEnglishSpellCorrection = false
        if allowSpellCorrection && isFragmented && !hasExactOrMixedMatch && clean.count >= 3 {
            let corrections = lexicon.fuzzyCorrect(query: clean, curatedOnly: false, limit: 3)
            for corr in corrections {
                let corrIsValidPinyin = (PinyinTypoCorrector.segmentFullSyllables(corr.lower) != nil)
                let promote = !(hasChineseTypoCorrection && (corrIsValidPinyin || !corr.isCuratedTech))
                if promote {
                    hasStrongEnglishSpellCorrection = true
                }
                appendCandidate(
                    text: corr.text,
                    canonicalKey: corr.lower,
                    isFragmentedSource: promote,
                    isSpellCorrected: true,
                    editCost: corr.editCost
                )
            }
        }

        // ------------------------------------------------------------------
        // 4. Path B-typo：英文错拼前缀恢复 + 中文拼音/简拼（如 gtidiz -> git地址、dokcerjx -> Docker镜像、recatzj -> React组件）
        // ------------------------------------------------------------------
        if allowSpellCorrection && isFragmented && !hasExactOrMixedMatch && !hasStrongEnglishSpellCorrection && !hasChineseTypoCorrection && clean.count >= 5 {
            let typoENCN = resolveTypoEnglishPrefixPlusChinese(clean: clean, engine: engine)
            for item in typoENCN {
                appendCandidate(
                    text: item.text,
                    canonicalKey: item.canonicalKey,
                    isFragmentedSource: item.isFragmentedSource,
                    isSpellCorrected: item.isSpellCorrected,
                    editCost: item.editCost
                )
            }
        }

        // ------------------------------------------------------------------
        // 5. Path C：中文全拼前缀 + 英文后缀（如 wodegit -> 我的git、yongreac -> 用React、yongdokcer -> 用Docker）
        // ------------------------------------------------------------------
        if clean.count >= 5 && isFragmented && !hasStrongEnglishSpellCorrection && !hasChineseTypoCorrection && collected.count < maxResults {
            let mixedCNEN = resolveChinesePrefixPlusEnglish(
                clean: clean,
                allowSpellCorrection: allowSpellCorrection,
                documentIndex: documentIndex,
                workingMemory: workingMemory,
                engine: engine
            )
            for item in mixedCNEN {
                appendCandidate(
                    text: item.text,
                    canonicalKey: item.canonicalKey,
                    isFragmentedSource: true,
                    isSpellCorrected: item.isSpellCorrected,
                    editCost: item.editCost
                )
            }
        }

        // ------------------------------------------------------------------
        // 6. Path D：中文 + 精选非拼音技术词 + 中文三段兜底（如 wodegitdizhi -> 我的git地址）
        // ------------------------------------------------------------------
        if clean.count >= 7 && isFragmented && !hasChineseTypoCorrection && collected.isEmpty {
            let triple = resolveChineseEnglishChinese(clean: clean, engine: engine)
            for item in triple {
                appendCandidate(
                    text: item.text,
                    canonicalKey: item.canonicalKey,
                    isFragmentedSource: true
                )
            }
        }

        return Array(collected.prefix(maxResults))
    }

    // MARK: - Path B-exact: 精确英文前缀 + 中文拼音/前缀/2字简拼

    private func resolveExactEnglishPrefixPlusChinese(
        clean: String,
        isFragmented: Bool,
        preferTech: Bool,
        engine: PinyinEngineProtocol
    ) -> [MixedBilingualCandidate] {
        let chars = Array(clean)
        let n = chars.count
        let maxPrefix = min(12, n - 2)
        guard maxPrefix >= 2 else { return [] }

        var exactResults: [MixedBilingualCandidate] = []
        var seen = Set<String>()

        // 从长到短尝试，保证 githubdizhi 优先拆成 GitHub+dizhi 而非 git+hubdizhi
        for splitLen in stride(from: maxPrefix, through: 2, by: -1) {
            let enPart = String(chars[0..<splitLen])
            let zhPart = String(chars[splitLen..<n])
            guard zhPart.count >= 2 else { continue }
            guard let entry = lexicon.lookupExact(enPart),
                  Self.isTrustedMixedEnglishToken(entry, rawLen: splitLen, strictOnly: !isFragmented)
            else { continue }

            let zhWords = probeValidatedChinese(
                zhPart,
                forEnglishAnchor: entry.lower,
                isCuratedTechAnchor: entry.isCuratedTech,
                engine: engine,
                maxResults: 3
            )
            guard !zhWords.isEmpty else { continue }

            let promoteTop: Bool
            if isFragmented {
                promoteTop = true
            } else {
                promoteTop = preferTech && Self.highPriorityTechPrefixes.contains(enPart) && enPart.count >= 3
            }

            for zh in zhWords {
                let text = entry.display + zh
                guard seen.insert(text).inserted else { continue }
                exactResults.append(MixedBilingualCandidate(
                    text: text,
                    canonicalKey: enPart + zhPart,
                    rank: exactResults.count,
                    isFragmentedSource: promoteTop
                ))
                if exactResults.count >= 3 { return exactResults }
            }
            if !exactResults.isEmpty {
                return exactResults
            }
        }

        return []
    }

    // MARK: - Path B-typo: 英文前缀错拼恢复 + 中文拼音/前缀/2字简拼

    private func resolveTypoEnglishPrefixPlusChinese(
        clean: String,
        engine: PinyinEngineProtocol
    ) -> [MixedBilingualCandidate] {
        let chars = Array(clean)
        let n = chars.count
        guard n >= 5 else { return [] }
        let maxTypoPrefix = min(10, n - 2)

        var seen = Set<String>()
        for splitLen in stride(from: maxTypoPrefix, through: 3, by: -1) {
            let enPart = String(chars[0..<splitLen])
            let zhPart = String(chars[splitLen..<n])
            guard zhPart.count >= 2 else { continue }

            guard Self.looksLikeChinesePinyinOrAbbrev(zhPart) else { continue }
            let corrections = lexicon.fuzzyCorrect(query: enPart, curatedOnly: true, limit: 1)
            guard let bestCorr = corrections.first, bestCorr.editCost <= 0.78 else { continue }

            let zhWords = probeValidatedChinese(
                zhPart,
                forEnglishAnchor: bestCorr.lower,
                isCuratedTechAnchor: true,
                engine: engine,
                maxResults: 2
            )
            guard !zhWords.isEmpty else { continue }

            var typoResults: [MixedBilingualCandidate] = []
            for zh in zhWords {
                let text = bestCorr.text + zh
                guard seen.insert(text).inserted else { continue }
                typoResults.append(MixedBilingualCandidate(
                    text: text,
                    canonicalKey: bestCorr.lower + zhPart,
                    rank: typoResults.count,
                    isFragmentedSource: true,
                    isSpellCorrected: true,
                    editCost: bestCorr.editCost
                ))
            }
            if !typoResults.isEmpty {
                return typoResults
            }
        }
        return []
    }

    // MARK: - Path C: 中文全拼前缀 + 英文后缀（含前缀补全与错拼恢复）

    private func resolveChinesePrefixPlusEnglish(
        clean: String,
        allowSpellCorrection: Bool,
        documentIndex: DocumentContextIndex?,
        workingMemory: SessionWorkingMemory?,
        engine: PinyinEngineProtocol
    ) -> [MixedBilingualCandidate] {
        let chars = Array(clean)
        let n = chars.count
        let maxSuffix = min(12, n - 2)
        guard maxSuffix >= 2 else { return [] }

        var results: [MixedBilingualCandidate] = []
        var seen = Set<String>()

        // 1. 精确英文后缀（如 wodegit -> 我的git、kanxiabug -> 看下bug、yongreact -> 用React）
        for sufLen in stride(from: maxSuffix, through: 2, by: -1) {
            let zhPart = String(chars[0..<(n - sufLen)])
            let enPart = String(chars[(n - sufLen)..<n])
            guard let zhSyllables = PinyinTypoCorrector.segmentFullSyllables(zhPart), !zhSyllables.isEmpty else {
                continue
            }
            guard let entry = lexicon.lookupExact(enPart),
                  Self.isTrustedMixedEnglishToken(entry, rawLen: sufLen, strictOnly: sufLen == 2)
            else { continue }
            // 单音节中文前缀仅与精选技术词组合（如 yong+React -> 用React），避免普通英文词误切（如 re+cat -> 热cat）
            if zhSyllables.count == 1 && !entry.isCuratedTech {
                continue
            }

            let zhWords = probeExactSyllableChinese(zhPart, expectedChars: zhSyllables.count, engine: engine, maxResults: 2)
            guard !zhWords.isEmpty else { continue }

            for zh in zhWords {
                let text = zh + entry.display
                guard seen.insert(text).inserted else { continue }
                results.append(MixedBilingualCandidate(
                    text: text,
                    canonicalKey: zhPart + enPart,
                    rank: results.count,
                    isFragmentedSource: true
                ))
            }
            if !results.isEmpty { return results }
        }

        // 2. 技术/文档英文后缀前缀补全（如 yongreac -> 用React、dakaivsc -> 打开VSCode、wodegith -> 我的GitHub）
        if n >= 6 {
            let maxPrefSuf = min(10, n - 2)
            for sufLen in stride(from: maxPrefSuf, through: 3, by: -1) {
                let zhPart = String(chars[0..<(n - sufLen)])
                let enPrefix = String(chars[(n - sufLen)..<n])
                guard let zhSyllables = PinyinTypoCorrector.segmentFullSyllables(zhPart), !zhSyllables.isEmpty else {
                    continue
                }
                let docMatch = documentIndex?.matchEnglishCompletions(prefix: enPrefix, maxResults: 1).first
                let techMatch = lexicon.prefixCompletions(for: enPrefix, limit: 2, preferCapitalized: false)
                    .first { $0.isCuratedTech && $0.lower.count > sufLen }
                let resolvedDisplay = docMatch ?? techMatch?.display
                let resolvedLower = resolvedDisplay?.lowercased()
                guard let display = resolvedDisplay, let lower = resolvedLower else { continue }

                let zhWords = probeExactSyllableChinese(zhPart, expectedChars: zhSyllables.count, engine: engine, maxResults: 2)
                guard !zhWords.isEmpty else { continue }

                for zh in zhWords {
                    let text = zh + display
                    guard seen.insert(text).inserted else { continue }
                    results.append(MixedBilingualCandidate(
                        text: text,
                        canonicalKey: zhPart + lower,
                        rank: results.count,
                        isFragmentedSource: true
                    ))
                }
                if !results.isEmpty { return results }
            }
        }

        // 3. 英文后缀错拼恢复（如 yongdokcer -> 用Docker、wodegti -> 我的git）
        if allowSpellCorrection && n >= 6 {
            let maxTypoSuf = min(10, n - 2)
            for sufLen in stride(from: maxTypoSuf, through: 3, by: -1) {
                let zhPart = String(chars[0..<(n - sufLen)])
                let enTypo = String(chars[(n - sufLen)..<n])
                guard let zhSyllables = PinyinTypoCorrector.segmentFullSyllables(zhPart), !zhSyllables.isEmpty else {
                    continue
                }
                guard let corr = lexicon.fuzzyCorrect(query: enTypo, curatedOnly: true, limit: 1).first,
                      corr.editCost <= 0.78
                else { continue }

                let zhWords = probeExactSyllableChinese(zhPart, expectedChars: zhSyllables.count, engine: engine, maxResults: 2)
                guard !zhWords.isEmpty else { continue }

                for zh in zhWords {
                    let text = zh + corr.text
                    guard seen.insert(text).inserted else { continue }
                    results.append(MixedBilingualCandidate(
                        text: text,
                        canonicalKey: zhPart + corr.lower,
                        rank: results.count,
                        isFragmentedSource: true,
                        isSpellCorrected: true,
                        editCost: corr.editCost
                    ))
                }
                if !results.isEmpty { return results }
            }
        }

        _ = workingMemory
        return results
    }

    // MARK: - Path D: 中文 + 精选非拼音技术词 + 中文（如 wodegitdizhi -> 我的git地址）

    private func resolveChineseEnglishChinese(
        clean: String,
        engine: PinyinEngineProtocol
    ) -> [MixedBilingualCandidate] {
        let curated = lexicon.curatedTechEntries()
        var bestMatch: (left: String, mid: EnglishLexiconEntry, right: String)?

        for entry in curated {
            guard entry.isPureAlpha,
                  entry.lower.count >= 3,
                  entry.lower.count <= clean.count - 4,
                  PinyinTypoCorrector.segmentFullSyllables(entry.lower) == nil
            else { continue }
            guard let range = clean.range(of: entry.lower) else { continue }
            let leftPart = String(clean[..<range.lowerBound])
            let rightPart = String(clean[range.upperBound...])
            guard leftPart.count >= 2, rightPart.count >= 2 else { continue }
            guard PinyinTypoCorrector.segmentFullSyllables(leftPart) != nil else { continue }
            guard Self.looksLikeChinesePinyinOrAbbrev(rightPart) else { continue }
            if bestMatch == nil || entry.lower.count > bestMatch!.mid.lower.count {
                bestMatch = (leftPart, entry, rightPart)
            }
        }

        guard let hit = bestMatch,
              let leftSyls = PinyinTypoCorrector.segmentFullSyllables(hit.left)
        else { return [] }

        let leftWords = probeExactSyllableChinese(hit.left, expectedChars: leftSyls.count, engine: engine, maxResults: 1)
        let rightWords = probeValidatedChinese(
            hit.right,
            forEnglishAnchor: hit.mid.lower,
            isCuratedTechAnchor: true,
            engine: engine,
            maxResults: 2
        )
        guard let leftZh = leftWords.first, !rightWords.isEmpty else { return [] }

        return rightWords.enumerated().map { idx, rightZh in
            MixedBilingualCandidate(
                text: leftZh + hit.mid.display + rightZh,
                canonicalKey: hit.left + hit.mid.lower + hit.right,
                rank: idx,
                isFragmentedSource: true
            )
        }
    }

    // MARK: - Rime 探针 + 技术搭配提权 + 严格覆盖守卫

    private func techFollowupIndex() -> [(word: String, keys: PinyinNormalizer.TermPinyinKeys)] {
        lock.lock()
        if let existing = indexedTechFollowups {
            lock.unlock()
            return existing
        }
        lock.unlock()

        var built: [(word: String, keys: PinyinNormalizer.TermPinyinKeys)] = []
        built.reserveCapacity(Self.generalTechChineseFollowups.count)
        for word in Self.generalTechChineseFollowups {
            built.append((word, normalizer.keys(forChineseTerm: word)))
        }

        lock.lock()
        if indexedTechFollowups == nil {
            indexedTechFollowups = built
        }
        let result = indexedTechFollowups ?? built
        lock.unlock()
        return result
    }

    private func probeRaw(_ pinyin: String, engine: PinyinEngineProtocol) -> [String] {
        lock.lock()
        if let cached = probeCache[pinyin] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let probed = engine.probeCandidates(forPinyin: pinyin, limit: 10).map(\.text)
        lock.lock()
        if probeCache.count >= probeCacheLimit {
            probeCache.removeAll(keepingCapacity: true)
        }
        probeCache[pinyin] = probed
        lock.unlock()
        return probed
    }

    private func probeExactSyllableChinese(
        _ pinyin: String,
        expectedChars: Int,
        engine: PinyinEngineProtocol,
        maxResults: Int
    ) -> [String] {
        let raw = probeRaw(pinyin, engine: engine)
        var out: [String] = []
        var seen = Set<String>()
        for word in raw {
            guard word.count == expectedChars, Self.isPureHanzi(word), seen.insert(word).inserted else { continue }
            let keys = normalizer.keys(forChineseTerm: word)
            if keys.fullVariants.contains(pinyin) {
                out.append(word)
                if out.count >= maxResults { break }
            }
        }
        return out
    }

    /// 严格校验 `zhPart` 对应的中文搭配词（要求 >= 2 字，且严格满足全拼 / 全拼前缀 / 2字纯简拼三者之一，
    /// 彻底杜绝 aighai->爱国还、nem->女恶魔、critp->次日突破 等非法残拼；
    /// 并对精选技术英文锚点优先提权对应技术搭配词，如 git+ck->仓库、react+zj->组件、docker+jx->镜像、api+wd->文档）
    private func probeValidatedChinese(
        _ zhPart: String,
        forEnglishAnchor anchorLower: String,
        isCuratedTechAnchor: Bool,
        engine: PinyinEngineProtocol,
        maxResults: Int
    ) -> [String] {
        let fullSyls = PinyinTypoCorrector.segmentFullSyllables(zhPart)

        func strictlyMatches(_ word: String, keys: PinyinNormalizer.TermPinyinKeys) -> Bool {
            guard word.count >= 2, Self.isPureHanzi(word) else { return false }
            if let fullSyls {
                return word.count == fullSyls.count && keys.fullVariants.contains(zhPart)
            }
            if zhPart.count == 2 {
                return word.count == 2 && keys.initialVariants.contains(zhPart)
            }
            // 不完整尾音节（如 diz -> 地址 dizhi、zuj -> 组件 zujian、wend -> 文档 wendang）：
            // 必须是该词全拼的连续前缀，绝不允许跨音节随机抽首字母！
            return keys.fullVariants.contains { $0.hasPrefix(zhPart) }
        }

        var out: [String] = []
        var seen = Set<String>()

        // 1. 专属技术搭配（Tier 0，如 git->地址/仓库/分支、react->组件、docker->镜像/容器、api->文档/接口）
        if isCuratedTechAnchor, let specific = Self.specificTechCollocations[anchorLower] {
            for word in specific {
                let keys = normalizer.keys(forChineseTerm: word)
                if strictlyMatches(word, keys: keys), seen.insert(word).inserted {
                    out.append(word)
                    if out.count >= maxResults { return out }
                }
            }
        }

        // 2. 通用技术搭配（Tier 1，覆盖全部 ~240 个技术英文词与 ~110 个常见中文技术名词/动词）
        if isCuratedTechAnchor && out.count < maxResults {
            for item in techFollowupIndex() {
                if strictlyMatches(item.word, keys: item.keys), seen.insert(item.word).inserted {
                    out.append(item.word)
                    if out.count >= maxResults { return out }
                }
            }
        }

        // 3. Rime 探针召回（Tier 2，兜底任意日常/长尾中英混输，如 git教程 / React原理 / API测试）
        if out.count < maxResults {
            let raw = probeRaw(zhPart, engine: engine)
            for word in raw {
                guard seen.contains(word) == false else { continue }
                let keys = normalizer.keys(forChineseTerm: word)
                if strictlyMatches(word, keys: keys), seen.insert(word).inserted {
                    out.append(word)
                    if out.count >= maxResults { break }
                }
            }
        }

        return out
    }

    private static func rimeCoversInput(
        raw: String,
        rimeTop: String?,
        fullSyllables: [String]?
    ) -> Bool {
        guard let top = rimeTop, !top.isEmpty else { return false }
        if top.lowercased() == raw { return true }
        if let syls = fullSyllables, !syls.isEmpty {
            let hanziCount = top.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
            return hanziCount >= syls.count
        }
        // 纯简拼保护（如 zgr -> 中国人、wsm -> 为什么、xtwt -> 系统问题）：
        // 若 Rime 首选是纯汉字且字数恰好等于输入字母数，视为已被万象简拼完整解析
        if raw.count >= 2 && raw.count <= 6 && isPureHanzi(top) && top.count == raw.count {
            return true
        }
        return false
    }

    private static func startsWithHighPriorityTechPrefix(_ raw: String) -> Bool {
        for len in [4, 3, 2] where raw.count > len {
            let pref = String(raw.prefix(len))
            if highPriorityTechPrefixes.contains(pref) {
                return true
            }
        }
        return false
    }

    private static func isTrustedStandaloneEnglish(_ entry: EnglishLexiconEntry, rawLen: Int) -> Bool {
        if rawLen == 2 {
            return EnglishLexiconStore.curatedTwoLetterAllowlist.contains(entry.lower)
        }
        return entry.isCuratedTech || entry.weight >= 35
    }

    private static func isTrustedMixedEnglishToken(
        _ entry: EnglishLexiconEntry,
        rawLen: Int,
        strictOnly: Bool
    ) -> Bool {
        if rawLen == 2 {
            return mixedTwoLetterAllowlist.contains(entry.lower)
        }
        if strictOnly {
            return entry.isCuratedTech && highPriorityTechPrefixes.contains(entry.lower)
        }
        return entry.isCuratedTech || entry.weight >= 180
    }

    private static func looksLikeChinesePinyinOrAbbrev(_ s: String) -> Bool {
        guard s.count >= 2 && s.count <= 14 else { return false }
        if s.contains("v") { return false }
        if PinyinTypoCorrector.segmentFullSyllables(s) != nil { return true }
        // 2 字母纯简拼（如 dz / ck / zj / wd / jx）
        if s.count == 2 { return true }
        let chars = Array(s)
        // 检查前段是否能切出至少 1 个完整音节，且尾段是合法音节前缀（如 diz = di + z、zuj = zu + j）
        for cut in stride(from: chars.count - 1, through: 1, by: -1) {
            let head = String(chars[0..<cut])
            let tail = String(chars[cut..<chars.count])
            if tail.count <= 4,
               PinyinTypoCorrector.segmentFullSyllables(head) != nil,
               PinyinTypoCorrector.validSyllables.contains(where: { $0.hasPrefix(tail) }) {
                return true
            }
        }
        return false
    }

    private static func isPureHanzi(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { v in
            (0x4E00...0x9FFF).contains(v.value)
                || (0x3400...0x4DBF).contains(v.value)
                || (0x20000...0x2A6DF).contains(v.value)
        }
    }
}

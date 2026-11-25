import Foundation
import LocalInferenceCore
import PinyinEngineCore
import SharedIPC

struct BenchmarkRunner {
    static func run() {
        let cwd = FileManager.default.currentDirectoryPath
        let rimeDataDir = URL(fileURLWithPath: cwd).appendingPathComponent("Resources/RimeData")
        let reuseCache = CommandLine.arguments.contains("--reuse-rime-cache")
        let userDir: URL
        if reuseCache {
            userDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("SmartPinyinBench_RimeUser_Warm", isDirectory: true)
        } else {
            userDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("SmartPinyinBench_RimeUser_\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        defer {
            if !reuseCache {
                try? FileManager.default.removeItem(at: userDir)
            }
        }

        print("============================================================")
        print(" SmartPinyin 原生输入法端到端 Benchmark (Tier-C < 2GB)")
        print("============================================================")
        print("计算后端: \(LocalInferenceCoordinator.backendSummary())")
        print(String(
            format: "[Baseline] 空进程内存: phys_footprint=%.1f MB | RSS=%.1f MB",
            ProcessMemoryMonitor.physicalFootprintMB(),
            ProcessMemoryMonitor.residentSizeMB()
        ))

        // ------------------------------------------------------------------
        // 1. L1 拼音引擎 Benchmark (librime 1.17 + 万象词库 + LTS 语法模型)
        // ------------------------------------------------------------------
        print("\n--- [1/4] L1 确定性拼音引擎 (librime + 万象拼音 + 语法模型) ---")
        let rimeInitStart = CFAbsoluteTimeGetCurrent()
        let rime = RimeEngineAdapter(
            bundledDataDirectory: rimeDataDir,
            userDataDirectory: userDir,
            preferredSchemaID: "wanxiang"
        )
        let rimeInitMs = (CFAbsoluteTimeGetCurrent() - rimeInitStart) * 1000.0
        print(String(
            format: "初始化耗时: %.1f ms | 激活方案: %@ | phys=%.1f MB | RSS=%.1f MB",
            rimeInitMs,
            rime.activeSchemaID,
            ProcessMemoryMonitor.physicalFootprintMB(),
            ProcessMemoryMonitor.residentSizeMB()
        ))

        let pinyinCases: [(label: String, input: String)] = [
            ("全拼短句", "nihaoshijie"),
            ("全拼长句", "woxiangquchifan"),
            ("全拼办公", "jintianxiawusandiankaihui"),
            ("简拼常用1", "zgr"),
            ("简拼常用2", "wsm"),
            ("简拼常用3", "bzd"),
            ("简拼长串", "jtqwqcf"),
            ("混拼常用", "xianzaiqunali")
        ]

        // 预热一次
        _ = rime.feedASCII("nihao")
        rime.clearComposition()

        var perKeyLatenciesMs: [Double] = []
        for item in pinyinCases {
            rime.clearComposition()
            let t0 = CFAbsoluteTimeGetCurrent()
            var snap = PinyinEngineSnapshot.idle
            for ch in item.input.unicodeScalars {
                let k0 = CFAbsoluteTimeGetCurrent()
                let res = rime.processKey(keyval: Int32(ch.value), mask: 0)
                let kms = (CFAbsoluteTimeGetCurrent() - k0) * 1000.0
                perKeyLatenciesMs.append(kms)
                snap = res.snapshot
            }
            let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            let top3 = snap.candidates.prefix(3).map(\.text).joined(separator: " / ")
            print("  [\(item.label)] \(item.input.padding(toLength: 26, withPad: " ", startingAt: 0)) -> [\(top3)] (\(String(format: "%.2f", totalMs)) ms)")
        }
        rime.clearComposition()

        let sortedKeys = perKeyLatenciesMs.sorted()
        let p50 = percentile(sortedKeys, 0.50)
        let p95 = percentile(sortedKeys, 0.95)
        let p99 = percentile(sortedKeys, 0.99)
        let l1Phys = ProcessMemoryMonitor.physicalFootprintMB()
        let l1RSS = ProcessMemoryMonitor.residentSizeMB()
        print(String(format: "单次击键延迟: P50=%.2f ms | P95=%.2f ms | P99=%.2f ms | phys=%.1f MB | RSS=%.1f MB", p50, p95, p99, l1Phys, l1RSS))

        // ------------------------------------------------------------------
        // 2. L2 轻量槽 (Qwen3-0.6B-Q4_K_M)：语境重排 + 联想词句
        // ------------------------------------------------------------------
        let config = InferenceBudgetConfig.defaultConfig(projectModelsDir: cwd + "/Models")
        let coordinator = LocalInferenceCoordinator(config: config)
        var peakPhysMB = l1Phys
        var peakRSSMB = l1RSS

        func recordMem() -> (phys: Double, rss: Double) {
            let p = ProcessMemoryMonitor.physicalFootprintMB()
            let r = ProcessMemoryMonitor.residentSizeMB()
            peakPhysMB = max(peakPhysMB, p)
            peakRSSMB = max(peakRSSMB, r)
            return (p, r)
        }

        print("\n--- [2/4] L2 轻量槽 (Qwen3-0.6B-Q4_K_M: 语境重排 & 联想词句) ---")
        print("模型路径: \(config.lightModelPath)")
        let lightLoad = coordinator.ensureSlotLoadedSync(.light)
        let mLight = recordMem()
        print(String(format: "冷加载耗时: %.1f ms | phys=%.1f MB | RSS=%.1f MB (n_ctx=%d, KV=Q8_0)", lightLoad.loadMs, mLight.phys, mLight.rss, config.contextSize))

        let rerankCases: [(ctx: String, pinyin: String, cands: [String])] = [
            ("我去银行取钱，发现这家", "nh", ["你好", "女孩", "农行", "南海"]),
            ("周末带孩子去海边看日出，", "nh", ["你好", "女孩", "农行", "南海"]),
            ("写代码时经常遇到并发竞争和内存", "xl", ["下来", "心里", "泄露", "效率", "系列"]),
            ("请帮我把这份季度财务报表发到项目", "ql", ["起来", "群里", "清理", "强烈"])
        ]
        print("• 语境候选重排测试 (目标 < 40ms):")
        // 预热 Metal pipeline
        for _ in 0..<2 {
            _ = coordinator.rerankCandidatesSync(leftContext: "今天天气真", pinyin: "h", candidates: ["好", "很", "坏"], timeoutMs: 250)
        }
        var rerankLatencies: [Double] = []
        for rc in rerankCases {
            let out = coordinator.rerankCandidatesSync(
                leftContext: rc.ctx,
                pinyin: rc.pinyin,
                candidates: rc.cands,
                timeoutMs: 120
            )
            let m = recordMem()
            rerankLatencies.append(out.latencyMs)
            let before = rc.cands.first ?? ""
            let after = out.orderedCandidates.first ?? ""
            print(String(format: "  上文「%@」[%@]  首候选: %@ -> %@  (%.1f ms | phys=%.1f MB | RSS=%.1f MB)", rc.ctx, rc.pinyin, before, after, out.latencyMs, m.phys, m.rss))
        }

        let predictCases = [
            "今天天气",
            "明天北京",
            "不好意思",
            "请问一下",
            "今天下午三点有个产品评审会，",
            "周末打算和朋友去公园",
            "麻烦帮我查一下这个报错的",
            "系统问题出现在",
            "麻烦帮我确认一下这个方案",
            "这个接口偶发超时"
        ]
        print("• 联想词句续写测试 (Qwen3-0.6B 共享 KV 原生多分支续写):")
        // 预热一次生成路径
        _ = coordinator.predictContinuationSync(leftContext: "明天上午我们一起", maxSuggestions: 2)
        var predLatencies: [Double] = []
        for ctx in predictCases {
            let pred = coordinator.predictContinuationSync(leftContext: ctx, maxSuggestions: 3)
            let m = recordMem()
            predLatencies.append(pred.latencyMs)
            let joined = pred.suggestions.joined(separator: " | ")
            print(String(format: "  上文「%@」 -> [%@] (total %.1f ms | phys=%.1f MB | RSS=%.1f MB)", ctx, joined, pred.latencyMs, m.phys, m.rss))
        }

        // ------------------------------------------------------------------
        // 3. L3 专职翻译槽 (HY-MT1.5-1.8B-Q4_K_M)：从 L2 互斥切换 + 多语种翻译
        // ------------------------------------------------------------------
        print("\n--- [3/4] L3 专职翻译槽 (HY-MT1.5-1.8B-Q4_K_M: 互斥懒加载 + 回车译文) ---")
        print("模型路径: \(config.translationModelPath)")
        let transLoad = coordinator.ensureSlotLoadedSync(.translation)
        let mTransLoad = recordMem()
        print(String(format: "从 L2 卸载并冷加载 L3 耗时: %.1f ms | phys=%.1f MB | RSS=%.1f MB", transLoad.loadMs, mTransLoad.phys, mTransLoad.rss))

        // 预热一次
        _ = coordinator.translateTextSync(sourceText: "你好", target: .english, bypassCache: true)

        let translateCases: [(src: String, lang: TargetLanguage)] = [
            ("今天下午三点开会，请大家提前准备好周报。", .english),
            ("我想去附近吃顿火锅，顺便聊聊新项目的架构方案。", .english),
            ("这个接口偶发超时，怀疑是数据库连接池打满了。", .english),
            ("不好意思，我晚五分钟到会议室。", .japanese),
            ("很高兴认识你，期待后续合作。", .korean)
        ]

        var transLatencies: [Double] = []
        for tc in translateCases {
            if let res = coordinator.translateTextSync(sourceText: tc.src, target: tc.lang, bypassCache: true) {
                transLatencies.append(res.latencyMs)
                let m = recordMem()
                print(String(format: "  [中→%@] %@\n          => %@ (%.1f ms | phys=%.1f MB | RSS=%.1f MB)", tc.lang.shortBadge, tc.src, res.translatedText, res.latencyMs, m.phys, m.rss))
            } else {
                print("  [中→\(tc.lang.shortBadge)] 翻译失败或模型缺失")
            }
        }

        // 验证预翻译命中缓存的回车 0ms 瞬时体验
        if let first = translateCases.first,
           let cached = coordinator.translateTextSync(sourceText: first.src, target: first.lang, bypassCache: false) {
            print(String(format: "  [预翻译缓存命中模拟回车] => %@ (%.2f ms, fromCache=%@)", cached.translatedText, cached.latencyMs, cached.fromCache ? "true" : "false"))
        }

        // 分段打字翻译回归验证：即使传入已上屏英文 leftContext="Hello!Today"，也绝不复读回声或重复翻译 today
        print("• 分段打字翻译防冲突回归测试 (leftContext=\"Hello!Today\"):")
        let piecemealCases = ["你好", "今天", "的", "天气不错", "今天天气不错"]
        for src in piecemealCases {
            if let res = coordinator.translateTextSync(
                sourceText: src,
                leftContext: "Hello!Today",
                target: .english,
                bypassCache: true
            ) {
                print(String(format: "  [%@] => %@ (%.1f ms)", src, res.translatedText, res.latencyMs))
            } else {
                print("  [\(src)] => <rejected/empty>")
            }
        }

        // ------------------------------------------------------------------
        // 4. 空闲自动卸载与 < 2GB 红线汇总
        // ------------------------------------------------------------------
        print("\n--- [4/4] 空闲卸载与内存红线汇总 ---")
        coordinator.unloadNow()
        let unloadPhys = ProcessMemoryMonitor.physicalFootprintMB()
        let unloadRSS = ProcessMemoryMonitor.residentSizeMB()
        let avgRerankMs = rerankLatencies.isEmpty ? 0 : rerankLatencies.reduce(0, +) / Double(rerankLatencies.count)
        let avgPredMs = predLatencies.isEmpty ? 0 : predLatencies.reduce(0, +) / Double(predLatencies.count)
        let avgTransMs = transLatencies.isEmpty ? 0 : transLatencies.reduce(0, +) / Double(transLatencies.count)

        print(String(format: "空闲卸载后内存:         phys_footprint=%.1f MB | RSS=%.1f MB", unloadPhys, unloadRSS))
        print(String(format: "全程峰值 phys_footprint: %.1f MB / 2048 MB -> %@", peakPhysMB, peakPhysMB < 2048.0 ? "PASS" : "EXCEEDED"))
        print(String(format: "全程峰值 RSS (含mmap页): %.1f MB / 2048 MB -> %@", peakRSSMB, peakRSSMB < 2048.0 ? "PASS" : "EXCEEDED"))
        print(String(format: "L1 单击键 P99:           %.2f ms (目标 < 5ms)", p99))
        print(String(format: "L2 语境重排平均耗时:     %.1f ms (目标 < 40ms)", avgRerankMs))
        print(String(format: "L2 联想续写平均耗时:     %.1f ms", avgPredMs))
        print(String(format: "L3 实时翻译平均耗时:     %.1f ms", avgTransMs))
        print("============================================================")
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[idx]
    }
}

BenchmarkRunner.run()

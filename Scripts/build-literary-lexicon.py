#!/usr/bin/env python3
"""
离线构建 SmartPinyin 诗词/成语与多领域知识库二进制索引：
  - Resources/Lexicon/literary_tags.bin  (SMLT v1: 128-bit 排序哈希表，成语 + 古诗词名句)
  - Resources/Lexicon/domain_tags.bin    (SMDM v1: 128-bit 排序哈希 + UInt16 多领域位掩码)
  - Resources/Lexicon/NOTICE.txt         (开源语料协议归属声明)

所有内置数据均来自宽松开源协议（MIT / CC-BY-4.0 / 自研精编），确保 100% 离线运行、零外部运行时依赖。
"""

from __future__ import annotations

import json
import os
import re
import struct
import subprocess
import sys
import urllib.request
from pathlib import Path
from typing import Iterable, Sequence

ROOT_DIR = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT_DIR / "Resources" / "Lexicon"
RIME_DICTS_DIR = ROOT_DIR / "Resources" / "RimeData" / "dicts"

# 与 Swift 侧 DomainAndLiteraryTagStore 完全一致的 128-bit 哈希常数与位掩码
FNV64_OFFSET_HI = 0xCBF29CE484222325
FNV64_OFFSET_LO = 0x84222325CBF29CE4
FNV64_PRIME = 0x100000001B3
LEN_MIX_CONST = 0x9E3779B97F4A7C15
MASK64 = 0xFFFFFFFFFFFFFFFF

DOMAIN_CS = 1 << 0
DOMAIN_GAMING = 1 << 1
DOMAIN_MATH = 1 << 2
DOMAIN_SCIENCE = 1 << 3
DOMAIN_ART = 1 << 4
DOMAIN_LITERATURE = 1 << 5
DOMAIN_MEDICINE = 1 << 6
DOMAIN_FINANCE_LAW = 1 << 7

CJK_RE = re.compile(r"^[\u4e00-\u9fff]+$")
CLAUSE_SPLIT_RE = re.compile(r"[，。！？；、：,.!?;:\s《》「」『』（）()\[\]·—\-]+")

# 高频泛用词黑名单（避免 THUOCL 等网页语料里的通用词误触发专业场景）
GENERIC_STOPWORDS: frozenset[str] = frozenset({
    "时间", "问题", "工作", "方法", "系统", "管理", "发展", "技术", "公司", "企业",
    "用户", "信息", "数据", "内容", "服务", "产品", "平台", "网络", "市场", "中国",
    "国际", "国家", "社会", "经济", "文化", "生活", "活动", "项目", "方案", "计划",
    "功能", "效果", "结果", "原因", "情况", "条件", "标准", "要求", "需要", "可以",
    "进行", "使用", "实现", "提高", "增加", "减少", "改变", "影响", "作用", "关系",
    "开始", "结束", "完成", "继续", "支持", "帮助", "提供", "选择", "决定", "认为",
    "觉得", "知道", "了解", "发现", "看到", "听到", "感觉", "希望", "喜欢", "需要",
    "今天", "明天", "昨天", "现在", "以前", "以后", "时候", "地方", "东西", "事情",
    "朋友", "大家", "自己", "我们", "你们", "他们", "什么", "怎么", "为什么", "因为",
    "所以", "但是", "如果", "虽然", "而且", "或者", "以及", "关于", "通过", "根据",
    "世界", "北京", "上海", "广州", "深圳", "中心", "部门", "人员", "单位", "机构",
    "基础", "基本", "主要", "重要", "一般", "特殊", "正常", "简单", "复杂", "容易",
    "困难", "直接", "间接", "完全", "部分", "全部", "整体", "具体", "详细", "明确",
    "设计", "开发", "测试", "运行", "处理", "分析", "研究", "学习", "教育", "培训",
    "专业", "行业", "领域", "方向", "目标", "任务", "过程", "阶段", "步骤", "方式",
    "模式", "类型", "形式", "结构", "组成", "特点", "优势", "价值", "意义", "水平",
    "能力", "质量", "效率", "成本", "价格", "费用", "资金", "资源", "环境", "安全",
    "保护", "控制", "检查", "监督", "评价", "评估", "比较", "对比", "总结", "报告",
    "记录", "文件", "资料", "文档", "材料", "设备", "工具", "软件", "硬件", "程序",
    "应用", "操作", "点击", "输入", "输出", "显示", "查看", "下载", "上传", "安装",
    "设置", "配置", "修改", "更新", "升级", "维护", "解决", "修复", "优化", "调整",
    "视频", "图片", "文字", "声音", "颜色", "大小", "位置", "速度", "数量", "比例",
    "健康", "身体", "生活", "家庭", "孩子", "学生", "老师", "医生", "患者", "病人",
    "手机", "电脑", "游戏", "数学", "科学", "美术", "音乐", "电影", "电视", "新闻",
    "网站", "页面", "账号", "密码", "登录", "注册", "支付", "订单", "客户", "销售",
})


def hash128(text: str) -> tuple[int, int]:
    """与 Swift 侧 bit-exact 一致的 128-bit 双 FNV-1a 哈希。"""
    raw = text.encode("utf-8")
    hi = FNV64_OFFSET_HI
    for b in raw:
        hi = ((hi ^ b) * FNV64_PRIME) & MASK64
    lo = FNV64_OFFSET_LO
    for b in reversed(raw):
        lo = ((lo ^ b) * FNV64_PRIME) & MASK64
    lo = (lo ^ ((len(raw) * LEN_MIX_CONST) & MASK64)) & MASK64
    return (hi, lo)


def fetch_text(url: str, timeout: int = 25) -> str:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "SmartPinyin-LexiconBuilder/1.0"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="ignore")


def to_simplified_batch(texts: Sequence[str]) -> list[str]:
    """使用 macOS 原生 Foundation CFStringTransform (Traditional-Simplified) 批量转简体。"""
    if not texts:
        return []
    swift_code = r"""
import Foundation
let data = FileHandle.standardInput.readDataToEndOfFile()
guard let input = String(data: data, encoding: .utf8) else { exit(0) }
let m = NSMutableString(string: input) as CFMutableString
CFStringTransform(m, nil, "Traditional-Simplified" as CFString, false)
let out = (m as String).data(using: .utf8)!
FileHandle.standardOutput.write(out)
"""
    joined = "\n".join(texts).encode("utf-8")
    proc = subprocess.run(
        ["swift", "-e", swift_code],
        input=joined,
        capture_output=True,
        check=True,
    )
    converted = proc.stdout.decode("utf-8").split("\n")
    if len(converted) != len(texts):
        raise RuntimeError(f"Simplified batch count mismatch: {len(converted)} vs {len(texts)}")
    return converted


def extract_poetry_clauses(raw_lines: Iterable[str]) -> set[str]:
    out: set[str] = set()
    for line in raw_lines:
        for clause in CLAUSE_SPLIT_RE.split(line):
            c = clause.strip()
            if 4 <= len(c) <= 14 and CJK_RE.match(c):
                out.add(c)
    return out


def collect_literary_sets() -> tuple[set[str], set[str], dict[str, int]]:
    stats: dict[str, int] = {}

    # 1. 成语源：chinese-xinhua (MIT) + THUOCL_chengyu (MIT)
    print("-> 拉取 chinese-xinhua idiom.json (MIT)...")
    idiom_json = json.loads(
        fetch_text("https://raw.githubusercontent.com/pwxcoo/chinese-xinhua/master/data/idiom.json")
    )
    idioms: set[str] = set()
    for item in idiom_json:
        w = str(item.get("word", "")).strip()
        if 4 <= len(w) <= 12 and CJK_RE.match(w):
            idioms.add(w)
    stats["xinhua_idioms"] = len(idioms)

    print("-> 拉取 THUOCL_chengyu.txt (MIT)...")
    thu_cy_raw = fetch_text("https://raw.githubusercontent.com/thunlp/THUOCL/master/data/THUOCL_chengyu.txt")
    thu_cy_count = 0
    for line in thu_cy_raw.splitlines():
        w = line.split("\t")[0].strip()
        if 4 <= len(w) <= 12 and CJK_RE.match(w):
            idioms.add(w)
            thu_cy_count += 1
    stats["thuocl_chengyu"] = thu_cy_count

    # 2. 诗词名句源：THUOCL_poem (MIT) + chinese-poetry 精选（唐诗三百首/宋词三百首/千家诗/诗经/古文观止）
    print("-> 拉取 THUOCL_poem.txt (MIT)...")
    thu_poem_raw = fetch_text("https://raw.githubusercontent.com/thunlp/THUOCL/master/data/THUOCL_poem.txt")
    thu_poems: set[str] = set()
    for line in thu_poem_raw.splitlines():
        w = line.split("\t")[0].strip()
        if 5 <= len(w) <= 14 and CJK_RE.match(w):
            thu_poems.add(w)
    stats["thuocl_poem"] = len(thu_poems)

    anthology_urls = [
        ("tang300", "https://raw.githubusercontent.com/chinese-poetry/chinese-poetry/master/%E8%92%99%E5%AD%A6/tangshisanbaishou.json"),
        ("songci300", "https://raw.githubusercontent.com/chinese-poetry/chinese-poetry/master/%E5%AE%8B%E8%AF%8D/%E5%AE%8B%E8%AF%8D%E4%B8%89%E7%99%BE%E9%A6%96.json"),
        ("qianjiashi", "https://raw.githubusercontent.com/chinese-poetry/chinese-poetry/master/%E8%92%99%E5%AD%A6/qianjiashi.json"),
        ("shijing", "https://raw.githubusercontent.com/chinese-poetry/chinese-poetry/master/%E8%AF%97%E7%BB%8F/shijing.json"),
    ]
    anthology_raw_lines: list[str] = []
    for label, url in anthology_urls:
        try:
            print(f"-> 拉取 chinese-poetry/{label} (MIT)...")
            doc = json.loads(fetch_text(url))
            collected = _walk_poetry_json(doc)
            stats[f"poetry_{label}_lines"] = len(collected)
            anthology_raw_lines.extend(collected)
        except Exception as exc:
            print(f"   [警告] 拉取 {label} 失败，已降级跳过: {exc}", file=sys.stderr)

    print(f"-> 批量繁简归一化 {len(anthology_raw_lines)} 条古诗文句...")
    simplified_lines = to_simplified_batch(anthology_raw_lines)
    anthology_clauses = extract_poetry_clauses(simplified_lines)
    # 经典名句强制兜底（确保中小学高频名句零遗漏）
    must_have_poetry = {
        "锄禾日当午", "汗滴禾下土", "谁知盘中餐", "粒粒皆辛苦",
        "床前明月光", "疑是地上霜", "举头望明月", "低头思故乡",
        "春眠不觉晓", "处处闻啼鸟", "夜来风雨声", "花落知多少",
        "白日依山尽", "黄河入海流", "欲穷千里目", "更上一层楼",
        "海内存知己", "天涯若比邻", "落霞与孤鹜齐飞", "秋水共长天一色",
        "明月几时有", "把酒问青天", "但愿人长久", "千里共婵娟",
        "先天下之忧而忧", "后天下之乐而乐", "人生自古谁无死", "留取丹心照汗青",
        "长风破浪会有时", "直挂云帆济沧海", "天生我材必有用", "千金散尽还复来",
        "会当凌绝顶", "一览众山小", "大漠孤烟直", "长河落日圆",
        "小荷才露尖尖角", "早有蜻蜓立上头", "接天莲叶无穷碧", "映日荷花别样红",
        "停车坐爱枫林晚", "霜叶红于二月花", "两个黄鹂鸣翠柳", "一行白鹭上青天",
        "飞流直下三千尺", "疑是银河落九天", "日照香炉生紫烟", "遥看瀑布挂前川",
        "孤帆远影碧空尽", "唯见长江天际流", "劝君更尽一杯酒", "西出阳关无故人",
        "莫愁前路无知己", "天下谁人不识君", "春风又绿江南岸", "明月何时照我还",
        "不识庐山真面目", "只缘身在此山中", "山重水复疑无路", "柳暗花明又一村",
        "沉舟侧畔千帆过", "病树前头万木春", "问渠那得清如许", "为有源头活水来",
        "等闲识得东风面", "万紫千红总是春", "好雨知时节", "当春乃发生",
        "随风潜入夜", "润物细无声", "独在异乡为异客", "每逢佳节倍思亲",
        "遥知兄弟登高处", "遍插茱萸少一人", "醉卧沙场君莫笑", "古来征战几人回",
        "秦时明月汉时关", "万里长征人未还", "但使龙城飞将在", "不教胡马度阴山",
        "大江东去", "浪淘尽", "千古风流人物", "谈笑间", "樯橹灰飞烟灭",
        "寻寻觅觅", "冷冷清清", "凄凄惨惨戚戚", "众里寻他千百度", "蓦然回首",
        "那人却在灯火阑珊处", "衣带渐宽终不悔", "为伊消得人憔悴", "两情若是久长时",
        "又岂在朝朝暮暮", "曾经沧海难为水", "除却巫山不是云", "身无彩凤双飞翼",
        "心有灵犀一点通", "春蚕到死丝方尽", "蜡炬成灰泪始干", "海上生明月",
        "天涯共此时", "关关雎鸠", "在河之洲", "窈窕淑女", "君子好逑",
        "蒹葭苍苍", "白露为霜", "所谓伊人", "在水一方", "路漫漫其修远兮",
        "吾将上下而求索", "老骥伏枥", "志在千里", "烈士暮年", "壮心不已",
        "采菊东篱下", "悠然见南山", "出淤泥而不染", "濯清涟而不妖",
        "处江湖之远", "居庙堂之高",
    }
    anthology_clauses |= {w for w in must_have_poetry if 4 <= len(w) <= 14}

    # 冲突裁决：
    # - 4 字标准成语留在 idioms，不重复放进 poetry（除诗经/唐宋纯诗句不在成语库中者）
    # - 5+ 字若出现在唐诗/宋词/千家诗名句中，归 poetry；若仅在 THUOCL_poem 且同时是成语（如「一言以蔽之」），归 idioms
    poetry = set(anthology_clauses - idioms)
    for w in thu_poems:
        if w not in idioms:
            poetry.add(w)
    # 剔除可能误入诗句的极少数日常 4 字非诗短语（仅保留 anthology 明确的 4 字诗句与 5-14 字诗句）
    poetry = {w for w in poetry if 4 <= len(w) <= 14 and CJK_RE.match(w) and w not in GENERIC_STOPWORDS}

    stats["final_idioms"] = len(idioms)
    stats["final_poetry"] = len(poetry)
    return idioms, poetry, stats


def _walk_poetry_json(node: object) -> list[str]:
    lines: list[str] = []
    if isinstance(node, list):
        for item in node:
            if isinstance(item, str):
                lines.append(item)
            else:
                lines.extend(_walk_poetry_json(item))
    elif isinstance(node, dict):
        for key in ("paragraphs", "content", "chapters"):
            if key in node:
                lines.extend(_walk_poetry_json(node[key]))
    return lines


def curated_domain_terms() -> dict[int, set[str]]:
    """精编高区分度核心领域术语（覆盖游戏、数学、计算机、美术设计、自然科学、文学、医学、财经法律）。"""
    return {
        DOMAIN_GAMING: {
            # 机制与通用玩法
            "排位", "排位赛", "段位", "上分", "掉分", "连胜", "连败", "匹配", "组排", "单排", "双排", "五排",
            "开黑", "带飞", "躺赢", "翻盘", "逆风", "顺风", "投降", "重开", "挂机", "掉线", "延迟", "帧率",
            "掉帧", "锁帧", "光追", "光线追踪", "抗锯齿", "垂直同步", "分辨率", "画质", "渲染管线", "着色器",
            "副本", "团本", "秘境", "深渊", "爬塔", "刷图", "搬砖", "打宝", "掉率", "爆率", "抽卡", "十连",
            "十连抽", "保底", "大保底", "小保底", "歪了", "欧皇", "非酋", "氪金", "零氪", "微氪", "月卡",
            "战令", "通行证", "赛季", "新赛季", "皮肤", "限定皮肤", "典藏", "联动", "卡池", "up池", "复刻",
            "角色", "英雄", "职业", "天赋", "技能", "大招", "必杀技", "连招", "普攻", "重击", "蓄力", "闪避",
            "弹反", "格挡", "招架", "韧性", "破韧", "破防", "霸体", "无敌帧", "后摇", "前摇", "取消后摇",
            "冷却", "冷却时间", "暴击", "暴击率", "暴击伤害", "爆伤", "穿透", "护甲", "魔抗", "抗性", "吸血",
            "回血", "护盾", "治疗", "奶妈", "辅助", "坦克", "肉盾", "输出", "爆发", "持续输出", "控制", "群控",
            "硬控", "软控", "沉默", "眩晕", "冰冻", "击飞", "击退", "减速", "灼烧", "中毒", "流血", "感电",
            "冻结", "蒸发", "融化", "超载", "超导", "扩散", "结晶", "激化", "绽放", "元素反应", "元素爆发",
            "元素战技", "圣遗物", "命座", "专武", "精炼", "突破", "养成", "配队", "轴", "伤害轴", "循环",
            # MOBA / FPS / RPG / 动作 / 肉鸽 / 沙盒
            "打野", "中路", "上路", "下路", "发育路", "对抗路", "游走", "支援", "抓人", "蹲草", "反野", "控龙",
            "小龙", "大龙", "暴君", "主宰", "推塔", "拆塔", "兵线", "补刀", "补兵", "控线", "对线", "换血",
            "单杀", "双杀", "三杀", "四杀", "五杀", "团战", "开团", "绕后", "拉扯", "风筝", "走砍", "走位",
            "视野", "插眼", "排眼", "真眼", "假眼", "闪现", "传送", "惩戒", "点燃", "净化", "幽灵疾步",
            "爆头", "压枪", "点射", "扫射", "盲狙", "瞬狙", "架枪", "拉枪", "预瞄", "跟枪", "急停", "身法",
            "烟雾弹", "闪光弹", "燃烧弹", "手雷", "投掷物", "拆包", "下包", "守包", "残局", "起枪", "经济局",
            "生态局", "半起", "全甲", "头盔", "防弹衣", "空投", "毒圈", "安全区", "跑毒", "吃鸡", "舔包",
            "搜刮", "撤离", "摸金", "跑刀", "战利品", "装备", "词条", "强化", "附魔", "镶嵌", "锻造", "合成",
            "任务", "主线", "支线", "日常", "周常", "成就", "白金", "全成就", "速通", "无伤", "一命通关",
            "魂类", "类魂", "肉鸽", "地牢", "开放世界", "沙盒", "建造", "生存", "联机", "局域网", "私服",
            "官服", "跨平台", "存档", "云存档", "读档", "回档", "模组", "创意工坊", "汉化", "补丁", "热修",
            "削弱", "加强", "重做", "平衡性", "版本答案", "超模", "下水道", "数值膨胀", "机制怪", "逃课",
            "篝火", "赐福", "褪色者", "法环", "黑魂", "只狼", "血源", "怪猎", "怪物猎人", "塞尔达", "王国之泪",
            "旷野之息", "博德之门", "赛博朋克", "巫师", "老头环", "黑神话", "悟空", "原神", "星穹铁道",
            "崩坏", "绝区零", "鸣潮", "王者荣耀", "英雄联盟", "无畏契约", "反恐精英", "绝地求生", "和平精英",
            "永劫无间", "守望先锋", "刀塔", "魔兽世界", "最终幻想", "任天堂", "宝可梦", "马里奥", "蒸汽平台",
            "手柄", "键鼠", "体感", "陀螺仪", "宏", "外挂", "透视挂", "自瞄", "封号", "反作弊",
        },
        DOMAIN_MATH: {
            "微积分", "导数", "偏导数", "全微分", "方向导数", "梯度", "散度", "旋度", "拉普拉斯", "不定积分",
            "定积分", "重积分", "二重积分", "三重积分", "曲线积分", "曲面积分", "黎曼积分", "勒贝格积分",
            "反常积分", "分部积分", "换元积分", "泰勒展开", "泰勒级数", "麦克劳林", "傅里叶级数", "傅里叶变换",
            "拉普拉斯变换", "幂级数", "级数收敛", "绝对收敛", "条件收敛", "一致收敛", "极限", "洛必达法则",
            "中值定理", "罗尔定理", "拉格朗日", "拉格朗日中值定理", "柯西中值定理", "格林公式", "高斯公式",
            "斯托克斯公式", "微分方程", "常微分方程", "偏微分方程", "特征方程", "通解", "特解", "边值问题",
            "线性代数", "矩阵", "方阵", "单位矩阵", "对角矩阵", "对称矩阵", "正交矩阵", "正定矩阵", "半正定",
            "埃尔米特矩阵", "稀疏矩阵", "伴随矩阵", "逆矩阵", "广义逆", "转置", "共轭转置", "行列式", "余子式",
            "代数余子式", "矩阵的秩", "满秩", "奇异矩阵", "非奇异", "特征值", "特征向量", "特征多项式",
            "奇异值分解", "特征分解", "正交分解", "施密特正交化", "线性空间", "向量空间", "内积空间",
            "希尔伯特空间", "巴拿赫空间", "欧几里得空间", "子空间", "线性相关", "线性无关", "极大无关组",
            "基底", "基变换", "线性变换", "线性映射", "核空间", "像空间", "双线性型", "二次型", "惯性定理",
            "范数", "欧氏范数", "点积", "叉积", "外积", "张量", "张量积", "仿射变换", "投影矩阵",
            "概率论", "随机变量", "概率密度", "分布函数", "联合分布", "边缘分布", "条件概率", "全概率公式",
            "贝叶斯定理", "贝叶斯公式", "数学期望", "方差", "标准差", "协方差", "协方差矩阵", "相关系数",
            "正态分布", "高斯分布", "泊松分布", "二项分布", "几何分布", "指数分布", "均匀分布", "卡方分布",
            "伽马分布", "贝塔分布", "大数定律", "中心极限定理", "马尔可夫链", "随机过程", "布朗运动",
            "鞅", "极大似然", "最大似然估计", "最小二乘法", "假设检验", "置信区间", "显著性水平", "自由度",
            "方差分析", "回归分析", "线性回归", "逻辑回归", "主成分分析", "蒙特卡洛", "信息熵", "交叉熵",
            "相对熵", "互信息", "吉布斯采样",
            "实分析", "复分析", "泛函分析", "测度论", "拓扑学", "拓扑空间", "同胚", "同伦", "基本群",
            "紧致性", "连通性", "豪斯多夫", "流形", "微分流形", "黎曼流形", "曲率", "测地线", "纤维丛",
            "抽象代数", "群论", "阿贝尔群", "交换群", "正规子群", "商群", "同态", "同构", "环论", "理想",
            "域论", "伽罗瓦理论", "多项式环", "数论", "素数", "质数", "合数", "最大公约数", "最小公倍数",
            "同余", "模运算", "费马小定理", "欧拉定理", "中国剩余定理", "黎曼猜想", "哥德巴赫猜想",
            "离散数学", "集合论", "映射", "单射", "满射", "双射", "等价关系", "偏序", "全序", "格",
            "布尔代数", "命题逻辑", "谓词逻辑", "图论", "连通图", "二分图", "欧拉回路", "哈密顿回路",
            "生成树", "最小生成树", "最短路径", "网络流", "组合数学", "排列组合", "二项式定理", "容斥原理",
            "抽屉原理", "母函数", "递推关系", "斐波那契", "卡特兰数", "凸优化", "拉格朗日乘数", "对偶问题",
            "梯度下降", "牛顿法", "单纯形法", "线性规划", "非线性规划", "动态规划", "数值分析", "插值",
            "样条", "有限元", "三角函数", "反三角函数", "双曲函数", "对数", "指数函数", "幂函数", "抛物线",
            "双曲线", "椭圆", "圆锥曲线", "渐近线", "切线", "法线", "拐点", "极值", "极大值", "极小值",
            "凹凸性", "反证法", "数学归纳法", "充分必要条件", "充要条件", "公理", "定理", "引理", "推论",
            "猜想", "证明", "恒等式", "不等式", "柯西不等式", "均值不等式", "三角不等式", "杨氏不等式",
        },
        DOMAIN_CS: {
            "编程语言", "编译器", "解释器", "虚拟机", "字节码", "汇编语言", "机器码", "词法分析", "语法分析",
            "抽象语法树", "中间代码", "即时编译", "垃圾回收", "引用计数", "内存泄漏", "内存溢出", "空指针",
            "野指针", "悬垂指针", "缓冲区溢出", "栈溢出", "堆内存", "栈内存", "指针", "引用", "泛型", "多态",
            "继承", "封装", "接口", "抽象类", "闭包", "协程", "回调函数", "异步编程", "多线程", "多进程",
            "并发", "并行", "竞态条件", "数据竞争", "死锁", "活锁", "互斥锁", "读写锁", "自旋锁", "信号量",
            "条件变量", "原子操作", "无锁队列", "线程池", "事件循环", "非阻塞", "多路复用", "零拷贝",
            "数据结构", "链表", "双向链表", "数组", "哈希表", "散列表", "二叉树", "红黑树", "平衡树",
            "前缀树", "字典树", "堆排序", "快排", "归并排序", "二分查找", "深度优先", "广度优先", "拓扑排序",
            "并查集", "线段树", "树状数组", "滑动窗口", "双指针", "时间复杂度", "空间复杂度", "递归", "迭代",
            "操作系统", "内核", "用户态", "内核态", "系统调用", "中断", "进程调度", "上下文切换", "虚拟内存",
            "分页", "页表", "缺页中断", "文件系统", "索引节点", "硬链接", "软链接", "管道", "共享内存",
            "套接字", "网络协议", "三次握手", "四次挥手", "滑动窗口", "拥塞控制", "负载均衡", "反向代理",
            "正向代理", "网关", "防火墙", "域名解析", "证书", "非对称加密", "对称加密", "数字签名", "哈希",
            "数据库", "关系型数据库", "索引", "联合索引", "覆盖索引", "聚簇索引", "回表", "事务", "隔离级别",
            "脏读", "幻读", "不可重复读", "乐观锁", "悲观锁", "分库分表", "主从复制", "读写分离", "日志",
            "缓存穿透", "缓存击穿", "缓存雪崩", "一致性哈希", "消息队列", "分布式", "分布式锁", "分布式事务",
            "最终一致性", "强一致性", "共识算法", "微服务", "服务发现", "熔断", "降级", "限流", "链路追踪",
            "可观测性", "容器", "镜像", "编排", "集群", "节点", "持续集成", "持续交付", "灰度发布", "蓝绿部署",
            "回滚", "自动化测试", "单元测试", "集成测试", "压测", "性能分析", "火焰图", "重构", "设计模式",
            "单例模式", "工厂模式", "观察者模式", "策略模式", "代理模式", "依赖注入", "面向切面", "领域驱动",
            "机器学习", "深度学习", "神经网络", "卷积神经网络", "循环神经网络", "注意力机制", "自注意力",
            "大模型", "大语言模型", "预训练", "微调", "量化", "剪枝", "蒸馏", "推理引擎", "词元", "分词器",
            "嵌入向量", "向量数据库", "检索增强", "提示词", "上下文窗口", "键值缓存", "反向传播", "激活函数",
            "损失函数", "过拟合", "欠拟合", "正则化", "批归一化", "层归一化", "张量", "显存", "算力",
            "前端", "后端", "全栈", "组件化", "状态管理", "虚拟节点", "服务端渲染", "静态生成", "跨域",
            "鉴权", "令牌", "会话", "接口文档", "版本控制", "分支", "合并冲突", "变基", "代码评审",
        },
        DOMAIN_ART: {
            "构图", "三分法", "黄金分割", "对角线构图", "对称构图", "引导线", "留白", "负空间", "视觉重心",
            "视觉引导", "透视", "一点透视", "两点透视", "三点透视", "鱼眼透视", "空气透视", "灭点", "视平线",
            "素描", "速写", "白描", "线稿", "勾线", "排线", "起形", "抓形", "结构素描", "明暗交界线",
            "三大面", "五大调", "亮面", "灰面", "暗面", "反光", "投影", "高光", "闭塞阴影", "环境光遮蔽",
            "色调", "色相", "饱和度", "明度", "纯度", "冷暖色", "冷暖对比", "互补色", "邻近色", "类似色",
            "三原色", "间色", "复色", "高级灰", "莫兰迪色", "撞色", "渐变", "色彩搭配", "色彩心理学", "色域",
            "色温", "白平衡", "曝光", "过曝", "欠曝", "景深", "大光圈", "焦外", "虚化", "快门速度", "感光度",
            "宽容度", "动态范围", "暗角", "畸变", "色散", "眩光", "逆光", "侧逆光", "轮廓光", "伦勃朗光",
            "蝴蝶光", "主光", "补光", "环境光", "体积光", "丁达尔效应", "全局光照", "光追", "光线追踪", "次表面散射",
            "金属度", "粗糙度", "法线贴图", "置换贴图", "漫反射", "镜面反射", "菲涅尔效应", "材质球", "着色器",
            "建模", "多边形", "拓扑", "布线", "雕刻", "展平", "贴图", "烘焙", "绑定", "蒙皮", "骨骼动画",
            "关键帧", "补间动画", "缓动曲线", "逐帧动画", "分镜", "故事板", "概念设计", "原画", "厚涂",
            "平涂", "赛璐璐", "伪厚涂", "叠色", "正片叠底", "滤色", "叠加", "柔光", "颜色减淡", "发光图层",
            "蒙版", "剪贴蒙版", "图层样式", "笔刷", "压感", "抖动修正", "羽化", "液化", "色阶", "曲线调色",
            "色相饱和度", "可选颜色", "色彩平衡", "高斯模糊", "动感模糊", "锐化", "噪点", "颗粒感", "暗房",
            "水彩", "水粉", "油画", "丙烯", "国画", "工笔", "写意", "没骨", "泼墨", "皴法", "留白液",
            "湿画法", "干画法", "罩染", "颜料", "画布", "画板", "画架", "调色盘", "炭笔", "彩铅", "马克笔",
            "版画", "木刻", "铜版画", "丝网印刷", "浮世绘", "壁画", "雕塑", "泥塑", "石膏像", "人体解剖",
            "比例", "动态线", "体块", "衣褶", "材质表现", "质感", "肌理", "笔触", "松弛感", "氛围感",
            "印象派", "后印象派", "野兽派", "立体主义", "超现实主义", "表现主义", "巴洛克", "洛可可", "文艺复兴",
            "新古典主义", "浪漫主义", "极简主义", "包豪斯", "扁平化", "拟物化", "毛玻璃", "液态玻璃", "新拟态",
            "字体设计", "排版", "字距", "行距", "对齐", "网格系统", "栅格", "留白", "信息层级", "视觉动线",
            "交互设计", "用户体验", "原型图", "线框图", "设计规范", "组件库", "设计系统", "图标设计", "品牌视觉",
            "海报设计", "插画", "绘本", "漫画", "国潮", "赛博朋克", "蒸汽波", "像素画", "矢量图", "位图",
            "贝塞尔曲线", "锚点", "路径", "布尔运算", "抠图", "通道", "色彩空间", "印刷色", "出血线", "分辨率",
        },
        DOMAIN_SCIENCE: {
            # 物理
            "力学", "牛顿力学", "经典力学", "量子力学", "相对论", "狭义相对论", "广义相对论", "热力学",
            "统计力学", "电动力学", "电磁学", "光学", "声学", "流体力学", "天体物理", "粒子物理", "凝聚态",
            "加速度", "角速度", "角动量", "动量守恒", "能量守恒", "机械能", "动能", "势能", "重力势能",
            "弹性势能", "摩擦力", "向心力", "离心力", "万有引力", "引力波", "引力场", "电场", "磁场", "电磁场",
            "电磁感应", "法拉第", "麦克斯韦", "洛伦兹力", "安培力", "欧姆定律", "基尔霍夫", "电容", "电感",
            "电阻", "阻抗", "超导", "半导体", "光电效应", "康普顿散射", "波粒二象性", "德布罗意波", "薛定谔方程",
            "波函数", "测不准原理", "不确定性原理", "量子纠缠", "量子隧穿", "量子叠加", "自旋", "泡利不相容",
            "费米子", "玻色子", "光子", "电子", "质子", "中子", "夸克", "中微子", "反物质", "希格斯玻色子",
            "核裂变", "核聚变", "放射性", "半衰期", "同位素", "热力学第一定律", "热力学第二定律", "熵增",
            "卡诺循环", "绝对零度", "相变", "临界点", "超临界", "折射率", "全反射", "干涉", "衍射", "偏振",
            "多普勒效应", "红移", "蓝移", "光谱", "黑体辐射", "激光", "谐振", "共振", "阻尼", "简谐运动",
            # 化学
            "化学反应", "化学键", "共价键", "离子键", "金属键", "氢键", "范德华力", "分子轨道", "杂化轨道",
            "氧化还原", "氧化剂", "还原剂", "催化剂", "活化能", "化学平衡", "勒夏特列", "反应速率", "放热反应",
            "吸热反应", "焓变", "吉布斯自由能", "电解质", "电离平衡", "水解", "酸碱中和", "缓冲溶液", "滴定",
            "沉淀", "络合物", "配位化合物", "有机化学", "无机化学", "物理化学", "分析化学", "高分子", "聚合物",
            "烷烃", "烯烃", "炔烃", "芳香烃", "苯环", "醇类", "醛类", "酮类", "羧酸", "酯化反应", "加成反应",
            "取代反应", "消去反应", "缩聚反应", "同分异构", "手性分子", "旋光性", "元素周期表", "原子序数",
            "相对原子质量", "摩尔质量", "阿伏伽德罗", "色谱", "质谱", "核磁共振", "红外光谱", "晶体结构",
            # 生物与天文地学
            "细胞核", "细胞膜", "细胞质", "线粒体", "叶绿体", "核糖体", "内质网", "高尔基体", "溶酶体",
            "有丝分裂", "减数分裂", "细胞凋亡", "干细胞", "基因表达", "转录", "翻译", "基因突变", "染色体",
            "双螺旋", "碱基互补", "基因编辑", "聚合酶链式反应", "蛋白质", "氨基酸", "多肽", "酶催化", "抗体",
            "抗原", "免疫系统", "光合作用", "呼吸作用", "新陈代谢", "生态系统", "食物链", "生物多样性",
            "自然选择", "进化论", "物种起源", "微生物", "细菌", "病毒", "真菌", "噬菌体", "神经递质", "突触",
            "太阳系", "银河系", "星系", "星云", "恒星", "白矮星", "中子星", "脉冲星", "超新星", "黑洞",
            "事件视界", "类星体", "系外行星", "暗物质", "暗能量", "宇宙大爆炸", "微波背景辐射", "光年",
            "天文单位", "板块构造", "地震波", "岩浆", "沉积岩", "变质岩", "大气层", "温室效应", "厄尔尼诺",
        },
        DOMAIN_LITERATURE: {
            "唐诗", "宋词", "元曲", "汉赋", "乐府", "诗经", "楚辞", "绝句", "律诗", "五言绝句", "七言绝句",
            "五言律诗", "七言律诗", "词牌", "词牌名", "平仄", "押韵", "对仗", "粘对", "格律", "韵脚",
            "意象", "意境", "比兴", "赋比兴", "借景抒情", "托物言志", "情景交融", "动静结合", "虚实相生",
            "用典", "典故", "互文", "通感", "拟人", "夸张", "排比", "反衬", "白描", "婉约派", "豪放派",
            "边塞诗", "山水田园", "咏史怀古", "送别诗", "闺怨诗", "文言文", "散文", "骈文", "古文运动",
            "唐宋八大家", "建安风骨", "盛唐气象", "诗仙", "诗圣", "诗佛", "诗鬼", "词圣", "红楼梦", "西游记",
            "三国演义", "水浒传", "史记", "资治通鉴", "古文观止", "世说新语", "文心雕龙", "人间词话",
        },
        DOMAIN_MEDICINE: {
            "心电图", "核磁共振", "血常规", "尿常规", "肝功能", "肾功能", "血糖", "血压", "血脂", "胆固醇",
            "甘油三酯", "糖化血红蛋白", "白细胞", "红细胞", "血小板", "血红蛋白", "淋巴细胞", "中性粒细胞",
            "抗生素", "消炎药", "退烧药", "止痛药", "降压药", "降糖药", "胰岛素", "激素", "免疫抑制",
            "高血压", "糖尿病", "冠心病", "心肌梗死", "脑卒中", "脑梗死", "心律失常", "房颤", "心力衰竭",
            "肺炎", "支气管炎", "哮喘", "慢阻肺", "胃炎", "胃溃疡", "十二指肠", "阑尾炎", "胆囊炎", "脂肪肝",
            "肝硬化", "肾结石", "尿路感染", "甲状腺", "甲亢", "甲减", "类风湿", "痛风", "骨质疏松", "颈椎病",
            "腰椎间盘突出", "白内障", "青光眼", "过敏性鼻炎", "荨麻疹", "湿疹", "抑郁症", "焦虑症", "失眠症",
            "恶性肿瘤", "良性肿瘤", "靶向治疗", "化疗", "放疗", "免疫治疗", "活检", "病理", "临床试验",
            "适应症", "禁忌症", "不良反应", "副作用", "半衰期", "药代动力学", "处方药", "非处方药", "疫苗",
            "无菌操作", "静脉注射", "肌肉注射", "皮下注射", "雾化吸入", "心肺复苏", "除颤", "气管插管",
        },
        DOMAIN_FINANCE_LAW: {
            "市盈率", "市净率", "净资产收益率", "现金流", "自由现金流", "资产负债表", "利润表", "现金流量表",
            "毛利率", "净利率", "营收增速", "净利润", "每股收益", "分红", "股息率", "除权", "除息", "复权",
            "涨停", "跌停", "熔断", "做多", "做空", "杠杆", "融资融券", "爆仓", "平仓", "止损", "止盈", "建仓",
            "加仓", "减仓", "清仓", "空仓", "满仓", "换手率", "成交量", "量价关系", "均线", "布林带", "背离",
            "定投", "指数基金", "主动基金", "公募基金", "私募基金", "对冲基金", "量化交易", "期权", "期货",
            "国债", "可转债", "逆回购", "年化收益", "七日年化", "复利", "折现", "贴现率", "基准利率", "降准",
            "降息", "量化宽松", "通胀", "通货膨胀", "通缩", "滞胀", "汇率", "外汇储备", "贸易顺差", "贸易逆差",
            "增值税", "所得税", "印花税", "关税", "会计准则", "审计", "合规", "风控", "反洗钱", "尽职调查",
            "股权激励", "期权池", "天使轮", "估值", "独角兽", "并购", "重组", "破产清算", "债务违约",
            "民法典", "刑法", "行政法", "公司法", "劳动法", "合同法", "知识产权", "著作权", "商标权", "专利权",
            "商业秘密", "竞业限制", "违约责任", "违约金", "损害赔偿", "不可抗力", "诉讼时效", "管辖权",
            "举证责任", "证据链", "一审", "二审", "终审", "再审", "上诉", "抗诉", "仲裁", "调解", "和解",
            "强制执行", "财产保全", "先予执行", "取保候审", "缓刑", "假释", "正当防卫", "紧急避险", "无罪推定",
            "法人", "法定代表人", "连带责任", "有限责任", "无限责任", "善意取得", "不当得利", "无因管理",
            "侵权责任", "过错责任", "无过错责任", "格式条款", "保密协议", "免责声明", "律师函", "起诉状",
        },
    }


def load_thuocl_domain(url: str, max_entries: int) -> set[str]:
    raw = fetch_text(url)
    words: list[tuple[str, int]] = []
    for line in raw.splitlines():
        parts = line.split("\t")
        if not parts:
            continue
        w = parts[0].strip()
        if not (2 <= len(w) <= 10 and CJK_RE.match(w)):
            continue
        if w in GENERIC_STOPWORDS:
            continue
        freq = 0
        if len(parts) >= 2:
            try:
                freq = int(parts[1].strip())
            except ValueError:
                freq = 0
        words.append((w, freq))
    words.sort(key=lambda x: x[1], reverse=True)
    return {w for w, _ in words[:max_entries]}


def collect_domain_masks(idioms: set[str], poetry: set[str]) -> tuple[dict[str, int], dict[str, int]]:
    stats: dict[str, int] = {}
    buckets: dict[int, set[str]] = {k: set(v) for k, v in curated_domain_terms().items()}

    thu_sources = [
        ("thuocl_it", DOMAIN_CS, "https://raw.githubusercontent.com/thunlp/THUOCL/master/data/THUOCL_IT.txt", 14000),
        ("thuocl_medical", DOMAIN_MEDICINE, "https://raw.githubusercontent.com/thunlp/THUOCL/master/data/THUOCL_medical.txt", 14000),
        ("thuocl_law", DOMAIN_FINANCE_LAW, "https://raw.githubusercontent.com/thunlp/THUOCL/master/data/THUOCL_law.txt", 9000),
        ("thuocl_caijing", DOMAIN_FINANCE_LAW, "https://raw.githubusercontent.com/thunlp/THUOCL/master/data/THUOCL_caijing.txt", 9000),
        ("thuocl_animal", DOMAIN_SCIENCE, "https://raw.githubusercontent.com/thunlp/THUOCL/master/data/THUOCL_animal.txt", 4000),
    ]
    thu_bucket_map: dict[int, set[str]] = {}
    for label, mask, url, cap in thu_sources:
        try:
            print(f"-> 拉取 {label} (MIT)...")
            ws = load_thuocl_domain(url, cap)
            stats[label] = len(ws)
            thu_bucket_map.setdefault(mask, set()).update(ws)
        except Exception as exc:
            print(f"   [警告] 拉取 {label} 失败: {exc}", file=sys.stderr)

    # 交叉纯净度过滤：同时出现在 >= 3 个不相关 THUOCL 大类里的 2 字泛用词剔除
    word_domain_hits: dict[str, int] = {}
    for mask, ws in thu_bucket_map.items():
        for w in ws:
            word_domain_hits[w] = word_domain_hits.get(w, 0) + 1

    for mask, ws in thu_bucket_map.items():
        for w in ws:
            if len(w) <= 2 and word_domain_hits.get(w, 0) >= 3:
                continue
            buckets.setdefault(mask, set()).add(w)

    # 万象官方化学词库若存在，合并进科学领域
    for extra_label, mask, url in [
        ("wanxiang_huaxue", DOMAIN_SCIENCE, "https://raw.githubusercontent.com/amzxyz/rime-wanxiang-data/main/dicts/huaxue.dict.yaml"),
    ]:
        try:
            print(f"-> 拉取 {extra_label} (CC-BY-4.0)...")
            raw = fetch_text(url)
            added = 0
            in_body = False
            for line in raw.splitlines():
                if line.strip() == "...":
                    in_body = True
                    continue
                if not in_body or not line or line.startswith("#"):
                    continue
                w = line.split("\t")[0].strip()
                if 2 <= len(w) <= 10 and CJK_RE.match(w) and w not in GENERIC_STOPWORDS:
                    buckets[mask].add(w)
                    added += 1
                    if added >= 8000:
                        break
            stats[extra_label] = added
        except Exception as exc:
            print(f"   [警告] 拉取 {extra_label} 失败: {exc}", file=sys.stderr)

    # 合并成 term -> bitmask，诗词/成语自动携带 DOMAIN_LITERATURE 供文学场景识别
    merged: dict[str, int] = {}
    for mask, ws in buckets.items():
        for w in ws:
            merged[w] = merged.get(w, 0) | mask
    # 注意：文学场景对高频经典诗词/成语直接通过 literary_tags.bin 联动，此处不把 5 万条全部重复写进 domain_tags.bin，节省内存！
    stats["final_domain_terms"] = len(merged)
    return merged, stats


def write_literary_bin(path: Path, idioms: set[str], poetry: set[str]) -> None:
    idiom_hashes = sorted({hash128(w) for w in idioms})
    poetry_hashes = sorted({hash128(w) for w in poetry})
    buf = bytearray()
    buf.extend(struct.pack("<4sIII", b"SMLT", 1, len(idiom_hashes), len(poetry_hashes)))
    for hi, lo in idiom_hashes:
        buf.extend(struct.pack("<QQ", hi, lo))
    for hi, lo in poetry_hashes:
        buf.extend(struct.pack("<QQ", hi, lo))
    path.write_bytes(buf)


def write_domain_bin(path: Path, term_masks: dict[str, int]) -> None:
    # 合并相同 hash（理论上 128-bit 无碰撞，按位或保安全）
    by_hash: dict[tuple[int, int], int] = {}
    for w, mask in term_masks.items():
        h = hash128(w)
        by_hash[h] = by_hash.get(h, 0) | (mask & 0xFFFF)
    entries = sorted(by_hash.items(), key=lambda kv: kv[0])
    buf = bytearray()
    buf.extend(struct.pack("<4sIII", b"SMDM", 1, len(entries), 0))
    for (hi, lo), mask in entries:
        buf.extend(struct.pack("<QQHH", hi, lo, mask, 0))
    path.write_bytes(buf)


def write_notice(path: Path, lit_stats: dict[str, int], dom_stats: dict[str, int]) -> None:
    notice = f"""SmartPinyin Bundled Lexicon Tag Index — Third-Party Attribution
===============================================================

1. chinese-xinhua (data/idiom.json)
   Source: https://github.com/pwxcoo/chinese-xinhua
   License: MIT License

2. THUOCL (THU Open Chinese Lexicon: chengyu, poem, IT, medical, law, caijing, animal)
   Source: https://github.com/thunlp/THUOCL
   License: MIT License
   Citation: 使用了清华大学开放中文词库 (THUOCL)

3. chinese-poetry (tangshisanbaishou, songci300, qianjiashi, shijing)
   Source: https://github.com/chinese-poetry/chinese-poetry
   License: MIT License

4. rime-wanxiang-data (huaxue terminology subset)
   Source: https://github.com/amzxyz/rime-wanxiang-data
   License: Creative Commons Attribution 4.0 International (CC-BY-4.0)

Build Summary
-------------
- Literary idioms:  {lit_stats.get('final_idioms', 0)}
- Literary poetry:  {lit_stats.get('final_poetry', 0)}
- Domain terms:     {dom_stats.get('final_domain_terms', 0)}
"""
    path.write_text(notice, encoding="utf-8")


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    idioms, poetry, lit_stats = collect_literary_sets()
    domain_masks, dom_stats = collect_domain_masks(idioms, poetry)

    lit_path = OUT_DIR / "literary_tags.bin"
    dom_path = OUT_DIR / "domain_tags.bin"
    notice_path = OUT_DIR / "NOTICE.txt"

    write_literary_bin(lit_path, idioms, poetry)
    write_domain_bin(dom_path, domain_masks)
    write_notice(notice_path, lit_stats, dom_stats)

    print("\n=== 构建完成 ===")
    print(f"literary_tags.bin: {lit_path.stat().st_size / 1024:.1f} KB  (idioms={lit_stats['final_idioms']}, poetry={lit_stats['final_poetry']})")
    print(f"domain_tags.bin:   {dom_path.stat().st_size / 1024:.1f} KB  (terms={dom_stats['final_domain_terms']})")

    # 关键抽样自检
    checks = [
        ("锄禾日当午", "poetry", "锄禾日当午" in poetry),
        ("床前明月光", "poetry", "床前明月光" in poetry),
        ("海内存知己", "poetry", "海内存知己" in poetry),
        ("画蛇添足", "idiom", "画蛇添足" in idioms),
        ("一心一意", "idiom", "一心一意" in idioms),
        ("超然物外", "idiom", "超然物外" in idioms),
        ("成人读物", "none", ("成人读物" not in idioms and "成人读物" not in poetry)),
        ("吃肉动物", "none", ("吃肉动物" not in idioms and "吃肉动物" not in poetry)),
        ("特征值", "math", bool(domain_masks.get("特征值", 0) & DOMAIN_MATH)),
        ("光追", "gaming+art", bool((domain_masks.get("光追", 0) & DOMAIN_GAMING) and (domain_masks.get("光追", 0) & DOMAIN_ART))),
        ("红黑树", "cs", bool(domain_masks.get("红黑树", 0) & DOMAIN_CS)),
        ("明暗交界线", "art", bool(domain_masks.get("明暗交界线", 0) & DOMAIN_ART)),
    ]
    failed = [c for c in checks if not c[2]]
    for word, expect, ok in checks:
        print(f"  [{'OK' if ok else 'FAIL'}] {word} -> {expect}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

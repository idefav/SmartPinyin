#ifndef SPM_LLAMA_BRIDGE_H
#define SPM_LLAMA_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SPMLlamaEngine SPMLlamaEngine;

typedef struct SPMLlamaConfig {
    int32_t n_ctx;        // 输入法短上下文，默认 512
    int32_t n_batch;      // 默认 128
    int32_t n_gpu_layers; // -1 表示全部卸载至 Metal GPU
    int32_t n_threads;    // 0 表示自动选择
    bool quantize_kv_q8;  // true 启用 Q8_0 量化 KV Cache 压缩内存
} SPMLlamaConfig;

typedef struct SPMLlamaGenResult {
    char* text;           // UTF-8 输出文本，调用方用 spm_llama_free_gen_result 释放
    int32_t prompt_tokens;
    int32_t generated_tokens;
    double ttft_ms;
    double total_ms;
    bool cancelled;
    bool ok;
} SPMLlamaGenResult;

typedef struct SPMLlamaBranchItem {
    char* text;           // UTF-8 单分支原生续写文本（无前缀、无跨行串味）
    double avg_logprob;   // 长度归一化平均对数似然，越高越自然
    int32_t token_count;
} SPMLlamaBranchItem;

typedef struct SPMLlamaBranchResult {
    SPMLlamaBranchItem* items;
    int32_t count;
    double total_ms;
    bool cancelled;
    bool ok;
} SPMLlamaBranchResult;

/// 进程级初始化/反初始化 llama 后端（幂等，自动加载 Metal & CPU 动态后端）
void spm_llama_backend_init(void);
void spm_llama_backend_free(void);

/// 返回当前已注册的 ggml 计算设备摘要（如 "Metal (Apple M5 Max), CPU"），调用方用 free 释放
char* spm_llama_backend_summary(void);

/// 按严格短上下文 + 量化 KV 参数加载 GGUF 模型
SPMLlamaEngine* spm_llama_load(const char* model_path, SPMLlamaConfig config);
void spm_llama_unload(SPMLlamaEngine* engine);

/// 抢占取消：从任意线程安全中断正在进行的生成或重排打分
void spm_llama_request_cancel(SPMLlamaEngine* engine);
void spm_llama_clear_cancel(SPMLlamaEngine* engine);

/// 应用模型内置 chat template 格式化消息（支持 system + user；无内置模板时返回 NULL）
char* spm_llama_apply_chat_template(
    SPMLlamaEngine* engine,
    const char* system_prompt,
    const char* user_prompt,
    bool add_generation_prompt
);

/// 文本生成（贪心或低温采样，支持 stop_sequences 与最大 token 数控制）
SPMLlamaGenResult spm_llama_generate(
    SPMLlamaEngine* engine,
    const char* prompt,
    int32_t max_tokens,
    float temperature,
    const char* const* stop_sequences,
    int32_t num_stops
);

void spm_llama_free_gen_result(SPMLlamaGenResult* result);

/// 语境候选重排打分：
/// 只对 shared_prefix 做一次 Prefill，随后逐候选计算平均 log-probability，并用 KV 截断复用前缀。
/// scores_out 长度须 >= num_candidates；超时（timeout_ms > 0）或被取消时返回 false。
bool spm_llama_score_candidates(
    SPMLlamaEngine* engine,
    const char* shared_prefix,
    const char* const* candidates,
    int32_t num_candidates,
    int32_t timeout_ms,
    double* scores_out,
    double* elapsed_ms_out
);

/// 精确联合对数似然打分（专用于整句错别字/易混字校对判别，不做 token 长度均分归一化）：
/// 使用自然用户输入语境头（<|im_start|>user\n）+ shared_prefix 仅 Prefill 一次并复用 KV，
/// 逐候选计算精确整串联合对数概率 ∑ log P(tok_k | prefix, tok_<k)，消除 BPE 合并/拆分 token 数差异偏差。
/// scores_out 长度须 >= num_candidates；超时（timeout_ms > 0）或被取消时返回 false。
bool spm_llama_score_texts_exact(
    SPMLlamaEngine* engine,
    const char* shared_prefix,
    const char* const* candidates,
    int32_t num_candidates,
    int32_t timeout_ms,
    double* scores_out,
    double* elapsed_ms_out
);

typedef struct SPMLlamaTokenProposal {
    int32_t byte_offset;   // 原 token 在 text 中的 UTF-8 起始字节偏移
    int32_t byte_length;   // 原 token 在 text 中的 UTF-8 字节长度
    double token_logprob;  // 原 token 在该位置的条件对数概率
    char** alt_texts;      // Top-K 高概率纯汉字替换候选片段（1~3 汉字）
    double* alt_logprobs;  // 对应条件对数概率
    int32_t alt_count;
} SPMLlamaTokenProposal;

typedef struct SPMLlamaSurprisalResult {
    SPMLlamaTokenProposal* items;
    int32_t count;
    double total_ms;
    bool cancelled;
    bool ok;
} SPMLlamaSurprisalResult;

/// 单次前向扫描整句中的异常低概率（高惊讶度）位置，并提取 Top-K 纯汉字替换候选（零生成、零幻觉）
SPMLlamaSurprisalResult spm_llama_probe_surprisal_proposals(
    SPMLlamaEngine* engine,
    const char* text,
    double surprisal_threshold,
    int32_t top_k,
    int32_t timeout_ms
);

void spm_llama_free_surprisal_result(SPMLlamaSurprisalResult* result);

/// 共享 KV 前缀原生多分支续写：
/// 仅对纯净上文 raw_prefix 做一次 Prefill，从末位 logits 选出 Top-K 合法词首 token，
/// 复用前缀 KV Cache 各自独立贪心短展开至自然语义边界，彻底消除 Chat 指令串行吐多行的跨行污染。
SPMLlamaBranchResult spm_llama_predict_branches(
    SPMLlamaEngine* engine,
    const char* raw_prefix,
    int32_t max_branches,
    int32_t max_tokens_per_branch,
    int32_t timeout_ms
);

void spm_llama_free_branch_result(SPMLlamaBranchResult* result);

#ifdef __cplusplus
}
#endif

#endif // SPM_LLAMA_BRIDGE_H

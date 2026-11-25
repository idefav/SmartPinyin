#ifndef SPM_RIME_BRIDGE_H
#define SPM_RIME_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SPMRimeCandidate {
    char* text;
    char* comment;
    int32_t global_index;
} SPMRimeCandidate;

typedef struct SPMRimeSnapshot {
    bool is_composing;
    char* preedit;
    char* raw_input;
    char* selected_prefix;
    char* commit_text;
    int32_t page_no;
    bool is_last_page;
    int32_t highlighted_index;
    int32_t num_candidates;
    SPMRimeCandidate* candidates;
    int32_t num_extended_candidates;
    SPMRimeCandidate* extended_candidates;
} SPMRimeSnapshot;

typedef struct SPMRimeEngine SPMRimeEngine;

/// 初始化全局 librime 实例并创建一个会话。
/// 注意：librime 为进程级单实例，多次创建引擎将共享底层运行时但各自持有独立 session。
SPMRimeEngine* spm_rime_create(
    const char* shared_data_dir,
    const char* user_data_dir,
    const char* log_dir,
    const char* preferred_schema_id
);

void spm_rime_destroy(SPMRimeEngine* engine);

bool spm_rime_process_key(SPMRimeEngine* engine, int32_t keyval, int32_t mask);
bool spm_rime_select_candidate(SPMRimeEngine* engine, int32_t global_index);
bool spm_rime_select_candidate_on_page(SPMRimeEngine* engine, int32_t index);
bool spm_rime_highlight_candidate_on_page(SPMRimeEngine* engine, int32_t index);
bool spm_rime_change_page(SPMRimeEngine* engine, bool backward);
bool spm_rime_commit_composition(SPMRimeEngine* engine);
void spm_rime_clear_composition(SPMRimeEngine* engine);

/// 获取当前会话快照及任何待消费的 commit 文本，调用方须用 spm_rime_free_snapshot 释放。
SPMRimeSnapshot spm_rime_get_snapshot(SPMRimeEngine* engine);
void spm_rime_free_snapshot(SPMRimeSnapshot* snapshot);

/// 返回当前激活的 schema_id（只读拷贝，调用方用 free 释放）
char* spm_rime_current_schema(SPMRimeEngine* engine);

/// 动态设置当前 Rime 会话开关选项（如 ascii_punct、s2t、emoji、abbrev）
void spm_rime_set_option(SPMRimeEngine* engine, const char* option, bool value);

/// 读取当前 Rime 会话开关选项状态
bool spm_rime_get_option(SPMRimeEngine* engine, const char* option);

/// 轻量重建会话以加载更新后的 default.custom.yaml（例如修改每页候选数、纠错或模糊音后生效）
bool spm_rime_reload_user_config(SPMRimeEngine* engine, const char* preferred_schema_id);

/// 使用共享词典的只读探针会话查询纠偏拼音的 Top-N 候选（绝不污染主会话 preedit/composition），
/// 调用方须用 spm_rime_free_candidates 释放返回的数组。
SPMRimeCandidate* spm_rime_probe_candidates(
    SPMRimeEngine* engine,
    const char* ascii_pinyin,
    int32_t max_results,
    int32_t* out_count
);

void spm_rime_free_candidates(SPMRimeCandidate* candidates, int32_t count);

#ifdef __cplusplus
}
#endif

#endif // SPM_RIME_BRIDGE_H

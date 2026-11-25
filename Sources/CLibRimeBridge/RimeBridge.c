#include "RimeBridge.h"
#include "rime_api.h"

#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct SPMRimeEngine {
    RimeApi* api;
    RimeSessionId session_id;
    RimeSessionId probe_session_id;
    char* preferred_schema_id;
};

static pthread_mutex_t g_rime_init_mutex = PTHREAD_MUTEX_INITIALIZER;
static bool g_rime_setup_done = false;
static bool g_rime_initialized = false;
static char* g_rime_user_data_dir = NULL;
static char* g_rime_shared_data_dir = NULL;

static char* spm_strdup_nullable(const char* s) {
    if (!s) return NULL;
    return strdup(s);
}

static bool spm_str_equal(const char* a, const char* b) {
    if (a == b) return true;
    if (!a || !b) return false;
    return strcmp(a, b) == 0;
}

static void spm_ensure_rime_initialized(
    RimeApi* api,
    const char* shared_data_dir,
    const char* user_data_dir,
    const char* log_dir
) {
    pthread_mutex_lock(&g_rime_init_mutex);
    const bool dir_changed = g_rime_initialized && (
        !spm_str_equal(g_rime_user_data_dir, user_data_dir) ||
        !spm_str_equal(g_rime_shared_data_dir, shared_data_dir)
    );
    if (dir_changed) {
        api->finalize();
        g_rime_initialized = false;
    }
    if (!g_rime_initialized) {
        RIME_STRUCT(RimeTraits, traits);
        traits.shared_data_dir = shared_data_dir;
        traits.user_data_dir = user_data_dir;
        traits.distribution_name = "SmartPinyin";
        traits.distribution_code_name = "SmartPinyin";
        traits.distribution_version = "0.1.0";
        traits.app_name = "rime.smartpinyin";
        traits.min_log_level = 2; // ERROR only to keep IME clean and fast
        traits.log_dir = log_dir;

        if (!g_rime_setup_done) {
            api->setup(&traits);
            g_rime_setup_done = true;
        }
        api->initialize(&traits);
        if (api->start_maintenance(False)) {
            api->join_maintenance_thread();
        }
        free(g_rime_user_data_dir);
        free(g_rime_shared_data_dir);
        g_rime_user_data_dir = spm_strdup_nullable(user_data_dir);
        g_rime_shared_data_dir = spm_strdup_nullable(shared_data_dir);
        g_rime_initialized = true;
    }
    pthread_mutex_unlock(&g_rime_init_mutex);
}

SPMRimeEngine* spm_rime_create(
    const char* shared_data_dir,
    const char* user_data_dir,
    const char* log_dir,
    const char* preferred_schema_id
) {
    RimeApi* api = rime_get_api();
    if (!api) return NULL;

    spm_ensure_rime_initialized(api, shared_data_dir, user_data_dir, log_dir);

    RimeSessionId sid = api->create_session();
    if (!sid) return NULL;

    if (preferred_schema_id && preferred_schema_id[0] != '\0') {
        api->select_schema(sid, preferred_schema_id);
    }
    // 确保处于中文输入态而非 ascii_mode
    api->set_option(sid, "ascii_mode", False);

    SPMRimeEngine* eng = (SPMRimeEngine*)calloc(1, sizeof(SPMRimeEngine));
    if (!eng) {
        api->destroy_session(sid);
        return NULL;
    }
    eng->api = api;
    eng->session_id = sid;
    eng->probe_session_id = 0;
    eng->preferred_schema_id = spm_strdup_nullable(preferred_schema_id);
    return eng;
}

void spm_rime_destroy(SPMRimeEngine* engine) {
    if (!engine) return;
    if (engine->api) {
        if (engine->probe_session_id) {
            engine->api->destroy_session(engine->probe_session_id);
            engine->probe_session_id = 0;
        }
        if (engine->session_id) {
            engine->api->destroy_session(engine->session_id);
            engine->session_id = 0;
        }
    }
    free(engine->preferred_schema_id);
    free(engine);
}

bool spm_rime_process_key(SPMRimeEngine* engine, int32_t keyval, int32_t mask) {
    if (!engine || !engine->api || !engine->session_id) return false;
    return engine->api->process_key(engine->session_id, keyval, mask) ? true : false;
}

bool spm_rime_select_candidate(SPMRimeEngine* engine, int32_t global_index) {
    if (!engine || !engine->api || !engine->session_id || global_index < 0) return false;
    if (RIME_API_AVAILABLE(engine->api, select_candidate)) {
        return engine->api->select_candidate(engine->session_id, (size_t)global_index) ? true : false;
    }
    return engine->api->select_candidate_on_current_page(engine->session_id, (size_t)global_index) ? true : false;
}

bool spm_rime_select_candidate_on_page(SPMRimeEngine* engine, int32_t index) {
    if (!engine || !engine->api || !engine->session_id || index < 0) return false;
    return engine->api->select_candidate_on_current_page(engine->session_id, (size_t)index) ? true : false;
}

bool spm_rime_highlight_candidate_on_page(SPMRimeEngine* engine, int32_t index) {
    if (!engine || !engine->api || !engine->session_id || index < 0) return false;
    if (RIME_API_AVAILABLE(engine->api, highlight_candidate_on_current_page)) {
        return engine->api->highlight_candidate_on_current_page(engine->session_id, (size_t)index) ? true : false;
    }
    return false;
}

bool spm_rime_change_page(SPMRimeEngine* engine, bool backward) {
    if (!engine || !engine->api || !engine->session_id) return false;
    if (RIME_API_AVAILABLE(engine->api, change_page)) {
        return engine->api->change_page(engine->session_id, backward ? True : False) ? true : false;
    }
    return false;
}

bool spm_rime_commit_composition(SPMRimeEngine* engine) {
    if (!engine || !engine->api || !engine->session_id) return false;
    return engine->api->commit_composition(engine->session_id) ? true : false;
}

void spm_rime_clear_composition(SPMRimeEngine* engine) {
    if (!engine || !engine->api || !engine->session_id) return;
    engine->api->clear_composition(engine->session_id);
}

SPMRimeSnapshot spm_rime_get_snapshot(SPMRimeEngine* engine) {
    SPMRimeSnapshot out;
    memset(&out, 0, sizeof(out));
    if (!engine || !engine->api || !engine->session_id) return out;

    RimeApi* api = engine->api;
    RimeSessionId sid = engine->session_id;

    RIME_STRUCT(RimeCommit, commit);
    if (api->get_commit(sid, &commit)) {
        out.commit_text = spm_strdup_nullable(commit.text);
        api->free_commit(&commit);
    }

    const char* raw_in = api->get_input(sid);
    out.raw_input = spm_strdup_nullable(raw_in);

    RIME_STRUCT(RimeContext, ctx);
    if (api->get_context(sid, &ctx)) {
        if (ctx.composition.length > 0 && ctx.composition.preedit) {
            out.is_composing = true;
            out.preedit = spm_strdup_nullable(ctx.composition.preedit);
            if (ctx.composition.sel_start > 0 && ctx.composition.sel_start <= ctx.composition.length) {
                char* prefix = (char*)calloc((size_t)ctx.composition.sel_start + 1, 1);
                if (prefix) {
                    memcpy(prefix, ctx.composition.preedit, (size_t)ctx.composition.sel_start);
                    out.selected_prefix = prefix;
                }
            }
        }
        out.page_no = ctx.menu.page_no;
        out.is_last_page = ctx.menu.is_last_page ? true : false;
        out.highlighted_index = ctx.menu.highlighted_candidate_index;
        out.num_candidates = ctx.menu.num_candidates;
        int32_t page_base = 0;
        if (ctx.menu.page_no > 0 && ctx.menu.page_size > 0 &&
            ctx.menu.page_no <= INT32_MAX / ctx.menu.page_size) {
            page_base = ctx.menu.page_no * ctx.menu.page_size;
        }
        if (ctx.menu.num_candidates > 0 && ctx.menu.candidates) {
            out.candidates = (SPMRimeCandidate*)calloc((size_t)ctx.menu.num_candidates, sizeof(SPMRimeCandidate));
            if (out.candidates) {
                for (int i = 0; i < ctx.menu.num_candidates; ++i) {
                    out.candidates[i].text = spm_strdup_nullable(ctx.menu.candidates[i].text);
                    out.candidates[i].comment = spm_strdup_nullable(ctx.menu.candidates[i].comment);
                    out.candidates[i].global_index = page_base + i;
                }
            } else {
                out.num_candidates = 0;
            }
        }

        // 第 1 页（page_no == 0）额外读取深层召回池（第 pageSize..<16 位），用于无损捞起被个人记忆/语境命中的第 2 页词
        const int32_t kDeepPoolCap = 16;
        if (ctx.menu.page_no == 0 &&
            ctx.menu.num_candidates > 0 &&
            ctx.menu.num_candidates < kDeepPoolCap &&
            !ctx.menu.is_last_page &&
            RIME_API_AVAILABLE(api, candidate_list_begin) &&
            RIME_API_AVAILABLE(api, candidate_list_next) &&
            RIME_API_AVAILABLE(api, candidate_list_end)) {
            const int32_t start_idx = ctx.menu.num_candidates;
            const int32_t max_ext = kDeepPoolCap - start_idx;
            RimeCandidateListIterator iter;
            memset(&iter, 0, sizeof(iter));
            if (api->candidate_list_begin(sid, &iter)) {
                SPMRimeCandidate* ext = (SPMRimeCandidate*)calloc((size_t)max_ext, sizeof(SPMRimeCandidate));
                int32_t ext_count = 0;
                if (ext) {
                    while (api->candidate_list_next(&iter)) {
                        if (iter.index >= kDeepPoolCap) {
                            break;
                        }
                        if (iter.index >= start_idx && ext_count < max_ext) {
                            ext[ext_count].text = spm_strdup_nullable(iter.candidate.text);
                            ext[ext_count].comment = spm_strdup_nullable(iter.candidate.comment);
                            ext[ext_count].global_index = iter.index;
                            ext_count++;
                        }
                    }
                    if (ext_count > 0) {
                        out.extended_candidates = ext;
                        out.num_extended_candidates = ext_count;
                    } else {
                        free(ext);
                    }
                }
                api->candidate_list_end(&iter);
            }
        }
        api->free_context(&ctx);
    }

    return out;
}

void spm_rime_free_snapshot(SPMRimeSnapshot* snapshot) {
    if (!snapshot) return;
    free(snapshot->preedit);
    free(snapshot->raw_input);
    free(snapshot->selected_prefix);
    free(snapshot->commit_text);
    if (snapshot->candidates) {
        for (int i = 0; i < snapshot->num_candidates; ++i) {
            free(snapshot->candidates[i].text);
            free(snapshot->candidates[i].comment);
        }
        free(snapshot->candidates);
    }
    if (snapshot->extended_candidates) {
        for (int i = 0; i < snapshot->num_extended_candidates; ++i) {
            free(snapshot->extended_candidates[i].text);
            free(snapshot->extended_candidates[i].comment);
        }
        free(snapshot->extended_candidates);
    }
    memset(snapshot, 0, sizeof(*snapshot));
}

char* spm_rime_current_schema(SPMRimeEngine* engine) {
    if (!engine || !engine->api || !engine->session_id) return NULL;
    char buf[128] = {0};
    if (engine->api->get_current_schema(engine->session_id, buf, sizeof(buf))) {
        return strdup(buf);
    }
    return NULL;
}

void spm_rime_set_option(SPMRimeEngine* engine, const char* option, bool value) {
    if (!engine || !engine->api || !engine->session_id || !option) return;
    engine->api->set_option(engine->session_id, option, value ? True : False);
}

bool spm_rime_get_option(SPMRimeEngine* engine, const char* option) {
    if (!engine || !engine->api || !engine->session_id || !option) return false;
    return engine->api->get_option(engine->session_id, option) ? true : false;
}

bool spm_rime_reload_user_config(SPMRimeEngine* engine, const char* preferred_schema_id) {
    if (!engine || !engine->api) return false;
    RimeApi* api = engine->api;
    if (engine->probe_session_id) {
        api->destroy_session(engine->probe_session_id);
        engine->probe_session_id = 0;
    }
    if (engine->session_id) {
        api->destroy_session(engine->session_id);
        engine->session_id = 0;
    }
    if (api->start_maintenance(True)) {
        api->join_maintenance_thread();
    }
    RimeSessionId sid = api->create_session();
    if (!sid) return false;
    if (preferred_schema_id && preferred_schema_id[0] != '\0') {
        api->select_schema(sid, preferred_schema_id);
        free(engine->preferred_schema_id);
        engine->preferred_schema_id = spm_strdup_nullable(preferred_schema_id);
    }
    api->set_option(sid, "ascii_mode", False);
    engine->session_id = sid;
    return true;
}

SPMRimeCandidate* spm_rime_probe_candidates(
    SPMRimeEngine* engine,
    const char* ascii_pinyin,
    int32_t max_results,
    int32_t* out_count
) {
    if (out_count) *out_count = 0;
    if (!engine || !engine->api || !ascii_pinyin || ascii_pinyin[0] == '\0' || max_results <= 0) {
        return NULL;
    }
    const int32_t cap = max_results > 8 ? 8 : max_results;
    RimeApi* api = engine->api;

    // 懒创建只读探针会话（共享进程级 librime 静态词典，额外内存仅 ~40KB，不碰主会话）
    if (!engine->probe_session_id) {
        RimeSessionId psid = api->create_session();
        if (!psid) return NULL;
        if (engine->preferred_schema_id && engine->preferred_schema_id[0] != '\0') {
            api->select_schema(psid, engine->preferred_schema_id);
        }
        api->set_option(psid, "ascii_mode", False);
        engine->probe_session_id = psid;
    }

    RimeSessionId psid = engine->probe_session_id;
    api->clear_composition(psid);

    // 同步当前主会话的繁简选项，保证纠偏查出的候选与当前输出简繁一致
    if (engine->session_id) {
        api->set_option(psid, "s2t", api->get_option(engine->session_id, "s2t"));
        api->set_option(psid, "s2s", api->get_option(engine->session_id, "s2s"));
        api->set_option(psid, "emoji", False);
    }

    const size_t len = strlen(ascii_pinyin);
    const size_t max_len = len > 28 ? 28 : len;
    for (size_t i = 0; i < max_len; ++i) {
        unsigned char c = (unsigned char)ascii_pinyin[i];
        if (c >= 'a' && c <= 'z') {
            api->process_key(psid, (int32_t)c, 0);
        }
    }

    SPMRimeCandidate* results = NULL;
    int32_t count = 0;

    RIME_STRUCT(RimeContext, ctx);
    if (api->get_context(psid, &ctx)) {
        int32_t n = ctx.menu.num_candidates;
        if (n > cap) n = cap;
        if (n > 0 && ctx.menu.candidates) {
            results = (SPMRimeCandidate*)calloc((size_t)n, sizeof(SPMRimeCandidate));
            if (results) {
                for (int32_t i = 0; i < n; ++i) {
                    results[i].text = spm_strdup_nullable(ctx.menu.candidates[i].text);
                    results[i].comment = spm_strdup_nullable(ctx.menu.candidates[i].comment);
                    results[i].global_index = i;
                }
                count = n;
            }
        }
        api->free_context(&ctx);
    }

    api->clear_composition(psid);
    if (out_count) *out_count = count;
    return results;
}

void spm_rime_free_candidates(SPMRimeCandidate* candidates, int32_t count) {
    if (!candidates) return;
    if (count > 0) {
        for (int32_t i = 0; i < count; ++i) {
            free(candidates[i].text);
            free(candidates[i].comment);
        }
    }
    free(candidates);
}

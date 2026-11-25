#include "LlamaBridge.h"
#include "ggml-backend.h"
#include "llama.h"

#include <mach-o/dyld.h>
#include <sys/stat.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

double elapsed_ms(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

void silent_log_callback(enum ggml_log_level level, const char* /*text*/, void* /*user_data*/) {
    // 屏蔽 llama.cpp 冗长启动日志，避免污染 IMK 控制台
    (void)level;
}

std::once_flag g_backend_once;

std::vector<llama_token> tokenize_string(
    const llama_vocab* vocab,
    const std::string& text,
    bool add_special,
    bool parse_special
) {
    if (text.empty()) return {};
    int32_t cap = static_cast<int32_t>(text.size()) + 16;
    std::vector<llama_token> tokens(cap);
    int32_t n = llama_tokenize(
        vocab,
        text.c_str(),
        static_cast<int32_t>(text.size()),
        tokens.data(),
        cap,
        add_special,
        parse_special
    );
    if (n < 0) {
        tokens.resize(static_cast<size_t>(-n));
        n = llama_tokenize(
            vocab,
            text.c_str(),
            static_cast<int32_t>(text.size()),
            tokens.data(),
            static_cast<int32_t>(tokens.size()),
            add_special,
            parse_special
        );
    }
    if (n < 0) return {};
    tokens.resize(static_cast<size_t>(n));
    return tokens;
}

std::string token_to_string(const llama_vocab* vocab, llama_token token) {
    char buf[128];
    int32_t n = llama_token_to_piece(vocab, token, buf, sizeof(buf), 0, false);
    if (n < 0) {
        std::string large(static_cast<size_t>(-n), '\0');
        n = llama_token_to_piece(vocab, token, large.data(), static_cast<int32_t>(large.size()), 0, false);
        if (n > 0) {
            large.resize(static_cast<size_t>(n));
            return large;
        }
        return {};
    }
    return std::string(buf, static_cast<size_t>(n));
}

double log_prob_of_token(const float* logits, int32_t n_vocab, llama_token target) {
    if (!logits || target < 0 || target >= n_vocab) return -20.0;
    float max_logit = logits[0];
    for (int32_t i = 1; i < n_vocab; ++i) {
        if (logits[i] > max_logit) max_logit = logits[i];
    }
    // 跳过距最大 logit 超过 20.0 的极尾项（exp(-20) ≈ 2e-9，总误差 < 1e-4 nats），可省去 99%+ 的 exp() 计算
    const float cutoff = max_logit - 20.0f;
    double sum_exp = 0.0;
    for (int32_t i = 0; i < n_vocab; ++i) {
        if (logits[i] > cutoff) {
            sum_exp += std::exp(static_cast<double>(logits[i] - max_logit));
        }
    }
    double log_z = static_cast<double>(max_logit) + std::log(sum_exp);
    return static_cast<double>(logits[target]) - log_z;
}

} // namespace

struct PureCJKVocabEntry {
    llama_token token;
    std::string piece;
};

struct SPMLlamaEngine {
    llama_model* model = nullptr;
    llama_context* ctx = nullptr;
    const llama_vocab* vocab = nullptr;
    int32_t n_ctx = 512;
    int32_t n_batch = 128;
    std::atomic<bool> cancel_requested{false};
    std::mutex exec_mutex;
    bool cjk_vocab_ready = false;
    std::vector<PureCJKVocabEntry> pure_cjk_vocab;

    ~SPMLlamaEngine() {
        if (ctx) {
            llama_free(ctx);
            ctx = nullptr;
        }
        if (model) {
            llama_model_free(model);
            model = nullptr;
        }
    }
};

void spm_llama_backend_init(void) {
    std::call_once(g_backend_once, []() {
        llama_log_set(silent_log_callback, nullptr);
        ggml_backend_load_all();

        // 若默认搜索路径未加载到动态插件（如从 .app/Contents/Frameworks 或 Homebrew libexec 运行），显式补充加载
        if (ggml_backend_dev_count() == 0) {
            std::vector<std::string> search_dirs;
            if (const char* env_dir = std::getenv("SMARTPINYIN_GGML_BACKEND_DIR")) {
                search_dirs.emplace_back(env_dir);
            }
            char exe_path[1024] = {0};
            uint32_t size = sizeof(exe_path);
            if (_NSGetExecutablePath(exe_path, &size) == 0) {
                std::string exe_str(exe_path);
                auto slash = exe_str.find_last_of('/');
                if (slash != std::string::npos) {
                    std::string dir = exe_str.substr(0, slash);
                    search_dirs.push_back(dir + "/../Frameworks/ggml-backends");
                    search_dirs.push_back(dir + "/../../../../Frameworks/ggml-backends");
                }
            }
            search_dirs.emplace_back("/opt/homebrew/opt/ggml/libexec");
            search_dirs.emplace_back("/usr/local/opt/ggml/libexec");

            for (const auto& dir : search_dirs) {
                struct stat st{};
                if (stat(dir.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
                    ggml_backend_load_all_from_path(dir.c_str());
                    if (ggml_backend_dev_count() > 0) break;
                }
            }
        }
        llama_backend_init();
    });
}

void spm_llama_backend_free(void) {
    llama_backend_free();
}

char* spm_llama_backend_summary(void) {
    spm_llama_backend_init();
    size_t count = ggml_backend_dev_count();
    std::string summary;
    for (size_t i = 0; i < count; ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        if (!dev) continue;
        if (!summary.empty()) summary += ", ";
        const char* name = ggml_backend_dev_name(dev);
        const char* desc = ggml_backend_dev_description(dev);
        summary += (name ? name : "unknown");
        if (desc && desc[0] != '\0') {
            summary += " (";
            summary += desc;
            summary += ")";
        }
    }
    if (summary.empty()) summary = "none";
    return strdup(summary.c_str());
}

SPMLlamaEngine* spm_llama_load(const char* model_path, SPMLlamaConfig config) {
    if (!model_path || model_path[0] == '\0') return nullptr;
    spm_llama_backend_init();

    auto mparams = llama_model_default_params();
    mparams.n_gpu_layers = config.n_gpu_layers;

    llama_model* model = llama_model_load_from_file(model_path, mparams);
    if (!model) return nullptr;

    auto cparams = llama_context_default_params();
    cparams.n_ctx = static_cast<uint32_t>(config.n_ctx > 0 ? config.n_ctx : 512);
    cparams.n_batch = static_cast<uint32_t>(config.n_batch > 0 ? config.n_batch : 128);
    cparams.n_ubatch = cparams.n_batch;
    cparams.n_seq_max = 1;
    cparams.no_perf = true;
    if (config.quantize_kv_q8) {
        cparams.type_k = GGML_TYPE_Q8_0;
        cparams.type_v = GGML_TYPE_Q8_0;
    }

    int32_t hw_threads = static_cast<int32_t>(std::thread::hardware_concurrency());
    int32_t chosen_threads = config.n_threads > 0 ? config.n_threads : std::max(2, std::min(6, hw_threads / 2));
    cparams.n_threads = chosen_threads;
    cparams.n_threads_batch = chosen_threads;

    llama_context* ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        llama_model_free(model);
        return nullptr;
    }

    auto* engine = new SPMLlamaEngine();
    engine->model = model;
    engine->ctx = ctx;
    engine->vocab = llama_model_get_vocab(model);
    engine->n_ctx = static_cast<int32_t>(cparams.n_ctx);
    engine->n_batch = static_cast<int32_t>(cparams.n_batch);
    return engine;
}

void spm_llama_unload(SPMLlamaEngine* engine) {
    if (!engine) return;
    engine->cancel_requested.store(true, std::memory_order_release);
    std::unique_lock<std::mutex> lock(engine->exec_mutex);
    lock.unlock();
    delete engine;
}

void spm_llama_request_cancel(SPMLlamaEngine* engine) {
    if (!engine) return;
    engine->cancel_requested.store(true, std::memory_order_release);
}

void spm_llama_clear_cancel(SPMLlamaEngine* engine) {
    if (!engine) return;
    engine->cancel_requested.store(false, std::memory_order_release);
}

char* spm_llama_apply_chat_template(
    SPMLlamaEngine* engine,
    const char* system_prompt,
    const char* user_prompt,
    bool add_generation_prompt
) {
    if (!engine || !engine->model || !user_prompt) return nullptr;
    const char* tmpl = llama_model_chat_template(engine->model, nullptr);
    if (!tmpl) return nullptr;

    std::vector<llama_chat_message> msgs;
    if (system_prompt && system_prompt[0] != '\0') {
        msgs.push_back({"system", system_prompt});
    }
    msgs.push_back({"user", user_prompt});

    int32_t needed = llama_chat_apply_template(
        tmpl, msgs.data(), msgs.size(), add_generation_prompt, nullptr, 0
    );
    if (needed <= 0) return nullptr;

    char* buf = static_cast<char*>(std::calloc(static_cast<size_t>(needed) + 1, 1));
    if (!buf) return nullptr;
    int32_t written = llama_chat_apply_template(
        tmpl, msgs.data(), msgs.size(), add_generation_prompt, buf, needed + 1
    );
    if (written < 0) {
        std::free(buf);
        return nullptr;
    }
    buf[written] = '\0';
    return buf;
}

SPMLlamaGenResult spm_llama_generate(
    SPMLlamaEngine* engine,
    const char* prompt,
    int32_t max_tokens,
    float temperature,
    const char* const* stop_sequences,
    int32_t num_stops
) {
    SPMLlamaGenResult res{};
    if (!engine || !engine->ctx || !engine->vocab || !prompt) return res;

    std::lock_guard<std::mutex> lock(engine->exec_mutex);
    if (engine->cancel_requested.load(std::memory_order_acquire)) {
        res.cancelled = true;
        return res;
    }

    auto t0 = Clock::now();
    llama_memory_clear(llama_get_memory(engine->ctx), true);

    std::vector<llama_token> prompt_tokens = tokenize_string(engine->vocab, prompt, true, true);
    if (prompt_tokens.empty()) return res;

    const int32_t max_prompt = std::max(32, engine->n_ctx - max_tokens - 4);
    if (static_cast<int32_t>(prompt_tokens.size()) > max_prompt) {
        prompt_tokens.erase(
            prompt_tokens.begin(),
            prompt_tokens.end() - max_prompt
        );
    }
    res.prompt_tokens = static_cast<int32_t>(prompt_tokens.size());

    // 分块 Prefill
    int32_t pos = 0;
    const int32_t total_prompt = static_cast<int32_t>(prompt_tokens.size());
    while (pos < total_prompt) {
        if (engine->cancel_requested.load(std::memory_order_acquire)) {
            res.cancelled = true;
            res.total_ms = elapsed_ms(t0);
            return res;
        }
        int32_t chunk = std::min(engine->n_batch, total_prompt - pos);
        llama_batch batch = llama_batch_get_one(prompt_tokens.data() + pos, chunk);
        if (llama_decode(engine->ctx, batch) != 0) {
            res.total_ms = elapsed_ms(t0);
            return res;
        }
        pos += chunk;
    }

    auto sparams = llama_sampler_chain_default_params();
    llama_sampler* sampler = llama_sampler_chain_init(sparams);
    const int32_t n_vocab = llama_vocab_n_tokens(engine->vocab);
    // 先 top_k 裁剪再温和重复惩罚，兼顾零耗时开销与防小模型复读回声（如 "Hello! Hello!"）
    if (temperature <= 0.01f) {
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(16));
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(n_vocab, 48, 1.06f, 0.0f, 0.0f));
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(n_vocab, 48, 1.06f, 0.0f, 0.0f));
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9f, 1));
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(42));
    }

    std::string output;
    output.reserve(static_cast<size_t>(max_tokens) * 4);
    bool got_first = false;

    for (int32_t step = 0; step < max_tokens; ++step) {
        if (engine->cancel_requested.load(std::memory_order_acquire)) {
            res.cancelled = true;
            break;
        }
        llama_token next_tok = llama_sampler_sample(sampler, engine->ctx, -1);
        if (!got_first) {
            res.ttft_ms = elapsed_ms(t0);
            got_first = true;
        }
        if (llama_vocab_is_eog(engine->vocab, next_tok)) {
            break;
        }

        std::string piece = token_to_string(engine->vocab, next_tok);
        output.append(piece);
        res.generated_tokens += 1;

        bool hit_stop = false;
        for (int32_t s = 0; s < num_stops; ++s) {
            if (!stop_sequences || !stop_sequences[s]) continue;
            std::string stop_str(stop_sequences[s]);
            if (stop_str.empty()) continue;
            auto found = output.find(stop_str);
            if (found != std::string::npos) {
                output.erase(found);
                hit_stop = true;
                break;
            }
        }
        if (hit_stop) break;

        if (pos + step + 1 >= engine->n_ctx) break;

        llama_batch next_batch = llama_batch_get_one(&next_tok, 1);
        if (llama_decode(engine->ctx, next_batch) != 0) {
            break;
        }
    }

    llama_sampler_free(sampler);
    res.total_ms = elapsed_ms(t0);
    if (!got_first) res.ttft_ms = res.total_ms;
    res.text = strdup(output.c_str());
    res.ok = !res.cancelled;
    return res;
}

void spm_llama_free_gen_result(SPMLlamaGenResult* result) {
    if (!result) return;
    std::free(result->text);
    result->text = nullptr;
}

bool spm_llama_score_candidates(
    SPMLlamaEngine* engine,
    const char* shared_prefix,
    const char* const* candidates,
    int32_t num_candidates,
    int32_t timeout_ms,
    double* scores_out,
    double* elapsed_ms_out
) {
    if (!engine || !engine->ctx || !engine->vocab || !candidates || num_candidates <= 0 || !scores_out) {
        return false;
    }

    std::lock_guard<std::mutex> lock(engine->exec_mutex);
    if (engine->cancel_requested.load(std::memory_order_acquire)) {
        if (elapsed_ms_out) *elapsed_ms_out = 0.0;
        return false;
    }

    auto t0 = Clock::now();
    llama_memory_t mem = llama_get_memory(engine->ctx);
    llama_memory_clear(mem, true);

    const std::string prefix_str = shared_prefix ? std::string(shared_prefix) : std::string();
    std::vector<llama_token> prefix_tokens = tokenize_string(engine->vocab, prefix_str, true, false);
    if (prefix_tokens.empty()) {
        llama_token bos = llama_vocab_bos(engine->vocab);
        if (bos >= 0) prefix_tokens.push_back(bos);
    }

    const int32_t max_prefix = std::max(16, engine->n_ctx - 48);
    if (static_cast<int32_t>(prefix_tokens.size()) > max_prefix) {
        prefix_tokens.erase(prefix_tokens.begin(), prefix_tokens.end() - max_prefix);
    }

    // 1. 仅 Prefill 一次共享前文上下文
    int32_t prefix_len = static_cast<int32_t>(prefix_tokens.size());
    int32_t pos = 0;
    while (pos < prefix_len) {
        int32_t chunk = std::min(engine->n_batch, prefix_len - pos);
        llama_batch batch = llama_batch_get_one(prefix_tokens.data() + pos, chunk);
        if (llama_decode(engine->ctx, batch) != 0) return false;
        pos += chunk;
    }

    const int32_t n_vocab = llama_vocab_n_tokens(engine->vocab);
    // 缓存前缀末 token 的 logits，供每个候选的首 token 打分复用
    const float* prefix_last_logits = llama_get_logits_ith(engine->ctx, -1);
    if (!prefix_last_logits) return false;
    std::vector<float> saved_prefix_logits(prefix_last_logits, prefix_last_logits + n_vocab);

    llama_batch cand_batch = llama_batch_init(64, 0, 1);

    for (int32_t i = 0; i < num_candidates; ++i) {
        scores_out[i] = -1e9;
    }

    bool cancelled = false;
    int32_t scored_count = 0;
    for (int32_t i = 0; i < num_candidates; ++i) {
        if (engine->cancel_requested.load(std::memory_order_acquire)) {
            cancelled = true;
            break;
        }
        // 超时时保留已经完成打分的前 i 个候选（>= 2 个即有排序价值），不再整批作废！
        if (timeout_ms > 0 && elapsed_ms(t0) > static_cast<double>(timeout_ms)) {
            break;
        }

        const char* cand_cstr = candidates[i];
        std::vector<llama_token> ctoks = tokenize_string(
            engine->vocab,
            cand_cstr ? std::string(cand_cstr) : std::string(),
            false,
            false
        );
        if (ctoks.empty()) {
            scores_out[i] = -100.0;
            continue;
        }

        // 候选第 0 个 token 直接用缓存的前缀末 logits 计算，零额外前向传播！
        double total_lp = log_prob_of_token(saved_prefix_logits.data(), n_vocab, ctoks[0]);

        if (ctoks.size() > 1) {
            // 仅清除前文之后的 KV，保留共享前文 KV 零重算
            llama_memory_seq_rm(mem, 0, prefix_len, -1);

            const int32_t eval_n = std::min<int32_t>(static_cast<int32_t>(ctoks.size()) - 1, 63);
            cand_batch.n_tokens = eval_n;
            for (int32_t k = 0; k < eval_n; ++k) {
                cand_batch.token[k] = ctoks[static_cast<size_t>(k)];
                cand_batch.pos[k] = prefix_len + k;
                cand_batch.n_seq_id[k] = 1;
                cand_batch.seq_id[k][0] = 0;
                cand_batch.logits[k] = 1; // 需要每步 logits 评分后续 token
            }

            if (llama_decode(engine->ctx, cand_batch) != 0) {
                scores_out[i] = -100.0;
                continue;
            }
            for (int32_t k = 0; k < eval_n; ++k) {
                const float* step_logits = llama_get_logits_ith(engine->ctx, k);
                total_lp += log_prob_of_token(step_logits, n_vocab, ctoks[static_cast<size_t>(k + 1)]);
            }
        }

        // 温和长度补偿（alpha = 0.65），避免按 token 数线性均分导致多 token 生僻词压过高频单 token 常用词
        const double length_norm = std::pow(static_cast<double>(ctoks.size()), 0.65);
        scores_out[i] = total_lp / length_norm;
        scored_count += 1;
    }

    llama_batch_free(cand_batch);
    if (elapsed_ms_out) *elapsed_ms_out = elapsed_ms(t0);
    return !cancelled && scored_count >= 2;
}

bool spm_llama_score_texts_exact(
    SPMLlamaEngine* engine,
    const char* shared_prefix,
    const char* const* candidates,
    int32_t num_candidates,
    int32_t timeout_ms,
    double* scores_out,
    double* elapsed_ms_out
) {
    if (!engine || !engine->ctx || !engine->vocab || !candidates || num_candidates <= 0 || !scores_out) {
        return false;
    }

    std::lock_guard<std::mutex> lock(engine->exec_mutex);
    if (engine->cancel_requested.load(std::memory_order_acquire)) {
        if (elapsed_ms_out) *elapsed_ms_out = 0.0;
        return false;
    }

    auto t0 = Clock::now();
    llama_memory_t mem = llama_get_memory(engine->ctx);
    llama_memory_clear(mem, true);

    const std::string prefix_str = shared_prefix ? std::string(shared_prefix) : std::string();
    std::vector<llama_token> prefix_tokens;
    const char* chat_tmpl = llama_model_chat_template(engine->model, nullptr);
    if (chat_tmpl && std::strstr(chat_tmpl, "<|im_start|>") != nullptr) {
        // 复用自然用户输入分布头（<|im_start|>user\n），同时天然支持 shared_prefix 为空时的句首字符打分
        prefix_tokens = tokenize_string(engine->vocab, "<|im_start|>user\n", false, true);
        if (!prefix_str.empty()) {
            auto body = tokenize_string(engine->vocab, prefix_str, false, false);
            prefix_tokens.insert(prefix_tokens.end(), body.begin(), body.end());
        }
    } else {
        prefix_tokens = tokenize_string(engine->vocab, prefix_str, true, false);
        if (prefix_tokens.empty()) {
            llama_token bos = llama_vocab_bos(engine->vocab);
            if (bos >= 0) prefix_tokens.push_back(bos);
        }
    }
    if (prefix_tokens.empty()) return false;

    const int32_t max_cand_tokens = std::min<int32_t>(engine->n_batch, 128);
    const int32_t max_prefix = std::max<int32_t>(16, engine->n_ctx - max_cand_tokens - 4);
    if (static_cast<int32_t>(prefix_tokens.size()) > max_prefix) {
        prefix_tokens.erase(prefix_tokens.begin(), prefix_tokens.end() - max_prefix);
    }

    const int32_t prefix_len = static_cast<int32_t>(prefix_tokens.size());
    int32_t pos = 0;
    while (pos < prefix_len) {
        if (engine->cancel_requested.load(std::memory_order_acquire)) {
            if (elapsed_ms_out) *elapsed_ms_out = elapsed_ms(t0);
            return false;
        }
        int32_t chunk = std::min(engine->n_batch, prefix_len - pos);
        llama_batch batch = llama_batch_get_one(prefix_tokens.data() + pos, chunk);
        if (llama_decode(engine->ctx, batch) != 0) {
            if (elapsed_ms_out) *elapsed_ms_out = elapsed_ms(t0);
            return false;
        }
        pos += chunk;
    }

    const int32_t n_vocab = llama_vocab_n_tokens(engine->vocab);
    const float* prefix_last_logits = llama_get_logits_ith(engine->ctx, -1);
    if (!prefix_last_logits || n_vocab <= 0) {
        if (elapsed_ms_out) *elapsed_ms_out = elapsed_ms(t0);
        return false;
    }
    std::vector<float> saved_prefix_logits(prefix_last_logits, prefix_last_logits + n_vocab);

    struct ScopedLlamaBatch {
        llama_batch batch;
        explicit ScopedLlamaBatch(int32_t cap) : batch(llama_batch_init(cap, 0, 1)) {}
        ~ScopedLlamaBatch() { llama_batch_free(batch); }
        ScopedLlamaBatch(const ScopedLlamaBatch&) = delete;
        ScopedLlamaBatch& operator=(const ScopedLlamaBatch&) = delete;
    } scoped_batch(max_cand_tokens);

    for (int32_t i = 0; i < num_candidates; ++i) {
        scores_out[i] = -1e9;
    }

    bool cancelled = false;
    int32_t scored_count = 0;
    for (int32_t i = 0; i < num_candidates; ++i) {
        if (engine->cancel_requested.load(std::memory_order_acquire)) {
            cancelled = true;
            break;
        }
        if (timeout_ms > 0 && elapsed_ms(t0) > static_cast<double>(timeout_ms)) {
            break;
        }

        const char* cand_cstr = candidates[i];
        std::vector<llama_token> ctoks = tokenize_string(
            engine->vocab,
            cand_cstr ? std::string(cand_cstr) : std::string(),
            false,
            false
        );
        if (ctoks.empty()) {
            scores_out[i] = -1e6;
            continue;
        }

        const int32_t avail_ctx = engine->n_ctx - prefix_len - 1;
        const int32_t max_eval_tokens = std::min<int32_t>(max_cand_tokens, std::max<int32_t>(1, avail_ctx));
        if (static_cast<int32_t>(ctoks.size()) > max_eval_tokens) {
            ctoks.resize(static_cast<size_t>(max_eval_tokens));
        }

        double total_lp = log_prob_of_token(saved_prefix_logits.data(), n_vocab, ctoks[0]);

        if (ctoks.size() > 1) {
            llama_memory_seq_rm(mem, 0, prefix_len, -1);

            const int32_t eval_n = static_cast<int32_t>(ctoks.size()) - 1;
            scoped_batch.batch.n_tokens = eval_n;
            for (int32_t k = 0; k < eval_n; ++k) {
                scoped_batch.batch.token[k] = ctoks[static_cast<size_t>(k)];
                scoped_batch.batch.pos[k] = prefix_len + k;
                scoped_batch.batch.n_seq_id[k] = 1;
                scoped_batch.batch.seq_id[k][0] = 0;
                scoped_batch.batch.logits[k] = 1;
            }

            if (llama_decode(engine->ctx, scoped_batch.batch) != 0) {
                scores_out[i] = -1e6;
                continue;
            }
            for (int32_t k = 0; k < eval_n; ++k) {
                const float* step_logits = llama_get_logits_ith(engine->ctx, k);
                total_lp += log_prob_of_token(step_logits, n_vocab, ctoks[static_cast<size_t>(k + 1)]);
            }
        }

        // 返回精确整串联合对数概率（不除以 token 数，避免 BPE 合并/拆分差异扭曲比较）
        scores_out[i] = total_lp;
        scored_count += 1;
    }

    if (elapsed_ms_out) *elapsed_ms_out = elapsed_ms(t0);
    return !cancelled && scored_count >= 2;
}

namespace {

bool decode_utf8_codepoint(const std::string& s, size_t pos, uint32_t& cp, size_t& len) {
    if (pos >= s.size()) return false;
    unsigned char b0 = static_cast<unsigned char>(s[pos]);
    if (b0 < 0x80) {
        cp = b0;
        len = 1;
        return true;
    }
    if ((b0 & 0xE0) == 0xC0 && pos + 1 < s.size()) {
        unsigned char b1 = static_cast<unsigned char>(s[pos + 1]);
        if ((b1 & 0xC0) != 0x80) return false;
        cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F);
        len = 2;
        return cp >= 0x80;
    }
    if ((b0 & 0xF0) == 0xE0 && pos + 2 < s.size()) {
        unsigned char b1 = static_cast<unsigned char>(s[pos + 1]);
        unsigned char b2 = static_cast<unsigned char>(s[pos + 2]);
        if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80) return false;
        cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
        len = 3;
        return cp >= 0x800 && !(cp >= 0xD800 && cp <= 0xDFFF);
    }
    if ((b0 & 0xF8) == 0xF0 && pos + 3 < s.size()) {
        unsigned char b1 = static_cast<unsigned char>(s[pos + 1]);
        unsigned char b2 = static_cast<unsigned char>(s[pos + 2]);
        unsigned char b3 = static_cast<unsigned char>(s[pos + 3]);
        if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80) return false;
        cp = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
        len = 4;
        return cp >= 0x10000 && cp <= 0x10FFFF;
    }
    return false;
}

bool is_valid_utf8(const std::string& s) {
    size_t i = 0;
    while (i < s.size()) {
        uint32_t cp = 0;
        size_t len = 0;
        if (!decode_utf8_codepoint(s, i, cp, len)) return false;
        i += len;
    }
    return true;
}

std::string trim_incomplete_utf8_tail(const std::string& s) {
    size_t i = 0;
    size_t last_good = 0;
    while (i < s.size()) {
        uint32_t cp = 0;
        size_t len = 0;
        if (!decode_utf8_codepoint(s, i, cp, len)) break;
        i += len;
        last_good = i;
    }
    return s.substr(0, last_good);
}

bool is_cjk_codepoint(uint32_t cp) {
    return (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF);
}

bool is_branch_stop_punctuation(uint32_t cp) {
    switch (cp) {
        case '\n': case '\r': case '\t':
        case ',': case '.': case '!': case '?': case ';': case ':':
        case '(': case ')': case '[': case ']': case '{': case '}':
        case '<': case '>': case '"': case '\'': case '`':
        case 0xFF0C: // ，
        case 0x3002: // 。
        case 0xFF01: // ！
        case 0xFF1F: // ？
        case 0xFF1B: // ；
        case 0xFF1A: // ：
        case 0x3001: // 、
        case 0xFF08: case 0xFF09: // （）
        case 0x300A: case 0x300B: // 《》
        case 0x3010: case 0x3011: // 【】
        case 0x201C: case 0x201D: // “”
        case 0x2018: case 0x2019: // ‘’
        case 0x300C: case 0x300D: // 「」
        case 0x300E: case 0x300F: // 『』
        case 0x2026: // …
        case 0x2014: // —
            return true;
        default:
            return false;
    }
}

bool prefix_ends_with_cjk(const std::string& s) {
    uint32_t last_cp = 0;
    size_t i = 0;
    while (i < s.size()) {
        uint32_t cp = 0;
        size_t len = 0;
        if (!decode_utf8_codepoint(s, i, cp, len)) break;
        if (cp != ' ' && cp != '\t' && cp != '\n' && cp != '\r') {
            last_cp = cp;
        }
        i += len;
    }
    return is_cjk_codepoint(last_cp);
}

size_t count_utf8_chars(const std::string& s) {
    size_t count = 0;
    size_t i = 0;
    while (i < s.size()) {
        uint32_t cp = 0;
        size_t len = 0;
        if (!decode_utf8_codepoint(s, i, cp, len)) break;
        count += 1;
        i += len;
    }
    return count;
}

/// 若 piece 内包含终止标点，返回截断到首个标点之前的有效前缀并标记 hit_boundary
std::string clip_at_boundary(const std::string& piece, bool& hit_boundary) {
    hit_boundary = false;
    size_t i = 0;
    while (i < piece.size()) {
        uint32_t cp = 0;
        size_t len = 0;
        if (!decode_utf8_codepoint(piece, i, cp, len)) break;
        if (is_branch_stop_punctuation(cp)) {
            hit_boundary = true;
            return piece.substr(0, i);
        }
        i += len;
    }
    return piece;
}

bool is_valid_branch_root_piece(const std::string& piece, bool expect_cjk) {
    if (piece.empty() || !is_valid_utf8(piece)) return false;
    // 跳过模板标签与空白/标点起头
    if (piece.find('<') != std::string::npos || piece.find('|') != std::string::npos) return false;
    uint32_t first_cp = 0;
    size_t first_len = 0;
    if (!decode_utf8_codepoint(piece, 0, first_cp, first_len)) return false;
    if (first_cp <= 0x20 || is_branch_stop_punctuation(first_cp)) return false;
    if (expect_cjk) {
        return is_cjk_codepoint(first_cp);
    }
    return is_cjk_codepoint(first_cp)
        || (first_cp >= 'A' && first_cp <= 'Z')
        || (first_cp >= 'a' && first_cp <= 'z');
}

struct LogitTopEntry {
    llama_token token;
    float logit;
};

} // namespace

SPMLlamaBranchResult spm_llama_predict_branches(
    SPMLlamaEngine* engine,
    const char* raw_prefix,
    int32_t max_branches,
    int32_t max_tokens_per_branch,
    int32_t timeout_ms
) {
    SPMLlamaBranchResult res{};
    if (!engine || !engine->ctx || !engine->vocab || !raw_prefix || raw_prefix[0] == '\0') {
        return res;
    }

    const int32_t clamped_branches = std::max<int32_t>(1, std::min<int32_t>(10, max_branches));
    const int32_t clamped_steps = std::max<int32_t>(2, std::min<int32_t>(8, max_tokens_per_branch));

    std::lock_guard<std::mutex> lock(engine->exec_mutex);
    if (engine->cancel_requested.load(std::memory_order_acquire)) {
        res.cancelled = true;
        return res;
    }

    auto t0 = Clock::now();
    llama_memory_t mem = llama_get_memory(engine->ctx);
    llama_memory_clear(mem, true);

    const std::string prefix_str(raw_prefix);
    const bool expect_cjk = prefix_ends_with_cjk(prefix_str);

    // 使用极简 3-token 用户语境引导头（<|im_start|>user\n），将 Qwen3 从网页新闻/范文分布切换至真实人类打字/提问分布，
    // 零 System Prompt、零 Few-Shot 污染、不进入 assistant 回复态，仅增加 < 0.5ms 开销。
    std::vector<llama_token> prefix_tokens;
    const char* chat_tmpl = llama_model_chat_template(engine->model, nullptr);
    if (chat_tmpl && std::strstr(chat_tmpl, "<|im_start|>") != nullptr) {
        std::vector<llama_token> role_head = tokenize_string(engine->vocab, "<|im_start|>user\n", false, true);
        std::vector<llama_token> body_toks = tokenize_string(engine->vocab, prefix_str, false, false);
        prefix_tokens.reserve(role_head.size() + body_toks.size());
        prefix_tokens.insert(prefix_tokens.end(), role_head.begin(), role_head.end());
        prefix_tokens.insert(prefix_tokens.end(), body_toks.begin(), body_toks.end());
    } else {
        prefix_tokens = tokenize_string(engine->vocab, prefix_str, true, false);
    }
    if (prefix_tokens.empty()) return res;

    const int32_t max_prefix = std::max<int32_t>(16, engine->n_ctx - clamped_steps - 8);
    if (static_cast<int32_t>(prefix_tokens.size()) > max_prefix) {
        prefix_tokens.erase(prefix_tokens.begin(), prefix_tokens.end() - max_prefix);
    }

    // 1. 仅 Prefill 一次纯净上文（零 Chat 模板开销）
    const int32_t prefix_len = static_cast<int32_t>(prefix_tokens.size());
    int32_t pos = 0;
    while (pos < prefix_len) {
        if (engine->cancel_requested.load(std::memory_order_acquire)) {
            res.cancelled = true;
            res.total_ms = elapsed_ms(t0);
            return res;
        }
        int32_t chunk = std::min(engine->n_batch, prefix_len - pos);
        llama_batch batch = llama_batch_get_one(prefix_tokens.data() + pos, chunk);
        if (llama_decode(engine->ctx, batch) != 0) {
            res.total_ms = elapsed_ms(t0);
            return res;
        }
        pos += chunk;
    }

    const int32_t n_vocab = llama_vocab_n_tokens(engine->vocab);
    const float* prefix_logits = llama_get_logits_ith(engine->ctx, -1);
    if (!prefix_logits || n_vocab <= 0) {
        res.total_ms = elapsed_ms(t0);
        return res;
    }

    // 2. 单次线性扫描获取 log_z 与 Top-48 候选词首 token（< 0.2ms）
    float max_logit = prefix_logits[0];
    for (int32_t i = 1; i < n_vocab; ++i) {
        if (prefix_logits[i] > max_logit) max_logit = prefix_logits[i];
    }

    constexpr size_t kRootPoolCap = 48;
    std::vector<LogitTopEntry> top_pool;
    top_pool.reserve(kRootPoolCap + 1);
    double sum_exp = 0.0;
    for (int32_t i = 0; i < n_vocab; ++i) {
        const float lg = prefix_logits[i];
        sum_exp += std::exp(static_cast<double>(lg - max_logit));
        if (top_pool.size() < kRootPoolCap || lg > top_pool.back().logit) {
            auto it = top_pool.begin();
            while (it != top_pool.end() && it->logit >= lg) ++it;
            top_pool.insert(it, LogitTopEntry{i, lg});
            if (top_pool.size() > kRootPoolCap) {
                top_pool.pop_back();
            }
        }
    }
    const double log_z = static_cast<double>(max_logit) + std::log(sum_exp);

    struct RootCandidate {
        llama_token token;
        std::string piece;
        double logprob;
        bool ends_with_boundary;
        bool bridged_with_comma;
        llama_token comma_token;
    };
    std::vector<RootCandidate> roots;
    roots.reserve(static_cast<size_t>(clamped_branches + 2));
    double best_root_lp = -100.0;

    // 检测上文未以标点结尾时，中文逗号「，」是否位于高概率前列（如「不好意思」->「，打扰一下」）
    llama_token high_prob_comma_tok = -1;
    double high_prob_comma_lp = -100.0;
    const bool prefix_ends_with_punct = [&]() {
        uint32_t last_cp = 0;
        size_t i = 0;
        while (i < prefix_str.size()) {
            uint32_t cp = 0;
            size_t len = 0;
            if (!decode_utf8_codepoint(prefix_str, i, cp, len)) break;
            if (cp > 0x20) last_cp = cp;
            i += len;
        }
        return is_branch_stop_punctuation(last_cp);
    }();

    for (size_t idx = 0; idx < top_pool.size(); ++idx) {
        const auto& entry = top_pool[idx];
        if (llama_vocab_is_eog(engine->vocab, entry.token)) continue;
        const double lp = static_cast<double>(entry.logit) - log_z;
        std::string raw_piece = token_to_string(engine->vocab, entry.token);

        if (!prefix_ends_with_punct && high_prob_comma_tok < 0 && idx < 4 && lp >= -2.2 &&
            (raw_piece == "\xEF\xBC\x8C" || raw_piece == ",")) {
            high_prob_comma_tok = entry.token;
            high_prob_comma_lp = lp;
            continue;
        }

        if (!roots.empty() && lp < std::max(best_root_lp - 3.6, -5.8)) {
            break;
        }
        bool hit_boundary = false;
        std::string clipped = clip_at_boundary(raw_piece, hit_boundary);
        if (!is_valid_branch_root_piece(clipped, expect_cjk)) continue;

        bool dup = false;
        for (const auto& existing : roots) {
            if (existing.piece == clipped) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        if (roots.empty()) best_root_lp = lp;
        roots.push_back(RootCandidate{entry.token, std::move(clipped), lp, hit_boundary, false, -1});
        if (static_cast<int32_t>(roots.size()) >= clamped_branches) break;
    }

    llama_batch step_batch = llama_batch_init(1, 0, 1);

    // 若中文逗号「，」高概率出现（例如「不好意思」「请问一下」后），额外展开最多 3 条逗号桥接分支！
    if (high_prob_comma_tok >= 0 && prefix_len + 2 < engine->n_ctx &&
        !engine->cancel_requested.load(std::memory_order_acquire) &&
        !(timeout_ms > 0 && elapsed_ms(t0) > static_cast<double>(timeout_ms))) {
        llama_memory_seq_rm(mem, 0, prefix_len, -1);
        step_batch.n_tokens = 1;
        step_batch.token[0] = high_prob_comma_tok;
        step_batch.pos[0] = prefix_len;
        step_batch.n_seq_id[0] = 1;
        step_batch.seq_id[0][0] = 0;
        step_batch.logits[0] = 1;

        if (llama_decode(engine->ctx, step_batch) == 0) {
            const float* post_logits = llama_get_logits_ith(engine->ctx, 0);
            if (post_logits) {
                float p_max = post_logits[0];
                for (int32_t v = 1; v < n_vocab; ++v) {
                    if (post_logits[v] > p_max) p_max = post_logits[v];
                }
                std::vector<LogitTopEntry> post_pool;
                post_pool.reserve(25);
                double p_sum = 0.0;
                for (int32_t v = 0; v < n_vocab; ++v) {
                    const float lg = post_logits[v];
                    p_sum += std::exp(static_cast<double>(lg - p_max));
                    if (post_pool.size() < 24 || lg > post_pool.back().logit) {
                        auto it = post_pool.begin();
                        while (it != post_pool.end() && it->logit >= lg) ++it;
                        post_pool.insert(it, LogitTopEntry{v, lg});
                        if (post_pool.size() > 24) post_pool.pop_back();
                    }
                }
                const double post_log_z = static_cast<double>(p_max) + std::log(p_sum);
                int32_t added_comma = 0;
                for (const auto& pe : post_pool) {
                    if (llama_vocab_is_eog(engine->vocab, pe.token)) continue;
                    const double plp = static_cast<double>(pe.logit) - post_log_z;
                    if (plp < -4.5) break;
                    std::string raw_p = token_to_string(engine->vocab, pe.token);
                    bool hb = false;
                    std::string cp = clip_at_boundary(raw_p, hb);
                    if (!is_valid_branch_root_piece(cp, expect_cjk)) continue;
                    std::string prefixed = "\xEF\xBC\x8C" + cp;
                    bool dup = false;
                    for (const auto& existing : roots) {
                        if (existing.piece == prefixed || existing.piece == cp) {
                            dup = true;
                            break;
                        }
                    }
                    if (dup) continue;
                    // 若逗号是绝对主流续写（> 45%），让逗号桥接分支在同等条件下自然胜出
                    const double bridged_lp = plp + high_prob_comma_lp * 0.25;
                    roots.push_back(RootCandidate{pe.token, std::move(prefixed), bridged_lp, hb, true, high_prob_comma_tok});
                    added_comma += 1;
                    if (added_comma >= 3) break;
                }
            }
        }
    }

    if (roots.empty()) {
        llama_batch_free(step_batch);
        res.total_ms = elapsed_ms(t0);
        res.ok = true;
        return res;
    }

    // 3. 在共享前缀 KV Cache 上为每个 root 独立贪心展开至自然语义边界
    struct BuiltBranch {
        std::string text;
        double score;
        int32_t token_count;
    };
    std::vector<BuiltBranch> built;
    built.reserve(roots.size());

    for (const auto& root : roots) {
        if (engine->cancel_requested.load(std::memory_order_acquire)) {
            res.cancelled = true;
            break;
        }
        if (timeout_ms > 0 && elapsed_ms(t0) > static_cast<double>(timeout_ms)) {
            break;
        }

        std::string text = root.piece;
        double total_lp = root.logprob;
        int32_t tok_count = 1;

        // 若首 token 本身已带标点边界或已足够长（>= 6 字），直接完成本分支
        if (!root.ends_with_boundary && count_utf8_chars(text) < 6) {
            llama_memory_seq_rm(mem, 0, prefix_len, -1);

            int32_t base_offset = 0;
            if (root.bridged_with_comma && root.comma_token >= 0) {
                step_batch.n_tokens = 1;
                step_batch.token[0] = root.comma_token;
                step_batch.pos[0] = prefix_len;
                step_batch.n_seq_id[0] = 1;
                step_batch.seq_id[0][0] = 0;
                step_batch.logits[0] = 0;
                if (llama_decode(engine->ctx, step_batch) != 0) continue;
                base_offset = 1;
            }

            llama_token cur_tok = root.token;
            for (int32_t step = 0; step < clamped_steps - 1; ++step) {
                if (engine->cancel_requested.load(std::memory_order_acquire)) {
                    res.cancelled = true;
                    break;
                }
                if (timeout_ms > 0 && elapsed_ms(t0) > static_cast<double>(timeout_ms)) {
                    break;
                }
                if (prefix_len + base_offset + step + 1 >= engine->n_ctx) break;

                step_batch.n_tokens = 1;
                step_batch.token[0] = cur_tok;
                step_batch.pos[0] = prefix_len + base_offset + step;
                step_batch.n_seq_id[0] = 1;
                step_batch.seq_id[0][0] = 0;
                step_batch.logits[0] = 1;

                if (llama_decode(engine->ctx, step_batch) != 0) break;

                const float* step_logits = llama_get_logits_ith(engine->ctx, 0);
                if (!step_logits) break;

                // 贪心选出下一步概率最高的 token 并计算其精确 logprob
                llama_token best_tok = 0;
                float best_lg = step_logits[0];
                for (int32_t v = 1; v < n_vocab; ++v) {
                    if (step_logits[v] > best_lg) {
                        best_lg = step_logits[v];
                        best_tok = v;
                    }
                }
                if (llama_vocab_is_eog(engine->vocab, best_tok)) break;

                double step_sum_exp = 0.0;
                for (int32_t v = 0; v < n_vocab; ++v) {
                    step_sum_exp += std::exp(static_cast<double>(step_logits[v] - best_lg));
                }
                const double step_lp = -std::log(step_sum_exp); // best_lg - (best_lg + log(step_sum_exp))

                std::string piece = token_to_string(engine->vocab, best_tok);
                if (piece.empty() || piece.find('<') != std::string::npos) break;

                // 若已有完整词（>= 2 字）且下一步置信度骤降，在自然词边界提前收尾
                const size_t current_chars = count_utf8_chars(text);
                if (current_chars >= 2 && step_lp < -3.2) {
                    break;
                }

                bool hit_boundary = false;
                std::string candidate_next = text + piece;
                if (is_valid_utf8(candidate_next)) {
                    std::string clipped_piece = clip_at_boundary(piece, hit_boundary);
                    if (clipped_piece.empty()) {
                        break; // 遇到标点/换行，正好停在完整短语边界
                    }
                    const size_t next_chars = count_utf8_chars(text + clipped_piece);
                    if (next_chars > 8 && current_chars >= 2) {
                        break;
                    }
                    text += clipped_piece;
                    total_lp += step_lp;
                    tok_count += 1;
                    if (hit_boundary || next_chars >= 6) {
                        break;
                    }
                } else {
                    // 多字节 UTF-8 拆分 token，继续补齐后续字节
                    text = std::move(candidate_next);
                    total_lp += step_lp;
                    tok_count += 1;
                }
                cur_tok = best_tok;
            }
        }

        if (res.cancelled) break;

        std::string clean_text = trim_incomplete_utf8_tail(text);
        const size_t final_chars = count_utf8_chars(clean_text);
        if (clean_text.empty() || final_chars == 0) continue;

        // 温和长度归一化 + 对过短单字轻微抑制（鼓励自然 2~6 字短语上浮）
        double avg_lp = total_lp / std::pow(static_cast<double>(tok_count), 0.78);
        if (final_chars == 1) {
            avg_lp -= 0.45;
        }
        built.push_back(BuiltBranch{std::move(clean_text), avg_lp, tok_count});
    }

    llama_batch_free(step_batch);

    if (!res.cancelled && !built.empty()) {
        std::sort(built.begin(), built.end(), [](const BuiltBranch& a, const BuiltBranch& b) {
            return a.score > b.score;
        });

        auto* out_items = static_cast<SPMLlamaBranchItem*>(
            std::calloc(built.size(), sizeof(SPMLlamaBranchItem))
        );
        if (out_items) {
            for (size_t i = 0; i < built.size(); ++i) {
                out_items[i].text = strdup(built[i].text.c_str());
                out_items[i].avg_logprob = built[i].score;
                out_items[i].token_count = built[i].token_count;
            }
            res.items = out_items;
            res.count = static_cast<int32_t>(built.size());
        }
    }

    res.total_ms = elapsed_ms(t0);
    res.ok = !res.cancelled;
    return res;
}

void spm_llama_free_branch_result(SPMLlamaBranchResult* result) {
    if (!result) return;
    if (result->items) {
        for (int32_t i = 0; i < result->count; ++i) {
            std::free(result->items[i].text);
        }
        std::free(result->items);
        result->items = nullptr;
    }
    result->count = 0;
}

namespace {

bool is_pure_cjk_piece(const std::string& piece, size_t& out_char_count) {
    out_char_count = 0;
    if (piece.empty()) return false;
    size_t i = 0;
    while (i < piece.size()) {
        uint32_t cp = 0;
        size_t len = 0;
        if (!decode_utf8_codepoint(piece, i, cp, len)) return false;
        if (!is_cjk_codepoint(cp)) return false;
        out_char_count += 1;
        i += len;
    }
    return out_char_count >= 1 && out_char_count <= 3;
}

} // namespace

SPMLlamaSurprisalResult spm_llama_probe_surprisal_proposals(
    SPMLlamaEngine* engine,
    const char* text,
    double surprisal_threshold,
    int32_t top_k,
    int32_t timeout_ms
) {
    SPMLlamaSurprisalResult res{};
    if (!engine || !engine->ctx || !engine->vocab || !text || text[0] == '\0') {
        return res;
    }

    const int32_t clamped_k = std::max<int32_t>(4, std::min<int32_t>(256, top_k));
    std::lock_guard<std::mutex> lock(engine->exec_mutex);
    if (engine->cancel_requested.load(std::memory_order_acquire)) {
        res.cancelled = true;
        return res;
    }

    auto t0 = Clock::now();
    llama_memory_t mem = llama_get_memory(engine->ctx);
    llama_memory_clear(mem, true);

    const int32_t n_vocab_init = llama_vocab_n_tokens(engine->vocab);
    if (!engine->cjk_vocab_ready && n_vocab_init > 0) {
        engine->pure_cjk_vocab.clear();
        engine->pure_cjk_vocab.reserve(32000);
        for (int32_t v = 0; v < n_vocab_init; ++v) {
            if (llama_vocab_is_eog(engine->vocab, v)) continue;
            std::string piece = token_to_string(engine->vocab, v);
            size_t cjk_len = 0;
            if (is_pure_cjk_piece(piece, cjk_len)) {
                engine->pure_cjk_vocab.push_back(PureCJKVocabEntry{v, std::move(piece)});
            }
        }
        engine->cjk_vocab_ready = true;
    }

    const std::string text_str(text);
    std::vector<llama_token> role_head;
    const char* chat_tmpl = llama_model_chat_template(engine->model, nullptr);
    if (chat_tmpl && std::strstr(chat_tmpl, "<|im_start|>") != nullptr) {
        role_head = tokenize_string(engine->vocab, "<|im_start|>user\n", false, true);
    } else {
        llama_token bos = llama_vocab_bos(engine->vocab);
        if (bos >= 0) role_head.push_back(bos);
    }

    std::vector<llama_token> text_tokens = tokenize_string(engine->vocab, text_str, false, false);
    if (role_head.empty() || text_tokens.empty()) {
        res.total_ms = elapsed_ms(t0);
        return res;
    }

    // 限制在单批次可执行长度内（默认 n_batch=128，足以覆盖 ~180 汉字整句）
    const int32_t max_text_toks = std::max<int32_t>(
        1,
        std::min<int32_t>(engine->n_batch, engine->n_ctx - 2) - static_cast<int32_t>(role_head.size())
    );
    if (static_cast<int32_t>(text_tokens.size()) > max_text_toks) {
        text_tokens.resize(static_cast<size_t>(max_text_toks));
    }

    const int32_t role_len = static_cast<int32_t>(role_head.size());
    const int32_t text_len = static_cast<int32_t>(text_tokens.size());
    const int32_t total_len = role_len + text_len;

    struct ScopedBatch {
        llama_batch batch;
        explicit ScopedBatch(int32_t cap) : batch(llama_batch_init(cap, 0, 1)) {}
        ~ScopedBatch() { llama_batch_free(batch); }
        ScopedBatch(const ScopedBatch&) = delete;
        ScopedBatch& operator=(const ScopedBatch&) = delete;
    } scoped(total_len);

    scoped.batch.n_tokens = total_len;
    for (int32_t i = 0; i < role_len; ++i) {
        scoped.batch.token[i] = role_head[static_cast<size_t>(i)];
        scoped.batch.pos[i] = i;
        scoped.batch.n_seq_id[i] = 1;
        scoped.batch.seq_id[i][0] = 0;
        // 仅在 role_head 末位输出 logits 以预测 text_tokens[0]
        scoped.batch.logits[i] = (i == role_len - 1) ? 1 : 0;
    }
    for (int32_t j = 0; j < text_len; ++j) {
        const int32_t idx = role_len + j;
        scoped.batch.token[idx] = text_tokens[static_cast<size_t>(j)];
        scoped.batch.pos[idx] = idx;
        scoped.batch.n_seq_id[idx] = 1;
        scoped.batch.seq_id[idx][0] = 0;
        // 预测下一个 token text_tokens[j + 1]；最后一个 token 无需 logits
        scoped.batch.logits[idx] = (j + 1 < text_len) ? 1 : 0;
    }

    if (engine->cancel_requested.load(std::memory_order_acquire)) {
        res.cancelled = true;
        res.total_ms = elapsed_ms(t0);
        return res;
    }
    if (llama_decode(engine->ctx, scoped.batch) != 0) {
        res.total_ms = elapsed_ms(t0);
        return res;
    }

    const int32_t n_vocab = llama_vocab_n_tokens(engine->vocab);
    if (n_vocab <= 0) {
        res.total_ms = elapsed_ms(t0);
        return res;
    }

    // 1. 映射每个 token 在原文中的 UTF-8 字节区间，并计算其条件对数概率
    std::vector<int32_t> tok_offsets(static_cast<size_t>(text_len), -1);
    std::vector<int32_t> tok_lengths(static_cast<size_t>(text_len), 0);
    std::vector<double> tok_lps(static_cast<size_t>(text_len), 0.0);
    std::vector<double> tok_log_z(static_cast<size_t>(text_len), 0.0);
    std::vector<float> tok_max_lg(static_cast<size_t>(text_len), 0.0f);

    size_t byte_cursor = 0;
    bool alignment_ok = true;
    for (int32_t j = 0; j < text_len; ++j) {
        const float* logits = llama_get_logits_ith(engine->ctx, role_len - 1 + j);
        if (logits) {
            float max_lg = logits[0];
            for (int32_t v = 1; v < n_vocab; ++v) {
                if (logits[v] > max_lg) max_lg = logits[v];
            }
            tok_max_lg[static_cast<size_t>(j)] = max_lg;
            const float exp_cutoff = max_lg - 20.0f;
            double sum_exp = 0.0;
            for (int32_t v = 0; v < n_vocab; ++v) {
                if (logits[v] > exp_cutoff) {
                    sum_exp += std::exp(static_cast<double>(logits[v] - max_lg));
                }
            }
            const double lz = static_cast<double>(max_lg) + std::log(sum_exp);
            tok_log_z[static_cast<size_t>(j)] = lz;
            const llama_token target = text_tokens[static_cast<size_t>(j)];
            tok_lps[static_cast<size_t>(j)] = (target >= 0 && target < n_vocab)
                ? (static_cast<double>(logits[target]) - lz)
                : -20.0;
        } else {
            tok_lps[static_cast<size_t>(j)] = -20.0;
        }

        if (alignment_ok) {
            std::string piece = token_to_string(engine->vocab, text_tokens[static_cast<size_t>(j)]);
            if (byte_cursor + piece.size() <= text_str.size()
                && text_str.compare(byte_cursor, piece.size(), piece) == 0) {
                tok_offsets[static_cast<size_t>(j)] = static_cast<int32_t>(byte_cursor);
                tok_lengths[static_cast<size_t>(j)] = static_cast<int32_t>(piece.size());
                byte_cursor += piece.size();
            } else {
                alignment_ok = false;
            }
        }
    }

    // 2. 筛选需要做 Top-K 替换扫描的位置：
    //    (a) 本位高惊讶度（lp < surprisal_threshold）
    //    (b) 下一 token 高惊讶度（捕获双字词拆 token 错字，如「电+恼」在「电」处提议「电脑」、「再+上海」在「再」处提议「在上海」）
    struct ScanTarget {
        int32_t j;
        double priority_lp;
    };
    std::vector<ScanTarget> targets;
    targets.reserve(static_cast<size_t>(text_len));
    for (int32_t j = 0; j < text_len; ++j) {
        const int32_t boff = tok_offsets[static_cast<size_t>(j)];
        if (boff < 0 || static_cast<size_t>(boff) >= text_str.size()) continue;
        // 跳过落在多字节 UTF-8 中间的字节偏移
        if ((static_cast<unsigned char>(text_str[static_cast<size_t>(boff)]) & 0xC0) == 0x80) continue;

        const double cur_lp = tok_lps[static_cast<size_t>(j)];
        const double next_lp = (j + 1 < text_len) ? tok_lps[static_cast<size_t>(j + 1)] : 0.0;
        const bool self_surprised = (cur_lp < surprisal_threshold);
        const bool next_surprised = (j + 1 < text_len && next_lp < (surprisal_threshold - 0.3));
        if (self_surprised || next_surprised) {
            targets.push_back(ScanTarget{j, std::min(cur_lp, next_lp)});
        }
    }

    // 优先处理最惊讶的前 12 处位置
    if (targets.size() > 12) {
        std::sort(targets.begin(), targets.end(), [](const ScanTarget& a, const ScanTarget& b) {
            return a.priority_lp < b.priority_lp;
        });
        targets.resize(12);
        std::sort(targets.begin(), targets.end(), [](const ScanTarget& a, const ScanTarget& b) {
            return a.j < b.j;
        });
    }

    struct BuiltProposal {
        int32_t byte_offset;
        int32_t byte_length;
        double token_logprob;
        std::vector<std::string> alts;
        std::vector<double> alt_lps;
    };
    std::vector<BuiltProposal> built;
    built.reserve(targets.size());

    struct CJKTopEntry {
        size_t vocab_idx;
        float logit;
    };
    const auto min_heap_cmp = [](const CJKTopEntry& a, const CJKTopEntry& b) {
        return a.logit > b.logit; // 最小堆：堆顶始终为当前 Top-K 中最低分
    };

    std::vector<CJKTopEntry> top_pool;
    top_pool.reserve(static_cast<size_t>(clamped_k) + 1);

    for (const auto& tgt : targets) {
        if (engine->cancel_requested.load(std::memory_order_acquire)) {
            res.cancelled = true;
            break;
        }
        if (timeout_ms > 0 && elapsed_ms(t0) > static_cast<double>(timeout_ms)) {
            break;
        }

        const int32_t j = tgt.j;
        const float* logits = llama_get_logits_ith(engine->ctx, role_len - 1 + j);
        if (!logits) continue;

        const double lz = tok_log_z[static_cast<size_t>(j)];
        const llama_token orig_tok = text_tokens[static_cast<size_t>(j)];
        // 仅扫描预索引的纯 1~3 汉字词表项（跳过 ~80% 英文/标点/碎片 token），零浪费且速度提升 ~5x
        const float min_keep_lg = static_cast<float>(lz - 12.0);
        top_pool.clear();
        const auto& cjk_vocab = engine->pure_cjk_vocab;
        for (size_t vi = 0; vi < cjk_vocab.size(); ++vi) {
            const llama_token v = cjk_vocab[vi].token;
            if (v == orig_tok || v < 0 || v >= n_vocab) continue;
            const float lg = logits[v];
            if (lg < min_keep_lg) continue;
            if (static_cast<int32_t>(top_pool.size()) < clamped_k) {
                top_pool.push_back(CJKTopEntry{vi, lg});
                if (static_cast<int32_t>(top_pool.size()) == clamped_k) {
                    std::make_heap(top_pool.begin(), top_pool.end(), min_heap_cmp);
                }
            } else if (lg > top_pool.front().logit) {
                std::pop_heap(top_pool.begin(), top_pool.end(), min_heap_cmp);
                top_pool.back() = CJKTopEntry{vi, lg};
                std::push_heap(top_pool.begin(), top_pool.end(), min_heap_cmp);
            }
        }

        std::sort(top_pool.begin(), top_pool.end(), [](const CJKTopEntry& a, const CJKTopEntry& b) {
            return a.logit > b.logit;
        });

        BuiltProposal prop;
        prop.byte_offset = tok_offsets[static_cast<size_t>(j)];
        prop.byte_length = tok_lengths[static_cast<size_t>(j)];
        prop.token_logprob = tok_lps[static_cast<size_t>(j)];
        prop.alts.reserve(top_pool.size());
        prop.alt_lps.reserve(top_pool.size());

        for (const auto& entry : top_pool) {
            const double alt_lp = static_cast<double>(entry.logit) - lz;
            if (alt_lp < -12.0) continue;
            prop.alts.push_back(cjk_vocab[entry.vocab_idx].piece);
            prop.alt_lps.push_back(alt_lp);
        }

        if (!prop.alts.empty()) {
            built.push_back(std::move(prop));
        }
    }

    if (!res.cancelled && !built.empty()) {
        auto* items = static_cast<SPMLlamaTokenProposal*>(
            std::calloc(built.size(), sizeof(SPMLlamaTokenProposal))
        );
        if (items) {
            for (size_t i = 0; i < built.size(); ++i) {
                const auto& b = built[i];
                items[i].byte_offset = b.byte_offset;
                items[i].byte_length = b.byte_length;
                items[i].token_logprob = b.token_logprob;
                const size_t ac = b.alts.size();
                items[i].alt_texts = static_cast<char**>(std::calloc(ac, sizeof(char*)));
                items[i].alt_logprobs = static_cast<double*>(std::calloc(ac, sizeof(double)));
                if (items[i].alt_texts && items[i].alt_logprobs) {
                    items[i].alt_count = static_cast<int32_t>(ac);
                    for (size_t k = 0; k < ac; ++k) {
                        items[i].alt_texts[k] = strdup(b.alts[k].c_str());
                        items[i].alt_logprobs[k] = b.alt_lps[k];
                    }
                }
            }
            res.items = items;
            res.count = static_cast<int32_t>(built.size());
        }
    }

    res.total_ms = elapsed_ms(t0);
    res.ok = !res.cancelled;
    return res;
}

void spm_llama_free_surprisal_result(SPMLlamaSurprisalResult* result) {
    if (!result) return;
    if (result->items) {
        for (int32_t i = 0; i < result->count; ++i) {
            auto& item = result->items[i];
            if (item.alt_texts) {
                for (int32_t k = 0; k < item.alt_count; ++k) {
                    std::free(item.alt_texts[k]);
                }
                std::free(item.alt_texts);
            }
            std::free(item.alt_logprobs);
        }
        std::free(result->items);
        result->items = nullptr;
    }
    result->count = 0;
}

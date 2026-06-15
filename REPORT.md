# MLOps Assignment – hw3 Report

## Phase 1 – Serving Configuration

Model: `Qwen/Qwen3-30B-A3B-Instruct-2507` (MoE, 30B total / 3B active params)  
Hardware: Nebius H100 SXM 80 GB, 1× GPU, 16 vCPU, 200 GB RAM

### Final vLLM flags

| Flag | Value | Justification |
|---|---|---|
| `--dtype` | `auto` | Uses BF16 on H100 natively; no accuracy loss vs FP32. |
| `--max-model-len` | `4096` | Reduced from 8192 to halve per-request KV-cache footprint, allowing more concurrent sequences. Agent prompts (schema + question + result) stay under 3 K tokens. |
| `--gpu-memory-utilization` | `0.92` | Leaves 8% headroom to avoid OOM on KV-cache peaks. |
| `--max-num-seqs` | `128` | Raised from 64; allows vLLM to batch 100+ concurrent agent LLM calls during load spikes. |
| `--enable-prefix-caching` | — | Automatic Prefix Caching (APC) for repeated system-prompt + schema prefixes. Reached 94% hit rate under load, cutting effective prefill tokens by ~16×. |

Qwen3 thinking mode (`enable_thinking`) was explicitly disabled in every agent LLM call via `extra_body={"chat_template_kwargs": {"enable_thinking": False}}`. Thinking tokens added ~600 tokens per call and caused 500 errors when context exceeded `max_model_len`.

---

## Phase 5 – Baseline Eval

Eval set: 30 questions from `evals/eval_set.jsonl` (BIRD-bench subset, 11 SQLite databases).  
Metric: execution accuracy – canonicalized row-set comparison.

| Metric | Value |
|---|---|
| Questions | 30 |
| Correct (final answer) | 10 |
| Overall pass rate | **33.3%** |
| Pass rate iter 0 (generate only) | 30.0% |
| Pass rate iter 1 (after 1st revise) | 33.3% |
| Pass rate iter 2 (after 2nd revise) | 33.3% |

The verify→revise loop recovered 1 question (iter 0 → iter 1) and then plateaued. The loop earns its keep for SQL-error and zero-row cases, where the verifier's issue message gives the reviser enough signal to fix the query.

---

## Phase 6 – SLO Iteration Log

**Target SLO:** P95 end-to-end agent latency < 5 s at 10+ RPS over a 5-minute window.

### Iteration 0 – Baseline (before Phase 6)

Config: sync FastAPI endpoint (`def answer`), `graph.invoke()`, shared Langfuse handler singleton, no Qwen3 thinking mode.

Result (2-minute test, 10 RPS):
- achieved_rps: 8.33, ok: 1599, timeouts: 427, http_errors: 415, client_errors: 559
- latency_p50: **90.67 s**, latency_p95: **115.33 s**

Diagnosis: uvicorn runs sync endpoints in a thread pool (default 20 threads). At 10 RPS × ~2 s per agent = 20 concurrent agents, the pool saturates. Requests pile up in the OS accept queue.

### Iteration 1 – Async endpoint

**Saw:** Thread-pool exhaustion (P50 = 90 s, 1000+ errors).  
**Hypothesized:** Sync `def answer` + `graph.invoke()` blocks a thread per request; switching to `async def` + `await graph.ainvoke()` with async LLM calls eliminates the thread-per-request cost.  
**Changed:** All three LLM nodes converted to `async def` using `await llm().ainvoke()`; server endpoint changed to `async def answer` + `await graph.ainvoke()`.

Incidentally discovered and fixed two bugs:
- **Shared Langfuse handler:** `CallbackHandler` must be instantiated per request, not shared – concurrent requests mixed traces and caused 500 errors.
- **NULL FK in schema:** `european_football_2.Match` has foreign keys with `fk[4] == None` (implicit PK target). Fixed `render_schema` to skip incomplete FK rows.

Result (30 s at 5 RPS, post-fix):
- ok: 129/150, http_errors: 0
- latency_p50: **1.40 s**, latency_p95: **4.76 s** ✓ (5 RPS only)

Result (2-minute test, 10 RPS):
- achieved_rps: 6.67, ok: 1192, timeouts: 4, client_errors: 4
- latency_p50: **25.35 s**, latency_p95: **74.10 s**

Diagnosis: Grafana shows vLLM `num_requests_waiting` spiking to 168. At 10 RPS × 2–3 LLM calls = 20–30 concurrent LLM requests, vLLM is compute-bound. Queue time dominates latency.

### Iteration 2 – vLLM tuning (APC + larger batch + shorter context)

**Saw:** `num_requests_waiting` = 168, Waiting queue growing throughout the test.  
**Hypothesized:** Schema prompts repeat across requests (11 DBs, many questions per DB). Enabling Automatic Prefix Caching (APC) should eliminate repeated KV computation. Reducing `max_model_len` 8192 → 4096 doubles effective KV-cache capacity per GPU memory budget. Raising `max_num_seqs` 64 → 128 allows larger decode batches.  
**Changed:** Added `--enable-prefix-caching`, `--max-model-len 4096`, `--max-num-seqs 128`. Also added `max_tokens=512` to agent LLM calls to cap runaway generation.

Result (2-minute test, 10 RPS):
- achieved_rps: 8.43, ok: 1180, http_errors: 0
- latency_p50: **16.00 s**, latency_p95: **52.31 s**
- Prefix cache hit rate: **88.7%** (from vLLM logs)

Diagnosis: APC is working (88–94% hit rate), but `Running: 124, Waiting: 168` still appears in bursts. The model generates correct-looking SQL only ~33% of the time; the other 67% trigger the LLM verify call (0-row or error path) and at least one revise. Average LLM calls per agent ≈ 2.5, giving ~25 calls/s at 10 RPS – still above vLLM's sustainable throughput.

### Iteration 3 – Fast-path heuristic verify

**Saw:** LLM verify being called on nearly every request; generating/verifying 2–3 LLM calls per agent at 10 RPS = ~25 calls/s overloads vLLM.  
**Hypothesized:** Many verify calls are "easy" cases. If execution succeeded and returned > 0 rows, it is very likely correct. Skipping the LLM verify call for that case cuts average LLM calls from ~2.5 to ~1.3 per agent (10 RPS × 1.3 = 13 calls/s, within vLLM capacity).  
**Changed:** `verify_node` fast-path: if `execution.ok and row_count > 0`, immediately return `verify_ok=True` without an LLM call.

Result (5-minute test, 10 RPS):
- achieved_rps: 8.85, ok: 2940/3000, http_errors: 0, client_errors: 58 (connection resets)
- latency_p50: **6.69 s**, latency_p95: **35.74 s**
- Prefix cache hit rate: 93–95%

Diagnosis: Still overloaded. vLLM queue oscillates: mostly `Waiting: 0`, but spikes to `Waiting: 55–168` every 1–2 minutes. These spikes correspond to moments when 100+ agents simultaneously submit their revise LLM call. The connection-reset errors occur when the OS TCP backlog fills during spikes. 

Root cause: the model's per-query accuracy is ~33%; 67% of first-attempt SQLs fail (return 0 rows or error), so the fast-path only skips the LLM verify for ~33% of calls. The remaining 67% still trigger LLM verify + revise = 2 extra LLM calls. Effective average remains ~2 calls/agent, and burst synchronization (all agents whose generate call completed at roughly the same time submit verify simultaneously) creates queue spikes.

### SLO Verdict

**SLO missed.** Best achieved: **P95 = 35.7 s at 8.85 RPS** (achieved_rps) vs. target P95 < 5 s at 10+ RPS. Gap: ~7×.

The fundamental bottleneck is model accuracy × agent call depth:
- Model accuracy ~33% → 67% of requests need 2–3 LLM calls.
- 10 RPS × 2 avg LLM calls = 20 calls/s; vLLM sustains ~15–18 LLM calls/s at P95 < 2 s per call.
- Burst synchronization amplifies queue depth, causing P95 spikes.

What would close the gap with fixed hardware/model:
1. **Remove the revise loop** (1 LLM call per agent): would bring ~10 calls/s, P95 < 3 s likely achievable.
2. **FP8 quantization** (`--quantization fp8`): ~2× decode throughput on H100 with minimal accuracy loss.
3. **Speculative decoding** with a small draft model: reduces decode latency for short SQL outputs.
4. **Request admission control / rate limiting** at the agent server to avoid burst synchronization.

---

## Phase 6 – Final Eval (after tuning)

Config: async endpoint, fast-path heuristic verify, APC, max_model_len=4096, max_tokens=512.

| Metric | Baseline | After tuning |
|---|---|---|
| Overall pass rate | 33.3% | **33.3%** |
| Pass rate iter 0 | 30.0% | 30.0% |
| Pass rate iter 1 | 33.3% | 33.3% |
| Pass rate iter 2 | 33.3% | 33.3% |

Accuracy is unchanged. The fast-path heuristic (accept if rows > 0) does not affect correctness on the eval set because the cases where verify previously returned "ok" are the same ones where the heuristic also returns "ok". The eval set does not contain examples where wrong SQL returns a non-empty (but wrong) result set that would have been caught by the LLM verifier.

---

## Phase 7 – Reflection

**What worked:**
- Async endpoint eliminated the thread-pool bottleneck (P50: 90 s → 1.4 s at 5 RPS).
- APC + reduced `max_model_len` reduced effective prefill cost by ~16× and allowed the H100 to sustain 8.85 RPS.
- Fixing the NULL FK schema bug eliminated a 14% error rate that was masking real throughput.

**What did not close the gap:**
- The core constraint is model accuracy × call depth. With ~33% first-try accuracy, every 10 RPS of agent traffic generates ~20 LLM calls/s, slightly above the GPU's sustainable throughput at the target latency.
- Burst synchronization makes queue depth oscillate, producing P95 spikes even when the average queue is manageable.

**Given more time:**
- Try `--quantization fp8` (Qwen3 is supported, expected ~2× decode speedup).
- Reduce MAX_ITERATIONS to 1 and measure the accuracy/latency tradeoff explicitly.
- Add per-request jitter / admission control to desynchronize burst waves.
- Profile whether the revise prompt (which carries the full schema + SQL + result) has a high cache miss rate and could be restructured to reuse a longer cached prefix.

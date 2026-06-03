# AI 推理 & MLOps 生态周报 2026-06-03

窗口:2026-05-27 → 2026-06-03(7 天)。与 [2026-05-29 digest](./2026-05-29-ai-infra-ecosystem.md) 前 2 天重叠,本期主轴是 **vLLM v0.22.0 / MLflow v3.13.0 / TRT-LLM v1.3.0rc17 / Ollama v0.30.2** 四个新 release,以及 SGLang / KServe / Ray / Hub 的产品级增量。

## 摘要(5 条以内)

- **vLLM v0.22.0 发布(2026-05-29)**([release notes](https://github.com/vllm-project/vllm/releases/tag/v0.22.0)):459 commit / 230 contributors 的大版本。**MRv2 进入 Qwen3 dense 默认路径**([#39337](https://github.com/vllm-project/vllm/pull/39337))、本周后续 [#43458](https://github.com/vllm-project/vllm/pull/43458) 把 MRv2 默认开关再延到 **Llama / Mistral dense**;**Batch invariance + Cutlass FP8 端到端延迟 -28.9%**([#40408](https://github.com/vllm-project/vllm/pull/40408));**多 tier KV offload 框架** GA([#40020](https://github.com/vllm-project/vllm/pull/40020) + Python fs 二级 tier #41735 + DSv4 #43142 + Mooncake 磁盘 #42689);**Rust 前端整树移入**([#43283](https://github.com/vllm-project/vllm/pull/43283))+ DP supervisor。**DSv4 一系列硬化是这一档的最大产品级看点**——MegaMoE / NVFP4 / MTP / sparse MLA / CUDA graph 全部收口。Ray Serve 在 2026-06-02 跟手升级到 vLLM 0.22.0([ray#63730](https://github.com/ray-project/ray/pull/63730))
- **MLflow v3.13.0 发布(2026-06-01)**([release notes](https://github.com/mlflow/mlflow/releases/tag/v3.13.0)):**RBAC + Admin UI**(自托管多用户多 workspace 一等公民,旧 per-resource permission API 全部 break);**Trace Retention & Auto Archival**(老 trace 自动归档到 S3,UI/API 仍可读)+ WAL 归档管道([#23641 MlflowWalSpanExporter](https://github.com/mlflow/mlflow/pull/23641));**官方 Helm Chart 上线**(MLflow tracking server 正式产品化 K8s 部署);**Coding-agent 一键观测**(Claude Code / Codex / Gemini CLI / Hermes 走 AI Gateway,带 budget + guardrail);本地 file-store 默认 fail-fast(`MLFLOW_ALLOW_FILE_STORE=true` 显式开关)。**这是 MLflow 第一次把"自托管多租户治理"做齐——OAI fork 若用 MLflow 做 model lifecycle,RBAC 模型必须 1:1 跟版本**
- **TRT-LLM v1.3.0rc17(2026-06-02)**([release notes](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc17))主线推进:**KV cache prefetch**([#14748](https://github.com/NVIDIA/TensorRT-LLM/pull/14748))+ **每 iteration log KV cache utilization 与 context tokens**([#14206](https://github.com/NVIDIA/TensorRT-LLM/pull/14206))+ **disagg TTFT 改善**([#14719](https://github.com/NVIDIA/TensorRT-LLM/pull/14719))+ **thinking token budget 控制**([#14665](https://github.com/NVIDIA/TensorRT-LLM/pull/14665))+ **DWDP 从 CUDA IPC 改 CUDA VMM + MNNVL composite VA**([#14453](https://github.com/NVIDIA/TensorRT-LLM/pull/14453))+ **NIXL→v1.0.1 / UCX→1.21**([#14436](https://github.com/NVIDIA/TensorRT-LLM/pull/14436))+ **Cutlass MoE 后端 per-expert LoRA**([#14801](https://github.com/NVIDIA/TensorRT-LLM/pull/14801))+ **MoT World Model 支持**([#14012](https://github.com/NVIDIA/TensorRT-LLM/pull/14012))。**rc17 的主旋律是"disagg 工业化+多模态生成型新负载",每 iter KV util 日志接 Prometheus 直接补一条 MaaS 容量曲线**
- **KServe v0.19.0 RC 阶段新增 4 个产品级 PR**:[#5470 多 OCI sources](https://github.com/kserve/kserve/pull/5470)(storageUris 支持多个 OCI artifact,模型 + adapter 分仓拉取)、[#5567 transformer→predictor 转发 Authorization 头](https://github.com/kserve/kserve/pull/5567)(打通多层链路鉴权)、[#5573 inferenceservice-config 缓存 + watch](https://github.com/kserve/kserve/pull/5573)(controller 不再每次 reconcile 重读 ConfigMap)、[#5541 ClusterStorageContainer 合并防 Value/ValueFrom 冲突](https://github.com/kserve/kserve/pull/5541)。**与上期 #5579 / #5586 / #5496 一起组成 v0.19.0 GA 前的"路由 + 状态契约 + drain + 鉴权 + storage"完整答卷**
- **SGLang 把 P/D + HiCache 双面打磨,把 mooncake / NIXL 接到生产可用度**:**[#26780 PD 乐观 prefill](https://github.com/sgl-project/sglang/pull/26780)**(prefill 提前推测发往 decode,降 TTFT)+ **[#26227 HiCache prefetching + PD 增量传输 decode 侧](https://github.com/sgl-project/sglang/pull/26227)**(decode 侧主动预取,跨 P/D KV 增量传输)+ **[#24984 HiCache mooncake draft offload](https://github.com/sgl-project/sglang/pull/24984)**(投机草稿写入 mooncake 而非本地 KV,跨节点共享)+ **[#27011 NIXL sender 失败状态清理](https://github.com/sgl-project/sglang/pull/27011)** + **[#26937 per-rank 错峰权重加载](https://github.com/sgl-project/sglang/pull/26937)**(TP 启动 I/O 不再尖峰)+ **[#26970 embed_tokens 复制掉 post-embed all-reduce](https://github.com/sgl-project/sglang/pull/26970)**。**对比 vLLM Mooncake / EC connector / KV offload,SGLang 这周把 PD + HiCache 的产品化进度推到与 vLLM 同档,KServe llmisvc 调度器接 SGLang 的入口更完整**

## 推理引擎动态

### vLLM
- **release:[v0.22.0(2026-05-29)](https://github.com/vllm-project/vllm/releases/tag/v0.22.0)** — 459 commit / 230 contributors,与 2026-05-29 digest 的"未来 1-2 天会 cut release"判断对齐。要点(release notes 节选):
  - **DSv4 maturity**:模型 reorg 到 `vllm/models/deepseek_v4/`([#43004 / #43039 / #43073 / #43077 / #43149](https://github.com/vllm-project/vllm))、NVFP4 fused MoE([#42209](https://github.com/vllm-project/vllm/pull/42209))、CUDA graph 完整/分段([#42604](https://github.com/vllm-project/vllm/pull/42604))、MTP speculative([#43385](https://github.com/vllm-project/vllm/pull/43385))、sparse MLA + compressor refactor + accuracy fix。**DSv4 的"实验→生产"切换在 0.22 完成**
  - **MRv2 默认路径扩展**:[#39337 Qwen3 dense 默认走 MRv2](https://github.com/vllm-project/vllm/pull/39337) + [sleep-mode reload #42673](https://github.com/vllm-project/vllm/pull/42673) + [update_config #42783](https://github.com/vllm-project/vllm/pull/42783) + [shared KV-cache layers #35045](https://github.com/vllm-project/vllm/pull/35045) + [遇到不支持特性自动 fallback MRv1 #42955](https://github.com/vllm-project/vllm/pull/42955)
  - **Batch invariance**:[#40408 Cutlass FP8 +28.9%](https://github.com/vllm-project/vllm/pull/40408)、[#42456 SM80 compile mode](https://github.com/vllm-project/vllm/pull/42456)、[#39912 NVFP4 Cutlass linear](https://github.com/vllm-project/vllm/pull/39912)
  - **多 tier KV offload 框架**:[#40020 框架](https://github.com/vllm-project/vllm/pull/40020) + [#41735 fs 二级 tier](https://github.com/vllm-project/vllm/pull/41735) + [#43142 DSv4](https://github.com/vllm-project/vllm/pull/43142) + [#42689 Mooncake 磁盘 offload](https://github.com/vllm-project/vllm/pull/42689)
  - **Rust 前端整树移入**:[#40848 集成](https://github.com/vllm-project/vllm/pull/40848)、[#43283 移入 vllm/](https://github.com/vllm-project/vllm/pull/43283)、[#40841 DP supervisor](https://github.com/vllm-project/vllm/pull/40841)
- 2026-05-29 release 后约 5 天的新合入(过滤 noise 后 94 条),挑核心:
  - **MRv2 进一步默认化**:[#43458 Llama/Mistral dense 也走 MRv2](https://github.com/vllm-project/vllm/pull/43458)、[#42187 避免 PP bubble](https://github.com/vllm-project/vllm/pull/42187)、[#44338 cudagraph_utils 清理 graph_pool 赋值](https://github.com/vllm-project/vllm/pull/44338)。**MRv2 默认开关在 0.22 后两天又扩两个家族,GA 临界点很近**
  - **KV offload 生命周期补全**:[#44206 `on_schedule_end()` hook 分离 step 生命周期与 event drain](https://github.com/vllm-project/vllm/pull/44206)、[#41627 EC Connector 非阻塞 lookup](https://github.com/vllm-project/vllm/pull/41627)、[#43332 W4A16 FlashInferB12xExperts 兼容性](https://github.com/vllm-project/vllm/pull/43332)
  - **Anthropic API 兼容继续**:[#44283 system role 消息可放在 messages 数组内](https://github.com/vllm-project/vllm/pull/44283)。**配合上期 [#42396 Anthropic structured outputs + effort](https://github.com/vllm-project/vllm/pull/42396),Anthropic API 表面在 vLLM 端继续完整化,与 ogx 同周的 [#6005 Messages 接受 system role](https://github.com/ogx-ai/ogx/pull/6005) 是同一波**
  - **Rust 前端继续补尾**:[#44320 thinking 模式 roundtrip](https://github.com/vllm-project/vllm/pull/44320)、[#44299 tool 参数递归](https://github.com/vllm-project/vllm/pull/44299)、[#43883 `--enable-request-id-headers`](https://github.com/vllm-project/vllm/pull/43883)
  - **核心**:[#44274 `max_concurrent_batches` 移入 VllmConfig](https://github.com/vllm-project/vllm/pull/44274)、[#44165 `scheduler_block_size` 入 KVCacheManager/Coordinator](https://github.com/vllm-project/vllm/pull/44165)、[#42977 ResponsesParser 接 unified Parser](https://github.com/vllm-project/vllm/pull/42977)
  - **模型 / kernel**:[#42191 Triton Top-p 单 pass](https://github.com/vllm-project/vllm/pull/42191)、[#43978 GDN 多模态 linear_key_head_dim 修复](https://github.com/vllm-project/vllm/pull/43978)、[#44065 sync FlashAttention 上游](https://github.com/vllm-project/vllm/pull/44065)
- 启示:
  - **v0.22.0 是 "MRv2 默认化 + Rust frontend + 多 tier KV + DSv4 工业化" 四线收口的版本。OAI MaaS 升级 vLLM 时,MRv2 默认范围需要在测试矩阵里覆盖到 Qwen3/Llama/Mistral dense**(`VLLM_USE_MODEL_RUNNER_V1=1` 是逃生口)
  - **multi-tier KV offload + Mooncake 磁盘**意味着"主机 RAM 不再是 KV 上限",MaaS 多模型场景可以把冷 KV 落盘,只要 SLA 容忍 fault recovery 时延
  - Rust 前端临界点更近;**当 0.23 / 0.24 把 Rust 设为默认时,我们 fork 的 Python middleware 链路要提前评估**

### SGLang
- 本窗口无新 release(0.5.12.post1 仍是上一档),近 7 天约 100 条新合入,核心:
  - **P/D 工业化**:
    - **[#26780 PD Optimistic prefill](https://github.com/sgl-project/sglang/pull/26780)** — prefill 节点不等 decode 节点确认,提前 forward 给 decode,**直接降 TTFT**
    - **[#26227 PD HiCache prefetching + decode 侧 PD 增量传输](https://github.com/sgl-project/sglang/pull/26227)** — decode 侧主动从 HiCache prefetch,并支持跨 P/D 节点 KV 增量,**P/D 分离架构在大上下文场景下吞吐边界进一步上移**
    - [#27028 PP disagg 中 aborted prefill bootstrap 请求孤儿修复](https://github.com/sgl-project/sglang/pull/27028)
    - **[#24984 HiCache mooncake draft offload](https://github.com/sgl-project/sglang/pull/24984)** — 投机草稿写 mooncake 而非本地,**spec decoding 在多副本间能共享**
    - [#26406 NIXL 改 prep+make API 提性能](https://github.com/sgl-project/sglang/pull/26406)、[#27011 NIXL sender 清理失败状态](https://github.com/sgl-project/sglang/pull/27011)
  - **多节点启动 / I/O**:
    - **[#26937 per-rank 错峰权重加载](https://github.com/sgl-project/sglang/pull/26937)** — 大 TP 启动时 I/O 不再尖峰,**冷启动时间显著降低**
  - **kernel / 通信路径**:
    - **[#26970 replicate embed_tokens 去掉 post-embed all-reduce](https://github.com/sgl-project/sglang/pull/26970)** — 关键路径上少一次集合通信,**dense 模型 TP 场景 throughput 直接受益**
    - [#26643 FlashInfer DP dispatcher workspace + set_dp_buffer_len 修](https://github.com/sgl-project/sglang/pull/26643)
    - [#26502 Gemma4 single-launch fused router(topk + softmax + scale)](https://github.com/sgl-project/sglang/pull/26502)
    - [#26623 hybrid 线性注意力的 plain RadixAttention 误路由修复(Ring-2.5-1T)](https://github.com/sgl-project/sglang/pull/26623)
  - **API / 推理控制**:
    - **[#27019 generate API 加 `require_reasoning` 字段](https://github.com/sgl-project/sglang/pull/27019)** — 显式要求 reasoning trace 输出,**对接 thinking 模型(Qwen3.5/DSv4)产品化**
    - [#26943 unified radix cache 类型注解优化](https://github.com/sgl-project/sglang/pull/26948)
  - **模型支持 / kernel**:[#26106 Command A plus](https://github.com/sgl-project/sglang/pull/26106)、[#27101 Gemma4 MTP 31B 用 hard GSM8K accuracy floor](https://github.com/sgl-project/sglang/pull/27101)、[#26145 CPU 显式开 AVX512+AMX](https://github.com/sgl-project/sglang/pull/26145)、[#25093 ROCm AITER 自定义 all-gather](https://github.com/sgl-project/sglang/pull/25093)、[#26209 DSv4 FP4 Indexer](https://github.com/sgl-project/sglang/pull/26209)、[#24870 DSv32 支持 NextN=2/4](https://github.com/sgl-project/sglang/pull/24870)
- 启示:
  - **SGLang PD 三件套(Optimistic prefill + HiCache prefetching + draft offload)是这周的产品级跃迁,与 vLLM 0.22 的 multi-tier KV + Mooncake 磁盘形成 PD 路线的两套"近上限"实现**。OAI 在评估 P/D 拓扑时,SGLang 已经从"可用"走到"可调"档
  - 启动 I/O 错峰(#26937)+ embed_tokens 复制(#26970)是 dense 模型大 TP 场景的两条立刻可享受改进——**大模型 startup time 与稳态吞吐双面受益**
  - `require_reasoning` API 字段对应"显式控制 thinking trace"产品形态,**MaaS API 层需要把这个字段透出到上层 OpenAPI**

### TensorRT-LLM
- **release:[v1.3.0rc17(2026-06-02)](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc17)** — 上一档 rc16(2026-05-26)后两天的新 rc,继续推 disagg + 多模态生成 + API 表面。重点:
  - **disagg 工业化**:
    - **[#14719 Improve disaggregated TTFT](https://github.com/NVIDIA/TensorRT-LLM/pull/14719)** — disagg TTFT 改善
    - **[#14475 Replace fixed disagg fill throttle with slow-start ramp](https://github.com/NVIDIA/TensorRT-LLM/pull/14475)** — 把固定 throttle 改成 slow-start,**减弱 P/D 切换瞬时尖峰**
    - **[#14453 DWDP 从 CUDA IPC 改 CUDA VMM + MNNVL composite VA](https://github.com/NVIDIA/TensorRT-LLM/pull/14453)** — disagg 跨 worker KV 传递路径重写,**性能与稳定性双面**
    - **[#14436 NIXL → v1.0.1,UCX → 1.21](https://github.com/NVIDIA/TensorRT-LLM/pull/14436)** — KV 传输栈升一档
    - [#14020 PyExecutor Hang in Disagg TP Prefill fix](https://github.com/NVIDIA/TensorRT-LLM/pull/14020)
  - **API 表面收敛**:
    - **[#14665 Thinking token budget control](https://github.com/NVIDIA/TensorRT-LLM/pull/14665)** — 显式限定 reasoning trace token 数,**与 SGLang `require_reasoning` / ogx extended thinking 同周对齐 thinking-model 治理**
    - **[#14206 Log KV cache utilization + context tokens per iteration](https://github.com/NVIDIA/TensorRT-LLM/pull/14206)** — 每 iter 日志带 KV util,**接 Prometheus 直接补 KV pressure 指标**(承接 rc16 #14127 host/GPU per-iter time)
    - [#14368 `content: null` 在 ChatCompletion 允许](https://github.com/NVIDIA/TensorRT-LLM/pull/14368)、[#13527 强制 `trust_remote_code` flag](https://github.com/NVIDIA/TensorRT-LLM/pull/13527)
  - **新能力 / 模型**:
    - **[#14748 Add KV cache prefetch](https://github.com/NVIDIA/TensorRT-LLM/pull/14748)** — **TRT-LLM 第一次有 KV prefetch 机制**,对 prefix-cache 命中率敏感的工作负载是大改进
    - **[#14801 Per-expert LoRA support with Cutlass backend](https://github.com/NVIDIA/TensorRT-LLM/pull/14801)** — MoE 模型按 expert 装 LoRA,**对"MoE 上 multi-tenant 微调"是产品级口子**
    - [#14079 LoRA support to LLMAPI Triton backend](https://github.com/NVIDIA/TensorRT-LLM/pull/14079)、[#14550 MoE A2A kernel 去掉 one-warp-per-token](https://github.com/NVIDIA/TensorRT-LLM/pull/14550)
    - [#14638 Poolside Laguna tool parser](https://github.com/NVIDIA/TensorRT-LLM/pull/14638)、[#14659 Qwen3.5 reasoning parser](https://github.com/NVIDIA/TensorRT-LLM/pull/14659)、[#13449 Qwen image 支持](https://github.com/NVIDIA/TensorRT-LLM/pull/13449)、[#14012 MoT World Model](https://github.com/NVIDIA/TensorRT-LLM/pull/14012)
  - **kernel / perf**:[#14472 NCCL symmetric zero-copy 默认](https://github.com/NVIDIA/TensorRT-LLM/pull/14472)、[#13773 FlashInfer NVFP4 MoE SM120/121(Nemotron)](https://github.com/NVIDIA/TensorRT-LLM/pull/13773)、[#13644 FlashInfer GDN prefill kernel for Qwen3.5](https://github.com/NVIDIA/TensorRT-LLM/pull/13644)、[#12544 NVFP4 KV cache 在 trtllm-gen attention](https://github.com/NVIDIA/TensorRT-LLM/pull/12544)
  - **已知问题**:DSv3.2 长时间性能测试下 illegal memory access(release notes 显式标记)
- 启示:
  - rc17 的 **disagg TTFT + DWDP 重写 + NIXL/UCX 升级 + KV prefetch** 四件套是 TRT-LLM 这季度产品级最大跃迁——**与 SGLang PD Optimistic prefill / vLLM multi-tier KV 同周推进 disagg 路线,三家在"disagg = 一等公民"上达成共识**
  - 每 iter KV utilization 日志 + 上期 host/GPU per-iter time,**Prometheus 抓取后我们 MaaS 可以画出 KV 压力 vs host/GPU 时延的二维曲线**
  - Per-expert LoRA(#14801)对 MoE 多租户微调是新一类能力——**对标我们 MaaS 在 MoE 模型上做 adapter 隔离的方案,需要评估这条路径**

### Ollama / TGI
- **Ollama v0.30.2(2026-06-03)** — 23 commit,主线 launch 工具链 + llama-server 监控:
  - **[laguna (poolside) arch via llama.cpp 补丁](https://github.com/ollama/ollama/pull/16396)** — Poolside Laguna 模型支持(与 TRT-LLM Laguna tool parser 同周),**开源模型生态新成员**
  - **[Cline CLI 自动安装](https://github.com/ollama/ollama/pull/16402)** + [Qwen code integration](https://github.com/ollama/ollama/pull/15900) + [Codex launch 隔离](https://github.com/ollama/ollama/pull/16437) + [opencode 本地模型限额](https://github.com/ollama/ollama/pull/16425) — **Ollama 在做"本地 coding agent 启动器"**
  - **[llama-server load stall 检测](https://github.com/ollama/ollama/pull/16427)** + [缓存 prompt token 计数](https://github.com/ollama/ollama/pull/16428)
- **TGI:0 commit / 0 release** — 与上期一致,**月度跟踪即可**

## 模型服务 & 编排

### KServe(上游)
- v0.19.0-rc0(2026-05-28)已在 [2026-05-29 digest](./2026-05-29-ai-infra-ecosystem.md) 详述。本期 v0.19.0 RC 阶段新增 4 个产品级 PR(release 后到 06-03 期间):
  - **[#5470 支持 storageUris 多 OCI sources](https://github.com/kserve/kserve/pull/5470)** — storage URI 列表内允许多个 OCI artifact,**模型 + adapter 分仓拉取在 LLMISvc / ISVC 都打通**
  - **[#5567 forward Authorization 头 transformer → predictor](https://github.com/kserve/kserve/pull/5567)** — 多层链路鉴权透传,**MaaS 多 tenant 场景下 transformer 层鉴权可以原样传给 predictor**
  - **[#5573 InferenceService config 缓存 + watch](https://github.com/kserve/kserve/pull/5573)** — controller 不再每次 reconcile 都重读 inferenceservice-config ConfigMap,改 watch,**多 ISVC 场景 reconcile 压力显著降**
  - **[#5541 防 Value/ValueFrom 冲突 in ClusterStorageContainer merge](https://github.com/kserve/kserve/pull/5541)** — 之前 spec merge 路径会同时设 Value 与 ValueFrom 导致 pod 启动失败
  - 配套清理:[#5584 enqueue handlers 不分页](https://github.com/kserve/kserve/pull/5584)、[#5610 extendControllerSetup 把 reconciler 显式传入](https://github.com/kserve/kserve/pull/5610)、[#5548 loadConfig test helper 去重 yaml.Unmarshal](https://github.com/kserve/kserve/pull/5548)
- 启示:**v0.19.0 GA 前的"产品化补丁"完整覆盖了多 OCI 拉取、鉴权透传、配置 watch、storage container 合并**。OAI fork 跟版本时,这 4 个一定要 cherry-pick,**否则 v0.19.0 GA 后会持续踩这些坑**

### Ray
- 本窗口无新 release,~80 commit,核心:
  - **[#63730 Upgrade to vLLM 0.22.0](https://github.com/ray-project/ray/pull/63730)** — Ray Serve / Ray LLM 跟手升,**Ray 的 vLLM 兼容版本与 0.22 同步,这是 Ray Serve LLM 用户立刻能用上 MRv2 + 多 tier KV 的入口**
  - **[#63803 Co-locate DP rank 0 worker with advertised master address](https://github.com/ray-project/ray/pull/63803)** — 多节点 DP Serve 部署 fix:之前 `DPServer` 把 rank 0 的 node 地址作为 vLLM master,但 placement-group bundle 按 head node 排,**head 节点常常没 GPU,导致 rank 0 worker 被钉在另一节点,torch dist store 地址错位**——长时间存在的多节点 DP serve 启动问题
  - **[#63779 LLM Serve 加 direct streaming 遥测](https://github.com/ray-project/ray/pull/63779)** — `RAY_SERVE_LLM_ENABLE_DIRECT_STREAMING` 启用统计,**Ray 在为 LLM 直接流式落地做 A/B 跟踪**
  - **[#63586 Data 跟踪 streaming 调度循环 step duration 的 p50/p90](https://github.com/ray-project/ray/pull/63586)** — Ray Data 自己也开始把调度 step 时延作为一等指标
  - **[#63620 HAProxy 老 worker 退出后再标记 proxy drained](https://github.com/ray-project/ray/pull/63620)** — Ray Serve proxy drain 路径稳定性
  - [#63685 cgroup limit 下 fetch CPU](https://github.com/ray-project/ray/pull/63685)、[#63764 GCS restart 后 replica actor 僵尸进程](https://github.com/ray-project/ray/pull/63764)、[#63743 HandleKillLocalActor 加日志诊断孤儿 replica](https://github.com/ray-project/ray/pull/63743)、[#63720 同 inode 截断文件日志监控修复](https://github.com/ray-project/ray/pull/63720)
- 启示:**Ray 0.22 跟版本极快(release 后 3 天)+ DP master 修复是这周对 LLM 用户的两件大事**——MaaS 如果走 Ray Serve LLM,这两个 PR 直接决定多节点 DP 模型部署是否可靠

### KubeAI(原 lingo)
- 0 commit / 0 release(连续四期为 0)— **维持半年跟踪**

## 训练 & 微调

### LlamaFactory(已迁移至 `hiyouga/LlamaFactory`)
- **release:[v0.9.5(2026-06-01)](https://github.com/hiyouga/LlamaFactory/releases)** —
  - **[#10370 支持 HyperParallel PT training 与 activation 优化](https://github.com/hiyouga/LlamaFactory/pull/10370)** — 大模型预训练阶段的并行策略新增,**对国内 PT 场景有直接收益**(社区活跃度高)
  - [#10512 NPU FusedMoE 与 RMSNorm fix](https://github.com/hiyouga/LlamaFactory/pull/10512) — 国产 NPU 路径修复
  - [#10529 Qwen3.5 + FlashAttention 非 packing 多 bsz fix](https://github.com/hiyouga/LlamaFactory/pull/10529)
- 启示:**LlamaFactory v0.9.5 是这周国内训练栈的代表性版本**——HyperParallel PT 训练 + NPU 修复指向"国产 PT + 微调 + 国产卡"链路,**MaaS 训练侧若覆盖国内场景值得关注**

### Kubeflow Trainer
- 4 commit,主要 CI/example 修补([#3556 cncf runner 名迁移](https://github.com/kubeflow/trainer/pull/3556)、[#3539 multi-replica endpoint 生成](https://github.com/kubeflow/trainer/pull/3539)、[#3359 copyright boilerplate 检查](https://github.com/kubeflow/trainer/pull/3359)),无能力面新增

## 模型生命周期(MLflow / Hub / Feast)

### MLflow
- **release:[v3.13.0(2026-06-01)](https://github.com/mlflow/mlflow/releases/tag/v3.13.0)** — 上期(2026-05-29)是 v3.13.0rc0,本期 GA。Major 新功能(release notes 提炼):
  - **RBAC + Admin UI**:可复用 roles + workspace-scoped grants + 一套全新管理 UI。**Breaking**:旧 per-resource 权限表 / REST / client 方法全部移除,需迁移到 `role_permissions` 模型;`default_permission` 退化为 floor 不再 override;workspace 的 `USE` 权限就足以创建 experiment 与 registered model
  - **Trace Retention & Auto Archival**:trace span 数据老化后自动从 SQL 后端搬到对象存储(S3 等),UI / API 仍可读;配套 [#23641 MlflowWalSpanExporter → WAL daemon](https://github.com/mlflow/mlflow/pull/23641) 把 trace 写路径解耦
  - **Coding-agent 一键观测 + AI Gateway**:Claude Code / OpenAI Codex / Gemini CLI / Hermes 全部可以一键接 AI Gateway,**自带 tracing、用量、budget、guardrail**。`mlflow autolog claude` 老 hook 被官方 Claude plugin 取代(breaking)
  - **MLflow Assistant 引擎扩展**:本地 Ollama / OpenAI Codex CLI / 任意 MLflow AI Gateway 都可以作为 Assistant 后端
  - **官方 Helm Chart**:第一次有官方 Helm chart 部署 MLflow tracking server,**MLflow 自托管 K8s 形态正式产品化**
  - **Hermes Agent 走 AI Gateway**:Hermes Agent 跑时 trace 走 OTLP 进 MLflow
  - **Span log levels**:Python-logging-风格 severity + UI 过滤低噪声
  - 默认 fail-fast:[#22773 tracking/registry 指向本地文件系统报错](https://github.com/mlflow/mlflow/pull/22773),需显式 `MLFLOW_ALLOW_FILE_STORE=true`(breaking)
  - MLServer 退场:`mlflow models serve` 不再用 MLServer 后端
  - judge.align 默认 optimizer 改 MemAlign(breaking)
- 启示:**v3.13.0 把"自托管多租户治理"做齐——RBAC + Helm + 自动归档 + AI Gateway 治理是同一张图**。OAI fork 用 MLflow 做 model registry 与 lifecycle 时:
  - **必须**做 RBAC 迁移评估(老 per-resource permission API break)
  - **Helm chart** 是 OAI fork 部署模板的参考(自家 Operator 与 chart 协同)
  - **AI Gateway + coding agent observability** 直接对应"上层 IDE / agent 调用 OAI MaaS 的可观测"产品化路径
  - Trace WAL 归档模式 → 我们如果在 MaaS 加 LLM 调用 trace,**S3 归档路径可以照抄**

### Kubeflow Hub(原 model-registry)
- ~11 个 signal commit,产品化继续:
  - **[#2756 catalog UI 加 cold-start latency / vRAM / image size](https://github.com/kubeflow/hub/pull/2756)** — 模型卡新增 3 个一线运维指标,**"按算力 / 启动时延选模型" 用户视角第一次落到 UI**
  - **[#2748 catalog hardware tags](https://github.com/kubeflow/hub/pull/2748)** — 上期已提,本期合入
  - **[#2751 catalog plugin 拆 per-domain + 共享 PluginBase](https://github.com/kubeflow/hub/pull/2751)** — 与 #2735 续集,**plugin 模型逐步成型**
  - **[#2757 validated deployment resource label](https://github.com/kubeflow/hub/pull/2757)** — model 资源新增"经过验证可部署" label,**对应"模型质量门禁"产品化**
  - **[#2761 移除 tool calling 临时 flag](https://github.com/kubeflow/hub/pull/2761)** — tool calling 进入稳定路径
  - [#2760 FindModels 返回正确 HTTP 状态码](https://github.com/kubeflow/hub/pull/2760)、[#2754 Go 1.26 升级](https://github.com/kubeflow/hub/pull/2754)、[#2734 OpenAPI 同步](https://github.com/kubeflow/hub/pull/2634)
- 启示:**Hub 这周把"运维元数据 + 部署门禁 + plugin 模型" 三条同时推进**——OAI 自家 model registry 在做"按 GPU 型号 / 启动时延筛选" 与"deployment validation" 时可以直接参考 Hub 的 schema 与 label 命名

### Feast
- 无 release,~14 signal commit,主要 perf:
  - **[Pre-compute feature service](https://github.com/feast-dev/feast/commit/8011550)** — feature service 预计算
  - **[55c2f18 cache feature view resolution in get_online_features](https://github.com/feast-dev/feast/commit/55c2f18)** + [103809a 在线服务用 batched async Redis](https://github.com/feast-dev/feast/commit/103809a) — 在线 hot path 性能
  - **[8f187dd RemoteOnlineStore 单 HTTP 请求批量发送所有 feature](https://github.com/feast-dev/feast/commit/8f187dd)** — 远端 store 减少 round-trip
  - [9b088fe Add `async_supported` to RedisOnlineStore](https://github.com/feast-dev/feast/commit/9b088fe)、[e914d59 Snowflake 双引号 connection identifier 修复](https://github.com/feast-dev/feast/pull/6462)
- 启示:**Feast 在线 hot path 持续在挤性能,LLM 推理时把 Feature Store 用作上下文检索的场景直接受益**

## LLM 评估 & 安全

- **EleutherAI/lm-evaluation-harness:2 commit**(humaneval 任务名修 + PIQA 更新),**维持月度跟踪**
- **NVIDIA/garak:19 signal commit**,大量是文档 / contribution 流程:
  - [#1810 / 4facc4f scan_payload_dir 跳过无效 payload 不再 crash](https://github.com/NVIDIA/garak/pull/1810)、[#1797 probespec module 只有 inactive plugin 时给清楚错误](https://github.com/NVIDIA/garak/pull/1797)、[#1795 max_tokens 在 generator 不支持时 guard](https://github.com/NVIDIA/garak/pull/1795)。**全部 polish 类,无能力面跃迁**
- **ogx(原 llama-stack):2 个 release(v0.4.6 / v0.7.2)+ ~19 signal commit**,产品化继续推:
  - 上期已覆盖的核心 PR 本期合入并发版:#5938 extended thinking、#5908 cache_control、#5817 web search、#5977 starlette CVE、#5937 sql_postgres 凭据 URL-encode、#5949 vector_stores_config 默认
  - 本期新增 PR:
    - **[#5986 live Claude Code CLI smoke test against /v1/messages](https://github.com/ogx-ai/ogx/pull/5986)** — **实跑 Claude Code CLI 打 Messages API 的端到端 smoke**,**"Claude 作为一等 provider"在 ogx 端用真实 CLI 兜底**
    - **[#6005 accept system-role messages in /v1/messages](https://github.com/ogx-ai/ogx/pull/6005)** — **与 vLLM [#44283](https://github.com/vllm-project/vllm/pull/44283) 同周**:Messages 接受 system role,**Anthropic API 一等公民再补一块**
    - **[#5981 retrieve provider API key for Messages API passthrough](https://github.com/ogx-ai/ogx/pull/5981)** — Messages API passthrough 时按 provider 取 key,**多 provider passthrough 链路打通**
    - **[#5939 prefer AWS-native auth naming](https://github.com/ogx-ai/ogx/pull/5939)** + **[#5955 Bedrock SigV4 client close 屏蔽 shutdown timeout](https://github.com/ogx-ai/ogx/pull/5955)** — Bedrock 链路稳定性
    - **[#5983 CLI `--dry-run` 校验 config 不启动 server](https://github.com/ogx-ai/ogx/pull/5983)** — 部署前校验
    - [#5971 registry 子集 re-registration 时缓存 DB object 保留 owner](https://github.com/ogx-ai/ogx/pull/5971)、[#5984 constraint-dependencies workflow 总是重生成 uv.lock](https://github.com/ogx-ai/ogx/pull/5984)、[#5274 OpenAPI SDK 校验 / 发布 CI](https://github.com/ogx-ai/ogx/pull/5274)、[#6006 docling 加 OCR 选项](https://github.com/ogx-ai/ogx/pull/6006)
- 启示:**ogx 这周完成"Anthropic Messages API 1:1 兼容 + Claude Code 真实 CLI 端到端测试" 闭环**——`live Claude Code CLI smoke` 是一个强信号:**ogx 把自身 Messages API 当作 Claude CLI 后端来回归验证**。我们 MaaS 若要兼容 Anthropic Messages,**直接参考 ogx 的 endpoint 行为**

## 值得跟进

- [ ] **vLLM v0.22.0 升级评估**([release notes](https://github.com/vllm-project/vllm/releases/tag/v0.22.0)):
  - **必读**:#39337 + #43458 MRv2 默认开关扩展(Qwen3/Llama/Mistral dense)、#40020 + #41735 + #43142 + #42689 multi-tier KV offload 与 Mooncake 磁盘、#40408 batch invariance Cutlass FP8、Rust frontend 整树移入
  - **行动**:升级测试矩阵必须覆盖 MRv2 默认范围;评估 multi-tier KV 在 MaaS 多模型场景的部署模板(冷 KV 落盘 vs 主机 RAM);Rust frontend 临界点临近,准备评估 Python middleware 链路兼容性
- [ ] **MLflow v3.13.0 RBAC 迁移评估**([release notes](https://github.com/mlflow/mlflow/releases/tag/v3.13.0)):OAI fork 内若依赖 MLflow per-resource permission API,**必须迁移到 role-based** —— 重点关注 [#23337 / #23379](https://github.com/mlflow/mlflow)。Helm chart 与 trace WAL/S3 归档是部署模板的两条参考
- [ ] **TRT-LLM rc17 disagg 工业化四件套**:#14719 disagg TTFT、#14453 DWDP CUDA VMM+MNNVL、#14436 NIXL/UCX 升级、#14748 KV cache prefetch。**与 SGLang #26780 + #26227、vLLM #43205 同周共同推进 disagg = 一等公民**
- [ ] **TRT-LLM `/metrics` 每 iter KV utilization log(#14206)+ 上期 host/GPU per-iter time(#14127)**:接 Prometheus 即可画"KV 压力 × host/GPU 时延" 二维曲线,直接给 MaaS 容量曲线补维度
- [ ] **TRT-LLM per-expert LoRA(#14801)**:MoE 模型按 expert 装 LoRA,**评估对标我们 MoE adapter 隔离方案**
- [ ] **KServe v0.19.0 RC 阶段 4 个产品化补丁**:#5470 多 OCI sources、#5567 转发 Authorization header、#5573 InferenceService config 缓存 + watch、#5541 ClusterStorageContainer 合并冲突修复。**OAI fork 必须全部 cherry-pick**
- [ ] **SGLang PD 三件套**:#26780 Optimistic prefill、#26227 PD HiCache prefetching + decode 侧增量、#24984 HiCache mooncake draft offload。**评估"P/D 分离 + Mooncake 共享 KV"在 MaaS 多模型场景的落地**
- [ ] **SGLang #26937 per-rank 错峰权重加载 + #26970 embed_tokens 复制**:大 TP dense 模型 cold start + 稳态吞吐双面收益,部署模板可以直接加
- [ ] **SGLang #27019 require_reasoning + TRT-LLM #14665 thinking token budget + ogx extended thinking**:三家同周做 reasoning 模型 API 治理,**MaaS API 层要把 reasoning 控制字段透出到上层 OpenAPI**
- [ ] **Ray #63730 vLLM 0.22.0 + #63803 多节点 DP master 修**:用 Ray Serve LLM 的 MaaS 立刻评估,**长期存在的多节点 DP 启动地址错位**修复
- [ ] **Kubeflow Hub 运维元数据**:#2756 catalog 加 cold-start latency / vRAM / image size、#2748 hardware tags、#2757 validated deployment label。**OAI dashboard 做"按算力 / 时延筛模型 + 部署门禁" 时直接参考 schema**
- [ ] **ogx Messages API 闭环**:#5986 live Claude Code CLI smoke + #6005 system role + #5981 provider API key passthrough。**MaaS 若做 Anthropic Messages 兼容代理,直接参考 ogx endpoint 行为**
- [ ] **Ollama Laguna 模型支持 + Coding agent launcher**(#16396 / #16402 / #15900 / #16437):"本地推理 + 本地 coding agent" 形态在 Ollama 收口,值得作为产品形态参考

## 原始材料

<details>
<summary>本窗口 release(2026-05-27 → 2026-06-03)</summary>

- **vLLM v0.22.0(2026-05-29)— 本期重点**
- **MLflow v3.13.0(2026-06-01)— 本期重点**
- **TensorRT-LLM v1.3.0rc17(2026-06-02)— 本期重点**
- **Ollama v0.30.2(2026-06-03)— 本期重点**
- KServe v0.19.0-rc0(2026-05-28)— 已在 [2026-05-29 digest](./2026-05-29-ai-infra-ecosystem.md) 详述
- LlamaFactory v0.9.5(2026-06-01)
- ogx v0.4.6(2026-05-29)/ v0.7.2(2026-05-28)
- SGLang、TGI、Ray、KubeAI、Trainer、Feast、garak、lm-eval、Hub 本期无新 release
</details>

<details>
<summary>本周(2026-05-27 后)commit 计数,过滤 merge/bump/CI/doc 噪音前</summary>

- vLLM:~100(过滤后 94)
- SGLang:~100(过滤后 91)
- TensorRT-LLM:~100(过滤后 98)
- MLflow:80(过滤后 73)
- Ray:80(过滤后 79)
- meta-llama/llama-stack(ogx):39(过滤后 19)
- Ollama:24(过滤后 23)
- kubeflow/model-registry(Hub):23(过滤后 11)
- garak:22(过滤后 19)
- feast:19(过滤后 14)
- KServe:18(过滤后 14)
- LlamaFactory:6
- kubeflow/trainer:4
- lm-evaluation-harness:2
- 0 commit:TGI、KubeAI(原 lingo)
</details>

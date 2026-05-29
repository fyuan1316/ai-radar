# AI 推理 & MLOps 生态周报 2026-05-29

窗口:2026-05-22 → 2026-05-29(7 天)。前 5 天与 [2026-05-27 digest](./2026-05-27-ai-infra-ecosystem.md) 重叠,本报告以 2026-05-27 之后的新信号为主轴。

## 摘要(5 条以内)

- **KServe v0.19.0-rc0 发布(2026-05-28)**([release notes](https://github.com/kserve/kserve/releases/tag/v0.19.0-rc0)):llmisvc 全线打包,产品级新原语集中落地——header-based **model name routing**([#5521](https://github.com/kserve/kserve/pull/5521),`X-Gateway-Model-Name` 头分流共享网关下多模型,LoRA adapter 自动展开走同后端)+ **model-based routing gates 与 ModelSourcedAddressStatus**([#5579](https://github.com/kserve/kserve/pull/5579),`serving.kserve.io/model-based-routing-enabled` annotation 显式开关,旧 preset 默认不再静默触发;`status.addresses` 暴露 served model name 含 LoRA)+ **vLLM 优雅退出**([#5496](https://github.com/kserve/kserve/pull/5496),preStop `sleep 15` 给 EPP 摘流时间 + vLLM `--shutdown-timeout` 一并写进所有 LLM config 模板)+ 14 个 ConditionType 全部加 godoc([#5586](https://github.com/kserve/kserve/pull/5586),把 status 当 API contract 来文档化)。**这是 v0.18 → v0.19 的功能性 release,模型路由 / 状态契约 / 滚动更新 drain 三件事是 OAI 直接受益项**
- **vLLM 这周补"产品级 KV / RDMA / 多副本启动"基础设施**:KV 二级 tier 加 **per-request offloading policy**([#43205](https://github.com/vllm-project/vllm/pull/43205),新增 `OffloadPolicy` 枚举 + `on_new_request` lifecycle hook,多 tier 任一拒绝就走 REQUEST_LEVEL 路径)+ **per-GPU worker RDMA NIC 选择**([#42083](https://github.com/vllm-project/vllm/pull/42083),`VLLM_GPU_NIC_PCIE_MAPPING` / `VLLM_NIC_SELECTION_VARS` 显式按 PCIe 亲和绑定)+ **#42585 后续修补**:Ray DP 走 actor pickle 路径,driver 的 post-bind rebind 触达不到 actor,这次 #43864 把 Ray 排除在 deferred port 之外、#43768 修硬编码超时。**KV / 网络 / DP 启动三条都是 MaaS 生产部署直接踩的坑**
- **KServe Envoy AI Gateway 升 v0.6.0、Envoy Gateway v1.7.0**([#5520](https://github.com/kserve/kserve/pull/5520),v0.19.0-rc0 同 release 内):llmisvc 的网关栈整体跳一档,**OAI 自己锁的 Gateway/AI Gateway 版本要跟着评估**。同 release 还有 [#5485](https://github.com/kserve/kserve/pull/5485)(preStop + 抬高 terminationGracePeriod,与 #5496 同一思路)、[#5485](https://github.com/kserve/kserve/pull/5485) / [#5318](https://github.com/kserve/kserve/pull/5318)(LocalModelCache 支持 LLMInferenceService)、[#5485](https://github.com/kserve/kserve/pull/5485) / [#5451](https://github.com/kserve/kserve/pull/5451)(Standard ISVC dual-protocol REST/gRPC 路由)
- **SGLang 把 UnifiedRadixCache 接上 KV events 与 LMCache mp 模式**:[#26387](https://github.com/sgl-project/sglang/pull/26387) 让 UnifiedRadixCache 发 GPU BlockStored/Removed + CPU/GPU tier transition 事件,**让外部路由器(对标 vLLM Mooncake 的事件流)能精确感知缓存命中**;[#24089](https://github.com/sgl-project/sglang/pull/24089) 把 LMCache 多进程模式接进来,`--lmcache-mp-host/--lmcache-mp-port` 走 IPC;[#26499](https://github.com/sgl-project/sglang/pull/26499) DSv4 改用 `sgl-flashmla` 替换上游 flashmla。**SGLang 这周完成"router/sidecar + KV events 外发"两面会师**,与 KServe llmisvc-router 路线开始正面对位
- **ogx(原 llama-stack)Messages API 一周内连发两个 breaking + 一组安全补丁**:**extended thinking** 全链路支持([#5938](https://github.com/ogx-ai/ogx/pull/5938) `_SignatureDelta` 解析 + 加密签名转发,passthrough 不再静默丢)、**cache_control + 服务端 tool 类型化**([#5908](https://github.com/ogx-ai/ogx/pull/5908),prompt cache breakpoint 字段下沉到所有 content block + tool 定义)、Web Search 域名过滤 + 用户定位 + 结构化 action([#5817](https://github.com/ogx-ai/ogx/pull/5817))、[#5949](https://github.com/ogx-ai/ogx/pull/5949) `vector_stores_config` 默认值修(breaking)+ [#5977](https://github.com/ogx-ai/ogx/pull/5977) Starlette CVE-2026-48710 收紧 + [#5937](https://github.com/ogx-ai/ogx/pull/5937) sql_postgres 凭据 URL-encode。**"Claude/Codex 作为一等 provider + Anthropic API 兼容"的事实标准在 ogx 这边一周一个 breaking 推进**

## 推理引擎动态

### vLLM
- 本窗口无新 release(v0.21.0 仍是 2026-05-15 那个)
- 2026-05-27 后约 100 个新合入(过滤 noise 后):
  - **KV / Offload**:
    - [#43205 KV Offload: per-request offloading policy via `on_new_request` lifecycle hook](https://github.com/vllm-project/vllm/pull/43205) — 新增 `OffloadPolicy` 枚举(`BLOCK_LEVEL` / `REQUEST_LEVEL`)+ `RequestOffloadingContext`;`TieringOffloadingManager` 轮询所有 secondary tier,任一返回 REQUEST_LEVEL 就走整请求路径。**KV 多 tier 策略的运行时入口**
    - [#43797 [kv_offload] Skip decode-phase blocks in CPU offload](https://github.com/vllm-project/vllm/pull/43797)
    - [#39983 token-offset based selective offload in OffloadConnector](https://github.com/vllm-project/vllm/pull/39983)
    - [#43600 change name of fs_python secondary tier to fs](https://github.com/vllm-project/vllm/pull/43600) — 二级 tier 改名收尾
    - [#43870 SecondaryTierManager.get_finished() → get_finished_jobs()](https://github.com/vllm-project/vllm/pull/43870)
    - [#42423 EC Connector add shutdown API](https://github.com/vllm-project/vllm/pull/42423)
  - **网络 / 多副本启动**:
    - [#42083 per-GPU worker RDMA NIC selection](https://github.com/vllm-project/vllm/pull/42083) — `VLLM_GPU_NIC_PCIE_MAPPING` 把 `GPU_BDF=NIC_BDF` 显式映射,`VLLM_NIC_SELECTION_VARS` 列出要按映射设置的环境变量。**多 GPU 节点上 KV / 集合通信走指定 NIC,直接关系 RDMA 部署吞吐**
    - [#43864 Bugfix: Exclude Ray DP from #42585's deferred port allocation](https://github.com/vllm-project/vllm/pull/43864) — Ray DP 走 `.remote()` pickle actor,driver 的 rebind 触达不到;按后端排除
    - [#43768 BugFix: Fix hard-coded timeout for multi-API-server startup](https://github.com/vllm-project/vllm/pull/43768)
    - [#42343 UX: Increase DP Coordinator startup timeout from 30s to 120s](https://github.com/vllm-project/vllm/pull/42343)
    - [#43732 Core: Cleanup KVConnector handling with PP + fix MRV2](https://github.com/vllm-project/vllm/pull/43732)
  - **Rust 前端继续向 GA 推进**:
    - [#43854 Rust Frontend: Add `/version` endpoint using engine-reported value](https://github.com/vllm-project/vllm/pull/43854)
    - [#43670 Rust Frontend: Optimize multimodal prompt expansion](https://github.com/vllm-project/vllm/pull/43670)
    - [#43872 Rust Frontend: Add `hy_v3` tool parser](https://github.com/vllm-project/vllm/pull/43872)
    - [#43850 Rust Frontend: Reduce Gemma4 tool parser args scan complexity](https://github.com/vllm-project/vllm/pull/43850)
    - [#43469 Rust Frontend: Introduce mock engine for benchmark baseline](https://github.com/vllm-project/vllm/pull/43469)
    - [#43429 rust: aggregate `is_sleeping` and `reset_prefix_cache` across DP engines](https://github.com/vllm-project/vllm/pull/43429)
    - [#43662 Rust Frontend: Align tool parser fallback between streaming & non-streaming](https://github.com/vllm-project/vllm/pull/43662)
    - **Rust 前端目前在补 endpoint / multimodal / DP 聚合三条尾巴,默认开的临界点已经看得到**
  - **API 表面**:
    - [#42396 Add structured output and effort support to Anthropic Messages API](https://github.com/vllm-project/vllm/pull/42396) — 对齐 Anthropic `structured outputs` + `effort` 参数,**与 ogx 的 Messages API breaking 是同一周的"Anthropic API 兼容性"共识**
    - [#39795 timed trace replay in `vllm bench serve` (Moonshot/Alibaba traces)](https://github.com/vllm-project/vllm/pull/39795) — `prompt_ids` / hash 时间戳轨迹回放,**可以直接拿真实生产 trace 给我们 MaaS 做 SLO 评测**
    - [#42683 streaming tool-call serializer drops first args chunk fix](https://github.com/vllm-project/vllm/pull/42683)
    - [#42879 Stream DeepSeek DSML tool-call argument deltas incrementally](https://github.com/vllm-project/vllm/pull/42879)
  - **模型与 kernel**:
    - [#43859 Support Step-3.7-Flash](https://github.com/vllm-project/vllm/pull/43859)、[#43356 Add Cosmos3 Reasoner model](https://github.com/vllm-project/vllm/pull/43356)、[#41459 Multimodal placeholders for Gemma4 tool message template](https://github.com/vllm-project/vllm/pull/41459)
    - [#38831 ModelRunnerV2: Support kernel block size in hybrid model](https://github.com/vllm-project/vllm/pull/38831) — hybrid 模型在 MRV2 上的可调 block size
    - [#43014 Optimize moe permute (9-14% kernel perf)](https://github.com/vllm-project/vllm/pull/43014)、[#43667 Perf KDA fuse gate softplus / chunk-local cumsum / RCP_LN2](https://github.com/vllm-project/vllm/pull/43667)
    - DSv4 收口继续:[#43679 ROCm DSV4 Tilelang MHC 替换 torch/triton](https://github.com/vllm-project/vllm/pull/43679)、[#43891 Remove unnecessary torch op registration](https://github.com/vllm-project/vllm/pull/43891)、[#43746 Remove torch compile dependency in DSv4](https://github.com/vllm-project/vllm/pull/43746)、[#43829 Remove AMD/XPU path in deepseek_v4/nvidia](https://github.com/vllm-project/vllm/pull/43829)
  - **稳定性 / 移植**:
    - [#43717 (9/n) Migrate attention and cache kernels to torch stable ABI](https://github.com/vllm-project/vllm/pull/43717) / [#43361 (8/n) merge_attn_states, mamba, sampler](https://github.com/vllm-project/vllm/pull/43361) — stable ABI 大迁移持续,**这是 vLLM 对接 torch 2.12+ 的产品级动作**
    - [#43791 Fix early CUDA init](https://github.com/vllm-project/vllm/pull/43791)、[#43794 Validate against some config fields being set to 0](https://github.com/vllm-project/vllm/pull/43794)、[#43464 Fix RunAI streamer tensor buffer reuse during weight loading](https://github.com/vllm-project/vllm/pull/43464)
- 启示:**vLLM 这两天的主线是"KV multi-tier policy + RDMA NIC 显式绑定 + 多副本启动收尾 + Rust 前端 GA 临界"**。
  - `VLLM_GPU_NIC_PCIE_MAPPING` 直接对应我们 MaaS 在多 NIC 节点上"每个 GPU 走最近 NIC"的诉求,部署文档可以现在就把这两个环境变量加进去
  - `on_new_request` lifecycle hook + per-request `OffloadPolicy` 是"按请求大小 / SLA 决定 KV 路径"的产品化口子,与 KServe llmisvc 调度器对话需要这一层
  - 真实 trace replay(Moonshot / Alibaba)可以直接拿来评测我们 MaaS 的 SLO 收敛

### SGLang
- 本窗口 release:[v0.5.12.post1(2026-05-26)](https://github.com/sgl-project/sglang/releases/tag/v0.5.12.post1) — 已在 2026-05-27 digest 详述
- 2026-05-27 后约 100 个新合入,主要信号:
  - **缓存事件 / 多进程缓存**:
    - **[#26387 Support KV events for UnifiedRadixCache](https://github.com/sgl-project/sglang/pull/26387)** — UnifiedRadixCache 启用 `KVCacheEventMixin`,发 GPU `BlockStored` / `BlockRemoved` 事件,以及 HiCache backup / demotion / load-back / host eviction 路径的 CPU/GPU tier transition 事件,节点 split 时保留 block hash。**让外部 router / metrics 系统能精确感知 prefix cache 状态,对 disaggregated 路由起决定性作用**
    - **[#24089 [LMCache] Support LMCache mp mode](https://github.com/sgl-project/sglang/pull/24089)** — SGLang 端配套 LMCache PR #3166,`--lmcache-mp-host / --lmcache-mp-port` 走 IPC;**LMCache 与 SGLang 解耦多进程部署,KV 跨进程共享**
  - **DSv4 kernel 进一步收口**:
    - [#26499 Import flash_mla kernels from sglang kernel for deepseek v4](https://github.com/sgl-project/sglang/pull/26499) — DSv4 改走 `sgl-flashmla`(自有 kernel),不再依赖上游 flashmla
    - [#26383 DSV4 MTP graph + sparse triton attn optimizations (AMD)](https://github.com/sgl-project/sglang/pull/26383)
    - [#26238 refactor(dsv4): route MHC prenorm through DeepGEMM wrapper](https://github.com/sgl-project/sglang/pull/26238)
    - [#25391 DSV4 DeepEP Waterfill](https://github.com/sgl-project/sglang/pull/25391) / [#26609 CI 清理 DSV4 测试与安装脚本](https://github.com/sgl-project/sglang/pull/26609)
  - **EPD / Mooncake**:
    - [#22587 Optimize the Mooncake backend (EPD)](https://github.com/sgl-project/sglang/pull/22587) — EPD 部署中 Mooncake 后端做编码 batching / 元数据路径优化
    - [#26487 convert mm_hashes to str in encode_server for Mooncake key compat](https://github.com/sgl-project/sglang/pull/26487)
  - **多模态 / ASR**:
    - [#22848 WebSocket streaming audio input for ASR](https://github.com/sgl-project/sglang/pull/22848) — `POST /v1/audio/transcriptions?stream=true` 之后再补 WebSocket 输入侧,**实时 ASR 用 case(直播字幕 / 语音助手)产品化**
  - **模型支持**:[#26565 Step-3.7-Flash](https://github.com/sgl-project/sglang/pull/26565)、[#26506 spec decoding kimi-k2.6-eagle3.1-mla draft](https://github.com/sgl-project/sglang/pull/26506)、[#24429 NemotronHPuzzle](https://github.com/sgl-project/sglang/pull/24429)
  - **kernel / 后端**:
    - [#24737 Support Flashinfer Cute-DSL MLA attention](https://github.com/sgl-project/sglang/pull/24737)、[#25486 Use Cute-DSL MXFP8 quantize kernels](https://github.com/sgl-project/sglang/pull/25486)、[#22921 GDN FlashInfer prefill SM100+ (Blackwell)](https://github.com/sgl-project/sglang/pull/22921)
    - [#26412 SWA / cross-attention 修 fixed_split_size 前向](https://github.com/sgl-project/sglang/pull/26412)、[#26513 Fix FlashInfer SWA EXTEND-with-prefix correctness](https://github.com/sgl-project/sglang/pull/26513)
  - **API 性能 / 工具调用**:
    - [#26355 API Perf: Replace pydantic per-element validation with C loop validation](https://github.com/sgl-project/sglang/pull/26355) — 请求 schema 校验从 pydantic per-element 切到 C 路径
    - [#26433 reland tool_call schema type normalization](https://github.com/sgl-project/sglang/pull/26433)
- 启示:**SGLang 这周完成了"对外可观测 + LMCache 解耦"两件事**:
  - KV events 让 SGLang 实例可以被外部 router(包括 KServe llmisvc 调度器)按缓存命中精确路由——**与 vLLM Mooncake 事件流形成事实标准,KServe 调度器若要做"按 prefix 路由 SGLang",这是上下文**
  - LMCache mp mode 让"vLLM / SGLang / 多进程"共享缓存层,对 MaaS 多模型 / 多副本场景值得评估

### TensorRT-LLM
- 本窗口 release:**v1.3.0rc16(2026-05-26)** 在 2026-05-27 digest 详述
- 2026-05-27 后约 70 个新合入(过滤 noise 后):
  - **API 收敛**:
    - [#14635 improve attention backend selection](https://github.com/NVIDIA/TensorRT-LLM/pull/14635) — backend 名大小写不再敏感,无效值改为 warning,不再静默 fallback 到 "TRTLLM"。**API 表面 fail-fast 化的小步**
    - [#14127 Expose host/GPU per-iter time and clarify iter labeling in /metrics](https://github.com/NVIDIA/TensorRT-LLM/pull/14127) — `/metrics` 加 `hostStepTimeMS` / `gpuStepTimeMS` / `iterMode`,沿用 #12413 的序列化注入模式(纯 Python,不需 C++ rebuild);**给 disagg 观察 host vs GPU 路径瓶颈一个直接探针**
    - [#12885 Enable test for kv_cache_manager_v2 for A10](https://github.com/NVIDIA/TensorRT-LLM/pull/12885) — KV manager v2 现在在 A10 上跑 CI 矩阵,**rc16 引入的 KV manager v2 进入"会被持续 gating"阶段**
  - **新能力**:
    - [#14012 MoT World Model Support](https://github.com/NVIDIA/TensorRT-LLM/pull/14012) — MoT(可能是 Mixture-of-Transformers)世界模型支持
    - [#13745 Gemma4 multi-head_dim pools + host-side slicing for Triton SWA](https://github.com/NVIDIA/TensorRT-LLM/pull/13745)
    - [#13721 visual_gen: add CuTe DSL attention via exported binaries](https://github.com/NVIDIA/TensorRT-LLM/pull/13721)
    - [#13888 support non-divisible EP in MoE alltoall and slurm benchmark](https://github.com/NVIDIA/TensorRT-LLM/pull/13888) — MoE EP 不再要求专家数被 EP rank 整除
  - **AutoDeploy 持续推进**:[#14361 NVFP4 RMSNorm quant fusion](https://github.com/NVIDIA/TensorRT-LLM/pull/14361)、[#14554 MLIR elementwise fusion + trtllm_gen MoE on Nano NVFP4](https://github.com/NVIDIA/TensorRT-LLM/pull/14554)、[#14622 tune Llama-3.1-8B FP8 TP=2/4](https://github.com/NVIDIA/TensorRT-LLM/pull/14622)
  - **kernel / 性能**:[#14548 Fuse FlashInfer GDN prefill state I/O into Triton kernels](https://github.com/NVIDIA/TensorRT-LLM/pull/14548)、[#14474 Replace Parakeet audio encoder with native trtllm layers](https://github.com/NVIDIA/TensorRT-LLM/pull/14474)、[#14381 Reuse batch_indices_cuda across CUDA graph captures in EAGLE3](https://github.com/NVIDIA/TensorRT-LLM/pull/14381)
  - **disagg / 安全**:[#14375 disagg cancellation stress-test harness skeleton](https://github.com/NVIDIA/TensorRT-LLM/pull/14375)、[#14161 Restrict HTTP cluster storage to loopback](https://github.com/NVIDIA/TensorRT-LLM/pull/14161)、[#14378 Pass IPC HMAC key through file descriptor](https://github.com/NVIDIA/TensorRT-LLM/pull/14378)
- 启示:**TRT-LLM rc16 之后两天进入 polish 期**——`/metrics` 加 host/GPU 时间维度,backend 选择 fail-fast,KV manager v2 进 A10 CI。**`/metrics` 新字段如果接 Prometheus 抓取,直接给我们 MaaS 提供 host vs GPU 时延维度**

### Ollama / TGI
- Ollama:0 commit
- TGI:0 commit
- **两者继续维持低活跃,跟踪频率可下沉到月度**

## 模型服务 & 编排

### KServe(上游)
- **[v0.19.0-rc0(2026-05-28)](https://github.com/kserve/kserve/releases/tag/v0.19.0-rc0)** — v0.18.0 → v0.19.0-rc0,**功能性 release**,体量很大。本周 2026-05-27 后新增的 release-blocker / 收尾型 PR:
  - **[#5579 feat(llmisvc): model-based routing gates and models in status](https://github.com/kserve/kserve/pull/5579)** — `serving.kserve.io/model-based-routing-enabled` annotation 显式开关 model-based routing(默认 config 模板都设),**避免旧 preset 在没有 alternative served model name 时静默触发**;HTTPRoute 构造路径接管 routing rule 的展开/剥离(原先在 config merge 时做)。新增 `ModelSourcedAddressStatus`,把 served model name(含 LoRA adapter 名字)写进 `status.addresses`,**对外做"按 model name 发现 endpoint"的语义闭环**
  - **[#5496 feat(llmisvc): adding vLLM shutdown-timeout](https://github.com/kserve/kserve/pull/5496)** — 两层 drain:preStop `/bin/sleep 15` 给 EPP(Endpoint Picker)察觉 readiness 失败摘流的时间,然后 vLLM `--shutdown-timeout` 接走 SIGTERM,把所有 LLM config 模板都加上。**滚动更新 / scale-down 不再 abort in-flight 请求**——这是 OAI MaaS 在生产里直接掉用户的痛点修法
  - **[#5586 docs(llmisvc): add godoc to all LLMInferenceService conditions](https://github.com/kserve/kserve/pull/5586)** — 14 个 `ConditionType` 全加 godoc,每条标注 True/False 语义、归属 reconciler、上卷的父 condition、是否在多节点 / PD disagg / scheduler / autoscaling 拓扑下才出现。**把 status 当成 API contract 文档化**——dashboard/CLI/operator 拿这份 godoc 作为 source of truth
- v0.19.0-rc0 release 还包含 2026-05-27 digest 已覆盖的 #5521 / #5560 / #5533 / #5318 / #5451 / #5417 / #5414 等,以及本次未单独提的关键改动:
  - [#5520 deps: upgrade Envoy AI Gateway to v0.6.0 and Envoy Gateway to v1.7.0](https://github.com/kserve/kserve/pull/5520) — 网关栈整体跳一档
  - [#5485 feat(llmisvc): add preStop hook and up terminationGracePeriod](https://github.com/kserve/kserve/pull/5485) — 与 #5496 同一思路,先一步把 preStop 范围抬高
  - [#5318 feat: add LocalModelCache support for LLMInferenceService](https://github.com/kserve/kserve/pull/5318) — LocalModelCache 第一次覆盖 LLMInferenceService
  - [#5451 feat(isvc): add dual-protocol (REST/gRPC) routing for Standard mode](https://github.com/kserve/kserve/pull/5451) — Standard ISVC 双协议路由
  - [#5540 feat(llmisvc): bubble up HPA/KEDA scaling status to service conditions](https://github.com/kserve/kserve/pull/5540) — 把 HPA/KEDA 状态映射到 LLMISvc condition
  - [#5544 feat(charts): make llmisvc GIE CRD creation optional](https://github.com/kserve/kserve/pull/5544) — chart 可选 install GIE CRD
- 主线 2026-05-27 后非 release 单独 commit 极少(#5579 / #5586 / #5496 已列上;CI 收尾若干)
- 启示:**v0.19.0-rc0 是这个季度 OAI fork 的核心同步点**——OAI fork 把 v0.18 → v0.19-rc0 全量过一遍,优先评估:
  - **routing**:#5521 model name routing(共享 gateway 多模型分流)+ #5579 routing gates(显式 opt-in,避免旧配置静默改语义)。对 MaaS 多模型场景是必须能力
  - **优雅退出**:#5496 + #5485 是 SRE 直接受益项,可以倒推自查我们 fork 里同类组件的 SIGTERM 路径
  - **status 契约**:#5586 godoc 直接抄给 OAI dashboard / CLI 用
  - **Envoy AI Gateway v0.6.0 + Gateway v1.7.0**:版本对齐评估,看 OAI 是否需要 lock-step 升级

### Ray
- 本窗口无新 release;2026-05-27 后约 21 个新合入,信号:
  - **[#63035 [Core] Add Support for Furiosa AI NPU](https://github.com/ray-project/ray/pull/63035)** — Ray Core 加 Furiosa NPU 加速器类型,**国产/异构 NPU 在 Ray 体系里多一个一等公民**(对 OAI 在国内做异构推理是一个观察点)
  - **[#63312 Avoid FabricManager stall on NVLink systems in GpuProfilingManager](https://github.com/ray-project/ray/pull/63312)** — NVLink 节点上 FabricManager stall 修复,**多 GPU NVLink 节点跑 Ray 的稳定性**
  - **[#63482 [Data] Implement distributed upsert for Iceberg using task-based scan merge approach](https://github.com/ray-project/ray/pull/63482)** — Ray Data 对 Iceberg 表分布式 upsert
  - [#63694 [core] Fix ray.get hanging forever when an object's owner dies during pull](https://github.com/ray-project/ray/pull/63694) — 长跑集群的悬挂 bug 修复
  - [#62608 [core] Add `IOContextMonitor` implementation](https://github.com/ray-project/ray/pull/62608) — 核心 IO 上下文监控,后续用于排查 Ray 内部 IO 卡死
  - [#63653 Avoid extra memcpy when spilling fused objects](https://github.com/ray-project/ray/pull/63653)
  - [#63393 Ray Data usage metric collection](https://github.com/ray-project/ray/pull/63393)
  - [#63618 dashboard: Show last data load time](https://github.com/ray-project/ray/pull/63618)、[#63687 Fix invalid PromQL when global_filters is empty](https://github.com/ray-project/ray/pull/63687)
- 启示:**Furiosa NPU(#63035)是 Ray 这周唯一对"国产 AI 芯片入栈"有直接信号的改动**——Ray 已有的加速器抽象(Resource 标签 + scheduler hint)被沿用,**意味着新 NPU 可以快速进 Ray 生态**。如果我们 MaaS 要把 Ray 作为多框架编排,这是把"Furiosa-on-Ray"模板化的契机

### KubeAI(原 substratusai/lingo,现 `kubeai-project/kubeai`)
- 本窗口无 release,**0 commit**(连续三期为 0) — **下沉到半年跟踪**

## 训练 & 微调

- **Kubeflow Trainer**:2026-05-27 后只有 [#3560 fix(examples): use namespaced SQuAD dataset](https://github.com/kubeflow/trainer/pull/3560),无能力面变化
- **LlamaFactory**:2026-05-27 后无新 commit(2026-05-27 digest 覆盖了 v1 dynamic padding-free 等内容);本周无新增信号

## 模型生命周期(MLflow / Hub / Feast)

### MLflow
- 本窗口 release:**v3.13.0rc0(2026-05-22)** 在 2026-05-27 digest 详述
- 2026-05-27 后约 33 个新合入,主要是 rc0 后的 polish + 后续模块:
  - **Coding-agent tracing 基础设施继续**:
    - [#23579 IPC layer for claude code batched tracing](https://github.com/mlflow/mlflow/pull/23579) — Claude Code 批量 tracing 的 IPC
    - [#23605 Daemon implementation for coding agents batched tracing](https://github.com/mlflow/mlflow/pull/23605) — Daemon 实现
    - [#23562 Support native UC trace ingestion from TypeScript SDK](https://github.com/mlflow/mlflow/pull/23562)
    - [#23483 Forward MLflow client telemetry from inside Databricks workloads](https://github.com/mlflow/mlflow/pull/23483)
  - **Trace 存储**:
    - [#23194 Add ON DELETE CASCADE relationship for SqlTraceInfo to SqlExperiment](https://github.com/mlflow/mlflow/pull/23194) — 删 experiment 不再留 trace 孤儿
    - [#23656 Clarify trace archival max-traces behavior](https://github.com/mlflow/mlflow/pull/23656)、[#23655 Clear archive-now requests for non-archivable leftovers](https://github.com/mlflow/mlflow/pull/23655)
    - [#23591 extend `mlflow.sourceRun` metrics filter to cover post-hoc linked OTLP traces](https://github.com/mlflow/mlflow/pull/23591)
  - **AI Gateway**:
    - [#23559 Support AI Gateway as a backend of MLflow Assistant](https://github.com/mlflow/mlflow/pull/23559)(2026-05-27 已在前一 digest 提及,这里确认合入)
    - [#23612 Warn on submit with an unsaved direct-grant draft](https://github.com/mlflow/mlflow/pull/23612)
    - [#23650 Forward OpenAI custom base URL in Detect Issues flow](https://github.com/mlflow/mlflow/pull/23650)
- 启示:**rc0 后两天主要补 IPC / daemon / archival 等基础设施**——3.13 的"Coding-agent + tracing + AI Gateway"三件套继续在收紧 IO 路径,**OAI 对接 MLflow 3.13 时 daemon 形态值得提前评估部署模型(sidecar vs node-agent)**

### Kubeflow Hub(原 model-registry)
- 2026-05-27 后约 3 个有效 commit:
  - **[#2751 refactor(catalog): split unified plugin into per-domain plugins with shared PluginBase](https://github.com/kubeflow/hub/pull/2751)** — 继 #2735 之后再 split,**catalog plugin 从"统一二进制 + 插件 SO"转向"每 domain 独立 plugin 共享 base"**,plugin 模型继续在成型
  - [#2748 Add catalog hardware tags](https://github.com/kubeflow/hub/pull/2748) — catalog 给模型加硬件 tag(GPU 型号 / 数量等元数据),**对"按算力筛选模型"是基础设施**
  - [#2754 chore: upgrade to go 1.26](https://github.com/kubeflow/hub/pull/2754) — Hub Go 1.26 升级
- 启示:**Hub 在沿着 "model + MCP" 双 catalog 走,plugin 拆分 + 硬件 tag 都是为大规模 model 目录服务**。OAI 自家 model registry 若有"按 GPU 选模型"诉求,可参考 #2748 字段命名

### Feast
- 本窗口无 release;2026-05-27 后:
  - [#6015 perf: Replace MessageToDict with optimized custom dict builder](https://github.com/feast-dev/feast/pull/6015)
  - [perf: Cache feature view resolution in get_online_features](https://github.com/feast-dev/feast/commit/55c2f18) — 在线查询路径减少 per-request 解析开销
- 启示:**两条都是在线查询 hot path 性能,Feature Store 用在 LLM 推理上下文检索时受益**

## LLM 评估 & 安全

- **EleutherAI/lm-evaluation-harness**:**连续三期 0 commit / release**,**已可降为月度甚至季度跟踪**
- **NVIDIA/garak**:2026-05-27 后 6 个 commit:
  - [#1729 allow promptinject probes to limit `generation_params`](https://github.com/NVIDIA/garak/pull/1729) — 红队 probe 可以限制生成参数
  - [#1794 fix(evaluators): inline score_to_defcon in get_z_rating](https://github.com/NVIDIA/garak/pull/1794)
  - [#1791 test(config): regression guard for config_files dedup](https://github.com/NVIDIA/garak/pull/1791)
- **ogx-ai/ogx(原 meta-llama/llama-stack)**:2026-05-27 后 10 个 commit,产品级密集:
  - **[#5938 feat(messages)!: add extended thinking support](https://github.com/ogx-ai/ogx/pull/5938)** — **breaking**:`_SignatureDelta` 解析 + 加密签名转发,passthrough 不再静默丢 `signature_delta` 事件;Anthropic Messages API extended thinking 全链路接通
  - **[#5908 feat(messages): add cache_control support and typed server-tool definitions](https://github.com/ogx-ai/ogx/pull/5908)** — `AnthropicCacheControl` 模型 + 所有 content block(text / image / tool_use / tool_result / thinking)和 tool 定义都接 `cache_control`;**prompt cache breakpoint 不再被吃掉**
  - **[#5817 feat(web-search): add domain filtering, user location, and structured search actions](https://github.com/ogx-ai/ogx/pull/5817)** — web search tool 对齐 OpenAI Responses API:domain include/exclude、user_location(国家/城市)、`WebSearchToolCall.action` 结构化 metadata
  - [#5949 fix!: default vector_stores_config to VectorStoresConfig()](https://github.com/ogx-ai/ogx/pull/5949) — **breaking**:防 `file_search` 崩溃
  - [#5977 fix: constrain starlette to >=1.0.1 (CVE-2026-48710)](https://github.com/ogx-ai/ogx/pull/5977)、[#5937 fix(storage): URL-encode credentials in sql_postgres connection string](https://github.com/ogx-ai/ogx/pull/5937) — 安全补丁
  - [#5957 chore: remove dead Llama SKU catalog and broken generate_prompt_format script](https://github.com/ogx-ai/ogx/pull/5957) — 历史 Llama 资产清理
- 启示:**ogx 这周 Messages API 一周内连发 3 个 breaking,持续把 Anthropic API 表面打到 1:1 兼容**——`extended thinking` / `cache_control` / 结构化 web search action 都是 Anthropic SDK 端必备字段。**与 vLLM #42396 同周做 Anthropic structured output + effort,共同推"Anthropic API 兼容性"作为 LLM API 事实标准**

## 值得跟进

- [ ] **KServe v0.19.0-rc0 全量评估**([release notes](https://github.com/kserve/kserve/releases/tag/v0.19.0-rc0)):
  - **必读**:#5579 model-based routing gates(防旧配置静默改语义)、#5521 model name routing(共享 gateway 多模型分流)、#5496 + #5485 vLLM shutdown-timeout & preStop(滚动更新/scale-down 不掉 in-flight 请求)、#5586 ConditionType godoc(status 契约文档化)、#5520 Envoy AI Gateway v0.6.0 / Envoy Gateway v1.7.0
  - **行动**:OAI fork 跟版本对齐;自家 dashboard 用 #5586 godoc 作为 status 解读 source of truth;评估 #5521 是否替换我们自有 model 分流逻辑
- [ ] **vLLM RDMA NIC 显式绑定(#42083)**:多 NIC 节点上把 `VLLM_GPU_NIC_PCIE_MAPPING` / `VLLM_NIC_SELECTION_VARS` 加入部署模板,对 KV / 集合通信吞吐立刻有改善
- [ ] **vLLM per-request KV offload policy(#43205)**:`on_new_request` lifecycle hook + `OffloadPolicy` 是 KServe llmisvc 调度器与 vLLM 之间的新可调旋钮,**评估"按请求 SLA 决定 KV 路径"在我们 MaaS 的产品化**
- [ ] **vLLM `vllm bench serve` 真实 trace replay(#39795)**:用 Moonshot / Alibaba 公开 trace 给我们 MaaS SLO 评测搭一套基准
- [ ] **SGLang KV events(#26387)+ LMCache mp 模式(#24089)**:外部 router 若想"按 prefix cache 命中路由"SGLang 实例,这是入口;LMCache 多进程为"vLLM + SGLang 共享缓存层"提供基础
- [ ] **TRT-LLM `/metrics` 增 host/GPU per-iter time(#14127)+ KV cache manager v2 A10 gating(#12885)**:接 Prometheus 直接产出 host vs GPU 时延维度;KV manager v2 进入"会被 CI gating"阶段意味着 rc 之后稳定性会持续上行
- [ ] **Ray Furiosa NPU(#63035)+ NVLink FabricManager(#63312)**:Furiosa 是异构 NPU 入 Ray 的样板;NVLink stall 修复对长跑 GPU 集群直接受益
- [ ] **Kubeflow Hub catalog hardware tags(#2748)+ per-domain plugin(#2751)**:做"按算力筛选模型"的 catalog 时直接参照 schema
- [ ] **ogx 一周 3 个 Messages API breaking(#5938 / #5908 / #5817)+ vLLM #42396**:"Anthropic API 一等公民"形态在多个项目同步推进,**评估我们 MaaS API 层是否做 Anthropic Messages 兼容代理**

## 原始材料

<details>
<summary>本窗口内 release(2026-05-22 后)</summary>

- MLflow v3.13.0rc0(2026-05-22)— 已在 2026-05-27 digest 详述
- SGLang v0.5.12.post1(2026-05-26)— 已在 2026-05-27 digest 详述
- TensorRT-LLM v1.3.0rc16(2026-05-26)— 已在 2026-05-27 digest 详述
- **KServe v0.19.0-rc0(2026-05-28)— NEW(功能性 rc0,本期重点)**
- vLLM、SGLang、TRT-LLM、Ollama、Ray、TGI、KubeAI、Trainer、LlamaFactory、Feast、garak、lm-eval、Hub、ogx 本两日无新 release
</details>

<details>
<summary>本两日(2026-05-27 后)commit 计数,过滤 merge/bump/CI/doc 噪音前</summary>

- vLLM:~100
- SGLang:~100
- TensorRT-LLM:72
- MLflow:33
- Ray:21
- ogx:10
- KServe:6(其中 4 为新功能 / 文档 / vLLM shutdown,2 为 CI)
- garak:6
- Feast:4
- kubeflow/hub:3
- kubeflow/trainer:1
- 0 commit:TGI、Ollama、KubeAI、lm-evaluation-harness、LlamaFactory
</details>

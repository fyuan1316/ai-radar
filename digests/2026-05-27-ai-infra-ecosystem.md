# AI 推理 & MLOps 生态周报 2026-05-27

窗口:2026-05-20 → 2026-05-27(7 天)。前半窗口与 [2026-05-22 digest](./2026-05-22-ai-infra-ecosystem.md) 重叠,本报告以 2026-05-22 之后的新信号为主轴。

## 摘要(5 条以内)

- **MLflow 3.13.0rc0 大版本启动**([release notes](https://github.com/mlflow/mlflow/releases/tag/v3.13.0rc0),2026-05-22):RBAC 与权限表大重构 + Admin UI + Trace Archival([#23359](https://github.com/mlflow/mlflow/pull/23359))+ Coding-Agent Plugin 化(Claude Code / Codex / Ollama / OpenClaw 全部接入 AI Gateway)+ Kubernetes Helm chart + `mlflow.genai.test_agent` 自动压测 + OpenTelemetry Span Links + DB 读写分离。**3.13 把"实验跟踪 → AI Gateway → Coding-agent → K8s 部署"四件事打包成一个版本**,这是上周 executor RFC + tracing 异步导出基础设施的成果落地
- **TensorRT-LLM v1.3.0rc16**([release notes](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc16),2026-05-26):KV cache manager v2 + Python transceiver([#12928](https://github.com/NVIDIA/TensorRT-LLM/pull/12928))、hybrid 模型 disagg 启用 block reuse([#14060](https://github.com/NVIDIA/TensorRT-LLM/pull/14060))、FlashInfer MLA attention backend([#13428](https://github.com/NVIDIA/TensorRT-LLM/pull/13428))、disagg 多 postproc worker 的 OpenTelemetry 指标([#12637](https://github.com/NVIDIA/TensorRT-LLM/pull/12637))、llmapi triton backend 加 LoRA([#14079](https://github.com/NVIDIA/TensorRT-LLM/pull/14079))、KV 连接器配置不兼容时构造期拒绝([#13577](https://github.com/NVIDIA/TensorRT-LLM/pull/13577))、SWA scratch reuse rewind([#14412](https://github.com/NVIDIA/TensorRT-LLM/pull/14412))。**rc15 的"产品级可观测 + 多租户 KV"基线进一步上行**,把 disagg + hybrid + LoRA 三轴补齐
- **SGLang 把"路由 / 传输 / 指标"三件事产品化**:实验性 [sgl-router Rust HTTP 路由器(#25851)](https://github.com/sgl-project/sglang/pull/25851) 进库——141 commits, M0→M6 全周期,定位与 vLLM Rust 前端([#43582](https://github.com/vllm-project/vllm/pull/43582))同源,但形态是 sidecar 二进制;mooncake_tcp 传输后端([#26346](https://github.com/sgl-project/sglang/pull/26346))给 PD disagg 一个 no-RDMA 部署路径(`--disaggregation-transfer-backend mooncake_tcp`);`ServerArgs.stat_loggers` 让指标后端可插拔([#24610](https://github.com/sgl-project/sglang/pull/24610))。**这是对标 KServe llmisvc 网关栈的另一条路:不依赖 K8s gateway,直接出 Rust 二进制**
- **KServe v0.17.1 cherry-pick 发布([release notes](https://github.com/kserve/kserve/releases/tag/v0.17.1)),主线 llmisvc 完成 v0.6→v0.7 调度迁移收尾**:[#5560](https://github.com/kserve/kserve/pull/5560) 把 v0.6 的 `threshold > 0` 自动转为 `prefix-based-pd-decider`(按 4:1 字符/token 比换算),日志提示用户重新调优。同周 [#5533](https://github.com/kserve/kserve/pull/5533) 修 workload Service 在 `EnableTLS=false` 时仍写 `appProtocol: https` 的 bug,导致 Traefik 误把上游当 HTTPS;Feast [#6367](https://github.com/feast-dev/feast/pull/6367) 同周修了对偶问题(registry gRPC service 没写 `appProtocol: grpc` 导致 Istio 降级为 HTTP/1.1)。**两个仓库同周都在补"Service appProtocol → 网格识别"这块,在 OAI 这种 mesh-heavy 部署里值得统一审一遍 Service 元数据**
- **vLLM 这周补的是产品 SRE 基线**:多 API server DP 启动的 TOCTOU race 修掉(`bind/close → bind`,5/79 失败率,[#42585](https://github.com/vllm-project/vllm/pull/42585))、非 root docker 镜像目标 `vllm-openai-nonroot` 主线进库([#40275](https://github.com/vllm-project/vllm/pull/40275))、KV 连接器 HMA 由 opt-in 转 opt-out([#41847](https://github.com/vllm-project/vllm/pull/41847))、Python 文件系统二级 tier 进库支持多层 KV offload([#41735](https://github.com/vllm-project/vllm/pull/41735))。**OAI fork 维护这条:non-root 镜像目标的合并意味着上游兼容 OpenShift 启动模型的差距进一步缩小**

## 推理引擎动态

### vLLM
- 本窗口无新 release(v0.21.0 在 2026-05-15,2026-05-22 后未出 rc)
- 191 个合入 commit(全窗口),2026-05-22 后新增信号:
  - **稳定性 / 部署**:
    - [#42585 Fix TOCTOU race causing intermittent EADDRINUSE on multi-API-server DP startup](https://github.com/vllm-project/vllm/pull/42585) — `bind(("", 0)) → close()` 预占端口的竞态;5/79 启动失败率,**多副本 DP K8s 部署直接受益**
    - [#40275 Non-root support for vllm-openai; add opt-in vllm-openai-nonroot target](https://github.com/vllm-project/vllm/pull/40275) — 与 OpenShift 专用镜像目标 `vllm-openai-openshift`(#38552)互补,**OAI 路线的非 root 兼容性合到主线了**
    - [#43358 [Deprecation] Deprecate functions as scheduled for v0.21.0](https://github.com/vllm-project/vllm/pull/43358) — `cprofile` / `logit_bias` / `logit_scale` 进入 deprecation
  - **KV Connector**:
    - [#41847 Enable HMA by default for connectors that support it](https://github.com/vllm-project/vllm/pull/41847) — HMA 由 opt-in 转 opt-out,Hybrid Memory Architecture 在 KV 连接器路径默认生效
    - [#41735 File system secondary tier implemented in python](https://github.com/vllm-project/vllm/pull/41735) — 多层 KV offload 的文件系统二级 tier,**对接对象存储 / 本地 SSD 的产品分层方案首次进库**
    - [#42788 KV Connector Propagate MooncakeStore load failures](https://github.com/vllm-project/vllm/pull/42788) / [#43494 Keep MooncakeStore full hits block-aligned](https://github.com/vllm-project/vllm/pull/43494) / [#43627 drop dead discard_partial_chunks parameter](https://github.com/vllm-project/vllm/pull/43627) / [#43516 MooncakeStore: don't double-apply Eagle prune in load_mask](https://github.com/vllm-project/vllm/pull/43516) / [#43392 Add metrics for MooncakeStoreConnector operations](https://github.com/vllm-project/vllm/pull/43392) / [#43281 Handle Mooncake finish after preemption](https://github.com/vllm-project/vllm/pull/43281) / [#42694 [Mooncake] Wire reset_cache cascade end-to-end](https://github.com/vllm-project/vllm/pull/42694) — Mooncake 一条线大密度修补,Mooncake 整合已经进入"上线时遇到 bug 就修"阶段
  - **DSv4 / 核心 kernel**:
    - [#43162 Fuse q pad into deepseek v4 fused kernel](https://github.com/vllm-project/vllm/pull/43162) / [#43690 Drop _get_compressed_kv_buffer](https://github.com/vllm-project/vllm/pull/43690) / [#43710 Refactor compressor & Fix ROCm compatibility](https://github.com/vllm-project/vllm/pull/43710) / [#42789 W4A8 int8 oracle](https://github.com/vllm-project/vllm/pull/42789) / [#43632 Move MegaMoE input prep kernel to nvidia/ops](https://github.com/vllm-project/vllm/pull/43632) — DSv4 走到"kernel 收口 + 跨平台"阶段
    - [#43273 GDN Prefill kernel for SM100](https://github.com/vllm-project/vllm/pull/43273) — MLSys 2026 FlashInfer 竞赛 kernel 移植到 CuteDSL,Blackwell 上 GDN prefill 加速,需显式 opt-in
    - [#43325 Add OOT MLA prefill backend registration mechanism](https://github.com/vllm-project/vllm/pull/43325) — out-of-tree MLA prefill 后端注册机制,**MLA 走可插拔后端**
    - [#38822 Add head_dim=512 support for FlashInfer trtllm attention backend](https://github.com/vllm-project/vllm/pull/38822)
  - **Rust 前端继续**:[#43582 Rust Frontend reasoning/tool parser & renderer roundtrip tests](https://github.com/vllm-project/vllm/pull/43582) — Rust 路径在补 chat 模板 ↔ 解析器的回环测试,**接近可以默认开启的状态**
  - 其他:[#42124 Add LM head quantization support for ModelOpt](https://github.com/vllm-project/vllm/pull/42124)、[#42290 [LoRA] Add one shot triton kernel For MoE LoRA](https://github.com/vllm-project/vllm/pull/42290)
- 启示:**vLLM 这周补的是"产品 SRE 基线"**——TOCTOU race、non-root 镜像、HMA 默认开、KV 二级 tier。OAI fork 维护可以把 `vllm-openai-nonroot` 目标直接拉进自家 Dockerfile,省掉私有 patch;Mooncake 连接器大密度修补意味着 v0.21 之后的 patch release 主要会以稳定性 PR 为主

### SGLang
- 本窗口 release:[v0.5.12.post1(2026-05-26)](https://github.com/sgl-project/sglang/releases/tag/v0.5.12.post1) — 12 个 cherry-pick,主要修 DSV4 在 B200/B300 上的精度 / 启动 / KV 索引问题(DSV4-Pro 单 token decode 乱码、DSV4 EAGLE/MTP 在 disagg decode 约 2000 请求处崩溃、DSV4 HiSparse 用 compressor v2 时 GSM8K 0.825 → 0.960 恢复等)
- 247 个合入 commit(全窗口),2026-05-22 后新增信号:
  - **[#25851 sgl-router: experimental Rust HTTP router for SGLang worker pools](https://github.com/sgl-project/sglang/pull/25851)** — 实验性 Rust HTTP router 进入 `experimental/sgl-router/`,与 model-gateway sidecar(SMG)同位但形态为单二进制。141 commits,M0(scaffold)→M6(observability + Docker/Helm)+ PD-on-K8s 全周期。**与 vLLM Rust 前端是两种路线**:vLLM 把 Rust 嵌入 engine,SGLang 出 sidecar
  - **[#26346 Add mooncake_tcp transfer backend (mooncake over TCP)](https://github.com/sgl-project/sglang/pull/26346)** — `--disaggregation-transfer-backend mooncake_tcp` 别名,设置 `MC_FORCE_TCP=1` 跳过 RDMA HCA 选择,**给 PD disagg 一个 no-RDMA 部署路径**(普通云上没 RDMA 的环境直接可用)
  - **[#24610 [observability] add ServerArgs.stat_loggers for pluggable metrics backend](https://github.com/sgl-project/sglang/pull/24610)** — 把硬编码的 5 个 `*MetricsCollector`(prometheus_client.Counter/Gauge/Histogram/Summary)解耦,指标后端做成可插拔。**对接私有 telemetry 系统的口子**
  - **存储 / 缓存**:
    - [#26062 [UnifiedRadixTree] Support L3 HiStorage framework](https://github.com/sgl-project/sglang/pull/26062) — 三层存储(L1 GPU / L2 host / L3 远端),Verify 过 GLM5.1 DSA + Qwen Hybrid
    - [#26295 Refactor HiCache stack dispatch into strategies](https://github.com/sgl-project/sglang/pull/26295) — HiCache 多策略路径
    - [#26425 Maintain req_pool_indices_cpu host mirror](https://github.com/sgl-project/sglang/pull/26425) — 复用 `seq_lens_cpu` 设计,消除每次 decode 的 D2H copy
  - **DSv4 / MoE**:[#25948 [dsv4] support eplb](https://github.com/sgl-project/sglang/pull/25948)、[#25391 Support DeepSeek V4 DeepEP Waterfill](https://github.com/sgl-project/sglang/pull/25391)、[#26088 GLM-4.7-Flash: standalone MLA impl and MLA NextN/MTP](https://github.com/sgl-project/sglang/pull/26088)(以前 subclass deepseek_v2.py 频繁被 DSV4 改坏,现拆独立实现)
  - **Spec V2 收尾**:[#26235 / #26397 Skip full-vocab softmax in EAGLE draft when topk==1](https://github.com/sgl-project/sglang/pull/26397)(reland)
  - **EPD**:[#25964 [EPD] Cross-request batching for image/audio encoder](https://github.com/sgl-project/sglang/pull/25964) — Encode-Prefill-Decode 部署中 encoder server 在小 mm_item 高并发场景吞吐打不上来,引入跨请求 batching
- 启示:**SGLang 在做"独立 sidecar 形态的 inference 网关栈"**——Rust router 解决 K8s 网关之外的轻量场景,mooncake_tcp 解决普通云没 RDMA 的场景,stat_loggers 解决私有 telemetry 接入。这条线是对 KServe llmisvc(必须依赖 K8s + Gateway API)的明确补集;**评估"哪些客户场景用 sidecar、哪些用 llmisvc"成为选型问题**

### TensorRT-LLM
- **[v1.3.0rc16(2026-05-26)](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc16)** — 距 rc15(2026-05-21)5 天,150+ commit
- 模型与基线:
  - Gemma4 多模态 + 原生视觉 / 音频塔([#14300](https://github.com/NVIDIA/TensorRT-LLM/pull/14300))
  - Qwen3.5 MTP + Qwen3.6-27B-FP8([#12646](https://github.com/NVIDIA/TensorRT-LLM/pull/12646)、[#14359](https://github.com/NVIDIA/TensorRT-LLM/pull/14359))
  - EXAONE-4.5 / Laguna([#12873](https://github.com/NVIDIA/TensorRT-LLM/pull/12873)、[#13559](https://github.com/NVIDIA/TensorRT-LLM/pull/13559))
  - DeepSeek / NemotronH / Qwen3 / Qwen3.5-MoE 全部切到 sharding-IR canonical 模型([#13478](https://github.com/NVIDIA/TensorRT-LLM/pull/13478)) — 模型实现走"统一中间表示"
- API / 运行时:
  - [#12928 Add KV cache manager v2 with Python transceiver](https://github.com/NVIDIA/TensorRT-LLM/pull/12928) — KV manager 主版本升级,Python transceiver 走新协议,与 rc15 的 `cache_salt_id` 是一条线的延续
  - [#14060 Disaggregated serving support with block reuse ON for hybrid models](https://github.com/NVIDIA/TensorRT-LLM/pull/14060) — hybrid(softmax + linear)模型走 disagg 时也能复用 KV block,**这与 vLLM #41847 HMA 默认开是同一周的"hybrid disagg + 块复用"共识**
  - [#13428 Add FlashInfer MLA attention backend support](https://github.com/NVIDIA/TensorRT-LLM/pull/13428) — MLA 在 FlashInfer 后端落地,与 vLLM #38822(head_dim=512 进 FlashInfer)对偶
  - [#12947 SkipSoftmax sparse attention for visual generation](https://github.com/NVIDIA/TensorRT-LLM/pull/12947)
  - [#14412 Support SWA scratch reuse rewind](https://github.com/NVIDIA/TensorRT-LLM/pull/14412)
  - [#13577 Reject incompatible KV connector configurations at construction time](https://github.com/NVIDIA/TensorRT-LLM/pull/13577) — 配置层 fail-fast
  - [#14275 Drop sink_token_length from PyTorch attention surface](https://github.com/NVIDIA/TensorRT-LLM/pull/14275)
  - [#14079 [#11257][feat] Add LoRA support to llmapi triton backend](https://github.com/NVIDIA/TensorRT-LLM/pull/14079) — Triton 后端补 LoRA
  - [#14052 Add single-rank MPI sleep/wakeup support and a rank-0 collective_rpc shim](https://github.com/NVIDIA/TensorRT-LLM/pull/14052)
- 可观测 / 失败处理:
  - [#12637 Add opentelemetry metrics for disaggregated serving with multiple postprocessing workers](https://github.com/NVIDIA/TensorRT-LLM/pull/12637) — disagg + 多 postproc worker 的 OTel 指标(rc15 已经做 per-rank stats,这里把 disagg 路径补上)
  - [#14206 chore: log KV cache utilization and context tokens per iter](https://github.com/NVIDIA/TensorRT-LLM/pull/14206)
  - [#14333 Add exact multimodal KV block hashing and KV cache reuse probing](https://github.com/NVIDIA/TensorRT-LLM/pull/14333)
- Kernel / 性能:
  - [#13985 ltx2: fused RMSNorm+RoPE across all attention paths + PE pre-shard](https://github.com/NVIDIA/TensorRT-LLM/pull/13985)、[#13426 EAGLE3 dynamic tree kernel optimizations](https://github.com/NVIDIA/TensorRT-LLM/pull/13426)、[#14306 shared-expert combine fusion](https://github.com/NVIDIA/TensorRT-LLM/pull/14306)、[#14133 paged MQA logits decode tuning](https://github.com/NVIDIA/TensorRT-LLM/pull/14133)
  - [#14197 Optimize beam search candidate reconstruction by skipping prompt-prefix copies](https://github.com/NVIDIA/TensorRT-LLM/pull/14197)
  - [#14462 Update cubins to resolve FMHA PDL issue](https://github.com/NVIDIA/TensorRT-LLM/pull/14462)、[#14354 Use CUDA 13 CUTLASS DSL package](https://github.com/NVIDIA/TensorRT-LLM/pull/14354)
- 启示:**TRT-LLM 在 rc15 的"统一异常分类 + 多租户 KV salt"基础上,rc16 把 disagg + hybrid + LoRA 三轴补齐**:`#14060` hybrid disagg block reuse、`#14079` Triton LoRA、`#12637` disagg OTel 指标。**KV manager v2 是接下来值得直接对接的口子**——若我们 MaaS 做多租户 KV 隔离,rc15 的 `cache_salt_id` + rc16 的 KV manager v2 是完整原语对

### Ollama
- 本窗口无新 release(最近 v0.30.0-rc27 / v0.24.0 都在 05-13/14 早于窗口)
- 7 个合入 commit,只有 [#16289 mlx: fix reported information in ollama show](https://github.com/ollama/ollama/pull/16289)、[#16287 server: remove duplicate template parsing](https://github.com/ollama/ollama/pull/16287) 是正经修复
- 启示:与产品对接无直接接口,**进入低活跃期,可下沉跟踪频次**

### TGI
- 本窗口无 release、0 commit — 维护模式持续确认

## 模型服务 & 编排

### KServe(上游)
- **[v0.17.1(2026-05-21)](https://github.com/kserve/kserve/releases/tag/v0.17.1)** — cherry-pick 小版本,主要回填 v0.17.0 安装脚本 + helm chart 修复
- 主线 2026-05-22 后 4 个 commit:
  - **[#5560 feat(llmisvc): migrate non-zero threshold to prefix-based-pd-decider](https://github.com/kserve/kserve/pull/5560)** — 完成 v0.6 → v0.7 调度迁移:`threshold: 0` 走 `always-disagg-pd-decider`(#5433 已做),`threshold > 0` 自动换算为 `prefix-based-pd-decider` 的 `nonCachedTokens = ceil(threshold / 4)`(英文 4:1 字符/token 比),并日志提示用户重新调优。**这是 v0.18 后续在调度配置语义上彻底告别 v0.6 的最后一块**
  - **[#5533 fix(llmisvc): set workload service appProtocol based on TLS config](https://github.com/kserve/kserve/pull/5533)** — workload Service 之前不论 TLS 与否都写 `Name: https / AppProtocol: https`,Traefik 等 Gateway API 实现会把它当 HTTPS 上游,非 TLS 的 vLLM 直接连不上。修复后按 `config.EnableTLS` 设置
  - [#5568 fix(llmisvc): wait for pod termination before starting next test](https://github.com/kserve/kserve/pull/5568) — `delete_llmisvc` 改为同步等 pod 真正 Terminating 结束,CI 在低规格节点上(4 CPU/14 GB)的 back-to-back 测试稳定下来
  - [#5577 chore: add bump-version Copilot agent and release issue template](https://github.com/kserve/kserve/pull/5577) — 发版流程加 Copilot agent + 模板
- 启示:**v0.17.1 是给"已锁老线"的 cherry-pick,主线方向看 #5560 / #5533**。#5560 把 v0.6 的 `threshold` 配置兼容性彻底解决,任何还停在 v0.6 schema 的 llmisvc 都能无痛升级,**OAI fork 把 v0.6 → v0.7 升级阻塞清掉了**;#5533 是产品在 mesh-heavy 部署的真实问题,**同周 Feast #6367 修了对偶问题(gRPC 缺 appProtocol)**,值得在 OAI 自家组件 Service 元数据上统一审一遍

### Ray
- 本窗口无新 release(最近 ray-2.55.1 在 2026-04-22),59 个合入 commit;2026-05-22 后新增信号(整窗口大头在 05-22 之前,见 [2026-05-22 digest](./2026-05-22-ai-infra-ecosystem.md#ray)):
  - [#63521 [Core] (Resource Isolation 16/n) Consider all idle workers for OOM killing policy](https://github.com/ray-project/ray/pull/63521) — idle worker 内存外溢导致的 OOM 调度策略改进,**长跑 Ray 集群的内存稳定性**
  - [#63638 Improve State API filter key handling](https://github.com/ray-project/ray/pull/63638)
  - [#63551 Removing destroyed_actors_ cache](https://github.com/ray-project/ray/pull/63551)
  - [#63578 Retries and better logging when querying prometheus server fails](https://github.com/ray-project/ray/pull/63578)
  - [#63546 [doc] Add GKE Gateway example for ingress](https://github.com/ray-project/ray/pull/63546) — GKE Gateway 接入示例
- 启示:**HAProxy 大潮在 05-20 那波;05-22 之后 Ray Serve 没有新主轴**。Resource Isolation 16/n 是 Core 的多租户基线渐进改进,**对长跑生产 Ray 集群有用**

### KubeAI(原 substratusai/lingo)
- 本窗口无 release,**0 个 commit**(连续两期为 0) — 项目活跃度持续低,**对标可考虑从季度跟踪改为半年跟踪**

## 训练 & 微调

- **LlamaFactory v1** 持续 push:
  - [#10507 [v1] Implement dynamic padding-free strategy for batching](https://github.com/hiyouga/LlamaFactory/pull/10507) — 上期 #10469 是 FlashAttention selection + 三种 batching 模式,这次把 dynamic padding-free 真正实现
  - [#10513 [v1] fix padding free with sp](https://github.com/hiyouga/LlamaFactory/pull/10513) — sequence parallel 下 padding-free 修复
  - 启示:**v1 进入"功能补完 + bug 收敛"节奏**,跟踪到 v1 第一个 GA 版本即可
- **Kubeflow Trainer**:
  - [#3324 feat(api): Add terminationGracePeriodSeconds to PodSpecPatch in TrainJob](https://github.com/kubeflow/trainer/pull/3324) — `RuntimePatches` 加 `terminationGracePeriodSeconds`,**支撑 PyTorch Elastic 的 JIT checkpoint**:节点 drain / Job 暂停时 Kubelet 发 SIGTERM,torchrun agent 转给 worker 做 checkpoint,默认 30s 不够。**对我们做"训练任务可中断 + 检查点"的产品形态有直接价值**

## 模型生命周期(MLflow / Hub / Feast)

### MLflow
- **[v3.13.0rc0(2026-05-22)](https://github.com/mlflow/mlflow/releases/tag/v3.13.0rc0)** — 上期已预告 rc 启动,这一周 rc0 正式发布,体量很大:
  - **RBAC + Admin UI**:legacy per-resource permission 表合并到 `role_permissions`、`/mlflow/users/permissions/*` 统一 per-user 权限 API、workspace 加 `USE` permission、prompt 升级为一级 `resource_type`、4 页 Admin UI(account widget、`/account`、Platform Admin、backend auth)开给 workspace manager([#22855](https://github.com/mlflow/mlflow/pull/22855) 等系列 stacked PR)
  - **Coding-Agent Plugins**:Claude Code / OpenClaw / Ollama / OpenAI Codex 全部接入 AI Gateway 成为 first-class assistant provider;新 Claude Code TS 插件 + setup wizard + `settings.local.json`;legacy `mlflow autolog claude` Python autolog 被官方插件替换;AI Gateway UI 直接创建 coding-agent endpoint
  - **Trace Archival**([#23359](https://github.com/mlflow/mlflow/pull/23359)) — 端到端 trace 归档:OTLP / artifact helper + SQLAlchemy 归档 pass + 归档后的查询回退 + workspace / experiment / server 级归档配置 UI
  - **Helm Charts** — first-class Helm chart 部署 MLflow 到 K8s,production-ready 配置 + ingress + persistence + `appVersion` 绑定镜像([#21973](https://github.com/mlflow/mlflow/pull/21973)
  - **`mlflow.genai.test_agent`** — GenAI agent 自动压测:生成对抗输入 / 回放 / 在 trace 里复盘([#22990](https://github.com/mlflow/mlflow/pull/22990))
  - **OpenTelemetry Span Links** — `LiveSpan.add_link()` 连接跨 trace 的因果 span([#22797](https://github.com/mlflow/mlflow/pull/22797))
  - **DB 读写分离** — SQL tracking store 支持 reader/writer 路由([#22910](https://github.com/mlflow/mlflow/pull/22910))
- 同周还合入([#23545](https://github.com/mlflow/mlflow/pull/23545)、[#23559](https://github.com/mlflow/mlflow/pull/23559)、[#22496](https://github.com/mlflow/mlflow/pull/22496)、[#23310](https://github.com/mlflow/mlflow/pull/23310)、[#22566](https://github.com/mlflow/mlflow/pull/22566)):
  - Claude Code 批量 tracing 的 WAL 组件(batch writer / clients / protocol / daemon supervisor)
  - AI Gateway 作为 MLflow Assistant 的后端
  - Google ADK LLM judge scorers(`Hallucination` / `Safety` / `ResponseEvaluation`)
  - GitRunContext 记录 run 的 git branch + repo URL
- 启示:**3.13 是把"实验跟踪 → AI Gateway → Coding-agent 平台 → K8s Helm 部署 → 自动压测"这一整圈打包**。对我们做 OAI 对标 / "AI 工厂"形态:
  - Helm chart 直接抄就行,避免我们自己写 manifest
  - RBAC 的"role_permissions 单表 + per-user API + USE permission"路线对我们多租户权限模型是参考实现
  - Coding-Agent 接入 AI Gateway 的形态(Claude Code / Codex / Ollama / OpenClaw 都是 provider)与 OAI 做 RHELAI 的 chat assistant 路线高度相关
  - `mlflow.genai.test_agent` 把 evaluation 的入口从"我准备测试集"改为"系统生成对抗样本",**是 LLM 评估面板下一步形态**

### Kubeflow Hub(原 model-registry)
- 本窗口 2026-05-22 后只有 3 个 commit:
  - [#2735 refactor(catalog): split OpenAPI spec into per-plugin files with independent generation](https://github.com/kubeflow/hub/pull/2735) — 继上周 #2724(unified plugin server)之后,把 catalog OpenAPI 也按 plugin 拆分,**plugin 化扩展模式继续在成型**
  - [#2726 Refactor filter components to share across model and MCP catalogs](https://github.com/kubeflow/hub/pull/2726) — 模型 catalog 与 MCP catalog 共享 filter 组件(注意:同一个 Hub 里现在有两个 catalog,普通模型 + MCP 工具)
  - [#2695 Update a couple references to model registry](https://github.com/kubeflow/hub/pull/2695) — 文档更名收尾
- 启示:**Hub 在做 model catalog ↔ MCP catalog 的"双 catalog"统一**,这与 MLflow 把 Coding-Agent 接入 AI Gateway 是同一个方向("AI 工厂"里模型 / 工具 / agent 都是一等公民)

### Feast
- 本窗口无 release,2026-05-22 后 5 个 commit:
  - **[#6401 feat: Add enabled/disabled toggle for feature views](https://github.com/feast-dev/feast/pull/6401)** — 给 feature view 加生命周期状态机(`CREATED → GENERATED → MATERIALIZING → AVAILABLE_ONLINE`)+ 运行时启停开关(`ENABLED / DISABLED`),只有 `state == AVAILABLE_ONLINE AND enabled == True` 才提供在线服务。**生产环境 feature view 灰度上线 / 紧急下线的能力上游补齐**
  - **[#6367 fix(operator): Set appProtocol: grpc on registry gRPC Service](https://github.com/feast-dev/feast/pull/6367)** — registry Service 缺 `appProtocol: grpc` 导致 Istio 把 gRPC 流量识别为 HTTP/1.1 → 连接被降级断开(local registry + `server.grpc` enabled 场景)。**与 KServe #5533 同周修的是对偶问题——上游对"Service 元数据 → 服务网格识别"的 cleanup 周**
  - [#6358 chore: Split integration tests out of unit suite](https://github.com/feast-dev/feast/pull/6358) — 测试矩阵拆分
  - [#6362 fix(go): skip registry refresh when cache_ttl_seconds <= 0](https://github.com/feast-dev/feast/commit/97ed40ca175e29cc1df30fb8d866f4cfc3f3d62c)
  - [PyJWT 2.10+ 空 HMAC key 修复](https://github.com/feast-dev/feast/commit/e756ffe26b0b4fd16e8f621269195f15f14340f4)
- 启示:**#6401 的"feature view 生命周期 + 启停开关"对应到 KServe 的 `LLMInferenceService` 也有同样诉求**——产品做 MaaS 时,模型服务从注册到上线、再到紧急下架,需要一套类似状态机;参考 Feast 的字段命名

## LLM 评估 & 安全

- **EleutherAI/lm-evaluation-harness**:**本窗口连续两期无任何 commit / release** — 进入完全维护模式,**跟踪频率可降为月度**
- **NVIDIA/garak**:3 个 commit,只有 [#1796 Fix malformed MISP tag on snowball detectors](https://github.com/NVIDIA/garak/pull/1796) 是修复,其他是 plugin cache 自动更新 — 无产品级新能力
- **ogx-ai/ogx(原 meta-llama/llama-stack)**:33 个 commit,12 个是 v1.0.x 热修;值得注意的产品级:
  - [#5877 feat(cli): add `ogx connect claude` command](https://github.com/ogx-ai/ogx/commit/65fb13381a2e193600e3db439aab6dda40a43f1f) — CLI 直接接 Claude provider,**对应 MLflow 把 Claude Code / Codex 接入 AI Gateway 的同一周共识"agent provider 入栈"**
  - [#5894 fix(api)!: add post-generation schema transforms for Responses API conformance](https://github.com/ogx-ai/ogx/commit/83ed3173cd8a0293fd9a62d49908edac9f4684e3) — **breaking**:Responses API 的 schema conformance 修正
  - [#5934 test(security): add ABAC test coverage for vector store create](https://github.com/ogx-ai/ogx/commit/583c0b0f6265d7ce053dd317072a14858fe10a83)、[#5931 fix(security): add authorization check to AuthorizedSqlStore.upsert](https://github.com/ogx-ai/ogx/commit/d24faac24ab0d5a48c5ca08a94384636086c46af) — ABAC + Authorized SQL store 这条线持续补
  - [#5917 feat(vllm): populate embedding metadata from models.dev](https://github.com/ogx-ai/ogx/commit/11c174c9b1a351b1db382ee85604670a7061edcd)、[#5918 feat(cli/letsgo): add VLLM_API_TOKEN support to provider autodetection](https://github.com/ogx-ai/ogx/commit/463e82e46951bcaa290cd1e874d54878e7ad4c46) — vLLM 作为 provider 集成在补
- 启示:**ogx + MLflow 同周都在做"Claude / Codex 等 coding agent 作为 first-class provider"的接入**,这是"AI 工厂"形态对外接 agent 的事实标准在形成

## 值得跟进

- [ ] **MLflow 3.13.0rc0 试用**:在 staging 部一份(用上游新发的 Helm chart),重点验:RBAC 单表新模型 / Coding-Agent Plugin 与 AI Gateway 联动 / Trace Archival;评估 OAI 自家 pipeline 控制面对接 MLflow 3.13 的成本
- [ ] **TRT-LLM v1.3.0rc16 的 KV cache manager v2(#12928)+ hybrid disagg block reuse(#14060)+ disagg OTel(#12637)**:与 rc15 的 `cache_salt_id` 一起,作为我们 MaaS KV 隔离与 disagg 可观测的完整参考
- [ ] **SGLang sgl-router(#25851)+ mooncake_tcp(#26346)**:评估"非 K8s gateway 路径"的客户场景;若有客户在无 RDMA 环境跑 PD disagg,可以直接试 mooncake_tcp 路径
- [ ] **KServe llmisvc 调度迁移收尾(#5560)+ Service appProtocol 修复(#5533)**:OAI fork 把 v0.6 → v0.7 的最后调度配置兼容性问题清掉了,任何还停在 v0.6 schema 的 LLMInferenceService 都能升级;同时审一遍 OAI 自家组件的 Service 元数据(对照 Feast #6367 同周修的对偶问题)
- [ ] **vLLM non-root docker target(#40275)**:`vllm-openai-nonroot` 主线进库,OAI fork 可以把私有 patch 撤掉
- [ ] **vLLM HMA 默认开(#41847)+ 文件系统二级 KV tier(#41735)**:与 KServe v0.18 storage migration 一并评估,作为 KV 分层的产品方案
- [ ] **Kubeflow Trainer terminationGracePeriodSeconds(#3324)**:做"训练任务可中断 + 检查点"产品形态时,这是 PodSpec 必须暴露的字段
- [ ] **Feast feature view 生命周期 + 启停开关(#6401)**:对应到 LLMInferenceService 也有同样需求,参考字段命名
- [ ] **MLflow `mlflow.genai.test_agent`(#22990)**:LLM 评估面板下一步形态是"系统生成对抗样本",值得评估接入

## 原始材料

<details>
<summary>本窗口内 release(2026-05-20 后)</summary>

- KServe v0.17.1(2026-05-21)— 前半窗口,见 2026-05-22 digest
- TensorRT-LLM v1.3.0rc15(2026-05-21)— 前半窗口,见 2026-05-22 digest
- **MLflow v3.13.0rc0(2026-05-22)— NEW(大版本 rc0)**
- **SGLang v0.5.12.post1(2026-05-26)— NEW(DSV4 稳定性 patch)**
- **TensorRT-LLM v1.3.0rc16(2026-05-26)— NEW**
- vLLM、Ollama、Ray、TGI、KubeAI、Trainer、LlamaFactory、Feast、garak、lm-eval、Hub、ogx 本窗口无新 release
</details>

<details>
<summary>本窗口合入 commit 计数(整窗口 / 仅 2026-05-22 后,过滤 merge/bump/CI 噪音前)</summary>

- SGLang:247 / 100+(注:重叠期 sgl-router 单 PR 即 141 commits)
- vLLM:191 / 80+
- TensorRT-LLM:154 / 60+
- MLflow:68 / 40+
- Ray:59 / 9
- ogx(原 llama-stack):33 / 15
- kubeflow/hub:28 / 3
- KServe:13 / 4
- feast:10 / 5
- garak:9 / 3
- hiyouga/LlamaFactory:8 / 2
- ollama:7 / 2
- kubeflow/trainer:3 / 1
- 0 commit(整窗口):TGI、KubeAI、lm-evaluation-harness、kubeflow/training-operator(已并入 kubeflow/trainer)
</details>

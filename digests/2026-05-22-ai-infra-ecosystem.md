# AI 推理 & MLOps 生态周报 2026-05-22

窗口:2026-05-15 → 2026-05-22(7 天)。前半窗口与 [2026-05-20 digest](./2026-05-20-ai-infra-ecosystem.md) 重叠,本报告以 2026-05-20 之后的新信号为主轴,前半窗口仅留指针。

## 摘要(5 条以内)
- **KServe llmisvc 把"模型路由"与"自治状态"补齐**:`v0.17.1` cherry-pick 发布([release notes](https://github.com/kserve/kserve/releases/tag/v0.17.1));主线合入 model-name 路由([#5521](https://github.com/kserve/kserve/pull/5521))、HPA/KEDA 状态回吐 LLMInferenceService([#5540](https://github.com/kserve/kserve/pull/5540))、GIE CRD 装/不装可选([#5544](https://github.com/kserve/kserve/pull/5544))、appliedConfigs 状态可观测([#5418](https://github.com/kserve/kserve/pull/5418))。这是上周 v0.18 后续打磨在产品维度的进一步成形,**直接对标我们 MaaS 侧"按模型/租户路由 + 状态可见"的能力线**
- **TensorRT-LLM `v1.3.0rc15`([release notes](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc15),2026-05-21)发布**:Gemma4 多模态(文/视/音 + chunked prefill)、Kimi K2.5 多模态视觉 + reasoning parser、DeepSeek V4/V3.2 新 attention kernel + tokenizer/路由更新、KV cache v2 加 `cache_salt_id`、统一异常分类层 + Slurm 失败分类、TRTLLM-Gen 内部路由 + LoRA broadcast 优化、Transformers 5.x 升级。NV 闭源栈进入与 vLLM/SGLang 同步的"DSv4 + Gemma4 + Kimi K2.5"模型基线
- **Ray Serve 的 HAProxy 路径默认化**:本周合入大量 HAProxy 相关 PR——HAProxy 拼接(splice)默认开([#63531](https://github.com/ray-project/ray/pull/63531))、ingress 路由指标暴露([#63356](https://github.com/ray-project/ray/pull/63356))、AsyncioRouter pick-only 快速路径([#63517](https://github.com/ray-project/ray/pull/63517))、夜测加 HAProxy 变体([#63386](https://github.com/ray-project/ray/pull/63386))、跨节点 0.0.0.0 绑定([#62515](https://github.com/ray-project/ray/pull/62515))。Ray Serve 把"高性能代理"从 Python Proxy 切到 HAProxy,**inference router 选型若押 Ray Serve,需要重新评估 HAProxy 路径的运维契约**
- **MLflow 在补"Tracing → 编程代理"的链路**:加入 OpenAI Codex CLI 作为 assistant provider([#22566](https://github.com/mlflow/mlflow/pull/22566))/cherry-pick([#23517](https://github.com/mlflow/mlflow/pull/23517))、Claude Code Tracing 的 WAL 异步导出基础设施([#23464](https://github.com/mlflow/mlflow/pull/23464)、[#23511](https://github.com/mlflow/mlflow/pull/23511));同周还加入 executor framework 的 job store lifecycle API([#23128](https://github.com/mlflow/mlflow/pull/23128))。MLflow 在做"实验跟踪 → coding agent 平台"的扩边
- **Feast 出官方 MLflow 集成**([#6235](https://github.com/feast-dev/feast/pull/6235)):特征检索 metadata 自动打到当前 MLflow run + entity DataFrame 归档,**Feature Store ↔ 实验跟踪闭环上游 GA**。同周还合入 RBAC-compliant 注册中心 REST API + 懒加载 UI([#6420](https://github.com/feast-dev/feast/pull/6420)、[#6414](https://github.com/feast-dev/feast/pull/6414)),Registry 的 proto-dump 路径被替换。叠加上周的 MCP 暴露(#6304),Feast 把自己同时挂到 agent 调用链 + MLflow 实验跟踪 + RBAC UI 三条线

## 推理引擎动态

### vLLM
- 本窗口 release:[v0.21.0(2026-05-15)](https://github.com/vllm-project/vllm/releases/tag/v0.21.0)— 详见 [2026-05-20 digest](./2026-05-20-ai-infra-ecosystem.md#vllm)
- 2026-05-20 之后的新增信号(79 个 PR):
  - **Rust 前端集成正式落地**:[#40848 [Frontend][RFC] Rust front-end integration](https://github.com/vllm-project/vllm/pull/40848) + [#43283 Move code from `vllm-frontend-rs`](https://github.com/vllm-project/vllm/pull/43283) — 由 `VLLM_USE_RUST_FRONTEND=1` 启用,POC 已合入主线。这是 vLLM 前端开销下沉到 Rust 的第一步,长期会影响 OpenAI 兼容 API 的延迟基线
  - [#40841 [Frontend] DP Supervisor](https://github.com/vllm-project/vllm/pull/40841) — 数据并行的监督节点,暴露 `/health` `/readyz` 端口便于编排器探活。多副本 DP 部署的 K8s 集成将更直接
  - [#43105 [Core] Add native ModelExpress load format](https://github.com/vllm-project/vllm/pull/43105) — 新 `--load-format modelexpress`,委派给 ModelExpress 包做对象存储加速加载。对 LLM 镜像分发 / 模型仓库选型有影响
  - [#41753 [ROCm] Add XGMI backend for MoRI Connector](https://github.com/vllm-project/vllm/pull/41753) — MoRI KV connector 走 XGMI 路径,可在单节点跑 PD 拆分而不依赖 RDMA 驱动
  - [#43148 Mark env vars covered by `--moe-backend` / `--linear-backend`](https://github.com/vllm-project/vllm/pull/43148) — 旧 env var 进入 deprecation,镜像基线脚本要扫一遍
  - [#43168 [Frontend] Rework fastokens integration](https://github.com/vllm-project/vllm/pull/43168)
  - [#43378 fix dockerfile dependency graph for pre-commit](https://github.com/vllm-project/vllm/pull/43378)、[#43292 Pin protoc binary](https://github.com/vllm-project/vllm/pull/43292) — 与 Rust 前端联动的镜像基线收口
- 启示:**Rust 前端 + DP Supervisor 是 vLLM 向"产品级运行时"演进的两条线**。Rust 前端落地后,运行时启动行为(`build_rust.sh` / `VLLM_USE_RUST_FRONTEND`)成为镜像构建的新分支,在 OAI fork 维护 Dockerfile 的同时要规划"何时启用 Rust 前端"。`--load-format modelexpress` 提供对象存储友好的加载路径,与 KServe storage migration(v0.18)是同一条产品诉求

### SGLang
- 本窗口 release:[v0.5.12(2026-05-16)](https://github.com/sgl-project/sglang/releases/tag/v0.5.12)— 详见 [2026-05-20 digest](./2026-05-20-ai-infra-ecosystem.md#sglang)
- 2026-05-20 之后的新增信号(97 个 PR):
  - **DSv4 JIT 内核大清理**:[#25884 [Refactor] major JIT kernel clean up for dsv4](https://github.com/sgl-project/sglang/pull/25884) — `deepseek_v4.py` 拆分多文件、复用 `torch.mm`、统一 `topk` cuh
  - **Gemma4 NVFP4 MoE**:[#25054 Support Gemma4 MoE NVFP4](https://github.com/sgl-project/sglang/pull/25054) — `nvidia/Gemma-4-26B-A4B-NVFP4`,默认 `flashinfer_trtllm` MoE runner。与 TRT-LLM v1.3.0rc15 的 Gemma4 同周对齐
  - **HybridLinearKVPool + chunked prefix cache**:[#25753](https://github.com/sgl-project/sglang/pull/25753) — Bailing-2.6-Flash 这类 hybrid 模型(linear attention + softmax 混合层)首次拿到分片前缀缓存支持
  - **Spec V2 FutureMap 收尾**:[#25879 Route seq_lens through FutureMap; drop verify_done.wait](https://github.com/sgl-project/sglang/pull/25879)、[#25922 Unify output_tokens_buf in FutureMap](https://github.com/sgl-project/sglang/pull/25922)、[#25944 step 1: route non-spec seq_lens via FutureMap](https://github.com/sgl-project/sglang/pull/25944) — 投机 / 非投机路径状态机统一,异步同步开销下降
  - **MegaMoE 默认 W4A8**:[#26004 Default MegaMoE to W4A8 for Max-Throughput recipe](https://github.com/sgl-project/sglang/pull/26004) — Blackwell 上 Max-Throughput recipe 自动跳 W4A8,Hopper / low-latency / cp 不动
  - [#25923 [Docs] DeepSeek-V4: switch H200 FP4 Pro to flashinfer_mxfp4, Flash Balanced too](https://github.com/sgl-project/sglang/pull/25923) — 部署 recipe 文档随 kernel 变更更新
  - [#26012 init hisparse_coordinator before attn_backend](https://github.com/sgl-project/sglang/pull/26012) — HiSparse KV 卸载初始化时序修正
  - [#25531 [lora] Remove synchronous `.any().item()` guard in LoRA MoE prefill](https://github.com/sgl-project/sglang/pull/25531)
  - [#25988 [diffusion] enable warmup for sglang serve by default](https://github.com/sgl-project/sglang/pull/25988)、[#25661 FLUX.2-klein-base 模型支持](https://github.com/sgl-project/sglang/pull/25661) — diffusion 路线持续加固
- 启示:Spec V2 进入"清理 / 路径合一"阶段,投机解码不再是分支特性而是底座;Gemma4 NVFP4 + MegaMoE W4A8 是与 vLLM/TRT-LLM 同样的 "Blackwell 默认量化推荐变 W4A8" 信号

### TensorRT-LLM
- **[v1.3.0rc15(2026-05-21)](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc15)** — 距 rc14(2026-05-07)两周,100+ PR
- 模型与基线:
  - Gemma4 多模态(文/视/音 + chunked prefill)([#12932](https://github.com/NVIDIA/TensorRT-LLM/pull/12932)、[#14134](https://github.com/NVIDIA/TensorRT-LLM/pull/14134))
  - Kimi K2.5 多模态视觉 + reasoning parser([#12788](https://github.com/NVIDIA/TensorRT-LLM/pull/12788)、[#13801](https://github.com/NVIDIA/TensorRT-LLM/pull/13801))
  - GPT-OSS / Ministral3 / Nemotron-H / Nemotron Nano / DeepSeek 兼容性([#12743](https://github.com/NVIDIA/TensorRT-LLM/pull/12743)、[#12884](https://github.com/NVIDIA/TensorRT-LLM/pull/12884)、[#13844](https://github.com/NVIDIA/TensorRT-LLM/pull/13844)、[#13977](https://github.com/NVIDIA/TensorRT-LLM/pull/13977))
  - DeepSeek V4 / V3.2 新 attention kernel + routing + tokenizer + AutoConfig 注册([#13652](https://github.com/NVIDIA/TensorRT-LLM/pull/13652)、[#13186](https://github.com/NVIDIA/TensorRT-LLM/pull/13186)、[#14261](https://github.com/NVIDIA/TensorRT-LLM/pull/14261)、[#14293](https://github.com/NVIDIA/TensorRT-LLM/pull/14293))
- API / 运行时:
  - 统一异常分类层 + retry-consumer + Slurm 失败类型([#13732](https://github.com/NVIDIA/TensorRT-LLM/pull/13732)、[#13780](https://github.com/NVIDIA/TensorRT-LLM/pull/13780)、[#13863](https://github.com/NVIDIA/TensorRT-LLM/pull/13863)、[#13809](https://github.com/NVIDIA/TensorRT-LLM/pull/13809)、[#14147](https://github.com/NVIDIA/TensorRT-LLM/pull/14147))— 大规模部署可观测性的基础设施
  - KV cache v2 加 `cache_salt_id`([#13793](https://github.com/NVIDIA/TensorRT-LLM/pull/13793)) — 多租户 KV 隔离能力
  - per-rank iteration stats + Attention-DP metrics 暴露给 serving 端点([#13221](https://github.com/NVIDIA/TensorRT-LLM/pull/13221)、[#13649](https://github.com/NVIDIA/TensorRT-LLM/pull/13649))
  - VisualGen 公共输出 API + serving batch inference([#13635](https://github.com/NVIDIA/TensorRT-LLM/pull/13635)、[#12350](https://github.com/NVIDIA/TensorRT-LLM/pull/12350))
  - 限制 sampling logprobs 数量(**breaking**:[#13520](https://github.com/NVIDIA/TensorRT-LLM/pull/13520))
- Kernel / Disagg:
  - MegaMoE DeepGEMM、CUTEDSL MoE、shared-expert SwiGLU 量化、bf16 FlashInfer MoE([#13384](https://github.com/NVIDIA/TensorRT-LLM/pull/13384)、[#11897](https://github.com/NVIDIA/TensorRT-LLM/pull/11897)、[#13689](https://github.com/NVIDIA/TensorRT-LLM/pull/13689))
  - FP4 / FP8 decode kernel、FP4 DSA indexing、FMHA head_dim 80 cubins([#13929](https://github.com/NVIDIA/TensorRT-LLM/pull/13929)、[#13219](https://github.com/NVIDIA/TensorRT-LLM/pull/13219)、[#13340](https://github.com/NVIDIA/TensorRT-LLM/pull/13340)、[#13808](https://github.com/NVIDIA/TensorRT-LLM/pull/13808))
  - transceiver v2 KV reuse、多线程 KV 传输、TRTLLM-Gen 内部路由、LoRA 请求广播削减([#13115](https://github.com/NVIDIA/TensorRT-LLM/pull/13115)、[#13075](https://github.com/NVIDIA/TensorRT-LLM/pull/13075)、[#13997](https://github.com/NVIDIA/TensorRT-LLM/pull/13997)、[#13656](https://github.com/NVIDIA/TensorRT-LLM/pull/13656)、[#12959](https://github.com/NVIDIA/TensorRT-LLM/pull/12959))
  - 推测解码:fractional 合成接受率、MTP block reuse、EAGLE3 rejection sampling([#13569](https://github.com/NVIDIA/TensorRT-LLM/pull/13569)、[#12896](https://github.com/NVIDIA/TensorRT-LLM/pull/12896)、[#12588](https://github.com/NVIDIA/TensorRT-LLM/pull/12588))
- Infra:
  - Transformers 5.x 升级([#13994](https://github.com/NVIDIA/TensorRT-LLM/pull/13994)) — 与 vLLM v0.21 的 `transformers v4 废弃` 形成上游共识
  - flashinfer 0.6.10 升级([#13746](https://github.com/NVIDIA/TensorRT-LLM/pull/13746))
  - SBSA wheel 镜像、CMake 三方缓存([#12829](https://github.com/NVIDIA/TensorRT-LLM/pull/12829)、[#13942](https://github.com/NVIDIA/TensorRT-LLM/pull/13942))
- 启示:**TRT-LLM 在做"统一异常分类 + 多租户 KV salt + 暴露 per-rank 指标"的产品级基础设施**,这条线和 KServe llmisvc 本周做的"appliedConfigs + 路由 + HPA 状态"对应——上下游同时在补"大规模 LLM 部署的可观测性"。`cache_salt_id` 是若我们做 MaaS,**最值得直接引用的 KV 隔离原语**

### Ollama
- 本窗口无新 release(上次 v0.24.0 在 2026-05-14 早于窗口,v0.30.0-rc22 在 2026-05-13)
- 关键 PR:
  - [#16230 launch: enriched model inventory](https://github.com/ollama/ollama/pull/16230) — `ollama launch` 模型清单丰富化
  - [#16215 Reduce startup model hydration](https://github.com/ollama/ollama/pull/16215)
  - [#15795 launch: add codex model metadata catalog](https://github.com/ollama/ollama/pull/15795)、[#16163 docs: add codex app docs](https://github.com/ollama/ollama/pull/16163)、[#16231 codex: omit patch tool type](https://github.com/ollama/ollama/pull/16231) — Codex App 接入收尾
- 启示:与产品对接无直接接口,但 Ollama 把"开发者本地 + coding agent"覆盖面继续扩,值得留意"本地 + 云端服务一致性"诉求

### TGI
- 本窗口无 release、0 PR — 维护模式确认,对标可下沉

## 模型服务 & 编排

### KServe(上游)
- **[v0.17.1(2026-05-21)](https://github.com/kserve/kserve/releases/tag/v0.17.1)** — cherry-pick 类小版本,包含 0.17.0 安装脚本回填([#5257](https://github.com/kserve/kserve/pull/5257))、helm chart 修复([#5556](https://github.com/kserve/kserve/pull/5556)),用于已锁 v0.17 线的产品分支
- 主线本周新增信号(2026-05-20 之后,11 个 PR):
  - **[#5521 feat(llmisvc): add model name based routing](https://github.com/kserve/kserve/pull/5521)** — 通过 `X-Gateway-Model-Name` header 在共享网关里路由到不同模型,LoRA adapter 匹配在 Go 端按 template 后动态扩展。和 llm-d BBR / Gateway native 能力兼容
  - **[#5540 feat(llmisvc): bubble up HPA/KEDA scaling status to service conditions](https://github.com/kserve/kserve/pull/5540)** — `ScalingReady` / `PrefillScalingReady` 两条 condition,聚合到 `WorkloadsReady`,`kubectl get/describe` 一眼可见 HPA / ScaledObject 健康
  - **[#5544 feat(charts): make llmisvc GIE CRD creation optional](https://github.com/kserve/kserve/pull/5544)** — 新 `kserve.llmisvc.createGIECRDs` Helm value,共享集群里 GIE CRDs 由其他 chart 管时可关掉,**这是 OAI fork 在共集群部署时必须开启的安全阀**
  - [#5418 feat(llmisvc): observed applied configs](https://github.com/kserve/kserve/pull/5418) — `status.appliedConfigs` 暴露 Preset / UserRef 顺序,Config merge 调试不再靠脑补
  - [#5524 feat(llmisvc): track gateway origin on each discovered address](https://github.com/kserve/kserve/pull/5524) — 多 Gateway 场景下 URL 与 Gateway 绑定,方便消费者按 Gateway 选端点
  - [#5508 fix: pin azure-core>=1.38.0 (CVE-2026-21226)](https://github.com/kserve/kserve/pull/5508)
  - [#5562](https://github.com/kserve/kserve/pull/5562)、[#5552](https://github.com/kserve/kserve/pull/5552)、[#5528](https://github.com/kserve/kserve/pull/5528) — CI / 日志噪音收口
- 启示:**v0.17.1 是给"已落地老线"的兜底,v0.18 后续才是产品方向**。本周三条 llmisvc 新能力——model-name 路由(#5521)+ scaling 状态(#5540)+ GIE CRD 开关(#5544)——是 OAI 在多 LoRA / 共享网关 / 自治可观测三个轴上**最低成本就能拉进来的改动**。我们若要做"按模型路由 + 一眼看 scaling"的能力,这三个 PR 直接抄

### Ray
- 本窗口无新 release(最近 ray-2.55.1 在 2026-04-22),107 个 PR;窗口内有清晰主线
- **Serve / HAProxy 主轴**:
  - [#63531 [serve] Enable splice in haproxy by default](https://github.com/ray-project/ray/pull/63531) — HAProxy splice 默认开,大 payload 拷贝消除
  - [#63356 [serve] haproxy ingress request router metrics](https://github.com/ray-project/ray/pull/63356) — `serve_haproxy_ingress_router_latency_ms` / `_truncations` 等观测指标
  - [#63517 [serve][LLM] Add pick-only fast path to AsyncioRouter for LLM ingress](https://github.com/ray-project/ray/pull/63517) — LLM 路由放弃 RPC 检查、靠 HAProxy 兜底
  - [#63386 [serve][release] Add HAProxy variant to throughput-optimized serve microbenchmarks](https://github.com/ray-project/ray/pull/63386) — 夜测把 HAProxy 路径纳入基线
  - [#63468 [serve][llm] Enable direct streaming for DP and PD builders](https://github.com/ray-project/ray/pull/63468) — DP / PD 流式
  - [#62515 [serve] Bind direct ingress ports to 0.0.0.0 for cross-node HAProxy routing](https://github.com/ray-project/ray/pull/62515)
  - [#63556 [serve] Expose controller health metrics via `/api/serve/applications/`](https://github.com/ray-project/ray/pull/63556)
  - [#63415 HAProxy retry knobs](https://github.com/ray-project/ray/pull/63415)(已在上期提及)
- **Core / TPU**:
  - [#63171 [Core][TPU] Improve lifecycle handling of `SlicePlacementGroup` and support explicit `bundle_label_selector`](https://github.com/ray-project/ray/pull/63171)
  - [#63177 [LLM] Add per-host bundles default and fix fractional TPUs in default bundles for `TPUAccelerator`](https://github.com/ray-project/ray/pull/63177)
  - [#63520 Remove experimental `_owner` support for `ray.put`](https://github.com/ray-project/ray/pull/63520) — 旧实验 API 收口
- **Data**:
  - [#63582 [Data] Reorder block columns by name before positional schema ops](https://github.com/ray-project/ray/pull/63582)、[#63325 Report spilling and Fail Release Tests on Unexpected Spills](https://github.com/ray-project/ray/pull/63325)
- 启示:**Ray Serve 押注 HAProxy 路径,Python Proxy 不再是首要演进点**。若我们用 Ray Serve 做 inference ingress,产品形态要把 HAProxy 配置(splice / bufsize / 路由 metrics)纳入运维 SLI;同时,Python Proxy 的迁移 deadline 越来越近。TPU 侧 #63171 / #63177 是 TPU 多租户场景下的现成参照

### KubeAI(原 substratusai/lingo)
- 本窗口无 release,0 个合入 PR — 持续低活跃,对标继续观察即可

## 训练 & 微调

- **LLaMA-Factory(已改名 [hiyouga/LlamaFactory](https://github.com/hiyouga/LlamaFactory))**:**v1 重构活跃化**(上期"无任何 commit"的反差)
  - [#10469 [v1] Add FlashAttention selection and implement normal / padding-free / dynamic batching](https://github.com/hiyouga/LlamaFactory/pull/10469) — v1 引入动态批处理与 padding-free
  - [#10493 [v1] support liger_kernel](https://github.com/hiyouga/LlamaFactory/pull/10493) — liger kernel 整合
  - [#10481 [V1] add cuda fused moe kernel, implementing with triton](https://github.com/hiyouga/LlamaFactory/pull/10481) — MoE 训练自带融合 kernel
  - [#10431 [V1] support reward training stage](https://github.com/hiyouga/LlamaFactory/pull/10431) — RM stage 进入 v1
  - [#10463 add torch profiler callback](https://github.com/hiyouga/LlamaFactory/pull/10463)
  - 启示:**LlamaFactory v1 与稳定线(`v0.9.4`,2025-12-31)正在并行迭代**,国内社区主力微调框架的"产品化重写"刚开始;若我们 OAI 端的 fine-tune 体验对标这个用户群,v1 trainer/算子矩阵要列入跟踪
- **Kubeflow Trainer**:
  - [#3302 fix(runtimes): add validation for LoRA multi-node and immutable trainer args](https://github.com/kubeflow/trainer/pull/3302) — LoRA 多机训练参数校验 + 不可变 trainer args
  - [#3530 feat(ci): add Python dependency scanning to OSV-Scanner workflow](https://github.com/kubeflow/trainer/pull/3530)
  - 启示:LoRA 多机训练这条产品线终于有上游运行时验证

## 模型生命周期(MLflow / Hub / Feast)

### MLflow
- 本窗口 release:[ts/v0.2.0(2026-05-15)](https://github.com/mlflow/mlflow/releases/tag/ts/v0.2.0)— TS SDK 0.2.0,前半窗口已在 [2026-05-20 digest](./2026-05-20-ai-infra-ecosystem.md) 提及
- 2026-05-20 之后的 35 个 PR 主线:
  - **Coding agent 入栈**:[#22566 Add OpenAI Codex CLI as assistant provider](https://github.com/mlflow/mlflow/pull/22566) + [#23517 Cherry-pick](https://github.com/mlflow/mlflow/pull/23517) — Codex CLI 作为 MLflow assistant provider(此前已经有 Claude Code)
  - **Tracing 异步导出基础设施**:[#23464 Add WAL foundational files for async batch trace export for TS claude code integration](https://github.com/mlflow/mlflow/pull/23464) + [#23511 Adding storage layer changes for Claude Code tracing WAL batch processing](https://github.com/mlflow/mlflow/pull/23511)
  - **Executor 框架雏形**:[#23128 feat: Add job store lifecycle APIs for executor framework](https://github.com/mlflow/mlflow/pull/23128) — 配合 [`mlflow/rfcs#2`](https://github.com/mlflow/rfcs/pull/2)
  - [#23371 Document trace archival setup and behavior](https://github.com/mlflow/mlflow/pull/23371)、[#23423 Add metric filter to AI Gateway overview](https://github.com/mlflow/mlflow/pull/23423)、[#23486 MLflow kubernetes deployment guide](https://github.com/mlflow/mlflow/pull/23486)
  - [#23491 Bump version to 3.13.0rc0](https://github.com/mlflow/mlflow/pull/23491)、[#23490](https://github.com/mlflow/mlflow/pull/23490)、[#23485](https://github.com/mlflow/mlflow/pull/23485) — 3.13 release 启动
  - 安全:[#23294 Remove dead cloudpickle.load fallback in job subprocess entry](https://github.com/mlflow/mlflow/pull/23294)、[#23496 Reserve `__user_` role-name prefix](https://github.com/mlflow/mlflow/pull/23496)、[#23413 Reject same-password rotations](https://github.com/mlflow/mlflow/pull/23413)
- 启示:**MLflow 3.13 的两条主轴:Tracing → coding-agent + executor → job-store**。若我们要做"AI 工厂"形态(模型 / 流水线 / 评估一体),3.13 是个 inflection 版本,要对照 MLflow 的 executor RFC 评估我们流水线层的对接面;`appVersion` 已经走 rc0,正式版可能两到三周内到位

### Kubeflow Hub(原 model-registry)
- 本窗口 14 个 PR(主要在 05-20 之后),除依赖 bump 外两条产品级:
  - **[#2724 feat(catalog): add unified plugin server](https://github.com/kubeflow/hub/pull/2724)** — catalog server 由直连 model+MCP catalog 改为 plugin orchestrator(`Init` / `MountRoutes` / `Start` / `Stop` / `NotifyLeader`),为未来添加新 catalog 类型留出扩展点;直接配合 `CatalogPlugin` 接口 + 全局注册表
  - [#2730 Microcopy updates for tool calling](https://github.com/kubeflow/hub/pull/2730) — 配合上周的 model catalog tool calling 字段(#2687)做 UI 文案
  - [#2718 Fix the model type selector in model catalog](https://github.com/kubeflow/hub/pull/2718)、[#2683 "Clear all filters" appear in Model performance view](https://github.com/kubeflow/hub/pull/2683)
- 启示:Hub catalog 走向"插件化注册",对我们做"自家 catalog 扩展"(例如把 OAI 自定义 catalog 注入)的 PoC 是更友好的入口

### Feast
- 本窗口无 release(最近 0.63.0,2026-05-04),8 个 PR;但 05-20 之后含两条产品级:
  - **[#6235 feat: Feast-MLflow Integration](https://github.com/feast-dev/feast/pull/6235)** — feature retrieval metadata 自动打到 active MLflow run(`feast.feature_refs` / `feast.feature_views` / `feast.feature_service` / `feast.entity_count`),并可选归档 entity DataFrame。`feature_store.yaml` 一键开,这是 **Feast ↔ MLflow 闭环上游 GA**
  - **[#6420 fix: Replace registry proto dump with RBAC-compliant APIs in UI and feature servers](https://github.com/feast-dev/feast/pull/6420)** + [#6414 feat: REST API-backed UI for RBAC compatibility and per-page lazy loading](https://github.com/feast-dev/feast/pull/6414) — Registry 元数据访问路径由 proto-dump 切到 RBAC API,UI 走 REST + 懒加载。多租户 Feast 落地的关键一步
  - [#6421 chore(deps): Bump go 1.25.0 and grpc to fix CVE-2026-33186](https://github.com/feast-dev/feast/pull/6421)
- 启示:**Feast 在三条线同时收口:agent(MCP)、实验(MLflow)、UI(RBAC + REST)**。和上周的 MCP 暴露(#6304)叠加,Feast 正把自己从单纯 Feature Store 演成"AI 工厂"的元数据 hub。若我们要做 feature 平台,**MLflow tag + MCP 接入 + RBAC API** 这套组合就是参考实现

## LLM 评估 & 安全

- **EleutherAI/lm-evaluation-harness**:**本窗口无 commit / 无 PR / 无 release**(v0.4.12 在 2026-05-11 早于窗口),持续低活跃
- **NVIDIA/garak**:7 个 PR
  - [#1633 generator: add `simonw/llm` library support](https://github.com/NVIDIA/garak/pull/1633) — garak 接入 [simonw/llm](https://llm.datasette.io/) 作为 generator,扩了一条本地 / 多 provider 的红队入口
  - [#1788 avoid stored probename side-effects in evaluation](https://github.com/NVIDIA/garak/pull/1788)、[#1781 fix: improve data_path escape protections](https://github.com/NVIDIA/garak/pull/1781) — 评估正确性 / 安全收口
- **ogx-ai/ogx(原 meta-llama/llama-stack)**:窗口内合入 28 个 PR,2026-05-20 之后 11 个,多为 v1.0.x 热修(`fix(api)` / `fix(ui)` / `fix(cli)`),无新产品级 breaking;唯一新能力 [#5895 feat(messages): add URL image source and fix vision support in Messages API](https://github.com/ogx-ai/ogx/pull/5895)
- 启示:garak `simonw/llm` 接入对"红队基线扩 provider 矩阵"有帮助;ogx 进入 v1.0 修补期,暂无新 breaking,本周值得跟踪的是 [#5895](https://github.com/ogx-ai/ogx/pull/5895) 让 Messages API 支持 URL 图源——若做 vision MaaS,这是上游 fix

## 值得跟进
- [ ] **KServe llmisvc 三件套**:model-name 路由(#5521)+ scaling 状态(#5540)+ GIE CRD 开关(#5544)— 在 OAI fork 上评估同步引入的成本,优先做 #5544 防止共集群下 CRDs 冲突
- [ ] **TRT-LLM v1.3.0rc15 的 `cache_salt_id`(#13793)**:多租户 KV 隔离原语,值得作为我们 MaaS KV cache 设计的参考点
- [ ] **Ray Serve HAProxy 默认化**:若用 Ray Serve 做 inference router,需要确认我们的部署是否已开 HAProxy,并把 `serve_haproxy_ingress_router_*` 指标拉进 dashboard
- [ ] **MLflow 3.13 executor RFC**(#23128 + [`mlflow/rfcs#2`](https://github.com/mlflow/rfcs/pull/2)):评估我们流水线层是否要对齐 job store lifecycle 模型
- [ ] **Feast-MLflow 集成(#6235)**:若我们 feature 平台对接 MLflow,直接用上游集成更省事;同时把 RBAC REST API(#6414/#6420)路线加入 feature 平台路线图
- [ ] **vLLM Rust 前端(#40848/#43283)**:决定我们镜像基线何时启用 `VLLM_USE_RUST_FRONTEND`;`./build_rust.sh` 引入新构建步骤要纳入 OAI Dockerfile
- [ ] **vLLM `--load-format modelexpress`(#43105)**:与 KServe storage migration 一并评估,作为对象存储侧模型加载方案
- [ ] **LlamaFactory v1 路线**:RM stage(#10431)/ liger kernel(#10493)/ fused MoE kernel(#10481)/ padding-free batching(#10469)— 国内社区主力微调框架重写期,产品对标要跟版本
- [ ] **kubeflow/hub plugin server(#2724)**:若要做自家 catalog 扩展,选这个接入点而非旧的直连方式

## 原始材料

<details>
<summary>本窗口内 release</summary>

- vLLM v0.21.0(2026-05-15)— 前半窗口,详见 2026-05-20 digest
- SGLang v0.5.12(2026-05-16)— 前半窗口,详见 2026-05-20 digest
- MLflow ts/v0.2.0(2026-05-15)
- **TensorRT-LLM v1.3.0rc15(2026-05-21)— NEW**
- **KServe v0.17.1(2026-05-21)— NEW(cherry-pick patch on v0.17 line)**
- Ollama、Ray、TGI、KubeAI、Trainer、LlamaFactory、Feast、garak、lm-eval、Hub、ogx 本窗口无新 release
</details>

<details>
<summary>本窗口合入 PR 计数(整窗口 / 仅 2026-05-20 之后)</summary>

- SGLang:374 / 97
- vLLM:217 / 79
- TensorRT-LLM:208 / 100
- MLflow:119 / 35
- Ray:107 / 39
- ogx:28 / 11
- kubeflow/hub:24 / 14
- KServe:22 / 11
- feast:8 / 4
- garak:7 / 3
- LlamaFactory:7 / 6
- kubeflow/trainer:6 / 2
- ollama:7 / 1
- 0 PR(整窗口):TGI、KubeAI、lm-evaluation-harness、model-registry(已并入 kubeflow/hub)
</details>

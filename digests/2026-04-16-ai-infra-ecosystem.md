# AI 推理 & MLOps 生态周报 2026-04-16

窗口：2026-04-09 → 2026-04-16
扫描范围：15 个核心仓库

## 摘要（5 条以内）

1. **KServe 爆出 gRPC 鉴权绕过高危漏洞**（CVE-2026-33186），已合并修复 — 所有使用 gRPC 端口的部署需立即升级。
2. **KV Cache 压缩成为本周跨引擎最热主题**：vLLM 推进 per-token-head Int2/Int4 量化与 Layerwise KV 量化，Ollama 提交 TurboQuant（tq2/tq3）PR，SGLang 修复 Flashmla sparse MLA 精度问题。
3. **Ollama 7 天发布 4 个版本**（v0.20.5→v0.20.8-rc0），节奏极快：OpenClaw 多渠道集成、Copilot CLI、Gemma4 MLX 支持等全部落地。
4. **MLflow Gateway 护栏（Guardrails）体系基本成型**：创建/编辑/执行/删除全链路 PR 已合并，标志着 MLflow 从实验追踪平台向治理平台演进。
5. **Ray 2.55.0 正式发布**，带来 DataSourceV2 API；SGLang 集成被提升为用户指南级别文档。

---

## 推理引擎动态

### vLLM

本周无新版本发布，但提交活跃度极高（30+ commits）。核心方向集中在 KV Cache 压缩、投机解码、跨平台量化三条线。

| 方向 | 要点 |
|------|------|
| KV Cache 压缩 | Layerwise KV 量化模型热加载已合并 ([#38995](https://github.com/vllm-project/vllm/pull/38995))；per-token-head Int2/Int4 量化 + Triton 接口进行中 ([#39074](https://github.com/vllm-project/vllm/pull/39074))；KV offload + HMA 重构，从 KVEvents 移除 block_size ([#36644](https://github.com/vllm-project/vllm/commit/235e1f930a29f491e06fa89c2536576a71922d73)) |
| 投机解码 | DFlash speculators 配置解析已合并 ([#38300](https://github.com/vllm-project/vllm/commit/0b790a25013e6b63a51ba00fc7da70537b3b3191))；SPEED-bench 基准测试框架集成到 CLI ([#36029](https://github.com/vllm-project/vllm/commit/3cc328a4be4976f75ce016f60bc55beee4701d1b)) |
| 量化 & 算子融合 | Fused SiLU+Mul+per-token FP8 量化 Triton kernel ([#39952](https://github.com/vllm-project/vllm/pull/39952))；XPU MXFP4 量化算子 ([#39857](https://github.com/vllm-project/vllm/commit/fc701c80588c215f84af0b745edcf4d127e276bc))；CPU W4A16 AutoRound 支持 ([#38192](https://github.com/vllm-project/vllm/commit/60995c05b4ca3a26b92dfa7abed8f5db850301cc)) |
| 多租户 | LMCache cache_salt 透传，实现 per-user KV 缓存隔离 ([#39837](https://github.com/vllm-project/vllm/commit/ed333105520c9610daa17cfe6be21383513b9c34)) |
| 生态兼容 | transformers v5 升级已合并 ([#30566](https://github.com/vllm-project/vllm/commit/03f8d3a548ce9769f9fd89cb4505e8b77649c943))；Mooncake MLA+Eagle block-size 校验修复 ([#39596](https://github.com/vllm-project/vllm/commit/55e1a8e1035bddb0b5b63f9ddecc8b4e16fc3ef6))；NIXL 逻辑块 ID 转换修复 ([#39724](https://github.com/vllm-project/vllm/commit/41488f2acdc53eadbae98a316df47ba039589fe7)) |

**对我们的启示**：cache_salt 多租户隔离是云平台的刚需功能，值得在我们的推理网关层面适配透传。KV 量化路线（Int2/Int4 per-token-head）若落地，可显著降低长上下文场景的显存占用，建议在内部基准测试中提前跟进。

### SGLang

**v0.5.10.post1** 于 4/9 发布（[release](https://github.com/sgl-project/sglang/releases/tag/v0.5.10.post1)），修复 flashinfer jit cubin 下载问题。

本周重点：

- **Ray DP + DP attention**：RayEngine 正式支持数据并行和 DP attention ([#21887](https://github.com/sgl-project/sglang/commit/13a2cd748db5f83926ba43e8f17380aab77097e3))，自动创建 placement group ([#22898](https://github.com/sgl-project/sglang/commit/e8c6e54))，降低了多卡部署的配置门槛。
- **Context Parallelism 路线图**：Q2 2026 落地计划已公开 ([#21788](https://github.com/sgl-project/sglang/issues/21788))。
- **Flashmla sparse MLA kernel 精度修复** ([#22723](https://github.com/sgl-project/sglang/commit/113d654152cd7c4992e3e8610b44385cf6061753)) — 影响 DeepSeek 系列模型推理质量。
- **Per-image ViT cache for Kimi-K2.5**：避免 TP 场景下多余 CUDA context 创建 ([#22858](https://github.com/sgl-project/sglang/commit/8686f42acb3e33865735feda5b10a3c6f85cd145))。
- **CUTLASS FP8 GEMM 消除 nvjet memset 气泡** ([#22392](https://github.com/sgl-project/sglang/pull/22392)) — 针对分段 CUDA Graph 的性能优化。
- **AMD Qwen3.5 Triton 优化**：fused topk 输出内核 ([#22844](https://github.com/sgl-project/sglang/commit/b2af34be5404c3ca8f69642ea464470901871711))。
- HiCache 多项修复：CP 混合模型支持 ([#22782](https://github.com/sgl-project/sglang/commit/7d7fdc1))、内存释放逻辑 ([#22767](https://github.com/sgl-project/sglang/commit/3511c2d))、健康检查内存泄漏 ([#22882](https://github.com/sgl-project/sglang/commit/0a5c972))。
- Streaming session 稳定性：spec v2 bonus accounting ([#22651](https://github.com/sgl-project/sglang/commit/a4cf2ea))、overshoot 裁剪 ([#22897](https://github.com/sgl-project/sglang/commit/efc267c))、abort 处理重构 ([#22790](https://github.com/sgl-project/sglang/commit/aa78564))。
- FP4 import 容错处理 ([#21776](https://github.com/sgl-project/sglang/commit/4e480d5))。

**对我们的启示**：SGLang 的 RayEngine DP 支持使其在多卡/多节点场景中更易集成，Context Parallelism 路线图值得持续跟踪 — 若 Q2 落地，长序列推理的扩展方式会有质变。

### TensorRT-LLM

**v1.3.0rc11** 于 4/9 发布（[release](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc11)），新增 Mistral 4-small AutoDeploy 和 GlmMoeDsa EPLB 支持。

本周动态：

- **AutoDeploy 模型接入冲刺**：基础设施 PR 已合并 ([#12708](https://github.com/NVIDIA/TensorRT-LLM/commit/253f17eab5b06b9178ec7d2b44c2c522776cdf1d))，Qwen3.5 NVFP4 精度测试补充 ([#13014](https://github.com/NVIDIA/TensorRT-LLM/commit/dcb4a71))。
- **可调参 nvfp4 量化 + FlashInfer 后端** ([#12126](https://github.com/NVIDIA/TensorRT-LLM/commit/1480140211f16785e80fec8553ef47846c39e1d0))。
- **视频数据分块 prefill**（非连续内存）([#12944](https://github.com/NVIDIA/TensorRT-LLM/pull/12944))。
- **KVConnector 简写路径**：`"lmcache"` / `"kvbm"` 一键配置 ([#12626](https://github.com/NVIDIA/TensorRT-LLM/commit/968f397db1a745e4c4155a06c5f6ff762899a5a9))。
- **Nemotron Nano VL 音频支持**进行中 ([#12921](https://github.com/NVIDIA/TensorRT-LLM/pull/12921), [#12924](https://github.com/NVIDIA/TensorRT-LLM/pull/12924))。
- **zombie worker pod 检测** ([#12718](https://github.com/NVIDIA/TensorRT-LLM/pull/12718)) — 在分布式推理场景下防止僵尸进程。

**对我们的启示**：KVConnector shorthand 降低了 LMCache/KVBM 的集成成本，如果我们的平台支持 TRT-LLM 后端可直接受益。zombie worker 检测对 K8s 部署场景尤其重要。

### Ollama

**4 个版本密集发布**：v0.20.5 ([4/9](https://github.com/ollama/ollama/releases/tag/v0.20.5)) → v0.20.6 ([4/12](https://github.com/ollama/ollama/releases/tag/v0.20.6)) → v0.20.7 ([4/13](https://github.com/ollama/ollama/releases/tag/v0.20.7)) → v0.20.8-rc0 ([4/14](https://github.com/ollama/ollama/releases/tag/v0.20.8-rc0))。

| 特性 | 细节 |
|------|------|
| OpenClaw 多渠道集成 | `ollama launch` 一键接入 WhatsApp / Telegram / Discord（v0.20.5 核心特性）|
| Copilot CLI 集成 | [#15583](https://github.com/ollama/ollama/commit/7d271e6dc9fb114d48b91a1ed2ed3d414178a883) |
| Gemma4 MLX 支持 | 初始实现 ([#15244](https://github.com/ollama/ollama/commit/2cba7756c5d62b43c4d02e4df22b449a9c42af3e)) + fused ops 性能优化 ([#15587](https://github.com/ollama/ollama/commit/48ad7085c43006be50f61b0e933a769e6bdc9b58)) |
| ROCm 7.2.1 | [#15483](https://github.com/ollama/ollama/commit/798fd09bfe3ef2d749edc81b6ff4efec27d6bd0f) |
| TurboQuant KV cache | tq2/tq3/tq2k/tq3k 压缩 KV cache PR 进行中 ([#15505](https://github.com/ollama/ollama/pull/15505)) |
| GPU 设备信息 API | `/api/status` 暴露 GPU 信息 ([#15608](https://github.com/ollama/ollama/pull/15608)) |

**对我们的启示**：`/api/status` GPU 信息端点对平台侧的资源感知调度有参考价值。TurboQuant 如果合入，可以大幅降低端侧长对话的内存占用。

---

## 模型服务 & 编排

### KServe 上游

本周无新版本发布，但有一个**高危安全修复**和多项重要特性推进。

**安全**：
- **CVE-2026-33186：gRPC 鉴权绕过** — 已合并修复 ([#5342](https://github.com/kserve/kserve/commit/73a6053d725092b0bc001c2ae4d067cc6982a0d7))。攻击者可绕过 gRPC 端口的授权检查，**所有暴露 gRPC 端口的 KServe 部署必须立即升级**。
- PSS restricted profile 强制执行于 LLMInferenceService 默认模板 ([#5302](https://github.com/kserve/kserve/commit/e4067aef004dfac71759d3612f591ef3402d9a1f))。

**特性进展**：
- vLLM 升级至 0.19.0 ([#5367](https://github.com/kserve/kserve/commit/c034e83b5d5e3af1c98fd436e1c97346c790f33d))。
- 无 Ray 多节点推理基础架构 ([#5366](https://github.com/kserve/kserve/commit/4be98b112c8df61ef7ebf475c41e469285bcdc8b)) — 降低多节点部署的依赖复杂度。
- 机密模型服务（Confidential Model Serving）PR 进行中 ([#5382](https://github.com/kserve/kserve/pull/5382))。
- 静态 LoRA adapter 调和逻辑 ([#5317](https://github.com/kserve/kserve/pull/5317))。
- Pipeline-Parallel LLMISvc presets ([#5315](https://github.com/kserve/kserve/pull/5315))。
- 异构 GPU 负载均衡示例 ([#5374](https://github.com/kserve/kserve/pull/5374))。
- WVA 自动伸缩 e2e 测试 ([#5407](https://github.com/kserve/kserve/pull/5407))。

**对我们的启示**：CVE-2026-33186 是本周最紧急的行动项。无 Ray 多节点支持若成熟，可简化我们的多节点推理部署架构。机密模型服务和异构 GPU 负载均衡都是企业级平台差异化能力。

### Ray

**v2.55.0** 于 4/15 正式发布（[release](https://github.com/ray-project/ray/releases/tag/ray-2.55.0)）。

- **DataSourceV2 API**：新的 scanner/reader 框架、文件列表和分区机制 ([release notes](https://github.com/ray-project/ray/releases/tag/ray-2.55.0))。
- **vLLM 升级至 0.19.0** ([#62349](https://github.com/ray-project/ray/commit/36a5d61713e98f7976855a0179dc31e9ed84c98d))。
- **SGLang 集成提升为用户指南**，引擎代码移至 `_internal` ([#62570](https://github.com/ray-project/ray/commit/534cce7618ca5728353636e2cb6e22bed12f65db))。
- **Tokenization 分离文档** ([#62494](https://github.com/ray-project/ray/commit/13936e133113e577893440e770b01ebf59204f50))。
- **LLMConfig topology 字段**：支持多主机 TPU ([#61906](https://github.com/ray-project/ray/pull/61906))。
- **Resource Isolation**：按时间切换组杀进程策略 ([#62643](https://github.com/ray-project/ray/pull/62643))。
- HAProxy 安全升级修复 CVE-2025-11230 ([#62585](https://github.com/ray-project/ray/commit/f9ccc7a79ee4535a5575551687e193c003e6c7f9))。

**对我们的启示**：SGLang 被 Ray 官方提升为用户指南级别，说明 SGLang 在 Ray 生态中的地位已经稳固，值得在我们的多引擎策略中给予更高优先级。Tokenization 分离是 PD 分离架构的关键组件。

---

## 训练 & 微调

### Kubeflow Training Operator

本周无重大更新。

### LLaMA-Factory

本周无重大更新。

---

## 模型生命周期

### MLflow

**TypeScript SDK 0.2.0-rc1** 发布（[release](https://github.com/mlflow/mlflow/releases/tag/ts/v0.2.0-rc.1)），核心是 `@mlflow/vercel` 包。

**Gateway 护栏（Guardrails）— 本周最大特性**：
- 护栏执行逻辑集成到 Gateway API handler ([#22306](https://github.com/mlflow/mlflow/commit/f9fb2c6a53a72c25fdafe32caa75bc4b6e8b5bf5))。
- 创建护栏 Modal ([#22358](https://github.com/mlflow/mlflow/commit/aca3ebb37e830b2917a1422a864187bd52c51d56))。
- 查看/编辑护栏详情 Modal ([#22435](https://github.com/mlflow/mlflow/commit/369da3c84aefb24354e1899f7777eaf6f05b6767))。
- 端点编辑器增加 Guardrails 标签页 ([#22360](https://github.com/mlflow/mlflow/commit/511def9f8edce405effccf9e9f444671ab27cab5))。
- 护栏遥测（create/update/delete）([#22548](https://github.com/mlflow/mlflow/commit/26cc274e33975f714d8d4f0f5159e54c2cae6c06))。

**其他重要进展**：
- `mlflow gateway start` CLI 命令标记弃用 ([#22580](https://github.com/mlflow/mlflow/commit/ccea6a4177dfca279308d70d3515714881a4e9d5))。
- `@mlflow/vercel` 包支持 Vercel AI SDK tracing ([#22105](https://github.com/mlflow/mlflow/commit/1dfd61775ac3c5cf9917dbfeb9f09b6c6cb6f539))。
- **S3 预签名上传 URL** ([#21039](https://github.com/mlflow/mlflow/commit/d1618c4b4e388c9f7d46086c268a39bb096298fe)) — 大文件上传性能优化。
- **Trace 归档**：SQLAlchemy 后端实现 ([#22605](https://github.com/mlflow/mlflow/pull/22605)) + UI ([#22594](https://github.com/mlflow/mlflow/pull/22594)) — 合规场景刚需。
- Agent 审计跟踪 FR ([#22383](https://github.com/mlflow/mlflow/issues/22383))。
- 缓存感知 token 成本追踪 FR ([#22606](https://github.com/mlflow/mlflow/issues/22606)) — 支持 Anthropic/OpenAI 等提供商的 prompt cache 计费。

**对我们的启示**：Gateway Guardrails 全链路已基本落地，意味着 MLflow 正式切入 AI 治理领域。如果我们的平台集成了 MLflow，应尽早评估护栏能力的适配。Trace 归档是合规客户的硬需求。

### Kubeflow Model Registry

本周以 MCP 相关修复为主：
- MCP server 分页功能实现 ([#2571](https://github.com/kubeflow/model-registry/commit/f381dd22e4811c6292169aee72e4810a09c18de3))，默认排序修复 ([#2592](https://github.com/kubeflow/model-registry/commit/45ea1fa85df8c0759914392dc54b7476908f13ff))。
- Catalog 安全上下文强制 non-root ([#2568](https://github.com/kubeflow/model-registry/commit/0d88909139367169a986025298b29656cc3946ea))。
- UI 修复若干（搜索栏、DeleteModal、artifact URI 显示等）。

活动量中等，主要是 MCP Catalog 功能打磨。

### Feast

本周无新版本发布，但提交密度很高。

- **Feature view 版本化**：Redis 和 DynamoDB ([#6257](https://github.com/feast-dev/feast/commit/edf25af12686ace485a93d1a742e04f4d7681bf8))、FAISS ([commit](https://github.com/feast-dev/feast/commit/b36acb71673894db78283664dde10da9fec20c21)) 在线存储均已支持。
- **MCP server 迁移**：从 fastapi_mcp 迁移到 MCP Python SDK ([#6258](https://github.com/feast-dev/feast/pull/6258))。
- **AI agent 示例**：MCP + 持久化记忆的完整示例和博文 ([#6253](https://github.com/feast-dev/feast/commit/705df00ecfbdc5a23e7190fb0d014eb4f024e31b))。
- **时间分片物化（chunked materialization）**：防止密集数据集 OOM ([#6277](https://github.com/feast-dev/feast/pull/6277))。
- **Milvus 在线存储 5 项 bug 修复** ([#6275](https://github.com/feast-dev/feast/commit/212504bb7aa32fb6ff14be82490a2f5f50616937))。
- **Go Feature Server TLS 支持** ([#6229](https://github.com/feast-dev/feast/commit/28a58d0735ce4bf22554e1e562aef6b97e7bafe4))。
- **Feast-MLflow 集成** PR 进行中 ([#6235](https://github.com/feast-dev/feast/pull/6235))。
- **生产部署拓扑文档** ([commit](https://github.com/feast-dev/feast/commit/d0577b83ebce2c53381e647326c7c5bfadbb757f))。

**对我们的启示**：Feature view 版本化解决了特征迭代时的灰度发布问题，对多版本模型并行推理场景直接有用。MCP server 迁移到官方 SDK 说明 MCP 协议正在收敛为标准。

---

## LLM 评估 & 安全

### lm-evaluation-harness

本周无新版本发布、无代码提交。进展集中在 PR 层面：
- **0.5 版本审查** PR ([#3703](https://github.com/EleutherAI/lm-evaluation-harness/pull/3703))。
- **移除已弃用的 vLLM V0 ray 代码路径** ([#3701](https://github.com/EleutherAI/lm-evaluation-harness/pull/3701))。
- **新 benchmark 提交**：MolecularIQ 化学推理 ([#3707](https://github.com/EleutherAI/lm-evaluation-harness/pull/3707))、LICA-Bench 平面设计 VLM 评估（39 tasks, 7 领域）([#3705](https://github.com/EleutherAI/lm-evaluation-harness/pull/3705))、OpenSubtitles2024 多语言翻译 ([#3706](https://github.com/EleutherAI/lm-evaluation-harness/pull/3706))。

### Garak

本周无新版本发布，核心推进在 agent 安全测试能力建设。

- **ModernBERT 拒绝检测器**：已合并并移至 mitigation 类别 ([#1650](https://github.com/NVIDIA/garak/commit/c624bf2399b3200cea703c28fd51e87bb59136f1), [commit](https://github.com/NVIDIA/garak/commit/053bacf7ade066da473e2decf51ab498170ce088))。
- **Agent Threat Rules 检测器** ([#1676](https://github.com/NVIDIA/garak/pull/1676)) — 针对 agent 场景的威胁规则。
- **Agent breaker probe** ([#1628](https://github.com/NVIDIA/garak/pull/1628)) — agent 越狱测试。
- **系统提示词提取 probe** ([#1538](https://github.com/NVIDIA/garak/pull/1538))。
- **NeMoGuardrails server 支持** ([#1675](https://github.com/NVIDIA/garak/pull/1675))。
- **mTLS 客户端证书认证** for REST generator ([#1681](https://github.com/NVIDIA/garak/pull/1681))。

**对我们的启示**：Garak 正快速补齐 agent 安全测试能力（威胁规则、agent 越狱、系统提示词提取）。如果我们的平台提供 agent 托管服务，应将 Garak 的 agent probe 纳入上线前的安全检查流程。mTLS 支持也表明 Garak 在向企业级方向靠拢。

---

## 值得跟进

- [ ] **紧急**：KServe CVE-2026-33186 gRPC 鉴权绕过 — 检查所有 KServe 部署是否升级 ([#5342](https://github.com/kserve/kserve/commit/73a6053d725092b0bc001c2ae4d067cc6982a0d7))
- [ ] vLLM per-token-head Int2/Int4 KV 量化 ([#39074](https://github.com/vllm-project/vllm/pull/39074)) 合并后进行内部基准测试，评估长上下文场景显存节省比例
- [ ] SGLang Context Parallelism 路线图 ([#21788](https://github.com/sgl-project/sglang/issues/21788))：Q2 若落地，需评估对我们长序列推理方案的影响
- [ ] KServe 无 Ray 多节点推理 ([#5366](https://github.com/kserve/kserve/commit/4be98b1)) + 机密模型服务 ([#5382](https://github.com/kserve/kserve/pull/5382))：持续跟踪，这两项对企业客户价值大
- [ ] MLflow Gateway Guardrails 全链路就绪 — 评估是否将护栏能力集成到我们的模型服务网关
- [ ] Ollama TurboQuant KV cache ([#15505](https://github.com/ollama/ollama/pull/15505))：若合入，评估 tq2/tq3 在端侧推理的质量-性能权衡
- [ ] Feast Feature View 版本化 + Feast-MLflow 集成 ([#6235](https://github.com/feast-dev/feast/pull/6235))：关注特征平台与实验平台打通的进展
- [ ] Garak agent 安全 probe 集（[#1676](https://github.com/NVIDIA/garak/pull/1676), [#1628](https://github.com/NVIDIA/garak/pull/1628), [#1538](https://github.com/NVIDIA/garak/pull/1538)）：纳入 agent 上线安全检查清单评估

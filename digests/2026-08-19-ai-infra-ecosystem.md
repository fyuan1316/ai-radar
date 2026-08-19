# AI 推理 & MLOps 生态周报 2026-08-19

> 窗口:2026-08-12 ~ 2026-08-19。只筛对"做云原生 AI 基础设施产品"有借鉴/威胁的变化;版本 bump、dependabot、CI 修复、纯测试 waive 已跳过。上周(08-14)已覆盖的 vLLM v0.27 / SGLang v0.5.17 / TensorRT-LLM v1.3.0rc24 本周无新 tag,只看 main 分支增量。

## 摘要(5 条以内)

1. **MLflow 明确对接 OpenShift AI**:把 "Red Hat OpenShift AI" 加进官方 hosting options(#25151),同时分 6 步给 basic-auth 加**实验级权限门控**(fail-closed 授权网 #25065、evaluation dataset/issue 路由按实验权限收口 #25066/#25067),Helm chart 支持 External Secrets Operator(#24523)——MLflow 正在补企业级多租户/RBAC,且主动进 OAI 生态。这条对我们最直接。https://github.com/mlflow/mlflow/pull/25151
2. **Feast 大幅企业化**:默认走 kubernetes auth、CronJob 与 feature-server 拆分独立 ServiceAccount、新增 `ConnectionRef` 做可插拔外部凭据解析、operator 直接集成 MLflow、OpenLineage 血缘做到全对象覆盖 + API 级同步——Feature Store 往"平台级鉴权 + 血缘治理"走。https://github.com/feast-dev/feast/pull/6719
3. **KServe 模型分发多路线并进**:新增 ModelScope `ms://` 存储下载(#5330)、`oci+fetch://` OCI 镜像拉模型 Step 3 落地(#5739)、standalone KEDA 自动扩缩 e2e 覆盖(#6018)——LLM serving 的"模型来源 + 自动扩缩"标配继续补齐,OCI 分发是上游明确共识。https://github.com/kserve/kserve/pull/5739
4. **Ray 往生产级高可用控制面演进**:GCS Active-Passive leader-election Phase 2.1(协议/状态/客户端缓存,#65132)、外部 shuffle runtime + operators(#64828/#65144)、移除已废弃 Serve API(#65215)——继上周 RocksDB 去 Redis 后,GCS HA 再进一步。https://github.com/ray-project/ray/pull/65132
5. **Kubeflow model-registry catalog 化提速**:catalog v1 API handlers(#3065)、skill catalog Python client(SKC-113,#3083)、skill source preview/marketplace(SKC-110/111/114)、MCP serverJson 详情——Registry 正稳步变成"模型 + Skill + MCP 目录",是 agent/工具治理的上游锚点。https://github.com/kubeflow/model-registry/pull/3065

## 推理引擎动态

### vLLM(本周无新 release,main 活跃 100+ commit)
对平台层有价值的几条:
- **Model Runner V2 覆盖非生成负载再进一步**:pooling 模型默认启用 MRV2(#48290)——延续"同一 runtime 服务生成 + 向量/pooling"的统一化路线。
- **CPU 侧 AMX-only 高性能 MLA backend**(DeepSeek V2/V3/R1,#52616):无 GPU 也能高效跑 MLA,利好边缘/降本场景的推理落地。
- **Elastic EP 韧性**:拒绝低于最小 DP size 的缩容(#52702);XPU 上支持 EC connector KV offloading(#49532)——弹性专家并行 + KV 分层继续硬化。
- **前缀缓存确定性**:`NONE_HASH` 默认确定化(#51875),Kimi-K3 支持 DCP 部分前缀缓存命中(#50493)——KV/prefix cache 复用的正确性与覆盖面在补。
- 启示:引擎侧持续把"弹性 EP、KV 分层、CPU MLA"内建,产品差异化仍应聚焦调度/多租户/生命周期,不重复造推理内核。https://github.com/vllm-project/vllm/pull/52616

### SGLang(本周无新 release,main 活跃)
- **HiCache 分层 KV 治理加固**:host memory layer 的 buffer-only 模式(#34798)、PP 批量写/加载完成同步(#33473)——分层 KV 缓存工程化继续。
- **PD 分离容错**:传输中途 abort 时延迟释放 decode 侧 KV(#35049),避免半传输态泄漏——对"故障快恢复"是实用能力。
- **DCP 逻辑 KV-event block size 对外暴露**(#35298)、config 驱动的 MoE router 打分(Laguna,#35362)、NPU mxfp4-w4a4 MoE 量化(#30319)。https://github.com/sgl-project/sglang/pull/34798

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM:本周无新 tag**(仍是 v1.3.0rc24,08-12 发,上周已覆盖),main 100+ commit 基本是稳定化——KV cache block reuse 避免二次拷贝(#17848)、KVCM v2 host-tier 配额多 rank 同步(#17790)、disagg benchmark server 健康超时可配(#17881)。注意该版 API 层有多处 **BREAKING**(disagg 元数据共享密钥签名、`block_reuse_policy` 迁到 `block_reuse_config.policy`、Mamba 缓存换 KVCacheManagerV2),生产采用前要读迁移说明。https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc24
- **TGI:仍归档,无更新**。竞品/上游清单里推理引擎收敛为 vLLM / SGLang / TensorRT-LLM。https://github.com/huggingface/text-generation-inference
- **Ollama**(一周 5 版 v0.32.10→v0.32.14):新增 **Qwen 3.8 27B** 支持并为 Apple Silicon 做 MLX 优化(#v0.32.12);默认 `repeat_penalty` 从 1.1 改 1.0(对齐其他引擎、加速投机解码);NVFP4 MLX 模型 prefill 提速 7–8%;修 OCI manifest config 与 layer 共享 digest 时 blob 校验被跳过的 bug——边缘/桌面侧持续绑定新开源模型 + OCI 分发细节。https://github.com/ollama/ollama/releases/tag/v0.32.12

## 模型服务 & 编排

### KServe 上游(无 release,本周 14 个 commit,聚焦 llmisvc + 存储)
- **模型来源扩展**:ModelScope `ms://` URI 下载(#5330)——国内模型源接入;`oci+fetch://` KServe 侧 OCI 镜像拉模型 Step 3(#5739)——OCI 分发路线继续推进。
- **自动扩缩**:standalone KEDA autoscaling 的 e2e 覆盖(#6018),延续上周 scale-to-zero 主线。
- **加权 InferencePool** e2e 测试 job(#5886,对齐 Gateway API Inference Extension);llmisvc 给 CA bundle 同步补 configmap 写 RBAC(#5965);modelcar uidModelcar 回归测试(#5954)。
- 启示:"OCI/ModelScope 多源模型分发 + KEDA 缩容 + InferencePool 流量治理"是上游 LLM serving 的标配组合,逐条对照我们能力矩阵。https://github.com/kserve/kserve/pull/5330

### Ray(无 release,main 59 commit)
- **GCS 高可用**:Active-Passive leader-election Phase 2.1(协议 + 状态 + 客户端缓存,#65132)——继上周 RocksDB 去 Redis 之后,GCS 控制面 HA 再进一步,生产部署更稳。
- **Serve/LLM**:直连流式 ASGI app 上暴露 engine 错误(#65440);HAProxy 上 env-gated layer4 mark-down 观测(#65267);**移除已废弃 Serve API**(#65215)——集成方升级需留意。
- **Ray Data**:外部 shuffle runtime library + task/operators(#64828/#65144);新增 Mobilint 加速器支持(#61898)。文档侧新增大量 KubeRay/K8s 调度约定与 History Server 指南。https://github.com/ray-project/ray/pull/65132

### KubeAI(原 substratusai/lingo)
无重大更新(窗口内 0 提交,仓库持续静默)。https://github.com/kubeai-project/kubeai

## 训练 & 微调

- **Kubeflow Trainer**:本周只发了**遗留 v1.9.x 维护线** v1.9.4(Training Operator,K8s 依赖升到 1.36 + 几个 bugfix,#3924),**不是 v2 新特性**;v2 main 仅有 controller healthz/readyz 探针(#3338)与一个 add-new-crd 的 `.agents` skill(#3837)。做训练平台集成的:v1.9 线仍在收尾维护,新能力看 v2(上周 v2.3.0)。https://github.com/kubeflow/trainer/releases/tag/v1.9.4
- **LLaMA-Factory**(hiyouga,活跃):新增 **KTransformers VLM 微调**(#10760)、`[v1] FSDPTurbo EP/EFSDP` MoE 训练插件(#10676)、KTransformers MoE LoRA SFT 加固(#10738)、FA3 支持(#10742)——国内社区持续补 MoE + KTransformers(CPU/GPU 混布)微调栈。https://github.com/hiyouga/LLaMA-Factory/pull/10676

## 模型生命周期(MLflow / Registry / Feast)

- **MLflow**(活跃,无 release,90+ commit,本周最值得看):
  - **进 OAI 生态**:hosting options 加入 Red Hat OpenShift AI(#25151)——对我们是直接的对标/整合信号。
  - **企业级 RBAC**:basic-auth 分 6 步做实验级权限门控(fail-closed 授权网 #25065、evaluation dataset 路由 #25066、issue 路由 #25067),chart 支持 External Secrets Operator(#24523),`MLFLOW_TRACKING_AUTH=kubernetes` 进 TS SDK(#24243)。
  - **评估/tracing**:`mlflow scorers list --builtin` 补全 scorer catalog(#25003)、自定义 judge 描述进 tooltip、`optimize_prompts` 支持 chat 类 prompt(#23488);TS SDK 加 SpanLink(#23480)。
  - 启示:MLflow 正把"多租户鉴权 + 评估治理 + 与 OAI 对接"补齐,这几项与我们模型生命周期能力高度重叠,值得逐条比对。https://github.com/mlflow/mlflow/pull/25065
- **Kubeflow model-registry**(catalog 化提速):v1 API handlers(#3065)、skill catalog Python client SKC-113(#3083)、skill source preview + marketplace SKC-110/111/114(#3087)、MCP 详情页 serverJson(#3068)——Registry 从"模型登记"扩成"模型 + Skill + MCP 目录",agent/工具治理的上游锚点。https://github.com/kubeflow/model-registry/pull/3065
- **Feast**(活跃,企业化主线):默认 kubernetes auth、CronJob 与 feature-server 独立 ServiceAccount、`ConnectionRef` 可插拔外部凭据解析、operator 集成 MLflow(#6611)、OpenLineage 血缘全对象覆盖 + API 级同步(#6719)、HybridOfflineStore 持久化类型(#6707)、operator 暴露 OIDC JWKS 可调参(#6690)——鉴权 + 血缘 + 混合离线存储都在补。https://github.com/feast-dev/feast/pull/6719

## LLM 评估 & 安全

- **lm-evaluation-harness**(仅 3 个实质 commit):新增 LegalBench 的 Contract NLI 套件(14 个 NDA 蕴含任务,#3954)、Putnam Axiom 数学基准(#3998);修 fewshot gen_prefix 解析(#3979)。评测集侧法律/数学基准在扩,无框架级变化。https://github.com/EleutherAI/lm-evaluation-harness/pull/3954
- **garak**(NVIDIA):**弃 Python 3.10、全面支持 3.13**(#2084)——集成方 CI 需跟进 Python 版本;analyze 从 attack hits 重建置信区间(#2050)、加载内置 detector metrics(#2004);修 MarkdownExfilContent 的 ZeroDivisionError、FileDetector 格式不匹配中止整轮等若干 detector 稳定性问题。https://github.com/NVIDIA/garak/pull/2084
- **llama-stack**(release 已迁到 `ogx-ai/ogx`):本周发 **v1.2.3 补丁**(修 `AsyncOgxClient` 继承 sync ApiClient,#6401),非特性版。注意 release 线已从 meta-llama/llama-stack 迁到 ogx-ai/ogx。https://github.com/ogx-ai/ogx/releases/tag/v1.2.3

## 值得跟进

- [ ] **MLflow × OpenShift AI**:读 #25151 与 basic-auth 6 步 PR(#25065–25067),评估 MLflow 企业级 RBAC 与我们模型生命周期能力的重叠/差异,以及它进 OAI 生态对竞品格局的影响。
- [ ] **Feast 企业化对标**:kubernetes auth 默认化 + ConnectionRef 可插拔凭据 + OpenLineage 血缘——若我们做/集成 Feature Store,这是能力对齐清单。
- [ ] **KServe 模型分发多源(OCI + ModelScope)**:确认我们模型分发是否兼容 `oci+fetch://` 与 `ms://`,OCI 已成上游共识。
- [ ] **Ray GCS HA(Active-Passive + RocksDB)**:若产品内嵌 Ray,跟进 leader-election Phase 2.1 的落地节奏,规划去 Redis 的生产拓扑。
- [ ] **model-registry Agent/Skill/MCP catalog**:若要做 agent/工具治理,持续对齐这条 catalog 化主线。
- [ ] **依赖/升级噪音提醒**:garak 弃 Py3.10、TensorRT-LLM v1.3 多处 API BREAKING、Kubeflow Trainer v1.9 仍在维护但新能力在 v2——集成方规划升级路径时注意。

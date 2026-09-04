# AI 推理 & MLOps 生态周报 2026-09-04

覆盖窗口:2026-09-02 ~ 09-04(前一份 09-02 digest 已覆盖到 09-02,本份只看其后的增量主线提交)。仓库改名沿用备忘:lingo→kubeai-project/kubeai、training-operator→kubeflow/trainer、llama-stack 源码在 ogx-ai/ogx 但仍发 release 于 meta-llama/llama-stack;TGI 已 archived(正常 0 提交)。本窗口唯一"新"发版是 Ollama v0.33.3(09-02 已见其 rc0);TensorRT-LLM v1.3.0rc25 / model-registry v0.3.16 / lm-eval v0.4.13 / llama-stack v1.3.0-1.3.1 均在上一份已展开,不重复。

## 摘要(5 条以内)

1. **P/D 分离的"KV 传输容错"继续被三家集中补齐**:TensorRT-LLM 落 **Python Cache Transceiver 的流水线化 KV 传输**(#15727)、加 **DisaggTransferCoordinator 骨架**(#18595)、修 **disagg worker 存活探测限定在 TTL 窗口内**(#18403);vLLM 合入 **P2P NIXL + CPU EC(Embedding/KV)Connector**(#47941)并给 OffloadingConnector 加保留区间(#51886);SGLang 用 `SGLANG_DISAGGREGATION_ENGINE_INIT_TIMEOUT` **给传输引擎初始化上界**(#37874)、**按后端能力门控 decode 端 KV 延迟释放**(#37454)。延续上周"PD 生产化的头号风险是 KV 连接器正确性/容错"的判断——这块正在从"能跑"走向"抗挂死/抗超时"。
2. **安全硬化横扫 MLOps 侧,反序列化/SSRF 成重灾区**:MLflow 一周内连补 **webhook SSRF guard 拒绝内嵌私网 IPv4 的 IPv6-transition 地址**(#25568)、**shap explainer 加载受 `MLFLOW_ALLOW_PICKLE_DESERIALIZATION` 开关约束**(#25566),并把 **MLflow Assistant 编码 agent(Claude Code/Codex)关进加固 Docker 沙箱**(#25302/#25304/#25305);KServe kernelcache 上 **签名契约 + cert 模式签名校验**(#6118/#6103)。做模型平台的,unpickling/工件签名/出网隔离要按这几条对齐。
3. **Kubeflow Trainer 迈出 DRA 第一步**:KEP-2782 给 TrainJob 的 PodSpecPatch 加 **`resourceClaims` 字段**(#3540),平台管理员在 ClusterTrainingRuntime 预置 ResourceClaimTemplate、数据科学家经 runtimePatches 覆盖;因现有 strategic-merge 管道原生支持 PodSpec.ResourceClaims,几乎零控制器改动。DRA 已在 k8s 1.34 GA——训练调度接 DRA 是我们 GPU 分配层要跟的方向。
4. **推理层"Agent/工具化"信号变浓**:vLLM 把 **Triton kernel 编写 skill 暴露给 Claude**(#55019/#55028),Ollama v0.33.3 让 **gemma4 在 MLX 引擎支持图像+音频**并上报 cached prompt tokens(#17943),SGLang 引入 **高保真 CPU 推理模拟器**(#33824)用于免 GPU 的调度/性能预演。工具链把"AI agent"当一等公民,既是能力也是新攻击面(见第 2 条)。
5. **KV 分级/统一缓存 + 量化收口仍是主线底噪**:SGLang **Unified Cache 外部 linker 模式端到端打通**(#37381)、HiCache L3 预取生命周期指标与跨层归因(#37503);vLLM 弃用 "all" mamba cache 模式(#55041)、加在线量化按用户模式定向配置(#51285);TensorRT-LLM 给 DSA 加 **NVFP4 KV cache**(#17681)。方向与上周一致,做缓存/量化后端选型可持续参照。

## 推理引擎动态

### vLLM
本周无新 release,主线里对基础设施方有用的横切项(https://github.com/vllm-project/vllm/commits/main):
- **KV/EC 连接器**:合入 **P2P NIXL + CPU EC Connector**(#47941,把 embedding/KV 跨实例点对点传输 + CPU 卸载做进连接器层)、给 **OffloadingConnector 加 retention interval**(#51886)、多处 KV offload 竞态修复(过期 async lookup 结果忽略 #54872、超额 offer 的 tracker 进度保证 #54759)。https://github.com/vllm-project/vllm/pull/47941
- **Agent 化**:新增并向 Claude 暴露 **Triton kernel 编写 skill**(#55019/#55028),把"让 AI 写/调 kernel"内建进仓库工作流。https://github.com/vllm-project/vllm/pull/55028
- **在线量化**:**按用户模式做定向在线量化配置**(#51285),量化从离线 checkpoint 往运行时自适应走。https://github.com/vllm-project/vllm/pull/51285
- **Core/缓存**:弃用 "all" mamba cache 模式(#55041);Rust 前端继续成熟(render server 支持 TLS #54999、静态 `--lora-modules` 加载 #54837、reasoning token 计数 #54982)。
- 新模型:GLM-5.3-Flash(#53906)、K2-Horizon(#55063)、DeepSeek-V4-Flash-Vision-Exp(#54566)。

### SGLang
本周无新 release,亮点(https://github.com/sgl-project/sglang/commits/main):
- **统一缓存外部化**:**Unified Cache 外部 linker 模式端到端集成**(#37381)、**HiCache L3 存储预取的生命周期指标 + 跨层归因修复**(#37503)、buffer 模式空闲检查纳入 in-flight 备份计数(#37883)。https://github.com/sgl-project/sglang/pull/37381
- **PD 分离健壮性**:传输引擎初始化超时上界(#37874)、按后端能力门控 decode 端 KV 延迟释放(#37454)、断连后已派发请求的 abort 处理(#35255)。https://github.com/sgl-project/sglang/pull/37874
- **模拟器**:新增**高保真 CPU 推理模拟器**(#33824)+ 精确 host-cache 尺寸固定(#37285),可在无 GPU 下预演调度/性能。https://github.com/sgl-project/sglang/pull/33824
- **Router**:加**可组合的打分与准入策略**(composable scoring/eligibility,#37731),路由层策略化。https://github.com/sgl-project/sglang/pull/37731
- 另有大量 diffusion(MiniMax-H3/Cosmos3)与 AMD/NPU 适配提交,K2-Horizon 原生服务(#37654)。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**(无新 rc,主线 https://github.com/NVIDIA/TensorRT-LLM/commits/main):disagg 方向密集补齐——**Python Cache Transceiver 的流水线化 KV 传输**(#15727)、**DisaggTransferCoordinator 骨架 + loop 转录测试**(#18595)、**disagg worker 存活探测限定 TTL 窗口**(#18403)、Ray disagg 测试设 UCX_TLS(#18301);缓存/量化:**DSA 的 NVFP4 KV cache**(#17681)、混合 KV cache 前缀复用的 Mamba 分支点状态快照(#18272);硬件:**Rubin SM107 CuTe DSL 基座 + BF16 kernel**(#18369)。https://github.com/NVIDIA/TensorRT-LLM/pull/15727
- **Ollama v0.33.3**(09-02 定版):**gemma4 在 MLX 引擎支持图像+音频输入**、上报 cached prompt tokens(#17943)、尊重 GGUF 模型自带默认参数;延续"桌面/边缘 + 多模态"路线。https://github.com/ollama/ollama/releases/tag/v0.33.3
- **TGI**:已 archived,无更新(正常)。

## 模型服务 & 编排

### KServe 上游
主线继续压在企业级安全与 llmisvc(https://github.com/kserve/kserve/commits/master):
- **签名/安全**:kernelcache **抽出安全数据契约到 types 包**(#6130)、**加签名契约**(#6118)、**cert 模式签名校验**(#6103)——工件供应链完整性在成型。https://github.com/kserve/kserve/pull/6118
- **llmisvc**:**按 InferencePool 引用自动给 workload 打标签**(#5624)、修 llmisvcconfig 基础模板 namespace 渲染(#6088);**Envoy AI Gateway 升到 v1.1.0**(#6122)。https://github.com/kserve/kserve/pull/5624
- 杂项:localmodel controller 补 leader-election RBAC(#6120)、放宽 pyarrow>20(#6125)。

### Ray
无新 release,平台向有用的(https://github.com/ray-project/ray/commits/master):
- **RuntimeEnv**:**统一 archive 校验并支持 tar.xz**(#65742),运行环境打包更灵活且校验收口。https://github.com/ray-project/ray/pull/65742
- **Data**:**外部 shuffle planner**(#65499)、**默认启用基于 footer 的 Parquet 读**(#65821)、修缺失数据下 preprocessor 崩溃(#65272)。
- **健壮性**:actor 重启保留 worker ID(#64497)、dashboard 在 GPU 指标为 null 时白屏崩溃修复(#65591)、Serve dashboard 排除系统 gRPC 流量(#65812)。

### KubeAI
本窗口无提交(延续静默,属正常,见备忘)。

## 训练 & 微调

- **Kubeflow Trainer**:**KEP-2782 为 TrainJob 加 DRA 支持**(#3540)——PodSpecPatch 新增 `resourceClaims`,Phase 1 支持 Pod 级 ResourceClaims + CEL 校验,已知限制含 torch 插件 GPU 探测/ContainerPatch 缺口,Phase 2(k8s 1.36+)再做 PodGroup 级 claim 与 ComputeDomain。DRA 已在 k8s 1.34 GA,这是训练调度接 DRA 的起点。https://github.com/kubeflow/trainer/pull/3540
- **LLaMA-Factory**:加 **Qwen3.8 模型支持**(#10749),其余为常规跟模型。https://github.com/hiyouga/LLaMA-Factory/pull/10749

## 模型生命周期(MLflow / Registry / Feast)

- **MLflow**(3.16.0 CHANGELOG 已定,#25565,发版在即;主线 https://github.com/mlflow/mlflow/commits/master):安全硬化为本周主轴——**webhook SSRF guard 拒绝内嵌私网 IPv4 的 IPv6-transition 地址**(#25568)、**shap 加载受 `MLFLOW_ALLOW_PICKLE_DESERIALIZATION` 约束**(#25566)、**MLflow Assistant 编码 agent 关进加固 Docker 沙箱 + 出网走专用网络/可选代理 + 启动清理孤儿沙箱**(#25302/#25305/#25304);能力面:**AI Gateway 支持 USER 作用域的按用户预算策略**(#24371)。https://github.com/mlflow/mlflow/pull/25302
- **kubeflow/model-registry**:主线仅 **BFF 增加 HuggingFace 字段**(#3164)等小修(v0.3.16 已在上一份展开)。https://github.com/kubeflow/model-registry/pull/3164
- **Feast**:本窗口无提交,无重大更新。

## LLM 评估 & 安全

- **lm-evaluation-harness**:本窗口无新提交(v0.4.13 已在 08-31 发版并在上一份详述:少样本泄漏 / 多选正则前缀遮蔽 / 分组 stderr 误差条会改历史分数)。
- **garak**:红队方向的实用修复——**agent_breaker 判定裁判的 verdict 做类型校验**(#2121)、补充 intent detector 映射(#1952)、SurgeProfanityRacialEthnic 检测器加载正确类别(#2146)、ollama 空响应重试真正生效(#2122)、NIM 瞬时 HTTP 错误重试并报真实状态码(#2019)。做安全评测集成可跟其检测器契约。https://github.com/NVIDIA/garak/pull/2121
- **llama-stack**:主线仅集成测试运行器的 provider 依赖预检(#6471);v1.2.5/v1.3.1 均为 backport 修复。

## 值得跟进

- [ ] **PD 分离 KV 传输的容错一等化**:TRT-LLM(流水线传输 + DisaggTransferCoordinator + worker TTL 存活)/ vLLM(P2P NIXL + CPU EC connector)/ SGLang(init 超时 + 按能力门控延迟释放)三家同频,我们推理层若做 PD 分离,KV 连接器的超时/中止/清理需做成一等容错路径。
- [ ] **MLOps 安全基线对标**:反序列化开关化(MLflow pickle guard)、webhook/出网 SSRF 防护、工件签名(KServe kernelcache 签名契约)、AI agent 沙箱化——逐条对照我们平台的默认安全姿态。
- [ ] **训练调度接 DRA**:Kubeflow Trainer KEP-2782 起步(k8s 1.34 GA),评估我们 GPU/加速器分配层引入 ResourceClaim 的时机与 torch 插件 GPU 探测的兼容缺口。
- [ ] **推理调度的免 GPU 预演**:SGLang 高保真 CPU 推理模拟器,可用于容量规划/调度策略回归,评估是否引入类似仿真闭环。
- [ ] **网关多租户配额**:MLflow AI Gateway 的 USER 作用域按用户预算策略,是模型网关做租户级成本/配额治理的参照。

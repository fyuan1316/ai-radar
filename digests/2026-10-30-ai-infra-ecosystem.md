# AI 推理 & MLOps 生态周报 2026-10-30

窗口:2026-10-23 ~ 2026-10-30(过去 7 天)。版本 bump / dependabot / CI / 纯文档已过滤。
说明:本期紧接 10-28 期(两天前),**只写 10-28 以来的增量信号**,上期已详述的内容(TensorRT-LLM v1.4.0rc1、Ollama v0.40.10~12 决策模型族、Kubeflow Trainer OptimizationJob、KServe/Ray 的早期动向)不再重复。

## 摘要(5 条以内)

1. **KServe llmisvc 全面 TLS 化,并新增机密模型字段与 KV cache PVC evictor**:两天内密集落地——EPP 指标改走 TLS(#6506)、非 distroless 构建默认注入 TLS 安全 profile(#6489)、`spec.model.confidential` 在 v1alpha1 往返中保留(#6500)、集成 KV cache PVC evictor(#6411)、缓存节点预取运行时镜像(#6417)、InferenceService 自动扩缩支持 ClusterTriggerAuthentication(#6207,集群级 KEDA 触发认证)。这是对"做云原生推理平台"最直接的参照:企业安全(传输加密+机密模型)与推理缓存(KV/镜像预取)同时推进。 https://github.com/kserve/kserve/pull/6411
2. **TensorRT-LLM v1.4.0rc2 做了一轮大规模 BREAKING API 清理,收敛到 KV cache V2 / transceiver V2**:LlmRequest 字段 C++→Python 迁移(#20388)、transceiver V2 删掉 KV cache manager V1(#20129)、移除旧 executor backend 兼容路径(#20043)、Mooncake Store 启用零拷贝模式(#20108,BREAKING)、弃用 n-gram 与用户自备投机解码(#20438);能力侧 KV cache V2 原生 retention + 跨轮生成块复用(#20086)、解耦服务支持 FP4 MLA(#20544)。方向明确:KV 分层与解耦(disagg)成为下一版的底座,旧兼容面被成批砍掉。 https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.4.0rc2
3. **Ray 新增原生 Ascend NPU 可观测性,并在建 sandbox 隔离运行时;auth 硬化继续铺开**:Dashboard 原生 Ascend NPU 观测(#66920)——继 SGLang/vLLM 之后,国产 NPU 一等化蔓延到编排层监控;core/sandbox 系列把沙箱从 overlayfs rootfs 启动(#66470)、把镜像 tar 流式灌进 mkfs.erofs(#67493);auth token 继上期后进一步分发到 `ray up`/autoscaler 节点(#67457)与 HAProxy exporter/stats(#67418)。 https://github.com/ray-project/ray/pull/66920
4. **vLLM 与 SGLang 同周集中加固 KV offload / PD 解耦的可靠性**:vLLM 侧 Mooncake 从 decoder 续约 prefill KV 租约(#64193)、MooncakeStoreConnector 支持 sleep 模式(#59934),外加一大批 KV offload 容错(P2P 故障降级、reset 可重入、空闲引擎停泊);SGLang 侧 PD 传输在 PP 各阶段间对 KV 搬运结果达成一致(#47045/#47063)、解耦 decode 走统一 page-envelope host pool(#47124)。两家都在把"分层 KV + 解耦"从能力做到生产级容错。 https://github.com/vllm-project/vllm/pull/64193
5. **MLflow 一次安全硬化批次(含一枚 CVE)**:修复 FileStore trace 路径穿越 CVE-2026-53995(#26842)、MCP server 权限按存储名校验(#27230)、按 `MLFLOW_ALLOW_MODEL_CODE_EXECUTION` 门控 LlamaIndex 加载(#27231)、artifact proxy 授权忽略 `.` 路径段(#27229)、generic jobs 端点要求 admin(#27228)。作为实验追踪/模型仓的事实标准,这些是多租户部署时要一并对齐的安全基线。 https://github.com/mlflow/mlflow/pull/26842

---

## 推理引擎动态

### vLLM
本周无新 release(仍为 v0.32.0),主线活跃,挑对产品有意义的:
- **KV offload / Mooncake 生产级容错**(见摘要 4):Mooncake 从 decoder 续约 prefill KV 租约(#64193)、MooncakeStoreConnector 支持 sleep 模式(#59934);大批 P2P 容错——源 WRITE 卡住即判故障对端(#64251)、超时 load 立即失败延后释放 slot(#64256)、GPU-CPU KV 传输故障降级而非拖垮引擎(#52838/#63618)。信号:KV 分层从"能跑"迈向"故障可降级"。 https://github.com/vllm-project/vllm/pull/64193
- **安全**:为结构化决策强制请求模板信任(#64503)——延续上期"决策/判别模型"主线,给模板注入面加闸。 https://github.com/vllm-project/vllm/pull/64503
- **前端/推理控制**:Responses API 支持 `thinking_token_budget`(#63896,推理预算可控);继续补 Anthropic API 兼容(inline system 渲染探测 #63594)。 https://github.com/vllm-project/vllm/pull/63896
- **RL/权重同步**:NCCL 权重传输失败时显式报错而非静默 no-op(#57022)。 https://github.com/vllm-project/vllm/pull/57022
- **AMD/ROCm**:整期大量 ROCm 收口(CI/release 部署重构 #61939、DSv4.1 MI355X 多项 perf、NVFP4 MoE 在线再量化 #64378),AMD 一等化持续。

### SGLang
本周无新 release(仍为 v0.5.22),挑对产品有用的:
- **Rust server 可观测性成熟**(接上期 Rust 化主线):`/generate` meta_info 按缓存层级上报 cached tokens(#46961)、提供 `/start_profile` `/stop_profile`(#46968)、`/model_info` 暴露启动期字段(#47169)。 https://github.com/sgl-project/sglang/pull/46961
- **PD 解耦可靠性**(见摘要 4):PD 传输在 PP 各阶段对 KV 搬运结果达成一致(#47045/#47063)、解耦 decode 走统一 page-envelope host pool(#47124)、PD rebootstrap 时保留 output ids(#47366)。 https://github.com/sgl-project/sglang/pull/47124
- **多 LoRA 服务 perf**:重构 LoRADrainer 提性能(#46500)、PP 下多 LoRA 吞吐与显存优化(#45951)——多租户多适配器服务的吞吐在打磨。 https://github.com/sgl-project/sglang/pull/46500
- **Ascend NPU**:支持 Qwen3.6-35B-A3B-FP8 block FP8 MOE(#46212)、kimi-k3 NPU 融合算子修复(#47061),国产 NPU 继续补齐。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:v1.4.0rc2(2026-10-28 发布,见摘要 2)——一轮 BREAKING API 清理收敛到 KV cache V2 / transceiver V2 + Mooncake 零拷贝 + 解耦 FP4 MLA;注意 wheel 实际发为 `1.4.0rc2.post1`(移除阻碍 PyPI 发布的 Git 直连依赖)。 https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.4.0rc2
- **TGI**:仍 archived(最后 push 2026-03-21),窗口内 0 提交,属正常停维护。
- **Ollama**:窗口内 v0.40.13(2026-10-28)把 Liquid AI LFM3 家族(含 `lfm3-audio` TTS、`lfm3-omni`)从 Apple silicon 扩展到 **Linux / Windows**——上期的边缘多模态/音频能力补齐跨平台。 https://github.com/ollama/ollama/releases/tag/v0.40.13

## 模型服务 & 编排

### KServe 上游
本周无新 release,但 llmisvc 两天内密集合并(见摘要 1),是本期最值得对标的一组:
- **传输/机密安全**:EPP 指标走 TLS(#6506)、非 distroless 构建默认注入 TLS 安全 profile(#6489)、`spec.model.confidential` v1alpha1 往返保留(#6500)。 https://github.com/kserve/kserve/pull/6489
- **推理缓存**:集成 KV cache PVC evictor(#6411)、缓存节点预取运行时镜像以加速冷启(#6417)。 https://github.com/kserve/kserve/pull/6417
- **自动扩缩**:InferenceService 支持 ClusterTriggerAuthentication(#6207,集群级 KEDA 触发认证);`llm-d-router` 依赖升到 1.0.0(#6449,llm-d 网关整合趋稳)。 https://github.com/kserve/kserve/pull/6207
- 运维细节:关机时服务 drain 后再卸载模型(#6488)。

### Ray
见摘要 3。补充:
- **Serve 可观测性**:details API 暴露副本版本与已应用的 config id(#67458)——灰度/回滚可追溯。 https://github.com/ray-project/ray/pull/67458
- **Train**:`prepare_model` 支持 `parallel_strategy='simple_fsdp'`(#66902)、TPU 设备管理器支持 stream(#66822)。
- **Sandbox 隔离运行时**:overlayfs rootfs 启动(#66470)+ erofs 流式镜像(#67493)+ gRPC facade exec 状态留在 sandbox 宿主(#67078)——Ray 在构建更强的任务级隔离执行环境,值得关注其与 K8s 多租户的关系。

## 训练 & 微调
- **Kubeflow Trainer**:增量较小(OptimizationJob 已在上期详述)——新增 RuntimePatches 对 Volumes/VolumeMounts/Tolerations 的校验(#3961)、OptimizationJob 名称/算法服务名唯一性校验(#4155)、补 KEP-3562 的 kep.yaml(#4346)。 https://github.com/kubeflow/trainer/pull/3961
- **LLaMA-Factory**:新增 Xing4 模型支持(#10754),无框架级变化。 https://github.com/hiyouga/LLaMA-Factory/pull/10754

## 模型生命周期(MLflow / Registry / Feast)
- **MLflow**:安全硬化批次(见摘要 5,含 CVE-2026-53995);其余大量提交集中在其内置"issue detection / triage"AI 助手产品与 catalog 刷新,对平台能力参考有限。 https://github.com/mlflow/mlflow/pull/27230
- **Kubeflow Hub(原 model-registry)**:窗口内 10-28 以来无实质提交,无重大更新。
- **Feast**:窗口内无实质提交,无重大更新。

## LLM 评估 & 安全
- **lm-evaluation-harness**:无重大更新(10-28 以来 0 实质提交)。
- **garak**:无重大更新(10-28 以来 0 实质提交)。
- **llama-stack**:主要是 CI/测试与 `ogx connect` 新增共享 `--url` flag(#6928),无能力级变化。 https://github.com/meta-llama/llama-stack/pull/6928

## 值得跟进
- [ ] **KServe 的"TLS + 机密模型 + KV/镜像缓存"组合** 是直接对标项:我们产品的推理平面是否已有等价的传输加密默认开、机密模型字段、KV cache 淘汰与镜像预取能力?(#6506/#6500/#6411/#6417)
- [ ] **TensorRT-LLM rc2 的 BREAKING 收敛到 KV cache V2 / transceiver V2 + Mooncake 零拷贝**:若我们接 TRT-LLM 后端,需评估升级断点与 disagg/KV 分层的新接口契约。(v1.4.0rc2)
- [ ] **Ray sandbox(overlayfs/erofs)隔离运行时**:关注其定位(替代容器?补强多租户?)与 KubeRay 集成路径。(#66470/#67493)
- [ ] **vLLM/SGLang 的分层 KV + PD 解耦正进入"生产级容错"阶段**:评估我们网关/调度对 KV 租约、P2P 故障降级、PD 跨阶段一致性的要求。(vLLM #64193、SGLang #47045)
- [ ] **MLflow CVE-2026-53995(FileStore 路径穿越)**:若自建或集成 MLflow,确认升级与 artifact proxy 授权补丁已覆盖。(#26842)

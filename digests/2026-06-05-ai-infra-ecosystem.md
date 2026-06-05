# AI 推理 & MLOps 生态周报 2026-06-05

窗口:2026-06-03 → 2026-06-05(2 天,增量期,承接 [2026-06-03 digest](./2026-06-03-ai-infra-ecosystem.md))。本期**无重磅新 release**——上周的 vLLM v0.22.0 / MLflow v3.13.0 / TRT-LLM v1.3.0rc17 已覆盖,这两天只有 Ollama v0.30.4 / v0.30.5(均维护性)。但 vLLM(96)、SGLang(100+)、TRT-LLM(63)、Ray(39)的主干合入量仍很大,主轴是**KV 缓存平台化 + PD/EPD 分离硬化 + 推测解码子系统化 + 模型生命周期的多租户治理**。

## 摘要(5 条以内)

- **KV 缓存正从"引擎内部结构"升级为"平台级资源平面"**:vLLM 落地可插拔 [`KVCacheSpec` 抽象 #37505](https://github.com/vllm-project/vllm/pull/37505) + 混合内存(HMA)模型接入分层卸载并在 PD 测试默认开启([#44287](https://github.com/vllm-project/vllm/pull/44287) / [#44174](https://github.com/vllm-project/vllm/pull/44174));SGLang 把 HiCache 推到 L3 + mooncake 跨实例 offload + [KV 事件拆分写穿 #27072](https://github.com/sgl-project/sglang/pull/27072)。**KV 已是可声明、可共享、可事件订阅的独立资源——MaaS 控制面应及早引入"KV 缓存层"抽象**
- **PD/EPD 分离成为三家共同的默认架构**:SGLang 新增 [encoder DP(EPD)#26576](https://github.com/sgl-project/sglang/pull/26576) 把多模态编码从解码 pod 拆出独立扩缩,并修复 [DSA/SWA 模型 PD 状态页错配 #27004](https://github.com/sgl-project/sglang/pull/27004);Ray 修掉 vLLM 切 `RayExecutorV2` 后暴露的 [PD 端口偏移 + CUDA 早初始化抢 GPU0 两个 bug #63810](https://github.com/ray-project/ray/pull/63810)。**"P / D / E 各自独立扩缩 + 独立资源画像"要做成一等公民**
- **推测解码从实验特性走向带插件接口的稳定子系统**:SGLang 重新落地 [eagle topk>1 树状 drafting #26997](https://github.com/sgl-project/sglang/pull/26997) + [CustomSpecAlgo duck-typing 接口 #27300](https://github.com/sgl-project/sglang/pull/27300);TRT-LLM 把 [Eagle3 与 MTP-eagle 的 one-model worker 合并为统一实现 #12353](https://github.com/NVIDIA/TensorRT-LLM/pull/12353);vLLM 的 Model Runner V2 补上 [Gemma4 MTP #43241](https://github.com/vllm-project/vllm/pull/43241) 与 spec decode warmup。**spec decode 算法接口化,平台应把"投机算法"做成可插拔能力**
- **LLM 冷启动 SLA 的瓶颈被实测定位在"镜像拉取 + 节点弹性"而非引擎本身**:Ray 把 LLM 服务启动超时从 [600s 上调到 900s #63859](https://github.com/ray-project/ray/pull/63859),release test 显示 GPU worker 节点 autoscale + cu130 镜像拉取 + 入集群就吃掉 ~300s。**冷启动优化要押在预拉镜像 / 预热节点池 / 可观测埋点,而非引擎加载**
- **模型生命周期的"多租户治理 + 硬件画像元数据"持续产品化**:MLflow 把 [trace 显式绑定 run #23629](https://github.com/mlflow/mlflow/pull/23629)、[label schemas 落地 OSS #23603](https://github.com/mlflow/mlflow/pull/23603)、experiment 暴露 [workspace 字段 #23593](https://github.com/mlflow/mlflow/pull/23593);Kubeflow Hub 把 catalog 元数据键对齐为 [`min_vram_gb` / `cold_start_matrix` / `gpu_type` #2778](https://github.com/kubeflow/hub/pull/2778) 并预留 [`security-metrics` 类型 #2777](https://github.com/kubeflow/hub/pull/2777)。**OAI fork 的模型目录可直接复用这套 schema 键名,与 KServe 资源校验联动**

## 推理引擎动态

### vLLM

本窗口无新版本(v0.22.0 上周已覆盖),96 个 commit 中平台相关重点:

- **KV 连接器与 PD 分离持续硬化**:PP-aware 握手聚合让 PD 分离在张量+流水线并行下正确传递中间层输出([#43720](https://github.com/vllm-project/vllm/pull/43720));Nixl 通路新增 Mamba/混合模型 prefix caching([#42554](https://github.com/vllm-project/vllm/pull/42554));lmcache offloading 后端切到 LMCacheMPConnector([#42865](https://github.com/vllm-project/vllm/pull/42865));EPLB 的 Nixl 通信改为零拷贝([#41633](https://github.com/vllm-project/vllm/pull/41633))
- **KV 缓存分层/卸载走向可插拔**:新增可插拔 [`KVCacheSpec` 抽象 #37505](https://github.com/vllm-project/vllm/pull/37505) 为异构 KV 布局打基础;混合内存(HMA)模型接入分层卸载([#44287](https://github.com/vllm-project/vllm/pull/44287)),PD 测试默认开 HMA([#44174](https://github.com/vllm-project/vllm/pull/44174));SharedOffloadRegion 按 page-size 对齐([#43689](https://github.com/vllm-project/vllm/pull/43689))+ 小块 CPU→GPU `swap_blocks` Triton 快路径([#42212](https://github.com/vllm-project/vllm/pull/42212))
- **Model Runner V2 能力补齐**:V2 默认采样器切 FlashInfer([#42472](https://github.com/vllm-project/vllm/pull/42472));spec decode 侧补 Gemma4 MTP([#43241](https://github.com/vllm-project/vllm/pull/43241))与不同 attention 状态的 warmup/capture([#44253](https://github.com/vllm-project/vllm/pull/44253))。**V2 路径正逐步覆盖 spec decode 这类高级特性**
- **Rust 前端推进运维面**:新增 [`/server_info` 端点 #43942](https://github.com/vllm-project/vllm/pull/43942)、[动态 LoRA 加载/卸载端点 #43778](https://github.com/vllm-project/vllm/pull/43778)、[router 扩展 hook #43774](https://github.com/vllm-project/vllm/pull/43774);支持 [`--language-model-only` 跳过多模态处理器 #44500](https://github.com/vllm-project/vllm/pull/44500)。**Rust 前端正补齐 Python 前端的多租户/热更能力**
- **OpenAI/Responses API 兼容修复**:Chat Completions 流式正确处理 [`tool_choice="none"` #42752](https://github.com/vllm-project/vllm/pull/42752);Responses API 修复流式工具调用参数丢失([#44348](https://github.com/vllm-project/vllm/pull/44348))并把 developer→system 转换下沉到 HF renderer([#43590](https://github.com/vllm-project/vllm/pull/43590));在线服务工具函数收敛统一([#44479](https://github.com/vllm-project/vllm/pull/44479))
- **量化矩阵扩展**:compressed-tensors 新增 WNA8O8Int 线性层与 WNInt 嵌入([#44340](https://github.com/vllm-project/vllm/pull/44340)),NVFP4 线性层重构为单类([#42443](https://github.com/vllm-project/vllm/pull/42443))
- **稳定性/可观测性**:worker 在模型初始化后冻结 GC 降长尾抖动([#44363](https://github.com/vllm-project/vllm/pull/44363));进程组创建改 `split_group`([#41980](https://github.com/vllm-project/vllm/pull/41980));关停日志重构([#43707](https://github.com/vllm-project/vllm/pull/43707))
- 启示:
  - KV 卸载/分层从硬编码走向"可插拔 KVCacheSpec + HMA 默认开",**平台层应把 KV 分层、PD 连接器(Nixl/lmcache)做成可声明的运行时插件能力**,不绑死单一后端
  - Rust 前端已落地 `/server_info`、动态 LoRA、router hook 这类运维/多租户面,**若网关层仍依赖 Python 前端,需评估 Rust 前端成熟度并规划迁移**(动态 LoRA 热更价值高)
  - Model Runner V2 把 spec decode + FlashInfer 采样器纳入默认路径,**固化默认配置时应跟进 V2,避免后续被迫做大版本跳跃迁移**

### SGLang

本窗口无新 release(最新仍为 v0.5.12.post1,已覆盖)。06-03 → 06-05 主干合入:

- **PD 分离正确性与可观测性补强**:修复 [DSA/SWA 模型 PD 状态页传输错配 #27004](https://github.com/sgl-project/sglang/pull/27004),清理 [NIXL sender 失败状态防泄漏 #27011](https://github.com/sgl-project/sglang/pull/27011),为 [mooncake PD 后端接入分布式 tracing #23755](https://github.com/sgl-project/sglang/pull/23755) + [去重 PD logprob 归一化 #27085](https://github.com/sgl-project/sglang/pull/27085)。**PD 链路从"能跑"向"可诊断、可对账"演进**
- **EPD 编码分离 + 多模态吞吐**:新增 [encoder DP 模式 #26576](https://github.com/sgl-project/sglang/pull/26576),用每 rank 独立子进程 worker 替代单进程 MMEncoder,解除 GPU 工作阻塞 HTTP 事件循环、支持多 GPU 并行编码;配套 [diffusion 分离服务的 server args / warmup 工具 #26119](https://github.com/sgl-project/sglang/pull/26119)。**多模态生成正复用 P/D 的"分离即扩展"范式**
- **HiCache 多级缓存(L3/mooncake)持续打磨**:修复 [L3 HiCache CP reduce #27330](https://github.com/sgl-project/sglang/pull/27330)、[PD 下 L3 命中明细回传 #27046](https://github.com/sgl-project/sglang/pull/27046),[mooncake 支持 draft 模型 offload #24984](https://github.com/sgl-project/sglang/pull/24984),[mamba prefetch 按 host KV 余量截断 #26945](https://github.com/sgl-project/sglang/pull/26945),[KV 事件拆分写穿片段 #27072](https://github.com/sgl-project/sglang/pull/27072)。**KV 缓存正成为可跨实例共享、可事件化订阅的独立资源平面**
- **投机解码(spec v2)走向生产**:重新落地 [eagle topk>1 树状 drafting(page_size==1)#26997](https://github.com/sgl-project/sglang/pull/26997),启用 [trtllm_mha draft-extend 的 CUDA graph v2 #25002](https://github.com/sgl-project/sglang/pull/25002),补全 [CustomSpecAlgo duck-typing 接口防漂移 #27300](https://github.com/sgl-project/sglang/pull/27300)。**spec decode 转向带插件化算法接口的稳定子系统**
- **多节点启动 / IO 与通信优化**:[按 rank 错峰权重加载 #26937](https://github.com/sgl-project/sglang/pull/26937),ZMQ 增 [IPv6 支持 + 降日志噪声 #27180](https://github.com/sgl-project/sglang/pull/27180),Qwen3.5 增 [`--enable-symm-mem` 对称内存 #27296](https://github.com/sgl-project/sglang/pull/27296),默认开启 [DeepGEMM PDL #23979](https://github.com/sgl-project/sglang/pull/23979)
- **量化与新模型族扩展**:[compressed-tensors WNA16 非对称权重量化 #25292](https://github.com/sgl-project/sglang/pull/25292),FlashInfer NVFP4 [4over6 #25239](https://github.com/sgl-project/sglang/pull/25239) 与 [SM120(Blackwell)改进 #26496](https://github.com/sgl-project/sglang/pull/26496),[AMD 在线 MXFP4 量化 #18005](https://github.com/sgl-project/sglang/pull/18005);模型侧新增 [encoder-free 统一文/视/听模型 #27167](https://github.com/sgl-project/sglang/pull/27167)、[GLM-5 Blackwell trtllm MHA #21332](https://github.com/sgl-project/sglang/pull/21332)
- **Router 配置与调度可观测性**:实验性 sgl-router [改用 CLI flags 配置 #27073](https://github.com/sgl-project/sglang/pull/27073),新增 [`num_waiting_uncached_tokens` 负载指标 #27174](https://github.com/sgl-project/sglang/pull/27174),[健康检查失败触发调度器诊断 #26757](https://github.com/sgl-project/sglang/pull/26757)
- 启示:
  - **PD/EPD 分离已是行业默认架构**——把"P / D / E 各自独立扩缩、独立 RuntimeClass/资源画像"做成一等公民,而非把多模态编码塞进解码 pod;NIXL 失败态清理、状态页一致性这类正确性坑提前纳入 e2e
  - **KV 缓存正在平台化**——HiCache L3、跨实例 mooncake offload 与 KV 事件发布,意味 KV 已是可共享、可订阅、可计费资源。建议控制面引入"KV 缓存层"抽象(命中率指标 + 事件流),供路由器做亲和调度,对标 `num_waiting_uncached_tokens` 这类细粒度排队信号驱动 HPA
  - **量化矩阵碎片化要求平台做能力声明**——NVFP4(Blackwell SM120)、MXFP4(AMD)、WNA16 非对称并行演进,应在模型目录里把"硬件×量化格式×kernel 后端"做成可声明、可校验的兼容矩阵

### TensorRT-LLM

窗口内 ~63 commit,版本号已 bump 到 [1.3.0rc18 #14872](https://github.com/NVIDIA/TensorRT-LLM/pull/14872)(尚未发 tag,仍在 rc 滚动)。过滤 CI/waive 后,本期**新增**主线(注:per-expert LoRA #14801 上期已记,不重复):

- **MoE kernel 融合**:DeepGemmFusedMoE 把 masked gather + finalize-scale 融进单个 Triton kernel,减一次 kernel launch 与显存往返([#14592](https://github.com/NVIDIA/TensorRT-LLM/pull/14592))
- **推测解码架构收敛**:把 [Eagle3 与 MTP-eagle 的 one-model worker 合并为统一实现 #12353](https://github.com/NVIDIA/TensorRT-LLM/pull/12353),降低两套路径维护成本;AutoDeploy 补 [MTP 的 SSM replay kernel #13725](https://github.com/NVIDIA/TensorRT-LLM/pull/13725),修 [DeepSeek shared-weights 的 vanilla MTP 路径 #14457](https://github.com/NVIDIA/TensorRT-LLM/pull/14457)
- **KV cache 生命周期收紧**:KV pool window size [钳制到 max_seq_len 防越界 #14905](https://github.com/NVIDIA/TensorRT-LLM/pull/14905);[MAX_UTILIZATION 暂停时显式释放 v1 KV blocks 回收显存 #14723](https://github.com/NVIDIA/TensorRT-LLM/pull/14723);AutoDeploy 把 [非滑窗 KV window 归一为 full attention #14906](https://github.com/NVIDIA/TensorRT-LLM/pull/14906)
- **新模型与多模态扩面**:接入 [Step-3.7-Flash #14711](https://github.com/NVIDIA/TensorRT-LLM/pull/14711)、[Qwen image 文生图 #13449](https://github.com/NVIDIA/TensorRT-LLM/pull/13449),[FLUX 支持 num_images_per_prompt #14890](https://github.com/NVIDIA/TensorRT-LLM/pull/14890),[`llm.encode()` 加 encoder CUDA graph #14326](https://github.com/NVIDIA/TensorRT-LLM/pull/14326)
- **API/服务侧**:OpenAI 兼容接口 [减少流式 postprocess 开销 #14708](https://github.com/NVIDIA/TensorRT-LLM/pull/14708),[透传 chat prompt token ids #14420](https://github.com/NVIDIA/TensorRT-LLM/pull/14420);新增 [nemotron-v3 作为 nemotron-h 的 reasoning parser #14900](https://github.com/NVIDIA/TensorRT-LLM/pull/14900),reasoning 解析口径对齐
- 启示:
  - **推测解码两套路径合一(#12353)+ spec 算法接口化**与 SGLang #27300、vLLM V2 同向——平台应把"投机解码算法"做成可插拔能力,而非绑定单一实现
  - reasoning parser 走向"按模型族注册"(#14900),**统一暴露 `reasoning_content` 时应把 parser 做成可按模型注册的插件**,避免每接新推理模型就改主干

### Ollama / TGI

窗口内两个 release:**v0.30.4(2026-06-03)/ v0.30.5(2026-06-04)**,均为维护性,产品增量很薄:

- **稳定性修复为主**:v0.30.4 跟进 llama.cpp 并修 [Windows 残留 llama-server 进程 #16463](https://github.com/ollama/ollama/pull/16463) / [#16458](https://github.com/ollama/ollama/pull/16458);v0.30.5 修 [gemma4:12b 浮点异常崩溃](https://github.com/ollama/ollama/releases/tag/v0.30.5)
- **launcher/集成持续扩张(Ollama 差异化重心)**:大量 commit 是 desktop launcher 接入——[hermes desktop app + Windows 安装 #16516](https://github.com/ollama/ollama/pull/16516) / [#16487](https://github.com/ollama/ollama/pull/16487)、[Cline CLI 集成文档 #16341](https://github.com/ollama/ollama/pull/16341)
- **服务端小改进**:为 [projector(mmproj)层做 GPU offload #16473](https://github.com/ollama/ollama/pull/16473) / [#16472](https://github.com/ollama/ollama/pull/16472),多模态投影上 GPU
- 启示:Ollama 这两版几乎全押"桌面 launcher + 第三方 coding agent 一键接入",把自己做成本地模型分发/启动入口。这条边缘路线与企业级服务化正交,**按月度低频跟踪即可**
- **TGI(huggingface/text-generation-inference)**:0 commit / 0 release,月度跟踪即可

## 模型服务 & 编排

### KServe(上游)

本期仅 3 个增量,1 个产品相关:

- **[`storageUris` 支持多个 OCI 源 #5470](https://github.com/kserve/kserve/pull/5470)**(承接 #5261):此前多个 `oci://` URI 因硬编码容器/卷名(`modelcar`/`modelcar-init`)被 guard 命中后跳过,且 OCI 处理块提前 return 会把同 `storageUris` 里的 `s3://`/`gs://` 一并丢弃。修复后**多 OCI 源 + 混合存储后端可共存**——对"基座 + LoRA 适配器分仓走 OCI"是关键能力补齐
- 另两个为测试侧:[e2e 减少冗余 payload 日志 #5486](https://github.com/kserve/kserve/pull/5486);[把 `config/llmisvcconfig/**` 补进 LLMISVC e2e 触发路径 #5622](https://github.com/kserve/kserve/pull/5622)(侧面反映 `LLMInferenceService` 新路线仍在打磨)

### Ray

本期约 39 commit,无新 release。LLM/推理相关增量集中在 Serve LLM 稳定性与 Ray Data 显存治理:

- **vLLM 切 `RayExecutorV2` 后暴露并修复两个分布式 bug**:一是 worker 在设置 `CUDA_VISIBLE_DEVICES` 前就初始化 CUDA,导致共置 TP1 worker 全绑物理 GPU 0、抢不到卡 OOM;二是 PD 分离场景 `_compute_port_offset()` 在 Serve 类型切换后恒返回 0,同角色副本争抢同一 NIXL 握手端口([#63810](https://github.com/ray-project/ray/pull/63810))。**上量 DP/PD 部署才会踩到的坑**
- **新增 direct streaming 采用率遥测**:为 `RAY_SERVE_LLM_ENABLE_DIRECT_STREAMING` 加 usage tag,自动覆盖 OpenAI/DP/PD 三种模式([#63779](https://github.com/ray-project/ray/pull/63779))——direct streaming 已是默认推荐路径,官方在统计真实落地比例
- **Ray Data 批迭代显存/溢出治理(2 连发)**:[`iter_batches` 移除冗余缓冲 + 收紧 GPU 预取 #63660](https://github.com/ray-project/ray/pull/63660);[内层 format/collate 换 `iter_threaded`,pinned batch 从 ~16 降到 ~8 #63682](https://github.com/ray-project/ray/pull/63682)。**对大规模离线/批量推理(embedding、打分)直接降 OOM**
- **HAProxy 路由层稳定性 5 连击**:合并 reload、stdout/stderr 落盘防管道死锁、加 `option redispatch`+重试、隔离刚释放端口堵 404 路由竞态([#63623](https://github.com/ray-project/ray/pull/63623) / [#63621](https://github.com/ray-project/ray/pull/63621) / [#63622](https://github.com/ray-project/ray/pull/63622) / [#63628](https://github.com/ray-project/ray/pull/63628))
- **LLM 服务启动超时 [600s→900s #63859](https://github.com/ray-project/ray/pull/63859)**:release test 显示头节点 ~80s、GPU worker autoscale + cu130 镜像拉取 + 入集群 ~300s,引擎本身不慢
- 启示:
  1. PD 分离 + DP 服务切换执行后端,极易在"CUDA 早初始化抢 GPU 0"与"端口偏移计算"翻车,**分片/PD 编排要把 `CUDA_VISIBLE_DEVICES` 注入与握手端口分配做成强校验**
  2. **LLM 冷启动 SLA 应按"镜像拉取 + 节点 autoscale"为主成本设计**(预拉镜像/预热节点池 + 可观测埋点),Ray 直接把超时拉到 15 分钟说明这是行业普遍痛点,值得做差异化的快速冷启动能力

### KubeAI(原 lingo)

`kubeai-project/kubeai`(原 substratusai/lingo)本窗口提交持续为 0,**维持半年跟踪**

## 训练 & 微调

### LlamaFactory(已迁移至 `hiyouga/LlamaFactory`)

- 国产/NPU:为昇腾 NPU 适配 [GDN(Gated Delta Net)算子补丁 #10504](https://github.com/hiyouga/LlamaFactory/pull/10504),扩展 NPU 上可训练的模型结构
- 模型支持:新增 [gemma-4-12B-it #10549](https://github.com/hiyouga/LlamaFactory/pull/10549),并修 [embedding padding 时新增 token 嵌入放置位置 #10547](https://github.com/hiyouga/LlamaFactory/pull/10547)

### Kubeflow Trainer

本期 9 个 commit **全部为依赖升级(`chore(deps)`)**,无能力变更:DeepSpeed runtime 跟进 torch 2.11→2.12 / transformers 5.8→5.10([#3571](https://github.com/kubeflow/trainer/pull/3571) / [#3527](https://github.com/kubeflow/trainer/pull/3527) / [#3568](https://github.com/kubeflow/trainer/pull/3568))。训练镜像基础栈持续向前滚动,无新编排/调度特性

## 模型生命周期(MLflow / Hub / Feast)

### MLflow

本窗口无新 release(v3.13.0 上周已覆盖),~20 commit 多为下一档(Databricks 商业版对齐)的接口/钩子:

- **Trace 与 Run 显式绑定**:`run_id` 贯通 Python tracing API,可把一条 trace 直接挂到指定 run([#23629](https://github.com/mlflow/mlflow/pull/23629));`mlflow.openai.autolog` 修正 [`ChatCompletions` 子类 span 类型解析 #23759](https://github.com/mlflow/mlflow/pull/23759)。**trace↔run 归属链路收紧**
- **Label schemas(标注 schema)落地 OSS**:DAIS 2026 系列分四步合入 entity、REST/proto、handlers+SDK、OSS hooks+输入控件([#23603](https://github.com/mlflow/mlflow/pull/23603) / [#23604](https://github.com/mlflow/mlflow/pull/23604))——给 GenAI 评测引入**结构化人工标注**的基础设施
- **评测闭环 UI 化**:Evaluation Runs 页面新增 [`Run Eval` 按钮 #23758](https://github.com/mlflow/mlflow/pull/23758),并在已有 trace 时动态给出 [基于 trace 评测代码片段 #23737](https://github.com/mlflow/mlflow/pull/23737)
- **多租户/工作区线索**:experiment 响应开始暴露 [所属 workspace 字段 #23593](https://github.com/mlflow/mlflow/pull/23593);UC trace location 扩展到 [Claude Code / Codex 集成,trace 落 `catalog.schema.table_prefix` #23770](https://github.com/mlflow/mlflow/pull/23770) / [#23771](https://github.com/mlflow/mlflow/pull/23771);修 [全新数据库上 `mlflow db upgrade` 失败 #23752](https://github.com/mlflow/mlflow/pull/23752)
- 启示:MLflow 正把 trace 治理(归属 run、落库 Unity Catalog)与**结构化人工标注**做成一等公民——**OAI fork 若用 MLflow 做 GenAI 评测,需对齐 trace retention/归档位置的多租户隔离,以及 label schema 的 RBAC**;`workspace` 字段外露是多租户语义补全,但本批多为商业版对齐动作,OSS 拿到的是接口和钩子

### Kubeflow Hub(原 model-registry)

~14 commit,catalog 产品化继续:

- **catalog 元数据 schema 对齐硬件/延迟**:UI 自定义属性键对齐后端 AI Hub schema——[`minimum_vram→min_vram_gb` / `hardware_configurations→cold_start_matrix` / `hardware_type→gpu_type` #2778](https://github.com/kubeflow/hub/pull/2778);并把 [`hardware_tag` 提到模型卡标签展示 #2758](https://github.com/kubeflow/hub/pull/2758)。**vRAM/冷启动/GPU 型号正成为一类正式元数据**
- **安全度量进入 catalog**:`MetricsType` 枚举新增 [`security-metrics`(仅 OpenAPI spec,无后端实现)#2777](https://github.com/kubeflow/hub/pull/2777)——为模型安全/合规指标预留类型位
- **catalog 插件化工程**:新增 [`catalog-gen` 代码生成器 #2762](https://github.com/kubeflow/hub/pull/2762),从 flag 一键脚手架出新 catalog 插件;catalog context 抽成 [通用 `createCatalogContext` 工厂 #2752](https://github.com/kubeflow/hub/pull/2752)
- **controller 部署正确性修复**:当 ModelRegistry service 先于 InferenceService 删除时,[移除卡在 Terminating 的 finalizer #2789](https://github.com/kubeflow/hub/pull/2789)
- 启示:Hub 的 catalog 正把**硬件画像(vRAM/冷启动矩阵/GPU 型号)+ 安全度量**结构化进 schema,并用插件生成器支持多源接入——这正是做"模型选型/部署门禁"最需要的元数据基础。**OAI fork 可直接复用 `cold_start_matrix` / `min_vram_gb` 键名,与 KServe InferenceService 资源校验联动,避免自造 schema 后难对齐上游**

### Feast

无新 release,~6 commit,主线是企业级合规+观测:

- **离线 store 可观测性 + SOX 审计**:新增 [offline store 的 RED Prometheus 指标 + 在线/离线两条取数路径结构化 SOX 审计日志 #6340](https://github.com/feast-dev/feast/pull/6340)——补上此前缺失的离线路径
- **OpenLineage 默认配置**:允许给 [OpenLineage 设默认配置 #6467](https://github.com/feast-dev/feast/pull/6467),降低数据血缘接入门槛
- **热路径性能**:同期博客主推 Feature Server 亚 2ms 延迟([commit a7f7a02](https://github.com/feast-dev/feast/commit/a7f7a02));修 [Athena 物化对 `Array(String)` 列的 TypeError #6324](https://github.com/feast-dev/feast/pull/6324)
- 启示:Feast 这批主线是"企业级合规+观测"(SOX 审计、离线 RED 指标、血缘),补上特征平台在受监管行业落地的短板——**若 OAI fork 集成 Feast,审计日志和指标可直接对接既有多租户监控栈,但 SOX 日志留存与脱敏策略需自定**

## LLM 评估 & 安全

### lm-evaluation-harness

- 本窗口无新提交,**无重大更新,维持月度跟踪**

### garak(NVIDIA 红队工具)

- 修复 [多模态生成器 NVMultimodal(NIM provider)在 prompt 预处理时丢失多轮对话的问题 #1837](https://github.com/NVIDIA/garak/pull/1837),现完整保留所有 turn——影响多轮多模态越狱/红队探测准确性;其余为 plugin_cache 自动更新
- 启示:garak 正补齐多模态+多轮场景覆盖,**我们若提供模型安全评测应把"多轮上下文保真"作为基本要求**,避免单轮探测高估安全性

### ogx(原 meta-llama/llama-stack)

本窗口 ~11 commit,主线是把 Anthropic Messages API 兼容与 Claude Code/Agent SDK 接入做扎实:

- 修复 [`ogx connect claude` CLI 的 `/v1` 重复后缀导致 404 #5985](https://github.com/ogx-ai/ogx/pull/5985):`--url` 带 `/v1` 时 Anthropic SDK 会自行再追加,导致请求打到 `/v1/v1/messages`;现在 `_build_env` 在设 `ANTHROPIC_BASE_URL` 前剥掉尾部 `/v1`——**Claude Code 真正连上自建 OGX 服务端的关键修复**
- 新增 [针对上游 `claude-agent-sdk` 的活体冒烟测试 #6010](https://github.com/ogx-ai/ogx/pull/6010):该 SDK 不直接走 HTTP,而是拉起 Claude Code CLI 子进程解析其流式输出,因此覆盖了与 CLI 不同的客户端面(会话流式、`ResultMessage` 解析、inline system-role 分发)
- 安全加固:[Brave/Tavily/Bing 搜索 provider 的 `api_key` 由 `str` 改 `SecretStr` #6013](https://github.com/ogx-ai/ogx/pull/6013),降低密钥在日志/序列化泄露
- [Bedrock provider 切到 AWS 原生 SigV4/STS 鉴权 #5720](https://github.com/ogx-ai/ogx/pull/5720),给出现存配置迁移路径
- 工程化:[OpenAI provider 的 `construct_model_from_identifier` 重构去重 #5994](https://github.com/ogx-ai/ogx/pull/5994),新增 [集成测试目标模型矩阵文档 #5741](https://github.com/ogx-ai/ogx/pull/5741)
- 启示:
  - ogx 正把自己定位成"Claude Code / Agent SDK 的自托管后端"——通过 `/v1/messages` 兼容层 + `ogx connect claude`,任意后端 provider(Bedrock、OpenAI 等)都能被 Claude Code 当 Anthropic 端点调用。**我们做企业级网关值得对标这条路径,尤其"SDK 实为拉起 CLI 子进程"这一隐藏耦合——接入测试要像 ogx 一样区分 CLI 面与 SDK 面分别冒烟**
  - 密钥用 `SecretStr` 包装、Bedrock 走 SigV4/STS 而非长期密钥,是多 provider 网关的安全合规基线,可直接纳入 provider 接入规范

## 值得跟进

- [ ] **vLLM KV 缓存可插拔化**:[#37505 KVCacheSpec](https://github.com/vllm-project/vllm/pull/37505) + [#44287 HMA 分层卸载](https://github.com/vllm-project/vllm/pull/44287) + [#44174 PD 测试默认开 HMA](https://github.com/vllm-project/vllm/pull/44174)。**评估把 KV 分层 / PD 连接器做成平台可声明插件能力**,不绑死单一后端
- [ ] **vLLM Rust 前端运维面成熟度**:[#43942 /server_info](https://github.com/vllm-project/vllm/pull/43942) + [#43778 动态 LoRA 端点](https://github.com/vllm-project/vllm/pull/43778) + [#43774 router hook](https://github.com/vllm-project/vllm/pull/43774)。**若网关依赖 Python 前端,评估 Rust 前端迁移路径(动态 LoRA 热更价值高)**
- [ ] **SGLang EPD 编码分离**:[#26576 encoder DP](https://github.com/sgl-project/sglang/pull/26576) + [#26119 diffusion 分离服务工具](https://github.com/sgl-project/sglang/pull/26119)。**评估把多模态编码从解码 pod 拆出、P/D/E 各自独立扩缩的编排模型**
- [ ] **KV 缓存平台化(SGLang)**:[#27072 KV 事件拆分写穿](https://github.com/sgl-project/sglang/pull/27072) + [#24984 mooncake 跨实例 offload](https://github.com/sgl-project/sglang/pull/24984) + [#27174 num_waiting_uncached_tokens 指标](https://github.com/sgl-project/sglang/pull/27174)。**在控制面引入"KV 缓存层"抽象(命中率指标 + 事件流),用细粒度排队信号驱动 HPA**
- [ ] **投机解码算法接口化**:SGLang [#27300 CustomSpecAlgo](https://github.com/sgl-project/sglang/pull/27300) + TRT-LLM [#12353 Eagle3/MTP-eagle 合一](https://github.com/NVIDIA/TensorRT-LLM/pull/12353) + vLLM V2 spec decode。**把"投机解码算法"做成可插拔平台能力**
- [ ] **Ray RayExecutorV2 PD/DP 两个 bug 修复**:[#63810](https://github.com/ray-project/ray/pull/63810)(CUDA 早初始化抢 GPU0 + PD 端口偏移)。**用 Ray Serve LLM 的 MaaS 立即评估;分片/PD 编排把 CUDA_VISIBLE_DEVICES 注入与握手端口做成强校验**
- [ ] **LLM 冷启动 SLA 设计**:Ray [#63859 超时 600→900s](https://github.com/ray-project/ray/pull/63859) 实测瓶颈在镜像拉取 + 节点 autoscale。**做预拉镜像 / 预热节点池 + 冷启动可观测埋点,作为差异化能力**
- [ ] **KServe storageUris 多 OCI 源修复**:[#5470](https://github.com/kserve/kserve/pull/5470)。**OAI fork 跟版本时 cherry-pick——影响"基座 + LoRA 适配器分仓走 OCI"与 OCI/S3 混合存储**
- [ ] **Kubeflow Hub catalog 硬件画像 schema**:[#2778 min_vram_gb/cold_start_matrix/gpu_type](https://github.com/kubeflow/hub/pull/2778) + [#2777 security-metrics 类型](https://github.com/kubeflow/hub/pull/2777)。**OAI 模型目录直接复用键名,与 KServe 资源校验联动**
- [ ] **MLflow GenAI 评测治理**:[#23629 trace↔run 绑定](https://github.com/mlflow/mlflow/pull/23629) + [#23603 label schemas](https://github.com/mlflow/mlflow/pull/23603) + [#23593 workspace 字段](https://github.com/mlflow/mlflow/pull/23593)。**用 MLflow 做 GenAI 评测需对齐 trace 归档位置的多租户隔离与 label schema RBAC**
- [ ] **ogx Anthropic Messages 自托管后端**:[#5985 connect claude /v1 修复](https://github.com/ogx-ai/ogx/pull/5985) + [#6010 agent-sdk 活体冒烟](https://github.com/ogx-ai/ogx/pull/6010) + [#6013 SecretStr](https://github.com/ogx-ai/ogx/pull/6013)。**做企业级网关对标其路径,接入测试区分 CLI 面与 SDK 面**
- [ ] **TRT-LLM reasoning parser 按模型注册**:[#14900 nemotron-v3 parser](https://github.com/NVIDIA/TensorRT-LLM/pull/14900)。**统一暴露 reasoning_content 时把 parser 做成可按模型注册的插件**

## 原始材料

<details>
<summary>本窗口 release(2026-06-03 → 2026-06-05)</summary>

- Ollama v0.30.5(2026-06-04)、v0.30.4(2026-06-03)— 维护性
- TensorRT-LLM 版本号内部 bump 至 v1.3.0rc18(尚未发 tag)
- vLLM、SGLang、KServe、Ray、MLflow、Feast、Hub、ogx、LlamaFactory、Trainer、garak、lm-eval、TGI、KubeAI 本窗口无新 release
</details>

<details>
<summary>本窗口 commit 计数(since=2026-06-03T00:00:00Z,过滤前)</summary>

- SGLang:100+(分页)
- vLLM:96
- TensorRT-LLM:63
- Ray:39
- mlflow:20
- kubeflow/hub:14
- ogx:11
- kubeflow/trainer:9(全 deps bump)
- feast:6
- ollama:16
- garak:3、kserve:3、LlamaFactory:3
- 0 commit:TGI、lm-evaluation-harness、KubeAI
</details>

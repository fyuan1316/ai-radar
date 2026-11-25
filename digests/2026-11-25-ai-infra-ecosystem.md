# AI 推理 & MLOps 生态周报 2026-11-25

窗口:2026-11-18 ~ 2026-11-25(过去 7 天)。11-20 期已覆盖到 11-20(TensorRT-LLM v1.3.0、Hub #3455 SQL 注入、vLLM `--max-tokenize-tokens` 等),本期重点写 **11-20 之后**的新变化,旧条目只在有后续时提及。已过滤版本 bump、dependabot、CI、纯文档和测试修复。
源仓库沿用改名后的路径:lingo→kubeai-project/kubeai、training-operator→kubeflow/trainer、model-registry→kubeflow/hub、llama-stack→ogx-ai/ogx(release 仍看 meta-llama/llama-stack)。

本周主线很清楚:**各仓集中修「鉴权绕过 / 租户越权 / 资源耗尽」类安全问题**,而且大部分修复只进了 main,还没有发版。

## 摘要(5 条以内)

1. **vLLM `--api-key` 鉴权可被完全绕过(配置了特定 `--root-path` 时),已修但未发版**:`AuthenticationMiddleware` 用 `str.removeprefix(root_path)` 剥前缀,而 Starlette 路由只在路径段边界剥。`--root-path /v` 时 `/v1/models` 被剥成 `1/models`,鉴权判断为「非受保护路由」直接放行,但路由仍正常分发,导致所有受保护路由免 token 访问。修复改用 Starlette 的 `get_route_path`(#52794,11-21 合入)。最新 release v0.34.0(11-16)不含此修复。 https://github.com/vllm-project/vllm/pull/52794
2. **Kubeflow Hub(原 model-registry)又合入 3 个安全修复,加上周的 SQL 注入共 4 个,都还没发版**:
   - ISVC 控制器把**自己的 SA token**发给 InferenceService 注解里指定的 registry URL。能创建 ISVC 的用户把 URL 指到自己控制的主机,就能拿到持有 `model-registry-manager-role` ClusterRole 的 token(#3462)。
   - CSI storage-initializer 只校验初始 URI,HTTP 302 跳转可以绕过白名单,打到 `169.254.169.254` 等元数据地址(#3468)。
   - 配了 MySQL CA 但 `verify-server-cert` 保持默认 false 时,实际不校验证书,数据库密码可被中间人截获(#3471)。

   最新 release 仍是 v0.3.18(10-22)。 https://github.com/kubeflow/hub/pull/3462
3. **KServe 修复 Gateway API 下基于路径的路由错发**:Standard 模式下配置 `pathTemplate` 时,路径规则是未锚定的正则,Envoy 永远匹配不上;而且每个 ISVC 都在共享 `ingressDomain` 上挂了 `^/.*$` 兜底规则,导致 `/serving/<ns>/<name>/...` 请求被发给**任意一个模型**。现在拆成独立的 `<isvc>-path` HTTPRoute,用 PathPrefix 匹配并剥掉前缀,未知路径返回 404(#6650)。另外,安装器的 Envoy AI Gateway 升到 v1.3.0,修复了默认 LLMInferenceService 路由一个请求最多调用 EPP 16 次的问题(#6660)。 https://github.com/kserve/kserve/pull/6650
4. **应用层「多租户隔离没做完」的问题集中暴露**:
   - OGX 的 Skills 和 Anthropic message batches 原先存在全局 KV 里、不带 owner,`tenancy.mode=multi` 下任意用户可以读、改、删别人的数据(#7084、#7047;#7047 是破坏性变更,启动时必须能解析到 SQL store)。
   - Feast `Permission.required_tags` 从未生效,「仅 team=risk」这类权限实际匹配所有资源;lineage RBAC 默认放行(#7191)。
   - MLflow:Assistant 可以挂载无读权限实验的项目目录(#28071);OTLP `/v1/traces` 存在解压炸弹(#28060);GraphQL 鉴权中间件构建失败时退化为不鉴权,现已改为失败即拒绝(#27995)。

   https://github.com/ogx-ai/ogx/pull/7084
5. **推理冷启动出现「进程快照跨机迁移」路线**:vLLM 快照功能从原地 checkpoint/restore 扩展到跨机器(step 1:打包 triton JIT 缓存等启动产物、GPU UUID 映射、IP 变更重连、避免 PID 冲突),目标场景明确是自动扩缩(#61544)。同时给 model loader 加了 sleep/wake/reload 钩子,服务于 ModelExpress 通过 P2P/RDMA 从 GPU 显存直接分发权重(#57011)。 https://github.com/vllm-project/vllm/pull/61544

---

## 推理引擎动态

### vLLM
本周无新 release(最新仍是 v0.34.0,11-16)。
- **安全**(都在 main,未发版):
  - **鉴权绕过**:见摘要 1(#52794)。**启示**:我们如果给 vLLM 配了 `--root-path`(网关子路径部署时常见),在升级前要确认值不是受保护路由的字符串前缀;更稳妥的做法是不依赖引擎自带的 `--api-key`,在网关层统一鉴权。 https://github.com/vllm-project/vllm/pull/52794
  - **模型目录逃逸**:Sentence Transformers 的 `modules.json` 可以让 Pooling/Dense 加载器读取模型目录以外的文件(绝对路径、`..`、符号链接)。现在会校验路径,不合法就加载失败(#61430)。用户上传 embedding 模型的平台会受影响。 https://github.com/vllm-project/vllm/pull/61430
  - **多模态资源上限继续收紧**:
    - 新增 `VLLM_MAX_MEDIA_PREPROCESSING_BYTES`,默认约 683 MiB,单个 prompt 的媒体预处理超限返回 400(#69098)。
    - 一个批量 HTTP 请求内共享下载和解码字节预算(#68249)。
    - 限制 batch chat 的会话条数(#68904);pooling/scoring 路由限制 prompt 条数(#53473)。
    - 同步媒体拉取设置 deadline,防止慢速 URL 占住 pooling renderer 唯一的 worker(#69461)。

    https://github.com/vllm-project/vllm/pull/69098
  - **启示**:这是上周 tokenize 上限的延续。多模态服务模板里应该显式设置 `VLLM_MAX_MEDIA_PREPROCESSING_BYTES`,并在网关层限制请求体积。
- **Fast Start / 弹性**:
  - 跨机快照,见摘要 5(#61544)。
  - preload daemon 支持 VMM IPC 后端(#68210),延续上周的 `--weight-cache-seed`。
  - loader 的 sleep/wake 钩子(#57011)。
  - **启示**:冷启动现在有三条路线:权重从已有副本复制、进程快照迁移、LocalModelCache 从 PVC 加载。快照路线要求平台处理 GPU UUID 映射和 Pod IP 变化,和 K8s 调度强相关,值得单独评估。 https://github.com/vllm-project/vllm/pull/57011
- **KV offload**:多层 offload connector 新增 `access_mode`(read/write/readwrite),可以组合成「CPU 写入文件系统 + GDS 从文件系统直读到 GPU」(#67961);HF3FS connector 支持非 CUDA 设备(#66969)。 https://github.com/vllm-project/vllm/pull/67961
- **可观测**:`--enable-logging-iteration-details` 时,每次迭代额外输出 KV 上下文长度和等待队列摘要,可以用来从 batch 组成建模迭代耗时(#61691)。对我们做「按负载预测扩缩」有用。 https://github.com/vllm-project/vllm/pull/61691
- **RL / LoRA**:新增 worker 本地的张量 LoRA 加载(verl 风格,私有接口,#69229);新增 Connex 权重传输后端(#63805)。
- **弃用与删除**:LM Format Enforcer 结构化输出后端已删除,配置 `backend=lm-format-enforcer` 会直接校验失败(#69564);TorchAO 量化后端标记弃用,计划在 v0.37 删除(#69066)。**启示**:平台模板或 UI 里如果暴露了这两个选项,需要下线。 https://github.com/vllm-project/vllm/pull/69564

### SGLang
本周无新 release。
- **sgl-router 运行时 worker 管理 API**:原先 worker 只能来自静态配置或 K8s 发现,现在可以通过 API 增加、替换、删除 worker,`PUT`/`DELETE` 用 `If-Match` 做乐观并发;静态和 K8s 发现的 worker 通过 API 只读(#50242)。**启示**:外部控制面(例如我们的调度器或 Operator)可以直接驱动 router 的成员变更,不必依赖它自己的 K8s 发现。 https://github.com/sgl-project/sglang/pull/50242
- **控制面加鉴权**:
  - diffusion server 新增 `--api-key` 和 `--admin-api-key`。更新权重、LoRA、释放显存、profiling 等路由在未设置 admin key 时一律返回 403(#52929)。
  - Rust server 的 `/internal/peer` 原先在无 key 时任何人都能投递控制消息,现在改为只接受同一次启动内各 listener 之间用随机 token 互相调用(#51946)。

  https://github.com/sgl-project/sglang/pull/52929
- **PD 解耦**:Mooncake 抽象到通用 `Transport` 接口之后,便于接入其他传输后端(#46460);新增可选的、基于 EGM 的 Mooncake Store 池,走 NVLink(#51416)。 https://github.com/sgl-project/sglang/pull/46460

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:窗口内的 release 是 v1.3.0(11-20)和 v1.4.0rc4(11-18),11-20 期已详述。之后的新变化:
  - **BREAKING**:Qwen2.5-VL 和 Qwen3-VL 的 image embeddings 必须带上 `image_grid_thw`,否则直接报错。这是为了修复 PD 解耦(如 Dynamo)下图像 mRoPE 位置错误的问题(#22328)。 https://github.com/NVIDIA/TensorRT-LLM/pull/22328
  - 设置 `TLLM_KV_POOL_LOG=1` 后,按 pool group 输出 KV 利用率。KVCacheManager V2 下单个 pool 满了会被总利用率掩盖(#19098)。 https://github.com/NVIDIA/TensorRT-LLM/pull/19098
- **TGI**:仍为 archived 状态,无更新。
- **Ollama v0.40.18**:只有 Mac MLX 性能优化,以及删除 JetPack 5 支持(#19865)。无重大更新。 https://github.com/ollama/ollama/releases/tag/v0.40.18

## 模型服务 & 编排

### KServe 上游
本周无新 release。
- **Gateway API 路径路由修复**(#6650),见摘要 3。**启示**:我们的 fork 如果在共享域名下按路径暴露模型,要确认没有继承 `^/.*$` 兜底规则;这个问题属于「请求被发到错误租户的模型」,严重程度高于一般 bug。 https://github.com/kserve/kserve/pull/6650
- **Envoy AI Gateway 升级到 v1.3.0**,修复同一请求重复调用 EPP(#6660)。升级时注意上游的升级指引。 https://github.com/kserve/kserve/pull/6660
- Python transformer 在 `--workers > 1` 时对所有请求返回 501 `Could not find PredictorConfig`,原因是 spawn 出来的子进程拿不到 context var(#6662)。 https://github.com/kserve/kserve/pull/6662
- Logger 不再对响应体做两次拷贝,不需要记录响应时也不再缓存(#6180)。

### Ray
- **ray-2.60.1 / 2.59.2 / 2.57.2**(11-23 ~ 11-24),都是安全补丁:
  - Brotli CVE-2026-111497(已列入 CISA KEV)。base-deps 里 conda 自带的 brotli-python 1.1.0 不受 pip lock 管理,所以**所有 ray、ray-ml、ray-llm 镜像**都带着有漏洞的版本。
  - 2.60.1 另外修复了 token 鉴权文件 `~/.ray/auth_token` 以 0644 权限落盘、同机其他用户可读的问题。已有文件需要手动 `chmod 600`。

  https://github.com/ray-project/ray/releases/tag/ray-2.60.1
  - **启示**:我们分发的 Ray/KubeRay 镜像需要重建,同时在镜像扫描规则里检查 conda 环境里的包,不能只看 pip lock。
- 主线本周基本是 Ray Data 的工作。Serve LLM 没有新提交,上周的「按 token 扩缩」第 2 步仍未出现。

### KubeAI
- Helm chart 原先只在 release namespace 创建 `kubeai-models` ServiceAccount,配置 `watchNamespaces` 后,其他命名空间的模型 Pod 都会被准入拒绝,现已修复(#796)。属于 bug 修复,无重大更新。 https://github.com/kubeai-project/kubeai/pull/796

## 训练 & 微调
- **Kubeflow Trainer**:无新 release。
  - OptimizationJob(超参调优)的 webhook 拒绝用户自己设置保留前缀 `KUBEFLOW_TRAINER_OPT_` 的环境变量(#4453),也拒绝空的 categorical 选项(#4489)。
  - S3 initializer 不再默认 `region="auto"`。原先这个默认值导致 AWS 上所有 `s3://` 都失败,也会忽略 EKS 注入的 `AWS_REGION`(#4114)。
  - Nutanix 加入 adopters。

  https://github.com/kubeflow/trainer/pull/4114
- **LlamaFactory**:Intel XPU 支持 profiler 和 fp16(#10876、#10868);Docker 镜像加入 FSDPTurbo,triton-ascend 升到 3.6.0(#11011)。无框架级变化。 https://github.com/hiyouga/LlamaFactory/pull/11011

## 模型生命周期(MLflow / Registry / Feast)
- **Kubeflow Hub**:3 个安全修复(#3462、#3468、#3471),见摘要 2;另外,metric history 查询改为整名匹配(#3474)。仍未发版。**启示**:
  - 我们如果用了 model-registry 的 ISVC 集成(registry 注解驱动),要确认控制器不会把自己的 token 发给用户指定的 URL。
  - 修复发版前,可以用 NetworkPolicy 或准入策略限制 `modelregistry.kubeflow.org/url` 注解的取值。
  - CSI 拉取模型时要逐跳校验 302 跳转。
  - MySQL 后端显式设置 `verify-server-cert=true`。

  https://github.com/kubeflow/hub/pull/3468
- **MLflow**(无新 release),本周全是安全修复:
  - OTLP 解压炸弹(#28060)。
  - Assistant 越权挂载项目目录(#28071)。
  - `_safe_extractall` 的硬链接逃逸(#28018)。
  - GraphQL 鉴权改为失败即拒绝(#27995)。
  - 禁止模型代码执行时拒绝加载 Keras 2 H5 模型(#27980)。
  - `SearchLoggedModels` 的 `max_results` 上限设为 5 万(#28100)。

  https://github.com/mlflow/mlflow/pull/28060
- **Feast**:
  - RBAC 修复,见摘要 4(#7191)。 https://github.com/feast-dev/feast/pull/7191
  - 新增 OnlineConfig 的 sequence 模式基础,即在线特征可以按序列保留、设置保留上限(#6848),这是实验性的地基 PR。
  - context 模块新增 TokenBudget 和可插拔分词器(3ece12f),说明 Feast 在往「给 LLM 供给上下文」的方向延伸。 https://github.com/feast-dev/feast/commit/3ece12f005

## LLM 评估 & 安全
- **lm-evaluation-harness**:窗口内无提交,无重大更新。
- **garak**:新增 `goodside.TagIntent`(按意图生成 8 种隐藏 Unicode tag 注入变体),用来替代基于固定触发词的 `goodside.Tag`,旧探针随后会被禁用(#2430)。如果我们的评测流水线固定使用 `goodside.Tag`,需要切换。 https://github.com/NVIDIA/garak/pull/2430
- **OGX(原 llama-stack)**:无新 release。
  - 安全:多租户隔离修复(#7084、#7047,见摘要 4);图片 URL 的 DNS rebinding TOCTOU 漏洞和 connector MCP 读取补上了 SSRF 防护(#7040);Milvus filter 转义(#7042)。 https://github.com/ogx-ai/ogx/pull/7040
  - 继续做破坏性清理:`GET /v1/responses` 返回值与 OpenAI 结构对齐(#7083);删除 `stack run` 等旧 CLI(#7076)、`tool_groups` 和 `image_name` 配置(#7077)、`/v1alpha/file-processors/process`(#7078)。依赖旧配置的发行版需要迁移。

## 值得跟进
- [ ] 排查自家推理模板中 vLLM 的 `--root-path` 配置,确认不受 #52794 影响;跟踪带上该修复的 vLLM 下一个 release
- [ ] 自查 ODH 和自家 model-registry fork 是否存在 Hub #3462(控制器 token 外发)、#3468(302 跳转绕过白名单)、#3471(MySQL 不校验证书);跟踪 kubeflow/hub v0.3.19,目前共 4 个安全修复未发版
- [ ] 核对 fork 中的 KServe Gateway API 路径路由是否存在 `^/.*$` 兜底规则(#6650),以及 LLMISVC 的 EPP 重复调用(#6660)
- [ ] 重建 Ray 镜像(brotli CVE、auth_token 权限),镜像扫描覆盖 conda 环境
- [ ] 下线模板或 UI 中的 lm-format-enforcer 选项(已删除)和 torchao 选项(v0.37 删除)
- [ ] 评估 vLLM 跨机快照(#61544)作为扩缩冷启动方案,与权重复制、LocalModelCache 做对比
- [ ] 评估由我们的控制面通过 sgl-router 的 worker 管理 API(#50242)驱动成员变更

# AI 推理 & MLOps 生态周报 2026-11-20

窗口:2026-11-13 ~ 2026-11-20(过去 7 天)。11-18 期已覆盖 11-11 ~ 11-18 的内容(vLLM v0.34.0 默认值变化、Feast 伪造令牌、SGLang 删除 sgl-model-gateway 等),本期只简单提及这些条目,重点写 11-18 之后的新变化。已过滤版本 bump、dependabot、CI、纯文档和测试修复。
源仓库沿用改名后的路径:lingo→kubeai-project/kubeai、training-operator→kubeflow/trainer、model-registry→kubeflow/hub、llama-stack→ogx-ai/ogx(release 仍看 meta-llama/llama-stack)。

## 摘要(5 条以内)

1. **Kubeflow Hub(原 model-registry)的模型目录接口有 SQL 注入,已在 main 修复,但还没有发版**:`sortValueQuery` 把 `filterQuery` 里 `artifacts.<name>` 的属性名直接拼进 JOIN 别名。请求带 `orderBy=ACCURACY` 加一个构造过的反引号属性名,就能通过公开的 list 接口把任意 SQL 注入 catalog 的 Postgres 查询(PR 中的复现用的是 `pg_sleep`)。修复后别名改由条件序号生成(#3455)。最新 release v0.3.18 发于 10-22,所以**已发布的版本都包含这个漏洞**;opendatahub-io/model-registry fork 也还没有对应 PR。 https://github.com/kubeflow/hub/pull/3455
2. **TensorRT-LLM v1.3.0 正式版:去掉 TensorRT 引擎后端,只保留 PyTorch,并且默认开启使用遥测**:`trtllm-build`、C++ Executor、TensorRT-engine 的 Triton 后端全部删除;KV 传输超时默认 60s;单条请求的 chat template 改为需要显式开启;CLI flag 覆盖 YAML。PD 解耦不配 `internal_request_auth_key` 已被标记为弃用。**使用遥测默认开启**,关闭方式是设置 `TRTLLM_NO_USAGE_STATS=1` 或 `DO_NOT_TRACK=1`。同时新增 Anthropic `/v1/messages`、gRPC server 和 Prometheus 指标。 https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0
3. **vLLM 集中补「请求体积型」DoS 防护,并让副本之间互相灌权重**:安全方面,`/tokenize`、`/detokenize`、`count_tokens` 新增 `--max-tokenize-tokens` 上限(#67348);Rust 前端对未配置的模态也默认限制最多 999 个多模态项,不再是无限(#52602);视频帧在解码前就计入请求预算(#67314);在解码前拒绝 ICNS 图片(#68245)。Fast Start 方面,新增 `vllm preload --weight-cache-seed`,新副本可以从已加载的副本拉权重(同机走 CUDA IPC,跨机走 Mooncake RDMA),不必再读 checkpoint(#64641)。 https://github.com/vllm-project/vllm/pull/64641
4. **推理路由层继续往「会话亲和 + 按阶段分别负载均衡」演进**:Ray Serve LLM 的入口 router 用 HAProxy 一致性哈希,把同一会话固定到同一个 router 副本,并复用分词缓存(#67940);sgl-router 的 prefill 和 decode 改用各自独立的 DP rank 策略,`least_tokens` 改为按「预期 KV 占用」排序(#51415),同时新增 OpenAI Responses API(#42314)。 https://github.com/ray-project/ray/pull/67940
5. **OGX(原 llama-stack)破坏性删除 tool_runtime 和 tool_groups API**:同时删掉的还有 MCP tool runtime provider 和 `GET /v1/admin/tools`;file search 已收进 Responses API 内部(#7039、#7033)。基于 llama-stack 做 Agent/工具编排的集成需要迁移。 https://github.com/ogx-ai/ogx/pull/7039

---

## 推理引擎动态

### vLLM
本周 release 只有 v0.34.0(11-16,11-18 期已详述:可扩展 KV 默认开启、`gpu_memory_utilization` 默认 1.0、V1 Runner 删除)。 https://github.com/vllm-project/vllm/releases/tag/v0.34.0
11-18 之后的主线:
- **API server 资源边界加固**(一组 4 个 PR):
  - `--max-tokenize-tokens`,对应环境变量 `VLLM_MAX_TOKENIZE_TOKENS`,默认值为 `max(max_model_len*2, 131072)`,超限返回 400。Rust 前端暂不支持这个参数,配置后启动直接报错(#67348)。 https://github.com/vllm-project/vllm/pull/67348
  - Rust 前端原先把 `--limit-mm-per-prompt` 中没有列出的模态当作不限量。32 MiB 以内的单个请求就能触发无上限的媒体任务展开,在推理开始前就 OOM。现在默认限制为 999,与 Python 前端一致(#52602)。 https://github.com/vllm-project/vllm/pull/52602
  - 视频帧在解码前计入请求预算(#67314);在解码前拒绝 ICNS 图片(#68245)。 https://github.com/vllm-project/vllm/pull/68245
  - **启示**:我们的推理网关和 API 层应该在入口就限制 token 数、多模态项数和 body 大小,不要只靠引擎自己的默认值;Rust 前端和 Python 前端的默认值不一致,本身就是一类风险。
- **Fast Start / 权重预载**:`vllm preload --weight-cache-seed <source>` 让新副本的 daemon 从已加载的副本拉取权重分片,同机用 `peer_ipc`,跨机用 Mooncake `rdma`,也支持链式灌入(#64641);另外支持 ModelOpt INT8 和 compressed-tensors WNA16 预处理权重的缓存重启(#68176、#68328),删除了 IPC loader 的 copy 模式(#68388)。**启示**:扩副本时可以「从已有副本复制权重」而不是从对象存储重新拉,这和我们的模型缓存、预热方案(KServe LocalModelCache 一类)是两条不同路线,值得做冷启动对比。 https://github.com/vllm-project/vllm/pull/64641
- **跨引擎共享只读表**:新增 `engram_pool`,把 DeepSeek V4.1 的 Engram 表按行切分到一组引擎的所有 GPU 上,通过 NVLink(cuMem FABRIC)或 RDMA 取数,整个集群只存一份(#67539)。这对调度提出了新要求:需要把同一个 peer group 的引擎放在同一个 NVLink 或 RDMA 域内。 https://github.com/vllm-project/vllm/pull/67539
- **KV Connector 容错**:Mooncake 会校验传输结果,失败的传输也会被标记为完成(#67939),并遵守单请求的 offload 上限(#68529);NIXL 推送修复了提交卡顿和块提前释放的问题(#66795)。 https://github.com/vllm-project/vllm/pull/67939
- RL 场景:权重更新默认直接 reload(`VLLM_RELOAD_MODE=auto`,#68041)。镜像和 CI 默认 Python 改为 3.14(#68457),自建镜像时需要注意。 https://github.com/vllm-project/vllm/pull/68457

### SGLang
本周无新 release。
- **sgl-router**:
  - 新增 `POST /v1/responses`。请求在入口转换成 chat 请求,复用 cache-aware 路由、准入、重试和 PD 解耦(#42314)。 https://github.com/sgl-project/sglang/pull/42314
  - 新增 `--decode-dp-rank-policy`,prefill 和 decode 分开选 rank;`least_tokens` 改为按预期 KV 排序,PR 中的测试显示 decode KV 不均衡度从约 1.0 降到与 least_in_flight 相当的水平(#51415)。 https://github.com/sgl-project/sglang/pull/51415
  - DeepSeek 图像对话按前缀缓存路由(#48937)。
- **Rust server 补齐协议**:Anthropic Messages API(HTTP 和 gRPC,#49744)、无状态 `/v1/responses`(#49748)、`/v1/score` 与 embeddings、rerank、classify schema(#49746),以及 Vertex 和 SageMaker 包装(#49747)。 https://github.com/sgl-project/sglang/pull/49744
- **PD 解耦**:支持基于 NIXL 的统一内存 PD(#50767);`/v1/loads` 报告 decode host pool 已满的状态(#50853)。 https://github.com/sgl-project/sglang/pull/50767
- **镜像**:AWS EFA 直接装进主镜像,不再单独发 `-efa` 变体,运行时通过 `MOONCAKE_PROTOCOL=efa` 等环境变量开启(#48678)。 https://github.com/sgl-project/sglang/pull/48678
- 11-18 期已报道的 gateway 删除(#50732)和弃用 flag 清理(#51074)本周没有后续变化。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM v1.3.0**(11-20,正式版)。 https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0
  - **BREAKING**:TensorRT 后端删除,只剩 PyTorch 后端(`trtllm-build`、`BuildConfig`、`trtllm-bench build` 都删了);C++ Executor 和旧 runtime 删除;Triton 只保留 `llmapi` 模型;两模型投机解码、AutoDeploy、WIDEEP 删除;CLI flag 优先级高于 YAML;KV 传输超时默认 60s;单条请求的 chat template 需要 `--allow_request_chat_template` 才能用;logprobs 上限为 100;`/perf_metrics` 改为通过请求头 `X-TRTLLM-return-metrics: 1` 获取。
  - **企业合规相关**:**使用遥测默认开启**(关闭:`TRTLLM_NO_USAGE_STATS=1`、`DO_NOT_TRACK=1` 或 `--no-telemetry`);PD 解耦不配 `internal_request_auth_key` 已弃用,意味着后续会强制服务间鉴权。
  - 服务能力:Anthropic `/v1/messages`、gRPC server、多进程 HTTP 前端、请求级 `priority`、Prometheus 指标、LMCache 和 FlexKV connector、KV-aware attention-DP router、会话亲和路由;新增 VisualGen,图像和视频生成模型也通过 `trtllm-serve` 提供服务;Rubin(SM107)为 preview 支持。
  - **启示**:平台如果封装了 TRT-LLM 运行时模板,v1.3 必须改造:engine build 流水线作废,改为直接加载 HF/ModelOpt checkpoint。私有化和离线交付时,镜像或模板里要默认设置 `TRTLLM_NO_USAGE_STATS=1`,并给 PD 组件注入共享的 auth key。
  - v1.4.0rc4(11-18)是预发布版,新增 Apertus、Qwen3 rerank 等模型支持,对平台影响有限。 https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.4.0rc4
- **TGI**:仍为 archived 状态,无更新。
- **Ollama**:无正式 release。同一个模型的请求如果 `shift` 设置不同,不再重载 runner,改为在请求级别截断 `n_predict`(#19748),对边缘侧的稳定性有帮助,对云原生平台参考价值低。 https://github.com/ollama/ollama/pull/19748

## 模型服务 & 编排

### KServe 上游
本周无新 release。
- **LocalModelCache 选择改为确定性**:原先多个 namespace 级缓存都匹配同一个 storage URI 时,按 K8s list 顺序取第一个,结果会随 reconcile 变化。现在已绑定的缓存只要仍然匹配就继续保留;共享 PVC 缓存在 `status.sharedPVCImport` 还存在时保持绑定;这条规则从只在 webhook 生效扩展到 controller 也生效(#6590)。**启示**:我们的 fork 如果用了共享 PVC 模型缓存,应该合入这个修复,避免 Pod 在不同缓存之间漂移。 https://github.com/kserve/kserve/pull/6590
- Helm 可以配置 controller 日志格式(#6620)。11-18 期已报道的 qpext 崩溃修复(#6627)这周没有新变化。 https://github.com/kserve/kserve/pull/6620

### Ray
- **ray-2.58.2**(11-18)是安全补丁版:eMudhra 中间 CA 被攻破后,pip 和 certifi 跟进修复(pip 自带的 certifi 不受 OS CA 更新影响,必须升级);aiohttp、Brotli、idna 修复多个 CVE。与 2.59.1 内容相同。 https://github.com/ray-project/ray/releases/tag/ray-2.58.2
- **Serve LLM 入口会话亲和**:HAProxy 用一致性哈希(sdbm + avalanche)把同一个 session 固定到同一个 LLMRouter 副本,并复用 fastokens 的分段分词缓存,不带 session 的请求仍走轮询(#67940);另外新增分词绕过指标(#68055),并降低了 KV router 事件循环的 CPU 开销(#67981)。上周的「按 token 扩缩」三连 PR 本周没有出第 2 步。 https://github.com/ray-project/ray/pull/67940
- **autoscaler v2**:修复 `max_nodes` 截断待启动的 min_workers 时 scheduler 崩溃的问题(#67685)。 https://github.com/ray-project/ray/pull/67685
- core:uv runtime env hook 对每个 `uv run` 参数单独加引号(#68156);gRPC 不再取消在服务端队列里等待超过 30s 的调用(#68210)。 https://github.com/ray-project/ray/pull/68156

### KubeAI
窗口内 0 提交,无重大更新。

## 训练 & 微调
- **Kubeflow Trainer**:controller manager 高可用的 Helm 支持(#4147)已在 11-18 期报道;本周新增的只有 HF 数据集 ID 允许不带 namespace(#4316),以及 PlainML 的 EnforceMLPolicy 忽略 Flux 和 XGBoost 策略(#4398),无重大更新。 https://github.com/kubeflow/trainer/pull/4316
- **LlamaFactory**:新增 GS1 决策模型的两阶段训练 recipe(#10994),其余是依赖升级,无框架级变化。

## 模型生命周期(MLflow / Registry / Feast)
- **Kubeflow Hub**:catalog 排序查询的 SQL 注入修复(#3455,见摘要 1),目前还没有发版。**启示**:我们如果基于 model-registry 或 ODH fork 对外提供模型目录,需要自查 `filterQuery` 和 `orderBy` 的处理,在修复发版前先在网关层校验 `orderBy` 是否属于合法枚举。 https://github.com/kubeflow/hub/pull/3455
- **MLflow**(无新 release):
  - `archive_directory` 改用 tarfile 实现。原实现直接把目录项名传给 `tar` 命令行,文件名以 `-` 开头时会被当成选项,可以借 `--checkpoint-action=exec` 执行命令(#27948)。 https://github.com/mlflow/mlflow/pull/27948
  - 「创建数据集」按 experiment 权限校验(#27846);禁止修改 prompt 版本的保留 tag(#27917);新增 `MLFLOW_SQLALCHEMYSTORE_SEARCH_TRACES_TIMEOUT_SECONDS`,限制 PostgreSQL/MySQL 上 `search_traces` 的执行时长(#27943)。 https://github.com/mlflow/mlflow/pull/27943
  - 其余是 trace UI 性能优化和模型目录的自动刷新提交,与平台无关。
- **Feast**:独立部署的 MCP server 新增 TLS 证书选项(2a312cc),Operator 也支持为它配置 TLS(1d6cfb4);MCP feature 工具支持搜索过滤和在线写入。11-18 期报道的伪造令牌修复本周没有新变化。 https://github.com/feast-dev/feast/commit/1d6cfb40f47e82872a6275b96867746ca6ef5e88

## LLM 评估 & 安全
- **lm-evaluation-harness**:窗口内无提交,无重大更新。
- **garak**:新增一个需要显式开启的 `agent_breaker.SourceToSink` 探针。它根据运维人员编写的工具清单构建多工具之间的数据流路径,在有限步数内按链路逐步发起攻击,用来发现「A 工具的产出喂给 B 工具后才出现的危险操作」(#2247)。**启示**:Agent 平台的红队评估从单工具扩展到工具链,我们的 Agent 安全评测可以直接复用这个探针。 https://github.com/NVIDIA/garak/pull/2247
- **OGX(原 llama-stack)**:无新 release。破坏性删除 `tool_runtime` 和 `tool_groups` API、MCP tool runtime provider 和 `ogx-client toolgroups`;function tool 改为在客户端执行,file search 收进 Responses API 内部(#7039、#7033)。11-17 web search 已经拆成独立 API(#7014)。整体方向是向 OpenAI Responses 形态收敛。 https://github.com/ogx-ai/ogx/pull/7039

## 值得跟进
- [ ] 自查自家或 ODH fork 的 model catalog 是否存在 Hub #3455 的注入路径;跟踪 kubeflow/hub 带上该修复的下一个 release(v0.3.19?),修复发版前在网关层校验 `orderBy` 枚举
- [ ] TRT-LLM v1.3.0 迁移评估:运行时模板去掉 engine build;离线交付镜像默认设置 `TRTLLM_NO_USAGE_STATS=1`;PD 部署注入 `internal_request_auth_key`
- [ ] 在推理网关层统一限制 tokenize token 数、多模态项数和 body 大小,对照 vLLM #67348 和 #52602 的默认值
- [ ] 对比冷启动的两条路线:vLLM `--weight-cache-seed`(从已有副本复制权重)和 KServe LocalModelCache(从 PVC 加载)
- [ ] fork 中合入 KServe #6590 的确定性缓存选择逻辑
- [ ] 继续跟踪 Ray Serve 按 token 扩缩的第 2、3 步,以及本周新增的会话亲和(#67940)能否与我们网关的 session header 对接

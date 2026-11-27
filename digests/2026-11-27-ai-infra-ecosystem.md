# AI 推理 & MLOps 生态周报 2026-11-27

窗口:2026-11-25 ~ 2026-11-27。上一期(11-25)已覆盖到 11-25 的提交(vLLM 鉴权绕过 #52794、Kubeflow Hub 4 个安全修复、KServe Gateway API 路径路由 #6650、MLflow 安全补丁、Feast RBAC #7191 等),本期只写 **11-25 之后**的新变化,旧条目只在有后续时提及。已过滤版本 bump、dependabot、CI 噪声、纯文档和测试修复。
源仓库沿用改名后的路径:lingo→kubeai-project/kubeai、training-operator→kubeflow/trainer、model-registry→kubeflow/hub、llama-stack→ogx-ai/ogx(release 在两个 owner 下同步可见)。

本期只有 3 天窗口,但信号质量高,主线有两条:**引擎开始长出"给编排器用的接口"**(就绪探针、运行时缩容、入队限额与指标),以及**跨请求数据串台类缺陷继续冒头**。

## 摘要(5 条以内)

1. **vLLM 合入真正的 generation 就绪探针 `/health_generate`,带 K8s readinessProbe 示例**:现有 `/health` 只能看进程活着,抓不到 DP/EP + MTP 的 collective hang、idle 引擎上的潜伏 CUDA 故障、PP 阶段不返回输出的故障。新端点逐 engine rank 评估:busy 即 ready(不额外占 GPU);idle 则在每个 worker 上跑一次 dummy decode 并等设备同步;sleeping/paused 单独报。未就绪返回 503 + JSON 体,`reason` 为 `engine_dead`/`sleeping`/`probe_timeout`/`probe_failed`,`timeout_s` 查询参数默认 20s。文档明确区分 readiness(用 `/health_generate`)与 liveness(用 `/health`)。两个后续 PR 会补 busy 但不推进的 `stalled` 检测和 `in_progress`(报出该 rank 正在执行哪个 utility call,用于区分"权重同步中"和"挂了")。Rust 前端的同名端点尚未实现。 https://github.com/vllm-project/vllm/pull/60505
2. **OGX(原 llama-stack)发 2.0.0,破坏性变更面积很大**:`tool_runtime` / `tool_groups` 两套 API 连同 `remote::model-context-protocol` provider 整体删除(web/file search 改走 Responses API,MCP 工具由 Responses API 直供或走 MCP connector,工具指标 `ogx.tool_runtime.*` → `ogx.tools.*`);`remote::passthrough` inference provider 删除,**其中"调用方自带下游 URL + 凭据"的 `passthrough_url`/`forward_headers` 没有等价替代**;Python 3.12 不再支持(要 3.13–3.14);**配置里还带 `tool_runtime` 段的 stack/distribution config 直接不加载**(临时的宽松归一化器也被删了);`image_name`、`registered_resources.tool_groups`、vLLM 顶层 `tls_verify` 等配置键删除,`~/.llama` → `~/.ogx` 自动迁移取消。好消息:上周那批多租户隔离修复(Skills/message batches 带 owner #7084、#7047)已确认进入 2.0.0。 https://github.com/ogx-ai/ogx/releases/tag/v2.0.0
3. **SGLang 弹性 EP 补上第三个方向:运行时缩容,驱动用例明确写的就是 K8s reconciler 回收 GPU**:在同一个 `active_ranks` 位图上做 `PREPARE → DRAIN → NIXL_RETIRE → FLIP_MASK`,退役 rank 先把自己队列排空再过 barrier(`/scale_elastic_ep` 只关闭退役 slot 的准入,存活 slot 继续收新请求),最后主动调 `mooncake.pg.deactivate_ranks` 让协调者按请求摘除自己——而不是靠 ~10s/peer 的链路超时发现,reconfiguration 从 11–12s 降到 2s 内。decode CUDA graph 跨宽度变更存活(原先弹性 EP 全 eager,decode 成本 7.3x)。DeepSeek-V3-Lite FP8、单 H100 节点、8 并发流,4→3 缩容全程不中断:p50 ITL 8.9ms、峰值 stall 13ms、4.1s 收敛到新宽度。扩容侧改为"joiner 能真正参与一次 forward 才报完成"(`warming_up`,实测 37s 静态 / 68s 带载)。 https://github.com/sgl-project/sglang/pull/33111
4. **KServe 上游两条和我们产品直接相关的动向**:一是 **LoRA 运行时生命周期 RFC**(#6686,11-26 新开):现状是 LoRA 靠 init container / PVC 挂载在启动时传给 vLLM,增删适配器就改 Pod template → 触发 rollout;RFC 提议 opt-in runtime 模式,适配器有服务名 + 不可变源标识(version/digest)+ 源 URI,KServe 只负责声明与**按适配器的 readiness**(含 observed generation 和 artifact version),路由只在目标副本能服务时才发布,删除时先撤路由再卸载,新版本走新的不可变路径、绝不原地覆盖;路由继续由 llm-d InferenceModelRewrite 负责。二是 **informer cache 作用域收紧**(#6275,已合入):local-model import Job 过滤到命名空间、PV/PVC 只 watch metadata、每个 node agent 的 Job 和 LocalModelNode cache 限定到本节点(**要求必须设置 `NODE_NAME`**)、四个 serving 二进制全部打开 `ReaderFailOnMissingInformer`。 https://github.com/kserve/kserve/issues/6686
5. **跨请求数据串台,一个已修一个未修**:TensorRT-LLM 里带 precomputed image embeddings 的请求不产生 multimodal hash,KV block 复用只按 placeholder token id 做 key,**同样的文本配不同图片会复用上一个请求的图像 KV、描述错图片**(#22561,已修,改为按 embedding 行内容 + `multi_modal_uuids` 做 key,Qwen2.5/3-VL、LLaVA-NeXT、Llama 4 全覆盖)。SGLang PD 解耦下,客户端把别人正在用的 `bootstrap_room` 直接发给 prefill/decode 服务,**请求 B 的 HTTP 200 里返回的是请求 A 的输出**(#51980,11-21 开,**仍未修**,NIXL 后端,main 上可复现;前身 #40125 被 stale bot 关掉、修复 PR 也被 idle bot 关了)。 https://github.com/NVIDIA/TensorRT-LLM/pull/22561

---

## 推理引擎动态

### vLLM
本周无新 release(最新仍是 v0.34.0,11-16),以下全在 main。
- **就绪探针 `/health_generate`**,见摘要 1。**对我们产品的启示**:这是目前上游唯一能覆盖"进程活着但生成不动"的标准接口,我们的推理模板应该把 readinessProbe 切到 `/health_generate`、liveness 留给 `/health`,并把 `timeout_s` 调到大于单步耗时(冷启动首请求编译 kernel 时容易误判);503 的 `reason` 字段可以直接喂给我们的控制面做"该不该摘流/该不该重建 Pod"的判断——`sleeping` 和 `probe_timeout` 的处置显然不同。 https://github.com/vllm-project/vllm/pull/60505
- **入队限额真正生效 + 配套指标**(Rust 前端):
  - `--max-num-queued-reqs` / `--max-num-queued-tokens` 原先在 Rust 前端启动时就被当作未实现拒掉,现在真正执行:超限请求在到引擎之前就被拒,返回 HTTP 503(gRPC `UNAVAILABLE`);`n` 个采样占 `n` 个槽位,prompt token 在首个输出前计入 backlog;**槽位按引擎侧输出释放,不跟客户端读流的速度绑定**,所以慢客户端不会在引擎干完之后继续占容量;`--max-num-queued-tokens` 接受 `32k` 这类写法(#69640)。 https://github.com/vllm-project/vllm/pull/69640
  - `/metrics` 新增 `vllm:admission_rejections{model_name, reason}`,未配限额时两个 reason 序列也从 0 开始存在(#69856);另有 `vllm:num_preemptions`(#69862)、`vllm:nixl_num_declined_expired_reads`(#69863),以及把 `OffloadingConnector` 的 `vllm:kv_offload_*` / `vllm:kv_offload_tiering_*` 补齐到 Rust 前端(原先这类 payload 被当成 `Multi` 直接丢掉,用 Rust 前端 + offloading connector 的部署一个指标都看不到,#69848)。 https://github.com/vllm-project/vllm/pull/69856
  - **启示**:到现在为止,"引擎级限流 + 拒绝计数 + 抢占计数"这一套终于齐了,可以把 HPA/自研 autoscaler 的信号从"GPU 利用率"换成 `admission_rejections` + `num_preemptions` + 队列深度。另外要注意我们如果已经在网关层做了排队,引擎层 503 的语义要和网关对齐,否则会出现双重排队。
- **安全加固(延续上周的"请求侧参数收口")**:
  - 聊天请求里的 HF tokenizer 控制项被保留给服务端,请求覆写返回 400;校验放在 chat 预处理和 chat 形状的 pooling 预处理两处(#69852)。
  - Jina ranking / token-embedding 的 prompt 格式化改走共享的有界 formatter(#69967);Cohere 渲染路径要求模板必须由服务端配置,inline 模板覆写被拒(#69969)。
  - `allowed_token_ids` 按模型词表做上界(#70093);Qwen3-VL 默认每 prompt 最多 32 个视频(#69864)。
  - **启示**:这三周连起来看,vLLM 在系统性地把"请求能影响服务端渲染/分词/预处理配置"的面全部关掉。我们如果给用户暴露了 `chat_template_kwargs` 之类的直通字段,应该照这个清单做一次白名单收口。 https://github.com/vllm-project/vllm/pull/69852
- **KV offload / Fast Start**:
  - **GDS 落地**:在上周的 fs offload 基础上实现 GPU 直通磁盘的 GDS connector(RFC #54777 第二部分)。官方实测 Llama-3.1-8B / 8×H100 + 共享文件系统,从 fs 读 KV 吞吐 >2x;推荐姿势是 `VLLM_KV_CACHE_LAYOUT=BLHNC`、写用一个多层 offloading connector(CPU + fs)、读用 GDS connector(#66805)。 https://github.com/vllm-project/vllm/pull/66805
  - CPU 层优先淘汰非 retained chunk(#70026);MLA KV 按 host 共享副本(#69677);preload daemon 支持 engram CPU offload(#69627)。
  - **启示**:"共享文件系统 + GDS 读"这条路线对我们是现成方案——它不要求 RDMA 组网,只要有 RWX 存储和 GDS 驱动,比 P2P 权重分发的部署门槛低得多,值得和上周评估的快照迁移、LocalModelCache 一起横向对比。
- **模型与配置项删除(影响模型目录和模板)**:
  - 删除 DBRX(`DbrxForCausalLM`,Hub 上的 checkpoint 早已下架,CI 从未跑过,#70133);删除 Mamba1 全路径(`MambaForCausalLM`、`FalconMambaForCausalLM`、`JambaForCausalLM`/`...ForSequenceClassification`、`MambaMixer`、`MAMBA1` attention 后端、`selective_scan_fwd` kernel 及其 XPU Triton 版,以及 `--tool-call-parser jamba`,#68177);删除 TeleFLM(#69929);清掉残余 xformers 引用(#69794)。三者都写进了 `_PREVIOUSLY_SUPPORTED_MODELS`(标注"支持到 v0.34.0"),加载时会给出明确报错而不是"架构不支持"。
  - `cudagraph_copy_inputs` 弃用为 no-op,计划 v0.37.0 删除;底层的 compiler-managed input copy 直接移除(从来没有 runner 打开过它,只是每次 compiled call 多一个 copy kernel,#69675)。
  - **启示**:模型目录里 DBRX / Mamba / FalconMamba / Jamba 的条目要下线或改标 EOL;用 Jamba tool parser 的模板会直接起不来。这是继上周 lm-format-enforcer 删除、torchao 弃用之后的第二批,建议建立一张"上游已删/将删选项"的台账跟着每期更新。 https://github.com/vllm-project/vllm/pull/68177
- **可观测与前端**:
  - 新增 per-request `time_to_first_content_token_ms`(TTFC):从调度算起,到第一个产出**非空文本内容**的输出批次,**排除 reasoning 和 tool call**;复用现有 `--enable-per-request-metrics`,流式下挂在最后一个 usage chunk / Responses 终止事件上(#56914)。 https://github.com/vllm-project/vllm/pull/56914
  - **启示**:推理模型和工具调用场景下,TTFT 已经不能代表用户感知的首字延迟,SLO 口径该换成 TTFC。我们自己的指标体系和 SLO 看板需要同步加这一项,否则会系统性低估延迟。
  - 迭代指标里加入 workload snapshot(#61691,上周提到的 `--enable-logging-iteration-details` 条目本周落地);encoder cache 事件(#67030)。
- **其他值得注意**:`/inference/v1/generate` 新增 `features.kwargs_refs`,可信客户端把预处理好的多模态张量以单个 SafeTensors 对象上传到 S3 兼容存储、请求里只带引用,前端下载校验后重建(来自 Cohere fork,RL rollout 场景下 4 核 router 后吞吐最高 1.36x,#68477)。对"多模态预处理与推理分离"的架构是个参考,但注意它明确标注只给可信客户端。 https://github.com/vllm-project/vllm/pull/68477
- **仍然开着的问题**:HF3FS connector 把失败的 load 报成 finished 且不返回失败 block(#69058);KV transfer 调度器在 `_update_from_kv_xfer_finished` 里无条件释放 block,请求 abort 后在途传输不取消,LMCacheMPConnector 下复现 assert 崩溃(#69137)。两个都在 offload/PD 路径上,我们如果启用了 KV offload 要关注。

### SGLang
本周无新 release(最新仍是 v0.5.23,11-02)。
- **弹性 EP 运行时缩容**(#33111),见摘要 3。**对我们产品的启示**:这是第一个把"推理副本缩容"做到不中断服务、并且**主动给编排器发可终止信号**的实现,正好补上我们做 GPU 回收时最难的那一环(以前只能靠进程退出去推断)。要注意三个约束:缩容必须经 `/scale_elastic_ep` 下发目标宽度而不是直接杀 Pod;退役 rank 的排空由 `elastic_ep_scale_timeout` 兜底,我们的 `terminationGracePeriodSeconds` 必须大于它;decode graph 保留的那条路径要求 `max_ep_size == tp_size`,和扩容侧 (`max_ep_size > tp_size`) 的配置要求冲突,同一部署想同时要扩和缩需要权衡。 https://github.com/sgl-project/sglang/pull/33111
- **PD 解耦**:
  - **prefill 与 decode 的 attention TP 可以不同**:prefill TP2 喂 decode TP1(DP8 EP8),主 KV 按 page row 切 head、复制的 index K 由一个 prefill rank 发给一个 decode rank,draft KV 只发 sliding-window 尾部(#51234)。**启示**:异构 TP 组合直接影响我们怎么给 P/D 规划机型——prefill 用高算力卡做大 TP、decode 用显存型卡做小 TP,原先被"TP 必须一致"堵死,现在通了。 https://github.com/sgl-project/sglang/pull/51234
  - 只要 1 个输出 token 的请求(prompt scoring、分类、logprob 查询)可以由 prefill 服务直接作答,不再走 decode 腿:无 `bootstrap_host` + `max_new_tokens=1` 隐式触发,用 fake sender 不传 KV,`max_new_tokens` 不为 1 返回 400(#53153)。省掉 decode 侧的整段 prompt KV 预留和传输。 https://github.com/sgl-project/sglang/pull/53153
  - NPU 侧 layer split 传输后端切到 Mooncake(#53365)。
- **多租户与隐私**:diffusion serving 做了一轮系统性收口——常规请求摘要里不再出现 prompt / seed / embedding / 输出位置,显式请求日志默认只记 metadata,异步媒体 job 记录里抑制原始异常文本;新增 opt-in 的"仅媒体" HTTP listener profile,先认证网关再读 upload,服务端签发的 job 在每次 CRUD/list/content 操作上都绑定租户,公开的生成字段受限;HTTP 响应和媒体上传打 `private`/`no-store`,mesh job 遵守配置的输入输出持久化策略(#51786)。旧的"单信任域"serving 模式仍保留。**启示**:这份 PR 的"部署边界"段落值得直接拿来当我们多租户推理服务的 checklist(网关必须认证并替换内部 header、worker/scheduler 端口不得暴露、TLS/存储 ACL/ingress 限额归部署方)。 https://github.com/sgl-project/sglang/pull/51786
- **router / 可观测**:
  - sgl-router 现在会显式拒绝 104 个只属于 sgl-model-gateway 的命令行参数,并给出替换项或"不支持"的理由(`--json-log` → `--log-format json`、`--prefill`/`--decode` → `--worker-urls`、`--pd-disaggregation` 直接去掉因为 PD 角色从 worker 的 `/server_info` 读、`--api-key` 不支持因为 sgl-router 不校验客户端 key 而是把 `Authorization` 原样透传给引擎),#50643。**启示**:最后那条很关键——**sgl-router 不是鉴权点**,把它当网关用的部署必须在它前面再放一层。 https://github.com/sgl-project/sglang/pull/50643
  - scheduler 空闲时也输出状态日志,不再停留在最后一批活跃请求 ID 上(#51169);rust-server 把准入前被拒的 `/generate` 请求上报给 generate hook(#52958)。对"缩容到零"的判定有用。
- **EPLB**:Kimi-K3 支持在线专家迁移(原先 `--enable-eplb` 直接拒绝启动),16×GB300 上一次 rebalance 3.9–5.0s,decode 中位数 52.7ms vs 不开 52.0ms;仍不支持 `--ep-num-redundant-experts`(#53050)。TensorRT-LLM 侧则是给 DeepSeek-R1 modeling_v2 加了静态 EPLB(#22282)。
- **供应链 / CI 加固**(和 TensorRT-LLM 本周同主题):Intel XPU 的 nightly/release/monitor workflow 改用只读 token 且不持久化 git 凭据(#53018),PR 可控的代码和镜像被挡在 XPU release job 之外(#53008),HF 模型预取放到唯一持有 token 的受信步骤里(#53019)。
- **仍然开着的问题**:`bootstrap_room` 复用导致跨请求输出串台(#51980,见摘要 5);`/parse_function_call` 在 tool call 检测器里触发灾难性回溯,单个请求就能把事件循环堵死(#52090);`radix_eviction_policy=priority` 无视 `--schedule-low-priority-values-first`,优先淘汰了最高优先级的前缀(#52423)。**启示**:#51980 的现实缓解措施是**绝不把 prefill/decode 服务直接暴露给客户端**,`bootstrap_room` 只能由 router/网关生成;#52090 则说明 tool-call 解析应该有超时或长度上限。 https://github.com/sgl-project/sglang/issues/51980

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**(窗口内无新 release,最新 v1.3.0 / v1.4.0rc4 均已在 11-20 期详述):
  - **BREAKING**:图像默认解码为 RGB PIL、视频为 uint8 NumPy `(frames, H, W, 3)`,`media_io_kwargs` 和模型 preference 里的 `format` / `device` 两个键**被删除**——带上任一个会导致 LLM/VisualGen 启动报错、chat 返回 400、OpenEngine 报 invalid argument。动机是省内存和 host 时间(8 帧 1920×1080 从 199MB 降到 49.8MB,Kimi K2.5 的 token 计数 host 时间从 13.26ms 降到 0.024ms)。Python 调用方要张量可以传 `format="pt"` / `image_data_format="pt"`;Qwen 若输入是 `[0,1]` 的浮点需在 `mm_processor_kwargs` 里显式设 `do_rescale=True`(#22334)。 https://github.com/NVIDIA/TensorRT-LLM/pull/22334
  - 附带图像 embedding 的 KV 复用串台修复(#22561),见摘要 5。
  - **NIXL agent 自动恢复**:agent 故障后关闭新的收发准入,通过已有的 CTX/GEN 结果交换把失败意图传播到共享同一请求的各 rank,只让受影响的请求失败,恢复期间暂停新 CTX 工作和 GEN 接收准入;物理退役仍需所有参与 rank 同意后才释放请求和内存。**不需要 opt-in 环境变量**(#22530)。**启示**:PD 部署里 NIXL agent 挂掉原先是整机级故障,现在降级为请求级,我们的 PD 编排可以把"重建整个 decode Pod"的触发条件放宽。 https://github.com/NVIDIA/TensorRT-LLM/pull/22530
  - CI/supply-chain 加固:auto-assign、label_community_pr、bot-command 三个默认分支 workflow 补 `permissions:`、`persist-credentials: false`、停止把 `github.event.label.name` 直接插值进 JavaScript、issue_comment 触发器过滤非 PR 和 bot 发送者(#22854);Blossom-CI 的 checkout 凭据加固、清理不活跃 allowlist(#22871)。
  - 远端 KV cache 场景新增文档:Qwen3.5 在 GB300 上用 AgentX + remote KV cache 的 serving 配置(#22883),值得对照我们的 KV 池方案看。
- **TGI**:仍为 archived,无更新。
- **Ollama**:v0.40.18(11-24)已在上期覆盖;窗口内只有 v0.40.19-rc0(11-26),内容是 inkling2 短历史/draft proposal/conv 快照加速、mlxrunner 压缩 Engram history buffer、bump llama-server。**无重大更新**。 https://github.com/ollama/ollama/releases/tag/v0.40.19-rc0

## 模型服务 & 编排

### KServe 上游
本周无新 release(最新仍是 v0.21.0,09-25)。窗口内只有 2 个提交,但新开的 issue/RFC 信息量更大。
- **informer cache 作用域收紧**(#6275,已合入),见摘要 4。细节里有几个对运维直接可见的变化:**每个 node agent 的 Job 和 LocalModelNode cache 限定到本节点,要求必须设置 `NODE_NAME`**(没设会起不来);四个 serving 二进制都打开了 `ReaderFailOnMissingInformer`,所以**任何"顺手做一次 cached read"的代码路径不会再悄悄起一个 cluster-wide informer,而是直接报错**;PV/PVC 改为只 watch metadata;local-model 的 InferenceService informer 刻意**保持不过滤**,因为 KernelCache 捕获可能按注解选中没有标签的 ISVC。routing 相关的 Ingress/HTTPRoute 继续走 direct read,且 watch 注册仍然依赖启动时的 routing mode——**切换 routing 模式后不会动态加 watch,必须重启控制器**。 https://github.com/kserve/kserve/pull/6275
  - **启示**:我们的 fork 如果带了自研的 cached read 或自定义 informer,升级这块会直接因 `ReaderFailOnMissingInformer` 失败,需要提前把 direct read 显式声明出来;node agent 的 `NODE_NAME` 要在 DaemonSet 里补上。这个改动的收益对我们是实的:per-node agent 的 informer 内存按节点数放大,是大集群里控制器 OOM 的常见原因。
- **LoRA 运行时生命周期 RFC**(#6686,11-26,Discussion draft),见摘要 4。RFC 里还给了未决问题和验收标准:alias 切换归 KServe 还是 InferenceModelRewrite;首版存储模型选 RWX 共享、per-node cache 还是 per-Pod 拷贝;首版 runtime 范围是否只做 vLLM;验收要求在并发流量下完成 add / 版本切换 / 删除且**不替换模型 Pod**,跨两个 GPU 节点在扩容和 Pod 重启期间重复,并注入下载/校验失败、rank 或存储不足、副本部分就绪等故障,还要验证"runtime 管理 API 不通过公开路由暴露"。 https://github.com/kserve/kserve/issues/6686
  - **启示**:这正是我们在模型生命周期上的差异点所在,现在上游还只是 discussion draft,**这是介入设计讨论的窗口期**。两个点值得我们带着实践经验去提:一是"按适配器的 readiness 要带 observed generation + artifact version"这个契约,决定了上层能不能做安全的灰度;二是"runtime 管理 API 不得走公开路由"——vLLM 的 `/v1/load_lora_adapter` 一类端点如果和推理端口共用,等于给任何能发请求的人开了加载任意路径权重的口子。
- 其他新开 issue,反映上游下一步的需求面:managed EPP + 独立路由下的 readiness(#6694)、`storageUri` 支持 S3 对象版本固定(#6672)、huggingfaceserver CPU 镜像里塞了约 3.3GB 用不上的 CUDA 库(#6693)、以及社区提议把 **HAMi 作为 "GPU Sharing" 层加进 README 架构图**(#6692,理由是小模型独占整卡导致大量闲置,HAMi 是 CNCF 唯一聚焦 GPU 共享与虚拟化的 incubating 项目)。 https://github.com/kserve/kserve/issues/6692

### Ray
- 窗口内无新 release(ray-2.60.1 / 2.59.2 / 2.57.2 的 brotli CVE 与 auth_token 权限问题已在上期覆盖,**镜像重建这件事仍然要做**)。本周 main 上的变化集中在 K8s 运行时正确性:
  - **OOM 阈值跟随 cgroup limit 实时重算**:原先 Ray 在多处缓存了启动时观测到的内存上限算出的阈值,**Kubernetes in-place pod resize(IPPR)改了 cgroup memory limit 之后阈值会漂移**——缩容时阈值偏高,Ray 的有序 worker kill 来不及触发,内核/cgroup OOM killer 先把 Pod 杀了;扩容时阈值偏低,新给的内存还没用上 Ray 就开始杀 worker。现在 `ThresholdMemoryMonitor` 只存配置输入,每次 poll 从最新快照/cgroup 约束重算(#63868)。 https://github.com/ray-project/ray/pull/63868
  - **启示**:这条和本周 k8s 侧 Pod 级 IPPR GA 正好对上——**IPPR 一旦在我们平台可用,所有"启动时读一次 cgroup limit"的组件都是同一类 bug**。建议把这条当模板,扫一遍我们自己的 agent / sidecar / 推理引擎(vLLM 的 `--gpu-memory-utilization`、JVM 堆、各类 memory monitor)。
  - **KubeRay autoscaler v2**:设了 `RAY_AUTOSCALER_PENDING_NODE_IDLE_TIMEOUT_S` 后,autoscaler v2 会在 RayJob 提交之前就把 Pending 的 worker Pod 判为 idle 干掉(那时还没有资源需求)。现在只要 RayCluster 由 RayJob 持有且 `status.state` 不是 `ready`,这个超时就视为禁用——和 RayJob controller 等待同一个状态对齐;注释里点明 `RayClusterProvisioned` condition 不检查 reconcile 错误、也不保证每个 worker Pod 都存在,所以不能用它代替(#68187,kuberay#5434 第 2 步)。 https://github.com/ray-project/ray/pull/68187
  - **优雅下线的边界条件**:`ray start --block` 收到 SIGTERM 后以 `now + RAY_GRACEFUL_SHUTDOWN_DRAIN_TIMEOUT_S` 为 deadline 排空节点,但 poll 循环结束和 wall-clock deadline 几乎同一瞬间,raylet 要求 `deadline < now` 才记为 preempted,于是常常记成 `EXPECTED_TERMINATION`,**导致失败的 task 被计入 `max_retries`**,抢占不计重试的机制对忙节点形同虚设。修复是调用方多等到 deadline 过后 10ms 再杀本地进程(上限 1s 防时钟回跳,#68457)。 https://github.com/ray-project/ray/pull/68457
  - **GCS 重启后重放节点事件**:head 节点挂掉时 GCS 可能在 dashboard agent 已退出之后才把节点标 DEAD,这些 DEAD 事件被丢掉;重启后的 GCS 从 Redis 读到 DEAD 却不再发事件,消费者永远看到 ALIVE。现在 `GcsNodeManager::Initialize` 对表里每个节点(ALIVE 和 DEAD)重发 definition 与 lifecycle 事件(类比 K8s client 在 watch 断开后 re-list),DEAD 用记录的 `end_time_ms` 而不是构造时间。注意**超过约 4000 个 alive 节点时会撑爆 `ray_event_recorder_max_queued_events`(默认 10000)并丢最旧的事件**(#68502)。 https://github.com/ray-project/ray/pull/68502
  - **soft node-affinity 的 autoscaler 需求上报**:raylet 原先不把 node-affinity lease 算进 autoscaler 需求(除非不可行),但带 `spill_on_unavailable` 的 soft lease 在目标节点满了之后会落到任何有空间的节点。**Ray Serve 的 pack 调度正是这样钉住副本的,于是一个被钉在满节点上的副本会在集群没有余量时永远 pending**,因为没人会为它加节点(#68568)。 https://github.com/ray-project/ray/pull/68568
- 开着的 serve/llm 问题:direct streaming + `PrefixCacheAffinityRouter` 在 Python proxy 路径上**每个请求都挂**(#68424);raylet 在 worker PID 被复用时 SIGKILL 了无关进程(#68462)。两个都值得我们在用 Ray Serve LLM 前确认影响范围。

### KubeAI
窗口内 0 提交,最新 release 仍是 v0.25.1(11-10)。**无重大更新**。

## 训练 & 微调
- **Kubeflow Trainer**:无新 release(最新 v2.4.0,11-06)。窗口内只有 arm runner 的构建发布支持(#4482)和两个示例/文档修复,代码层面**无重大更新**。但新开的 issue 里有几个对运维有影响的:
  - 控制器在 health probe 路径冲突时**启动即 panic**(#4519)。
  - JAX plugin 接受 `spec.trainer.env` 里的保留 `JAX_*` 变量,会覆盖注入值并破坏分布式初始化(#4522)——和上期 OptimizationJob 拒绝 `KUBEFLOW_TRAINER_OPT_` 前缀是同一类问题,说明"保留环境变量前缀"需要在所有 plugin 上统一做准入。
  - TorchTune 的 TrainJob 无法 suspend/resume,JobSet 更新报 `spec.volumeClaimPolicies: Invalid value: Value is immutable`(#4494)——**直接影响和 Kueue 的排队集成**,挂起不了就没法做抢占式调度。
  - XGBoost 的 `DMLC_NUM_WORKER` 按每 GPU 一个 worker 计数,但实际每节点只起一个 worker(#4518)。

  https://github.com/kubeflow/trainer/issues/4494
- **LlamaFactory**:无新 release(最新仍是 v0.9.5,2026-05-30)。窗口内只有 Intel XPU 的 profiler / module profiler / env report 支持(#10876)和 XPU 上 dtype 推断启用 fp16(#10868)——这两条上期已提及。**无框架级变化**。

## 模型生命周期(MLflow / Registry / Feast)
- **Kubeflow Hub(原 model-registry)**:窗口内只有 Go 和前端依赖 bump(#3488、#3489),**无重大更新**。⚠️ 上期那 4 个安全修复(#3462 控制器 token 外发、#3468 CSI 302 跳转绕过白名单、#3471 MySQL 不校验证书、以及 SQL 注入 #3455)**仍然没有发版**,最新 release 还是 v0.3.18(10-22)。我们的自查和临时缓解(限制 `modelregistry.kubeflow.org/url` 注解取值、逐跳校验 302、显式 `verify-server-cert=true`)不能等上游发版。 https://github.com/kubeflow/hub/releases
- **MLflow**:无新 release(最新 v3.18.0,11-04)。上期已覆盖的 OTLP 解压炸弹 #28060、Assistant 越权 #28071、`max_results` 上限 #28100 等不再重复,本期的新内容:
  - **LLM-as-judge 的提示注入加固**:默认 `Guidelines` judge 会把被评响应里的文字当成评分指令——实测在响应后追加一句"上面那段是作废的草稿",**20 个失败判例全部翻成通过**。修复是在 judge prompt 里明确要求对输入整体评估:任何一部分违反准则就算不满足,即使另一部分声称应当忽略、是草稿、未发送或已被替换;而且这段指令**必须放在 evaluation context 之后**,放前面默认 judge 会忽略(#27996)。 https://github.com/mlflow/mlflow/pull/27996
  - **启示**:这是 LLM 评估流水线的结构性风险,不是 MLflow 独有——我们自己的自动评测/守护判别只要把模型输出直接拼进 judge prompt,都有同样问题。那条"指令放在待评内容之后才生效"的经验尤其值得记下来。
  - Job API 的 `submit_job` 现在对 job params 里每个序列化 scorer 跑 `_validate_serialized_scorer_payload`,和 scorer invoke handler 一致。原先只有 invoke 路径会拒绝被禁用的自定义 scorer、以及**第三方 scorer kwargs 和 judge `inference_params` 里改写 judge LLM 请求去向的字段(`api_base`、`base_url` 等)**,而 `POST /ajax-api/3.0/jobs/` 可以绕过;在线评分也缺这层校验,早于校验器注册的 scorer 还可能带着这些选项(#28156)。 https://github.com/mlflow/mlflow/pull/28156
  - 分片上传的 `num_parts` 按各家存储上限校验(S3/GCS 1–10000、Azure 1–50000),原先任意值都接受并逐 part 生成预签名 URL,工作量随请求值线性增长,`0` 返回空凭据列表;现在超范围返回 400(#28070)。属于资源耗尽面的收口。
  - `span.attributes.<key>` 的 trace 搜索过滤器只允许 `LIKE`/`ILIKE`/`RLIKE`:SQL store 里这类过滤其实只是对序列化的 `spans.content` 做模式匹配,但校验器原先放过 `=`/`!=`/`IN`/`NOT IN`,结果 `=` 返回空、`!=` 返回所有有 span 的 trace、`IN`/`NOT IN` 在 SQLAlchemy 里崩(#28092)。
  - 其他:并发 `FileStore` 写入时 `make_containing_dirs` 的 `FileExistsError` 竞态(#28136);`get_prompt` 在 registry 读不到时抛错而不是返回 `None`(#26810);新增公开的 `DetectIssues` API 启动 issue detection run(#27639);AI Gateway 工具参数 schema 保留 `anyOf`(#28129);AI Gateway 预算重置周期在 UI 里支持分钟和小时(#28106)。
- **Feast**:无新 release(最新 v0.68.0,11-10)。窗口内只有 1 个提交:Dask offline store 通过当前 snapshot 读 Delta Lake 表(#7229)。**无重大更新**。新开 issue 里 ScyllaDB online store 进程内首次读写用错默认 keyspace(#7226)、`feast teardown` 后 `feast apply` 不重建 sqlite 在线表(#7227)值得留意。上期提到的 context 模块 TokenBudget 方向本周无进展。 https://github.com/feast-dev/feast/pull/7229

## LLM 评估 & 安全
- **lm-evaluation-harness**:窗口内 0 提交,最新 release 仍是 v0.4.13(08-31)。**无重大更新**。
- **garak**:延续上期 `goodside.Tag` → `IntentProbe` 的迁移路线,本周三个合入:
  - **两个 Unicode 走私编码器本来是错的**:`sneaky_bits_smuggling` 用 `bin(ord(ch)).removeprefix("0b")` 丢掉了前导零,每个字符变成 1–7 位且没有分隔符,**解不回去**(`"a!"` 和 `"0a"` 编码相同),也不符合它引用的方案;`variant_smuggling` 的 `chr(0xE0100 + ord(ch))` 不匹配引用的 Paul Butler 方案(字节 0–15 应映射到 U+FE00–U+FE0F,16–255 映射到 U+E0100 + (byte−16)),解出来是偏移的。也就是说**这两个走私探针之前根本没有真正发送它声称的隐藏指令**(#2476)。 https://github.com/NVIDIA/garak/pull/2476
  - 新增三个 `IntentProbe` 兄弟探针(默认 inactive):`InjectUnicodeTagCharsIntent`、`InjectUnicodeVariantSelectorsIntent`、`InjectSneakyBitsIntent`,复用现有编码器和 decode-and-act 框架(#2452);doctor/Policy-Puppetry 角色扮演迁移为 `DoctorIntent`,旧的 `Puppetry`/`Bypass`/`BypassLeet` 不动(#2154)。
  - **启示**:#2476 意味着**我们如果用 garak 跑过 Unicode 走私类评测并得到"通过"的结论,那个结论是无效的,需要在升级后重跑**。这是评测工具链自身正确性的问题,比探针覆盖面的增减更值得关注。
- **OGX(原 llama-stack)**:发布 **v2.0.0**(11-26),见摘要 2。除破坏性变更外的新增能力:SystemOne judgment model API(TypeSafe provider),在 Ollama / llama.cpp / SGLang / vLLM 四个引擎上都有判别支持和各自的集成 CI lane;**新增 SGLang inference provider**(带 Tev1 支持);命名空间化的 function tool;SearchApi 搜索后端;web search 从 tool_runtime 工具改成 `web_search` 路由 API,并带一个内置占位实现以便在没配搜索 provider 时也能跑;引擎 pin 推进到 llama.cpp b12360 / Ollama 0.40.16 / vLLM 0.32.0 / SGLang 0.5.23。发版后还有一个破坏性变更合入 main:生成的 client SDK 里移除手写的 MCP OAuth helper(#7085);另外 `ogx` 裸装现在要求 chardet、pypdf、typesafe-sdk、ollama、aiohttp(#7089)。 https://github.com/ogx-ai/ogx/releases/tag/v2.0.0
  - **启示**:2.0.0 是一次"把过渡期兼容层全部拆掉"的发布,配置不兼容是**启动失败**而不是告警,升级必须先做配置迁移演练。另外注意它把引擎 pin 到 vLLM 0.32.0,而 vLLM 当前已到 0.34.0 且 0.33/0.34 之间删了不少模型和后端选项——拿 OGX 做上层编排的话,引擎版本线要单独管。

## 值得跟进
- [ ] 推理模板的 readinessProbe 切到 vLLM `/health_generate`(liveness 留 `/health`),`timeout_s` 设到大于单步耗时;把 503 的 `reason`(`engine_dead`/`sleeping`/`probe_timeout`/`probe_failed`)接进控制面的摘流与重建决策;跟踪 stall 检测与 `in_progress` 两个后续 PR
- [ ] 自家 autoscaler 的信号从 GPU 利用率改为 vLLM `vllm:admission_rejections` + `vllm:num_preemptions` + 队列深度;同时核对引擎层 `--max-num-queued-*` 返回的 503 与网关排队语义是否冲突
- [ ] SLO 口径补上 TTFC(`time_to_first_content_token_ms`):推理模型和工具调用场景下 TTFT 会系统性低估用户感知首字延迟
- [ ] 模型目录下线或标 EOL:DBRX、Mamba、FalconMamba、Jamba(含 `--tool-call-parser jamba`)、TeleFLM;`cudagraph_copy_inputs` 已弃用(v0.37 删除)。建立"上游已删/将删选项"台账,接上期的 lm-format-enforcer 与 torchao
- [ ] 评估 vLLM GDS KV offload(共享文件系统 + `VLLM_KV_CACHE_LAYOUT=BLHNC`,写走多层 CPU+fs、读走 GDS):不需要 RDMA 组网,部署门槛低于 P2P 权重分发,和跨机快照、LocalModelCache 一起横向对比
- [ ] 介入 KServe LoRA 运行时生命周期 RFC #6686 的设计讨论(目前仍是 discussion draft),重点带两条实践输入:按适配器 readiness 必须带 observed generation + artifact version;runtime 管理 API(如 vLLM `/v1/load_lora_adapter`)不得与推理端口共用公开路由
- [ ] 升级 KServe fork 前排查 #6275 影响:自研 cached read 会被 `ReaderFailOnMissingInformer` 直接打成错误;node agent DaemonSet 必须注入 `NODE_NAME`;routing 模式切换后需重启控制器
- [ ] 按 SGLang #51786 的"部署边界"段落给我们的多租户推理服务做一次 checklist 核对(网关必须认证并替换内部 header、worker/scheduler 端口不暴露、响应打 `private`/`no-store`、异步 job 绑租户)
- [ ] 确认 PD 部署中 prefill/decode 服务未直接暴露给客户端、`bootstrap_room` 只由 router/网关生成(SGLang #51980 仍未修,会把别人的输出以 200 返回);同时给 tool-call 解析加超时/长度上限(#52090 ReDoS)
- [ ] 以 Ray #63868 为模板扫一遍所有"启动时读一次 cgroup limit"的组件(memory monitor、JVM 堆、vLLM `--gpu-memory-utilization`):Pod 级 IPPR GA 后这是同一类 bug
- [ ] 评估 SGLang 弹性 EP 缩容(#33111)作为 GPU 回收方案:缩容必须经 `/scale_elastic_ep` 下发目标宽度,`terminationGracePeriodSeconds` 要大于 `elastic_ep_scale_timeout`;注意保留 decode graph 要求 `max_ep_size == tp_size`,与扩容侧配置要求冲突
- [ ] 规划 P/D 异构机型:SGLang #51234 打通了 prefill 与 decode 不同 attention TP(prefill TP2 → decode TP1),原先"TP 必须一致"的约束解除
- [ ] 自家 LLM-as-judge / 自动评测流水线按 MLflow #27996 加固(输出里的"忽略上文/这是草稿"类文字会翻转判定;加固指令必须放在待评内容之后才生效)
- [ ] 升级 garak 后重跑 Unicode 走私类评测:#2476 表明之前两个走私探针根本没发出声称的隐藏指令,历史"通过"结论无效
- [ ] Kubeflow Hub 4 个安全修复仍未发版(最新 v0.3.18,10-22),缓解措施不能等上游;继续跟踪 v0.3.19
- [ ] Ray 镜像重建(brotli CVE + `auth_token` 0644 权限)仍待执行;另确认 Ray Serve LLM 是否受 #68424(direct streaming + PrefixCacheAffinityRouter 每请求挂死)和 #68568(pack 调度副本永久 pending)影响

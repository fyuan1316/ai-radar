# 昇腾算力栈 diff 雷达 2026-11-21

## 摘要
- **mind-cluster 把一个 LLM Agent 塞进了算力运维栈**:`component/ascend-clusterops-agent` 本期合入 121 个文件,从"只会收日志做故障诊断"扩成完整的 **ReAct 对话 + WebUI + 四类只读查询工具 + 技能(Skill)宿主**,技术栈是 langchain `create_agent` + langgraph `MemorySaver` + FastAPI SSE。这是昇腾栈第一次把"集群运维问答"做成随包组件,而不是外挂脚本。
- **同一组件同时补齐了企业级接入面**:新增 9743 Authenticated HTTPS 第二监听(自签证书 + 共享 token 走 Secret 引导、TLS 1.2 下限、CSP/HSTS/滑窗限流),并为四类查询工具扩了 RBAC(`ascendjobs`/`batch.volcano.sh jobs` get + 三个 namespace 的 ConfigMap 只读)。
- **ascend-faultdiag 落地"掉卡"跨侧联合判定**:新增 `lost_device_diag.py`,以 BMC `sel.txt` 掉卡告警为时间锚点、前推 1min 内比对 host 侧 kernel/bbox/os_info 证据,用 9 条模式表判出 UCE_PANIC / HBM_OOM / SMMU timeout / hard-soft-core lockup 等根因;prechecker 侧同步新增 12 个 LostChecker。openFuyao 8 仓本期全无新提交。

## 当日重要改变
- mind-cluster **[新能力]** 新增 ReAct 对话链路与 WebUI 运维问答:`agent-core/chat/graph.py`(新增 `build_graph()`/`astream_chat_events()`)、`agent-core/api/stream_api.py`(新增 `POST /chat/stream` SSE)、`agent-core/webui/`(登录页 + SSE 前端 + toolcard/richtext 视图)。 https://gitcode.com/Ascend/mind-cluster/commit/196d56e682e8
- mind-cluster **[新能力]** 新增统一工具注册表与四类只读查询工具 `faulty_device` / `isolated_device` / `cluster_resource` / `task_status`,HTTP 与 CLI 共用一张名字/参数表。 https://gitcode.com/Ascend/mind-cluster/commit/040d093415f0
- mind-cluster **[架构方向]** 新增顶层 package `agent-core/https/`(5 个模块)+ `agent-core/skills/`(5 份 SKILL.md)+ `agent-core/datasources/`(11 个模块),并把进程入口从 `main.py` 抽到新文件 `agent-core/serve.py` 以承载双监听。 https://gitcode.com/Ascend/mind-cluster/commit/3a4ccb9f7f39
- mind-cluster **[API/CRD变更]** `component/ascend-clusterops-agent/build/agent-core.yaml` ClusterRole 新增 `mindxdl.gitee.com/ascendjobs` 与 `batch.volcano.sh/jobs` 的 `get`、`configmaps` 的 `get`,并新增 3 个 namespace(`mindx-dl` / `kube-system` / `cluster-system`)的 ConfigMap 只读 Role/RoleBinding;Deployment 新增 containerPort 9743。 https://gitcode.com/Ascend/mind-cluster/commit/3a4ccb9f7f39
- mind-cluster **[新能力]** ascend-faultdiag 新增 `lost_device_diag.py` 跨侧掉卡联合判定(RFC 模式 2/3/6/7/10/11/12/13/14)+ `lost_device_checker.py` 12 个 prechecker,并接进 `MergePrecheckCause` 的 `checker_list`。 https://gitcode.com/Ascend/mind-cluster/commit/9c4d76956d2d
- mind-cluster **[弃用/移除]** `agent-core/main.py` 删除 `summarize_report`/`LLMSummaryError` 导入与 `_JSON_HINT` 常量,`tests/test_main.py` 整文件删除(190 行)——旧"LLM 总结诊断报告"入口被新的 tool/chat 装配取代。 https://gitcode.com/Ascend/mind-cluster/commit/196d56e682e8

## mind-cluster: 20e6be78 -> 94d21ad9
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/20e6be7896e34988e554b1fcd5e5b281863e4050...94d21ad9355295041392d28e73704f3e0a04bda8 | tag: v26.3.0-beta.2 | commits=30 | truncated=false
- 改动分布:`component/ascend-clusterops-agent` 121 文件、`docs/zh` 12、`component/ascend-faultdiag` 7、`.gitcode/workflows` 3、`component/ascend-device-plugin` 2
- ⚠️ 取数说明:task 里给 helper 的 PATHPREFIX 清单**不含 `component/ascend-clusterops-agent` 与 `component/ascend-faultdiag`**,按原参数跑只能看到 2 个 device-plugin 文件。本期研判是绕过 PATHPREFIX、直读 compare 全量 files 写的(已把两个前缀补进 task 文件)。

### AI 总结重点(源码 diff 为据)

#### 1. ReAct 编排:直接用 langchain `create_agent`,自己只做"边界与事件翻译"
`chat/graph.py` 新增 `build_graph(llm, agent_tools, checkpointer)`,把工具对象、system prompt 都交给 `create_agent`;推理步数上限显式写成 `RECURSION_LIMIT = 25`(langgraph 超步计数)。会话记忆是**进程级 `MemorySaver`,`thread_id = session_id`,重启即丢**,源码注释自己标成"已知限制"。

<details><summary>代码依据 component/ascend-clusterops-agent/agent-core/chat/graph.py</summary>

```diff
+"""ReAct 编排：交给 langchain 的 `create_agent`，本模块只做边界与事件翻译。
+
+记忆是进程级 MemorySaver（thread_id = session_id，重启即丢）；推理步数上限用 langgraph
+自己的 recursion_limit。消息流翻译成 token 帧，工具帧经同一队列汇入。
+"""
+from langchain.agents import create_agent
+# langgraph 按超步计数，25 是它自己的默认值，显式写出来让上限可见。
+RECURSION_LIMIT = 25
+
+def build_graph(llm: Any, agent_tools: Any, checkpointer: Any = None) -> Any:
+    """编译 ReAct 图：提示词与工具对象都取自 agent_tools（模型每次调用时重新绑定工具）。"""
+    return create_agent(
+        llm,
+        agent_tools.as_langchain_tools(),
+        system_prompt=agent_tools.system_prompt(),
+        checkpointer=checkpointer,
+        name="clusterops-react",
+    )
```
</details>

#### 2. 对话面是"可降级旁路":装配失败只让 chat 掉线,不拖垮已有 `/diag`
`main.py` 的 `lifespan` 里新增一段 `AgentTools(adapter=ToolAdapter(), control=ToolControl(), skills=SkillLoader())` + `stream_api.init_stream(...)`,整段包在 `try/except Exception` 里,失败只打 warning、未装配的流答 503。这是明确的"新能力不得影响既有诊断入口"工程约束。

<details><summary>代码依据 component/ascend-clusterops-agent/agent-core/main.py</summary>

```diff
+    try:
+        # 对话链路自持一套装配：工具层适配 + 调用控制 + 技能宿主。
+        chat_tools = AgentTools(adapter=ToolAdapter(), control=ToolControl(), skills=SkillLoader())
+        # 记忆用 langgraph 自己的进程级 checkpointer：thread_id = session_id，重启即丢（已知限制）。
+        stream_api.init_stream(llm_provider=llm.get_llm, tools=chat_tools, checkpointer=MemorySaver())
+    except Exception:
+        # 对话装配失败只让对话面降级（未装配的流答 503），绝不能把已有的 /diag 入口一起拖下来。
+        logger.warning("chat assembly failed; the chat surface stays offline", exc_info=True)
```
</details>

#### 3. 工具注册表用"执行策略"把只读查询和写型诊断强制分开
`tools/registry.py` 新增 `ToolDefinition`(含 `execution_policy` + `read_only` 两个字段)与 `ToolRegistry.register()`,**在注册期 fail-fast**:`QUERY_POLICY` 的工具必须 `read_only=True`,`DIAGNOSIS_POLICY` 的必须 `read_only=False`,重名直接 raise。查询走 `QueryContext`(scope/evidence id),诊断走原有超时/互斥/缓存链。

<details><summary>代码依据 component/ascend-clusterops-agent/agent-core/tools/registry.py</summary>

```diff
+    def register(self, definition: ToolDefinition, *, replace: bool = False) -> None:
+        """Add one capability. Duplicate names and policy mismatches fail fast."""
+        if definition.execution_policy not in self._policies:
+            raise ValueError(f"tool {definition.name!r} has no execution policy")
+        if definition.execution_policy == QUERY_POLICY and not definition.read_only:
+            raise ValueError(f"query tool {definition.name!r} must be read_only")
+        if definition.execution_policy == DIAGNOSIS_POLICY and definition.read_only:
+            raise ValueError(f"diagnosis tool {definition.name!r} must not be read_only")
+        if definition.name in self._definitions and not replace:
+            raise ValueError(f"duplicate tool name: {definition.name!r}")
```
</details>

#### 4. 调用控制:查询 30s / 诊断 1200s 两档时限,诊断按 (namespace, job) 粒度加锁
`chat/tool_control.py` 新增 `ToolControl.call()`:非 `diagnose` 一律 `QUERY_CALL_TIMEOUT_SECONDS = 30.0`;`diagnose` 用 `DIAGNOSE_CALL_TIMEOUT_SECONDS = 1200.0`,并以 `_task_key()` 返回的 `(namespace, job)` 做互斥集合——同一任务已在诊断时**不重复执行**,而是回一条"正在诊断中"的错误信封让模型停手。同步 registry 调用通过 `asyncio.to_thread` 丢线程,不占事件循环。

<details><summary>代码依据 component/ascend-clusterops-agent/agent-core/chat/tool_control.py</summary>

```diff
+QUERY_CALL_TIMEOUT_SECONDS = 30.0
+DIAGNOSE_CALL_TIMEOUT_SECONDS = 1200.0
+
+    async def call(self, adapter: Any, name: str, args: Dict[str, Any]) -> ToolOutcome:
+        if name != DIAGNOSE_TOOL_NAME:
+            return await self._run(adapter, name, args, QUERY_CALL_TIMEOUT_SECONDS)
+        key = _task_key(args)
+        if key in self._diagnosing:
+            return _diagnose_busy(key)
+        self._diagnosing.add(key)
+        try:
+            return await self._run(adapter, name, args, DIAGNOSE_CALL_TIMEOUT_SECONDS)
+        finally:
+            self._diagnosing.discard(key)
+
+    async def _run(self, adapter, name, args, timeout) -> ToolOutcome:
+        """底座调用放到线程里跑：同步的 registry 调用不占事件循环。"""
+        try:
+            return await asyncio.wait_for(asyncio.to_thread(adapter.invoke, name, args), timeout=timeout)
+        except asyncio.TimeoutError:
+            return ToolOutcome(ok=False, result=None,
+                error={"code": TOOL_TIMEOUT, "message": f"工具调用超过 {timeout:.0f} 秒上限，已中止本轮等待"})
```
</details>

#### 5. 数据面是"只读 K8s 网关",没有任何写动词;每个数据源带分类状态
`datasources/gateway.py` 新增 `KubernetesReadGateway` / `SourceReadResult`,状态码枚举为 `ok/empty/absent_expected/missing/forbidden/invalid/unavailable`,`_classify_exception()` 把 404→`SOURCE_NOT_FOUND`、403→`SOURCE_FORBIDDEN`、408/429/504/5xx/传输类异常→`SOURCE_UNAVAILABLE`、其余→`SOURCE_INVALID`。固定分页 + 每对象 evidence id。

<details><summary>代码依据 component/ascend-clusterops-agent/agent-core/datasources/gateway.py</summary>

```diff
+"""Read-only Kubernetes gateway: get/list through the existing client, with a classified
+source status, fixed paging and a per-object evidence id. No write verbs exist.
+"""
+@dataclass
+class SourceReadResult:
+    status: str  # ok/empty/absent_expected/missing/forbidden/invalid/unavailable
+...
+def _classify_exception(exc: BaseException, absent_expected: bool = False):
+    if status == 404:
+        return ("absent_expected" if absent_expected else "missing", "SOURCE_NOT_FOUND")
+    if status == 403:
+        return "forbidden", "SOURCE_FORBIDDEN"
+    if status in (408, 429, 504) or isinstance(exc, TimeoutError) or "Timeout" in type(exc).__name__:
+        return "unavailable", "SOURCE_UNAVAILABLE"
```
</details>

#### 6. 四类查询工具各自把"唯一可信源"写死在 docstring 里,拒绝猜
- `task_status`:任务状态**只认 job 对象自身**——AscendJob 走 `AcJob.status.conditions`、Volcano Job 走 `Job.status.state.phase`;Pod 只用来输出 `pods[]`,不反推任务状态;明确声明"无回退源,不读 job-summary / hccl.json / relcache"。读取顺序固定,同名命中两种 CR 判为 conflict 而非猜测。
- `cluster_resource`:容量取 Node `status.capacity/allocatable`,占用只算 Running 普通容器 requests;**每个整卡 key(`Ascend910`/`npu`)是独立 bucket,与 `cpu` 平级**;故障/隔离按身份集合独立统计,不做"容量差值对账",一张卡同时故障且隔离在两个字段各记一次。
- `faulty_device`:主源是 ClusterD device summary 分片,per-node DP ConfigMap **只对主源没覆盖的目标、且只对主源解析不出的资源前缀**才回查。

<details><summary>代码依据 component/ascend-clusterops-agent/agent-core/tools/task_status.py + cluster_resource.py</summary>

```diff
+"""Tool: task_status.
+
+The job's own object is the only status source: ``AcJob.status.conditions`` for
+AscendJob and ``Job.status.state.phase`` for Volcano Job. Live Pods are read only to
+publish ``pods[]``; they never feed the job status. There is no fallback source: no
+job-summary, hccl.json or relcache read.
+"""
+# Read order is fixed; a name hitting both types is a conflict, never a guess.
+_TASK_OBJECTS = (
+    _TaskObject("acjob", "mindxdl.gitee.com", "v1", "ascendjobs"),
+    _TaskObject("vcjob", "batch.volcano.sh", "v1alpha1", "jobs"),
+)
--- cluster_resource.py
+"""Tool: cluster_resource.
+
+Capacity comes from Node ``status.capacity``/``allocatable`` and occupation from Running
+ordinary-container requests; every whole-card key (``Ascend910``/``npu``) is its own
+bucket, a sibling of ``cpu``. Fault/isolated are independent per-bucket statistics over
+the same device facts as faulty_device/isolated_device (identity sets, no capacity-difference
+reconciliation, a card that is both faulty and isolated counts once in each field)
+"""
```
</details>

#### 7. 技能宿主:Claude 式 SKILL.md 渐进披露,清单进系统提示词、正文按需读
`chat/skill_loader.py` 新增 `SkillCard` / `SkillLoader`:唯一来源是随包 `agent-core/skills/` 目录(启动扫一次,**不读环境变量、不热重扫**),每份技能 `SKILL.md` 带 `name`/`description` frontmatter + 可选 `allowed-tools`;清单每技能固定一行注入 system prompt(`LISTING_DESCRIPTION_MAX_CHARS = 200`,防伪造提示词段落),正文按需经 `load_skill` 工具读取,单份上限 `DEFAULT_MAX_BODY_BYTES = 8192` 超限截断并声明。本期落地 5 份:`cluster-resource` / `diagnose` / `faulty-device` / `isolated-device` / `task-status`。

<details><summary>代码依据 component/ascend-clusterops-agent/agent-core/chat/skill_loader.py</summary>

```diff
+"""技能宿主：清单注入系统提示词，正文按需读取（渐进披露）。
+
+唯一来源是随包的 skills/ 目录——启动时扫一次，不读环境变量、不热重扫。坏技能记 warning
+后跳过，不影响启动；正文读取有字节上限，超限截断并声明。
+"""
+SKILL_FILE_NAME = "SKILL.md"
+DEFAULT_MAX_BODY_BYTES = 8192  # 单份正文上限：一份失控的技能不能吃掉模型上下文
+# 清单每技能固定一行且注入系统提示词：多行描述会伪造提示词段落，无界描述会挤爆上下文。
+LISTING_DESCRIPTION_MAX_CHARS = 200
+# 技能名与 allowed-tools 条目同一形状：有界的标识符（小写字母开头）。
+_SAFE_IDENTIFIER_RE = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")
```
</details>

#### 8. HTTPS 第二监听:9700 HTTP 继续裸跑,9743 走共享 token 鉴权,失败只关 HTTPS
新增 `agent-core/serve.py` 作为进程入口(原来入口在 `main.py`):HTTP 先起并承载 application lifespan,HTTPS 在后台 bootstrap,**失败只禁用 9743**。端口校验 `validate_listen_ports()` 限定 1024~65535 且两者不同(组件以 `hwMindX` 非 root 运行);namespace 解析优先级"显式参数 > Downward API > ServiceAccount",拿不到 namespace 也只是关 HTTPS 保 HTTP。TLS 下限 `TLSVersion.TLSv1_2`。

<details><summary>代码依据 component/ascend-clusterops-agent/agent-core/serve.py + uvicorn_lifecycle.py</summary>

```diff
+"""Process entry point: runs the HTTP and HTTPS listeners and owns process signals.
+
+HTTP starts first and carries the application lifespan; HTTPS bootstraps in the
+background, so a failure there only disables port 9743.
+"""
+# Ports below 1024 need root privileges and the component runs as hwMindX.
+MIN_PORT, MAX_PORT = 1024, 65535
+def resolve_namespace(declared: Optional[str]) -> Optional[str]:
+    """Resolve the namespace: explicit argument > Downward API > service account.
+    None means HTTPS is disabled; HTTP keeps serving.
+    """
--- uvicorn_lifecycle.py
+DEFAULT_HTTP_PORT = 9700
+DEFAULT_HTTPS_PORT = 9743
+MINIMUM_TLS_VERSION = ssl.TLSVersion.TLSv1_2
```
</details>

#### 9. 证书与 token 都自举进 Secret:自签 RSA-4096 / 365 天 / 提前 30 天续签
`https/secret_bootstrap.py` 新增两个 Secret 名 `agent-core-webui-tls` 与 `agent-core-webui-token`,共享 token 用 `secrets` 生成 `TOKEN_BYTES = 32`;PEM 落在 `/tmp/webui-tls`,目录 0700 / 文件 0600。`https/tls.py` 定 `CERTIFICATE_VALIDITY_DAYS = 365`、`RENEWAL_WARNING_DAYS = 30`、`RSA_KEY_BITS = 4096`,SAN 从 `WEBUI_TLS_SANS` 环境变量取(上限 `MAX_TLS_SANS = 100`)。两份材料互相独立,任一失败只关 HTTPS,且日志永不带密钥内容。

<details><summary>代码依据 component/ascend-clusterops-agent/agent-core/https/secret_bootstrap.py + tls.py</summary>

```diff
+TLS_SECRET_NAME = "agent-core-webui-tls"  # nosec B105
+TOKEN_SECRET_NAME = "agent-core-webui-token"  # nosec B105
+TLS_SANS_ENV = "WEBUI_TLS_SANS"
+MAX_TLS_SANS = 100
+TOKEN_BYTES = 32
+TLS_MATERIAL_DIRECTORY = Path("/tmp/webui-tls")  # nosec B108
+PRIVATE_DIRECTORY_MODE = 0o700
+PRIVATE_FILE_MODE = 0o600
--- tls.py
+CERTIFICATE_VALIDITY_DAYS = 365
+RENEWAL_WARNING_DAYS = 30
+RSA_KEY_BITS = 4096
```
</details>

#### 10. 鉴权中间件刻意不用 401:凭据错返 200 + `X-WebUI-Auth` 头,只有 404/429/500 用错误码
`https/auth_middleware.py` 新增 `WebUIAuthMiddleware`:路径合法但凭据错时返 **200** 加 `X-WebUI-Auth: unauthenticated` 与 body 里的原因(`UNAUTHENTICATED` / "共享 token 无效或缺失"),**token 永不回显**;鉴权失败日志按 `AUTH_FAILURE_LOG_INTERVAL_SECONDS = 60.0` 节流。安全头固定下发 `nosniff` / `X-Frame-Options: DENY` / 一条不含 `unsafe-eval` 的 CSP(`script-src 'self'`、`object-src 'none'`、`frame-ancestors 'none'`)/ `cache-control: no-store`,HSTS 仅 HTTPS 响应加(`max-age=31536000`)。限流是滑窗 `SlidingWindowRateLimiter`,默认 600 req / 60s,可经 `WEBUI_RATELIMIT_MAX_REQUESTS`/`WEBUI_RATELIMIT_WINDOW_SECONDS` 在有界区间内调。

<details><summary>代码依据 component/ascend-clusterops-agent/agent-core/https/auth_middleware.py</summary>

```diff
+"""Failed authentication does not use an HTTP error code: a valid path with bad credentials
+returns 200 with the reason in the body and the ``X-WebUI-Auth`` header. Only 404, 429
+and 500 use error status codes.
+"""
+CSP = (
+    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
+    "img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; "
+    "frame-ancestors 'none'; form-action 'self'"
+)
+HSTS_MAX_AGE_SECONDS = 31536000
+AUTH_RESULT_HEADER = "X-WebUI-Auth"
+DEFAULT_MAX_REQUESTS = 600
+DEFAULT_WINDOW_SECONDS = 60.0
```
</details>

#### 11. SSE 协议与会话入参都有硬上限
`api/stream_api.py` 新增 `POST /chat/stream`,帧序固定 `start -> (token* / tool_call -> tool_result)* -> done`,**任何降级路径都是 HTTP 200**(无模型则 `error` + `done`);`RUN_TIMEOUT_SECONDS = 1800.0`(注释说明"单次诊断本身就可能跑满 1200 秒")、单条消息 `CHAT_TEXT_MAX_BYTES = 16 * 1024`、`session_id` 必须 `fullmatch` `[A-Za-z0-9_-]{1,128}`(注释点明用 `match` 会让结尾换行的 session_id 污染日志行与 checkpointer key)。另有心跳注释帧防代理空闲断连。

<details><summary>代码依据 component/ascend-clusterops-agent/agent-core/api/stream_api.py</summary>

```diff
+"""POST /chat/stream：一轮对话一条 SSE 流，任何降级路径都是 HTTP 200。
+
+帧序 `start` -> (`token`* / `tool_call` -> `tool_result`)* -> `done`，无模型时 `error` + `done`；
+"""
+SESSION_ID_MAX_CHARS = 128
+CHAT_TEXT_MAX_BYTES = 16 * 1024  # 单条消息的接口上限，按 UTF-8 字节计
+RUN_TIMEOUT_SECONDS = 1800.0  # 单轮上限；单次诊断本身就可能跑满 1200 秒
+        if not SESSION_ID_PATTERN.fullmatch(value):
+            raise ValueError("session_id must match [A-Za-z0-9_-] and be at most 128 characters")
```
</details>

#### 12. RBAC 扩面:为查询工具开 AscendJob/Volcano Job 只读 + 跨 3 namespace ConfigMap 读
`build/agent-core.yaml` ClusterRole 新增 `configmaps: [get]`、`mindxdl.gitee.com/ascendjobs: [get]`、`batch.volcano.sh/jobs: [get]`,注释明说"任务 namespace 不固定、名称动态,无法用前缀 `resourceNames` 约束;仅放行只读 get"。另新增同名 Role/RoleBinding `agent-core-query-read` 于 `mindx-dl`(ClusterD 设备/节点/交换机/DPU 汇总)、`kube-system`(DP deviceinfo 回退源)、`cluster-system`(公共故障/手工隔离/job statistics/调度异常),SA 统一是 `mindx-dl/agent-core`。

<details><summary>代码依据 component/ascend-clusterops-agent/build/agent-core.yaml</summary>

```diff
+  # 查询工具：按任务所在 namespace 读取任务对象与 Pod。
+  # 任务 namespace 不固定、名称动态，无法用前缀 resourceNames 约束；仅放行只读 get。
+  - apiGroups: [""]
+    resources: ["configmaps"]
+    verbs: ["get"]
+  - apiGroups: ["mindxdl.gitee.com"]
+    resources: ["ascendjobs"]      # task_status 任务状态唯一来源 (AscendJob)
+    verbs: ["get"]
+  - apiGroups: ["batch.volcano.sh"]
+    resources: ["jobs"]            # task_status 任务状态唯一来源 (Volcano Job)
+    verbs: ["get"]
...
+        - containerPort: 9743 # Authenticated HTTPS
```
</details>

#### 13. kubectl 插件从"只配 LLM"变成通用工具入口,并新增 4 档退出码
`kubectl-plugin/kubectl-clusterops` 新增业务子命令 `tools`(列能力,`GET /tools`)与 `tool <name> [--param K=V ...] [--params-json JSON]`——参数表由 `GET /tools` 目录驱动,**不在插件里注册 per-tool 子命令**;`kubectl ascend_diag` 保留为 legacy 诊断入口。新增 `clusterops_query_client.py` 定义 `EXIT_OK=0 / EXIT_FAILED=1 / EXIT_ARGUMENT=2 / EXIT_PARTIAL=3`(部分数据源不可用时专用码 3)。另新增 `--update-collect-manifest`:把本地 `collect_manifest.yaml` 经 `kubectl create --dry-run=client` 渲染后 apply 进 `collect-manifest/cluster-system` ConfigMap,**node-collector 每次采集重读、无需重启**。

<details><summary>代码依据 component/ascend-clusterops-agent/kubectl-plugin/kubectl-clusterops + clusterops_query_client.py</summary>

```diff
-Usage:
-    kubectl clusterops --create-llm-config [--base-url U] [--model M]
-    kubectl clusterops --clear-llm-config
+Business subcommands:
+    tools
+        list the registered capabilities (GET /tools)
+    tool <name> [--param NAME=VALUE ...] [--params-json JSON]
+        generic entry for every registered tool, driven by the GET /tools catalog
+Management commands (unchanged):
+    --create-llm-config [--base-url U] [--model M]
+    --clear-llm-config
--- clusterops_query_client.py
+EXIT_OK = 0
+EXIT_FAILED = 1
+EXIT_ARGUMENT = 2
+EXIT_PARTIAL = 3
```
</details>

#### 14. ascend-faultdiag:掉卡根因从"单侧看日志"升级为"BMC 锚点 + host 证据 1min 时间窗"
新增 `diag/knowledge_graph/lost_device_diag.py`(从 `kg_diag_job` 拆出,原因写明"避免 kg_diag_job 因行数超限"),核心是 `_CROSS_SIDE_LOST_DEV_PATTERNS` 模式表与 `_judge_cross_side_lost_device()`:**`sel_anchor = bmc_events.get(PRECHECK_SEL_LOG_LOST_NPU)` 为 None 直接返空**——没有 BMC 掉卡告警就不出跨侧结论;命中后按 `times_within_window(anchor_times, window_evidence, LOST_DEV_TIME_WINDOW_SEC)` 判 host 证据是否落在锚点前 1min 内。模式表里一条关键设计:`PRECHECK_DEVICE_INFO_HEARTBEAT_LOST` 的 `in_window` 标 `False`——心跳丢失**只判存在不判时间**(无时间戳,只有状态),其余证据码全部参与时间窗。

<details><summary>代码依据 component/ascend-faultdiag/src/.../diag/knowledge_graph/lost_device_diag.py</summary>

```diff
+# 跨侧掉卡联合判定模式表：(out_code, ((事件来源, PRECHECK码, 是否参与锚点时间窗), ...))
+# - 参与时间窗的码：须在掉卡锚点前推 1min 内命中（按故障码分别解析 occurrence 时间）
+# - 不参与时间窗的码：仅判事件存在（如 heartbeat lost 无时间戳、只有状态）
+_CROSS_SIDE_LOST_DEV_PATTERNS = (
+    (COMP_LOST_DEV_UCE_PANIC_CUSTOM,
+        ((BMC_SIDE, PRECHECK_FDM_MATA_UNCORRECTED_ERROR, True),
+         (HOST_SIDE, PRECHECK_KERNEL_PANIC, True))),
+    (COMP_LOST_DEV_SOFTLOCKUP_CUSTOM,
+        ((HOST_SIDE, PRECHECK_DEVICE_INFO_HEARTBEAT_LOST, False),
+         (HOST_SIDE, PRECHECK_KERNEL_PANIC_SOFTLOCKUP, True),
+         (HOST_SIDE, PRECHECK_KERNEL_WATCHDOG_TIMEOUT, True))),
+)
+def _judge_cross_side_lost_device(bmc_events, host_events):
+    sel_anchor = bmc_events.get(PRECHECK_SEL_LOG_LOST_NPU)
+    if sel_anchor is None:
+        return results
+    anchor_times = get_event_occur_times(sel_anchor)
+    ...
+        if not times_within_window(anchor_times, window_evidence, LOST_DEV_TIME_WINDOW_SEC):
+            continue
```
</details>

#### 15. prechecker 侧同步接入 12 个 LostChecker,解析器补齐 kernel/BMC 事件抽取
`prechecker/merge_precheck_cause.py` 的 `checker_list` 从 4 个 UB CQE checker 扩到 16 个,新增 `HbmMainMirrorLostChecker` / `AicEccLostChecker` / `AicpuCeLostChecker` / `UcePanicLostChecker` / `ThermalOomLostChecker` / `SmmuTimeoutLostChecker` / `MataEccLostChecker` / `HbmOomLostChecker` / `IllegalAddrLostChecker` / `HardlockupLostChecker` / `CorelockupLostChecker` / `SoftlockupLostChecker`。解析器侧 `npu_device_parse.py` 新增 `_match_device_info_heartbeat()` / `_match_smmu_timeout()` / `_match_kernel_multi_bit_ecc()` / `_match_kernel_oom_huge_page()` / `_match_kernel_execute_non_executable()` / `_match_kernel_hard_lockup()` / `_match_kernel_core_lockup()` / `_match_bbox_exception()` 等匹配器,并加 `_flush_kernel_panic_prechecks()` / `_flush_watchdog_prechecks()` 两个延迟刷出钩子 + `_find_softlockup_nearby()` 邻近时间配对;`bmc_parser.py` 新增 `parse_fdm_log_line()` / `parse_sel_txt_line()` / `parse_npu_connection_lost_line()` / `parse_multibit_ecc_line()` 与 `_should_keep_sel_state()` 状态保留判定,时间精度上到 `TIME_FORMAT_MICRO = "%Y-%m-%d %H:%M:%S.%f"`。

<details><summary>代码依据 component/ascend-faultdiag/src/.../prechecker/merge_precheck_cause.py</summary>

```diff
-        checker_list = [Cqe0x2Checker, Cqe0x3Checker, UBMemChecker, Cqe0x5Checker]
+        checker_list = [
+            Cqe0x2Checker, Cqe0x3Checker, UBMemChecker, Cqe0x5Checker,
+            HbmMainMirrorLostChecker, AicEccLostChecker, AicpuCeLostChecker,
+            UcePanicLostChecker, ThermalOomLostChecker, SmmuTimeoutLostChecker,
+            MataEccLostChecker, HbmOomLostChecker, IllegalAddrLostChecker,
+            HardlockupLostChecker, CorelockupLostChecker, SoftlockupLostChecker,
+        ]
```
</details>

#### 16. device-plugin 修交换机故障"查询失败即误判恢复"
`pkg/device/ascendcommon.go` 的 `UpdateNodeDeviceInfo()`:原来**无条件**先 `common.SetSwitchFaultCode(newFaults)` 再判 `err`——`GetSwitchFaults()` 失败时 `newFaults` 为空,等于把故障码清空、上报成"交换机已恢复"。改成只在 `err == nil` 分支才写入,失败分支只打 `Errorf` 并保留上次已知故障状态。配套测试 101 行(`TestUpdateNodeDeviceInfoSwitchFaultWhenSubscribeFailed`)覆盖"查询失败保留上次故障"。

<details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

```diff
 		if common.SwitchSubscribeFailed && common.ParamOption.EnableSwitchFault {
 			newFaults, err := deviceswitch.GetSwitchFaults()
-			common.SetSwitchFaultCode(newFaults)
 			if err != nil {
-				hwlog.RunLog.Error("failed to query all fault codes of switch")
+				// keep the last known good switch fault state to avoid false fault recovery
+				hwlog.RunLog.Errorf("failed to query all fault codes of switch, err: %v", err)
+			} else {
+				common.SetSwitchFaultCode(newFaults)
 			}
 		}
```
</details>

#### 17. Release notes 已把四类查询登记为对外特性
`docs/zh/release_notes.md` 在 "MindCluster Ascend FaultDiag关键特性" 下新增一条,把 `kubectl clusterops tool <name>` + `status/data/errors` 统一信封 + 固定退出码写成对外承诺(即"便于脚本化取数与核对")。tag 仍 `v26.3.0-beta.2`,**未跨档**。

<details><summary>代码依据 docs/zh/release_notes.md</summary>

```diff
 - **新增K8s集群运维Agent组件**：支持根据用户指令收集K8s集群中失败的昇腾训练/推理任务日志并执行故障诊断；支持接入模型API，优化诊断报告。
+- **集群运维Agent新增四类只读查询**：提供故障设备、隔离卡、集群资源和任务状态查询，统一经`kubectl clusterops tool <name>`调用，返回`status/data/errors`统一信封与固定退出码，便于脚本化取数与核对。
```
</details>

### 后续发展方向 [AI]
- **"AIOps Agent 作为算力栈随包组件"是昇腾本期最明确的方向转向**。证据不是宣传而是装配代码:`main.py` 的 lifespan 里 chat 装配与 `/diag` 并列、`build/agent-core.yaml` 把 9743 写进 Deployment、`release_notes.md` 把工具调用写成对外契约。对我们产品的启示:**对标 OpenShift AI 时,"运维 Agent"已不只是 OAI 侧的 Lightspeed 叙事,昇腾侧也在同一时间窗把它做成栈内组件**;若我们自家产品还把运维问答当外挂,差异点会从"有没有"变成"是否随包、是否有 RBAC/鉴权收口"。
- **它的可抄之处是"工具契约"而非模型能力**:`ToolRegistry` 在注册期强制 `query↔read_only` / `diagnosis↔非 read_only` 配对、`gateway.py` 全局无写动词、`task_status` 把"唯一可信源"写进 docstring 并拒绝回退猜测、CLI 用 `EXIT_PARTIAL=3` 显式表达"部分源不可用"。这套"Agent 只能读、读不到就如实说不知道"的设计,比 ReAct 本身更值得我们在自家 Agent 化运维里直接对齐。证据只覆盖本期新增代码,**未见**它在真实大集群上的召回/误报表现。
- **技能(Skill)机制被用作提示词预算管理手段,不是插件系统**:`skill_loader.py` 明确"启动扫一次、不读环境变量、不热重扫",清单单行 200 字符上限 + 正文 8KB 上限。这意味着昇腾目前把技能当**随包静态知识**而非用户可扩展点;若我们要做"客户自定义运维 SOP",这是一个明显的产品差异化缺口(他们现在填不了,我们可以)。证据只覆盖 loader 实现,**未见**任何技能热加载/用户上传路径。
- **安全面值得单独注意:凭据错误刻意返 200 而非 401**。`auth_middleware.py` 的注释把它写成有意设计(只有 404/429/500 用错误码),配合 token 不回显、失败日志 60s 节流,意图是减少探测信息泄漏;但这会让标准 HTTP 客户端与网关的鉴权重试/告警链路失效,**集成方必须读 `X-WebUI-Auth` 头**。我们做类似 WebUI 时若要兼容企业 SSO/网关,大概率不能照搬这一条。
- **掉卡诊断正从"规则匹配"走向"跨侧证据联合判定"**:`_judge_cross_side_lost_device()` 以 BMC `sel.txt` 为必需锚点、host 证据必须落在 1min 窗内,拿不到锚点就不出结论;`in_window=False` 只给 heartbeat lost 这一个无时间戳的证据开口子。这是超节点(super_pod)形态下"BMC 与 host 两套日志必须对齐时间轴"的直接后果。对我们的启示:**若自家产品只采 host 侧日志,这类根因在架构上就判不出来**——需要把 BMC/带外日志纳入采集面。证据只覆盖 9 条模式表与解析器符号,**未见**各模式的实测准确率与告警抑制策略。
- **证据边界**:本期 30 个提交中 121/145 个文件集中在 clusterops-agent 一个组件,昇腾 **device-plugin / docker-runtime / for-volcano / operator / npu-exporter / noded / clusterd / infer-operator / DRA** 本期几乎没动(仅 device-plugin 一处 bugfix)。即"算力调度与设备管理主线本期静默,增量全在运维 Agent 与故障诊断"。openFuyao 侧 8 仓零提交,驱动容器化/vNPU/DRA 方向本期无信号。

## 本期无实质改动
<details><summary>8 个 openFuyao 仓本期无新提交</summary>

- npu-operator(无新提交,tag v26.9.0)
- npu-container-toolkit(无新提交,tag v26.9.0)
- npu-driver-installer(无新提交,tag v26.9.0)
- vNPU(无新提交,tag v26.9.0)
- npu-node-provision(无新提交,tag v26.6.0)
- npu-dra-plugin(无新提交,tag v26.9.0)
- volcano-ext(无新提交,tag v1.9.0)
- ub-network-device-plugin(无新提交,tag v26.9.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=94d21ad9355295041392d28e73704f3e0a04bda8 tag=v26.3.0-beta.2 scanned=2026-11-21 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-21 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-21 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-21 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-11-21 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-21 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f0654355fb65ac3ffca9a41357100a82fde4fc10 tag=v26.9.0 scanned=2026-11-21 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-21 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=37a1d669b4f5ad815110d509c541d321c0c4fab5 tag=v26.9.0 scanned=2026-11-21 -->

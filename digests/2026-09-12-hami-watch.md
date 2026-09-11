# HAMi diff 雷达 2026-09-12

## 摘要
- **HAMi 主仓一条主线:给 scheduler `/refit` 端点加身份认证(issue #2878)**。此前任何 in-cluster 调用方只要够得着 scheduler Service 就能让它把别的 pod 的设备分配挪走;本期改成强制 TokenReview 校验调用方必须是 device-plugin 的 ServiceAccount、且其 bound pod 就在目标节点上。配套:client 侧带 bearer token、认证请求强制 TLS 校验且禁跳转、新增 NetworkPolicy(默认关)、新增两个**必填**启动 flag。
- **chart 默认姿态收紧**:scheduler Service 默认类型从 `NodePort` 改为 `ClusterIP`(不再默认对外暴露);新增可调 `nodeLockRetryTimeout` / `extenderHTTPTimeout`。
- HAMi-core / volcano-vgpu / ascend-device-plugin / HAMi-WebUI 四仓本期无新提交(EMPTY),软切分内核能力边界(HAMi-core)未动。

## 当日重要改变
- Project-HAMi/HAMi [新能力/安全] `/refit` 端点新增调用方认证:新增 `pkg/scheduler/numa_refit_auth.go`,通过 TokenReview 验证 caller 是 device-plugin SA 且 bound pod 在目标节点。PR #2882 https://github.com/Project-HAMi/HAMi/pull/2882
- Project-HAMi/HAMi [破坏性配置] scheduler 新增两个**必填** flag `--device-plugin-namespace` / `--device-plugin-service-account`,任一为空则 scheduler 拒绝启动(不再静默)。升级现存部署若不传这两参会起不来。cmd/scheduler/main.go https://github.com/Project-HAMi/HAMi/pull/2882
- Project-HAMi/HAMi [默认值变更] chart 中 scheduler Service 默认类型 `NodePort` → `ClusterIP`。PR #2944 https://github.com/Project-HAMi/HAMi/pull/2944

## Project-HAMi/HAMi: d872cee1 -> 88b118e5
- 比较: d872cee1959c70ac99c3bf41c49663a28c50f7aa -> 88b118e5 | ahead=5 | files=29 | Release: v2.10.0
- 全量 diff: https://github.com/Project-HAMi/HAMi/compare/d872cee1959c70ac99c3bf41c49663a28c50f7aa...88b118e565a9effaa27f81669da291c5508fc5e4

### AI 总结重点(源码 diff 为据)

- **`/refit` 从"任意 in-cluster 调用方可信"收窄为"仅 device-plugin SA + 同节点 bound pod"**。新增 `Scheduler.authenticateRefitCaller(ctx, token, nodeName)`:先 TokenReview 认证 token,再要求用户名等于 `system:serviceaccount:<DevicePluginNamespace>:<DevicePluginServiceAccount>`,并从 bound token 的 `authentication.kubernetes.io/pod-name|pod-uid` extra 里取出 pod,校验其 UID 匹配、且 `pod.Spec.NodeName == nodeName`。任一不符即拒。这是本期核心:填补了越权移动他人设备分配的漏洞。
  <details><summary>代码依据 pkg/scheduler/numa_refit_auth.go(新增 +91)</summary>

  ```diff
  +const (
  +	boundPodNameExtraKey = "authentication.kubernetes.io/pod-name"
  +	boundPodUIDExtraKey  = "authentication.kubernetes.io/pod-uid"
  +)
  +func (s *Scheduler) authenticateRefitCaller(ctx context.Context, token, nodeName string) error {
  +	review, err := client.GetClient().AuthenticationV1().TokenReviews().Create(ctx, &authenticationv1.TokenReview{
  +		Spec: authenticationv1.TokenReviewSpec{Token: token}}, metav1.CreateOptions{})
  +	...
  +	expectedUsername := fmt.Sprintf("system:serviceaccount:%s:%s", config.DevicePluginNamespace, config.DevicePluginServiceAccount)
  +	if review.Status.User.Username != expectedUsername { return fmt.Errorf("caller %q is not the device-plugin service account", ...) }
  +	podName := firstExtraValue(review.Status.User.Extra, boundPodNameExtraKey)
  +	...
  +	if pod.Spec.NodeName != nodeName { return fmt.Errorf("caller pod ... runs on node %q, not %q", ...) }
  ```
  </details>

- **route 层提取 bearer token 并改了 `RefitNumaAllocation` 签名**。新增 `bearerToken(r)` 从 `Authorization: Bearer <token>` 头取值;调用点从 `s.RefitNumaAllocation(request)` 变为 `s.RefitNumaAllocation(r.Context(), request, bearerToken(r))`——即认证 token 现在作为一等参数贯穿到 refit 逻辑。
  <details><summary>代码依据 pkg/scheduler/routes/route.go(+13/-1)</summary>

  ```diff
  +func bearerToken(r *http.Request) string {
  +	const prefix = "Bearer "
  +	auth := r.Header.Get("Authorization")
  +	if !strings.HasPrefix(auth, prefix) { return "" }
  +	return strings.TrimPrefix(auth, prefix)
  +}
  -		response = s.RefitNumaAllocation(request)
  +		response = s.RefitNumaAllocation(r.Context(), request, bearerToken(r))
  ```
  </details>

- **client 侧:携带 SA token,且"认证请求"强制 TLS 校验、禁止跳转**。`numaRefitTLSConfig` 加了 `authenticated bool` 形参:当携带 token 时,`HAMI_SCHEDULER_TLS_INSECURE` 不再能关掉证书校验(直接报错返回);`numaRefitHTTPClient(authenticated)` 新增 `CheckRedirect` 一律拒绝重定向,防止 bearer token 被转发到未校验的跳转目标而泄露。前→后:原来 insecure 开关对所有 refit 请求生效,现在仅对无 token 的请求生效。
  <details><summary>代码依据 pkg/device-plugin/.../numa_refit_client.go(+61/-14)</summary>

  ```diff
  -func numaRefitTLSConfig() (*tls.Config, error) {
  +func numaRefitTLSConfig(authenticated bool) (*tls.Config, error) {
  -	if insecure, err := strconv.ParseBool(os.Getenv(SchedulerTLSInsecureEnvName)); err == nil {
  -		config.InsecureSkipVerify = insecure
  +	if insecure, err := strconv.ParseBool(os.Getenv(SchedulerTLSInsecureEnvName)); err == nil && insecure {
  +		if authenticated { return nil, errors.New("insecure TLS verification is not permitted for authenticated refit requests") }
  +		config.InsecureSkipVerify = true
  	}
  +	CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
  +		return errors.New("redirects are not permitted for refit requests")
  +	},
  ```
  </details>

- **scheduler 启动强约束:两个新 flag 必填,否则拒绝启动**。`--device-plugin-namespace` / `--device-plugin-service-account` 标识允许调 `/refit` 的 SA;`start()` 里显式检查两者非空,空则返回 error(注释明说:否则 scheduler 表面健康、实则所有 refit 调用被拒的"静默失败")。对现存部署是破坏性升级项。
  <details><summary>代码依据 cmd/scheduler/main.go(+14)</summary>

  ```diff
  +	rootCmd.Flags().StringVar(&config.DevicePluginNamespace, "device-plugin-namespace", "", "namespace of the device-plugin ServiceAccount allowed to call the /refit endpoint")
  +	rootCmd.Flags().StringVar(&config.DevicePluginServiceAccount, "device-plugin-service-account", "", "name of the device-plugin ServiceAccount allowed to call the /refit endpoint")
  +	if config.DevicePluginNamespace == "" || config.DevicePluginServiceAccount == "" {
  +		return fmt.Errorf("--device-plugin-namespace and --device-plugin-service-account must both be set; ...")
  +	}
  ```
  </details>

- **chart:新增 NetworkPolicy(默认关)+ Service 默认类型改 ClusterIP + 两个可调超时**。NetworkPolicy 把 scheduler HTTP 口(filter/bind/refit/webhook 共用一个端口,NP 无法按 path 分)ingress 限制到 device-plugin pod 和 kube-system,是 #2878 之上的纵深防御(注释强调它不替代 TokenReview,关掉也不影响 refit 认证)。`values.yaml` 里 `service.type` 从 `NodePort` 改默认 `ClusterIP`;并暴露 `nodeLockRetryTimeout`(空=二进制默认 28s,0=禁重试)与 `extenderHTTPTimeout: 30`(秒,须 > nodeLockRetryTimeout,否则 kube-scheduler 会在 extender 还在重试节点锁时切断 bind)。
  <details><summary>代码依据 charts/hami/values.yaml(+31/-1)</summary>

  ```diff
  +  nodeLockRetryTimeout: ""
  +  extenderHTTPTimeout: 30
  -    type: NodePort  # Default type is NodePort, can be changed to ClusterIP
  +    type: ClusterIP  # Default type is ClusterIP, can be changed to NodePort
  +  networkPolicy:
  +    enabled: false
  ```
  </details>

- 其余为质量/测试类:`Cleanup: Replace %v with %w in fmt.Errorf()`(#2998,统一错误 wrap);`test(e2e): add scheduler policy E2E suite`(#2793,新增 `test/e2e/policy/`,并给 `test/utils/node.go` 加 `WaitForDevicePluginReady` 轮询 + 用 `retry.RetryOnConflict` 重写 Add/RemoveNodeLabel、去掉写死的 `time.Sleep(30s)`)。

### 后续发展方向 [AI]
- HAMi 正在把 `/refit`(NUMA 亲和的分配重定位,issue #2080/#2878)这条 device-plugin↔scheduler 的内部 RPC 从"信任集群内网"升级为"零信任 + 纵深防御"(TokenReview 认证 + 强制 TLS + 禁跳转 + NetworkPolicy + Service 默认不外暴)。证据只覆盖 refit 这一条链路的认证与 chart 默认值收紧;未见对 filter/bind/webhook 其它共用同端口路径做等价 per-path 认证(NetworkPolicy 注释也承认无法按 path 拆),也未见 HAMi-core 侧(真正的显存/算力软切分内核)本期有任何动作。
- 破坏性提示:升级到含 #2882 的版本必须同时下发两个新 flag,且若沿用 helm 默认值,Service 会从 NodePort 变 ClusterIP——原先靠 NodePort 直连 scheduler 的外部集成会断。仅从 diff 推断,未逐 PR 展开验证升级文档是否给了迁移说明。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=88b118e565a9effaa27f81669da291c5508fc5e4 branch=master release=v2.10.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=f01e9f23fc6ab251d2a7fee8987279f16b08afc8 branch=main release=— scanned=2026-09-12 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-12 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=f6ae916068e6a8e026343ec7679fd96643472e7c branch=main release=v1.3.0 scanned=2026-09-12 -->

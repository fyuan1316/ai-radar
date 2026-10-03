# NVIDIA 算力栈 diff 雷达 2026-10-04

## 摘要
- DRA GPU 驱动(dra-driver-nvidia-gpu)给 ComputeDomain 的 IMEX 守护进程开了一个**管理员可配**的口子:新增 `resources.computeDomains.imex.config` Helm map,能覆盖/追加任意 nvidia-imex 配置项(仅 `driverManaged` 模式生效),但把驱动自管的两个关键项(bind IP、node config file)列入黑名单硬拒绝。
- 同仓把 controller 的 `priorityClassName`(默认 `system-node-critical`)**透传**到动态渲染的 compute-domain-daemon DaemonSet pod,防止 IMEX 守护进程被驱逐。
- 其余 8 仓(gpu-operator/container-toolkit/driver-container/device-plugin/dcgm-exporter/DCGM/mig-parted/KAI-Scheduler)本期无实质改动。

## 当日重要改变
- dra-driver-nvidia-gpu [新能力] ComputeDomain 的 IMEX daemon 配置从"驱动全权生成"放开为"管理员可叠加覆盖",新增 `pkg/imex` 包做 KEV=VALUE 解析 + 黑名单校验。证据 pkg/imex/configoverrides.go、PR #1497 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/pull/1497
- dra-driver-nvidia-gpu [新能力] compute-domain-daemon pod 继承 controller 的 priorityClassName,降低被抢占/驱逐风险。证据 templates/compute-domain-daemon.tmpl.yaml、PR #1498 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/pull/1498

## kubernetes-sigs/dra-driver-nvidia-gpu: 0a3b1b43 -> c6784fea
- 比较: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/0a3b1b43faceba80fee63f6fa3f753adfce5b145...c6784feadfcb65aeddbd40ca86add9b0856288d8 | ahead=9 | files=15 | Release: v0.5.0

### AI 总结重点(源码 diff 为据)

- **新增 `pkg/imex/configoverrides.go`**,定义 `ParseConfigOverrides(csv)`:把 `KEY1=VALUE1,KEY2=VALUE2,` 这种 CSV(来自 Helm 值 `resources.computeDomains.imex.config`、经 `IMEX_CONFIG_OVERRIDES` 环境变量透传)解析成 `map[string]string`;空段/尾逗号忽略,key/value 去空白,无 `=` 或空 key 报错。这是把 IMEX daemon 配置从"驱动硬编码模板"改为"模板 + 管理员叠加覆盖"的核心入口。
  <details><summary>代码依据 pkg/imex/configoverrides.go</summary>

  ```diff
  +func ParseConfigOverrides(csv string) (map[string]string, error) {
  +	overrides := make(map[string]string)
  +	for _, pair := range strings.Split(csv, ",") {
  +		pair = strings.TrimSpace(pair)
  +		if pair == "" {
  +			continue
  +		}
  +		key, value, found := strings.Cut(pair, "=")
  +		if !found {
  +			return nil, fmt.Errorf("invalid IMEX config override %q: expected KEY=VALUE", pair)
  +		}
  +		key = strings.TrimSpace(key)
  +		if key == "" {
  +			return nil, fmt.Errorf("invalid IMEX config override %q: empty key", pair)
  +		}
  +		overrides[key] = strings.TrimSpace(value)
  +	}
  +	return overrides, nil
  +}
  ```
  </details>

- **同文件 `ValidateConfigOverrides` 设黑名单**:`driverManagedConfigKeys = {IMEX_CMD_BIND_INTERFACE_IP, IMEX_NODE_CONFIG_FILE}` 这两个由驱动在渲染期自算的项若被覆盖会"静默破坏该节点的 ComputeDomain 节点间 IMEX 连通性",故直接拒绝;同时拒绝 key/value 含换行符(防注入额外配置行)。即"可覆盖任意项"是**受限放开**,不是无条件开放。
  <details><summary>代码依据 pkg/imex/configoverrides.go</summary>

  ```diff
  +var driverManagedConfigKeys = []string{
  +	"IMEX_CMD_BIND_INTERFACE_IP",
  +	"IMEX_NODE_CONFIG_FILE",
  +}
  +func ValidateConfigOverrides(overrides map[string]string) error {
  +	...
  +		if strings.ContainsAny(key, "\r\n") {
  +			return fmt.Errorf("invalid IMEX config override key %q: must not contain a newline", key)
  +		}
  +		if strings.ContainsAny(overrides[key], "\r\n") {
  +			return fmt.Errorf("invalid IMEX config override value for %q: must not contain a newline", key)
  +		}
  +	...
  +	for _, key := range driverManagedConfigKeys {
  +		if _, ok := overrides[key]; ok {
  ```
  </details>

- **compute-domain-daemon 与 compute-domain-controller 两个二进制都加了 `--imex-config-overrides` flag(环境变量 `IMEX_CONFIG_OVERRIDES`)**。daemon 侧把解析结果传入 `writeIMEXConfig(podIP, configOverrides)`(签名从单参 `writeIMEXConfig(podIP)` 改为双参),在渲染默认模板后用 `applyIMEXConfigOverrides` 叠加覆盖再落盘;controller 侧在启动时即 `ParseConfigOverrides` + `ValidateConfigOverrides`,校验不过直接启动失败(fail-fast)。
  <details><summary>代码依据 cmd/compute-domain-daemon/main.go</summary>

  ```diff
  +		&cli.StringFlag{
  +			Name:        "imex-config-overrides",
  +			Usage:       "Comma-separated KEY=VALUE overrides for arbitrary nvidia-imex daemon config file settings generated in the driverManaged mode.",
  +			Destination: &flags.imexConfigOverrides,
  +			EnvVars:     []string{"IMEX_CONFIG_OVERRIDES"},
  +		},
  ...
  -	if err := writeIMEXConfig(flags.podIP); err != nil {
  +	imexConfigOverrides, err := imex.ParseConfigOverrides(flags.imexConfigOverrides)
  +	...
  +	if err := writeIMEXConfig(flags.podIP, imexConfigOverrides); err != nil {
  ...
  -func writeIMEXConfig(podIP string) error {
  +func writeIMEXConfig(podIP string, configOverrides map[string]string) error {
  +	finalConfig := applyIMEXConfigOverrides(configFile.Bytes(), configOverrides)
  ```
  </details>

- **controller 新增 `--cd-daemon-priority-class-name` flag(环境变量 `CD_DAEMON_PRIORITY_CLASS_NAME`)**,`ManagerConfig` 同时新增 `imexConfigOverrides map[string]string` 与 `cdDaemonPriorityClassName string` 两个字段并在 `Run` 里透传给动态渲染的 daemon。配套 Helm:`controller.yaml` 把 `.Values.controller.priorityClassName` 和 `.Values.resources.computeDomains.imex.config` 分别注入这两个环境变量;daemon 模板 `compute-domain-daemon.tmpl.yaml` 顶层加 `priorityClassName:`——目的是让动态起的 IMEX daemon pod 复用 controller 的优先级(默认 `system-node-critical`)从而不被驱逐。
  <details><summary>代码依据 templates/compute-domain-daemon.tmpl.yaml + deployments/helm/.../controller.yaml</summary>

  ```diff
  # compute-domain-daemon.tmpl.yaml
  +      {{- if .PriorityClassName }}
  +      priorityClassName: {{ .PriorityClassName }}
  +      {{- end }}
  ...
  +        {{- if .IMEXConfigOverrides }}
  +        - name: IMEX_CONFIG_OVERRIDES
  +          value: "{{ range $key, $value := .IMEXConfigOverrides }}{{ $key }}={{ $value }},{{ end }}"
  +        {{- end }}
  # helm/.../controller.yaml
  +        {{- if .Values.controller.priorityClassName }}
  +        - name: CD_DAEMON_PRIORITY_CLASS_NAME
  +          value: "{{ .Values.controller.priorityClassName }}"
  +        {{- end }}
  +        {{- if .Values.resources.computeDomains.imex.config }}
  +        - name: IMEX_CONFIG_OVERRIDES
  +          value: "{{ range $key, $value := .Values.resources.computeDomains.imex.config }}{{ $key }}={{ $value }},{{ end }}"
  +        {{- end }}
  ```
  </details>

- **Helm `values.yaml` 新增 `resources.computeDomains.imex.config: {}`**,注释里明确:仅 `mode=driverManaged`(驱动自渲染并拥有 IMEX config)生效,`hostManaged` 忽略;示例给了 `IMEX_NODE_DISCONNECTED_GRACE_TIME: "60"`(可见放开覆盖的典型用途是调 IMEX 节点断连宽限时间之类的运行时调参)。另有 PR #1520 "Fix dropped IMEX overrides config during merge conflict resolution",修合并冲突时丢失的 overrides 逻辑——说明该特性此前曾被 merge 吞掉过一版。
  <details><summary>代码依据 deployments/helm/dra-driver-nvidia-gpu/values.yaml</summary>

  ```diff
  +      # config lets you override, or add, arbitrary nvidia-imex daemon
  +      # config file settings as a map of setting name to value ...
  +      # Only applies when mode=driverManaged ... Ignored under mode=hostManaged.
  +      #   config:
  +      #     IMEX_NODE_DISCONNECTED_GRACE_TIME: "60"
  +      config: {}
  ```
  </details>

### 后续发展方向 [AI]
- IMEX(多节点 NVLink 内存共享)的配置面正从"驱动黑盒全管"向"管理员可运维"演进:先给出 override 通道(本期),同时用黑名单守住连通性关键项。方向上这是在为 **GB200/NVL72 类多节点 NVLink 域**的生产化调参铺路——让运维能调 IMEX 超时/宽限等参数,又不至于误配断网。证据只覆盖 override 的解析/校验/透传链路与 Helm 暴露,未见 `applyIMEXConfigOverrides` 的叠加合并细节(hunk 截断)与具体放行了哪些安全项的正向白名单(当前只有黑名单)。
- priorityClassName 透传 + overrides 的 fail-fast 校验,都指向 ComputeDomain daemon 的**生产稳定性收敛**(防驱逐、防误配即启动失败),而非新增调度/分片能力。未见与 device-plugin/time-slicing 侧的联动,DRA 原生路径本期仍聚焦 ComputeDomain/IMEX 这一子系统,未触及 GPU 分片语义。

## 本期无实质改动(折叠)
<details><summary>8 仓无新提交 / 仅 bump·CI·merge</summary>

- NVIDIA/gpu-operator(无新提交,Release v26.7.1)
- NVIDIA/nvidia-container-toolkit(无新提交,Release v1.20.1)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交,Release v0.20.1)
- NVIDIA/dcgm-exporter(无新提交,Release 4.8.4)
- NVIDIA/DCGM(无新提交,master)
- NVIDIA/mig-parted(无新提交,Release v0.15.1)
- kai-scheduler/KAI-Scheduler(无新提交,Release v0.18.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=3e1873a25ef46219f9b2db6f19a0b90818729586 branch=main release=v26.7.1 scanned=2026-10-04 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a672e378ef91bea7dfe92c0ed274847fa1cb9236 branch=main release=v1.20.1 scanned=2026-10-04 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=46f292d300b2affd6202d45a1422e41bfedd8fd0 branch=main release=— scanned=2026-10-04 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=d7265fdcf89f571e70b5eb6724ba78a3398bc03e branch=main release=v0.20.1 scanned=2026-10-04 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=c6784feadfcb65aeddbd40ca86add9b0856288d8 branch=main release=v0.5.0 scanned=2026-10-04 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-04 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-04 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9a831d5d84770d6d976c6499572425eddc88ee7a branch=main release=v0.15.1 scanned=2026-10-04 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=5982e4bf5559120d1fb5650ebec7fe400e85bc95 branch=main release=v0.18.2 scanned=2026-10-04 -->

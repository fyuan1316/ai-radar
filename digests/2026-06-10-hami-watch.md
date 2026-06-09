# HAMi diff 雷达 2026-06-10

## 摘要
- volcano-vgpu-device-plugin 落地两件实质改动:① 整仓 **Helm chart 化**并把 CDI 模式从硬编码静态 yaml 改为 `cdi.enabled` 开关 + 三个 hook 路径参数(PR #128);② **删除 node-handshake 注解机制**,设备注册改为幂等比对(设备信息未变即跳过 patch,PR #136 / issue 132)——与主仓早先去 handshake 的方向一致。
- HAMi 主仓本日仅 charts 层微调:scheduler 反亲和从 `required` 放宽为 `preferred`(weight=100),解决小集群滚动升级时调度器副本互斥导致 Pending(PR #1934);无能力/CRD 变化。
- HAMi-core、ascend-device-plugin、HAMi-WebUI 本日无新提交。

## 当日重要改变
- volcano-vgpu-device-plugin [弃用/移除] 删除节点握手注解常量 `NodeHandshake`(`volcano.sh/node-vgpu-handshake`)及 `KnownDevice` 映射,注册路径不再写握手时间戳 https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/9a6973b32bd677ee9c91a42fa6882cbc8a4d222d
- volcano-vgpu-device-plugin [新能力] CDI 模式参数化 + 整仓 Helm chart 化,新增 OCI chart 发布流水线 https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/93aa008b39ae8eb2be34d6dcf0471f860583135d

## Project-HAMi/volcano-vgpu-device-plugin: 7aba1850 -> 6561f1c1
- 比较: 7aba185031fd2f6169885b9c94cfbe1dfc5b788f -> 6561f1c1 | ahead=13 | files=15 | Release: —
- 合并自 PR #128(feat/helm-chart)与 PR #136(handshake)

### AI 总结重点(源码 diff 为据)
- **去握手 + 幂等注册(PR #136)**:`pkg/util/types.go` 删掉常量 `NodeHandshake = "volcano.sh/node-vgpu-handshake"` 和 `KnownDevice` map(原先把 handshake→register 两注解配对登记)。`pkg/plugin/register.go` 的 `RegisterInAnnotation` 不再每次写 `annos[NodeHandshake] = "Reported " + time.Now()`,改为读取节点当前 `NodeNvidiaDeviceRegistered` 注解,若编码后的设备清单与已存值相同则 `klog.V(3)` 记日志后直接 `return nil` 跳过。前→后行为差异:从"每轮上报都翻新一个带时间戳的握手注解(节点对象持续被 patch)"变成"设备拓扑无变化就完全不发 patch",减少 apiserver 写放大,也去掉了调度器侧依赖 handshake 时间戳判活的旧契约。
  <details><summary>代码依据 pkg/plugin/register.go / pkg/util/types.go</summary>

  ```diff
  // register.go
  -	annos[util.NodeHandshake] = "Reported " + time.Now().String()
  +	currentAnnotations := node.GetAnnotations()
  +	if currentAnnotations == nil {
  +		currentAnnotations = make(map[string]string)
  +	}
  +	existingEncodedDevices, exists := currentAnnotations[util.NodeNvidiaDeviceRegistered]
  +	if exists && existingEncodedDevices == encodeddevices {
  +		klog.V(3).Infoln("Device information unchanged, skipping annotation update")
  +		return nil
  +	}
  	annos[util.NodeNvidiaDeviceRegistered] = encodeddevices

  // types.go
  -	NodeHandshake              = "volcano.sh/node-vgpu-handshake"
  	NodeNvidiaDeviceRegistered = "volcano.sh/node-vgpu-register"
  ...
  -	KnownDevice = map[string]string{
  -		NodeHandshake: NodeNvidiaDeviceRegistered,
  -	}
  ```
  </details>
- **CDI 从静态 yaml 收敛为开关参数(PR #128)**:删除 340 行的单体 `volcano-vgpu-device-plugin-cdi.yml`(写死了 CDI 版的 ConfigMap+manifest),改由 Helm `values.yaml` 的 `cdi.enabled` 控制。daemonset 模板在 `cdi.enabled=true` 时才注入 `DEVICE_LIST_STRATEGY`(取 `cdi.deviceListStrategy`)、`NVIDIA_DRIVER_ROOT`(`cdi.nvidiaDriverRoot`)、`NVIDIA_CDI_HOOK_PATH`(`cdi.nvidiaHookPath`)及 `GDRCOPY/GDS/MOFED_ENABLED=false`。前→后:CDI 与非 CDI 不再是两份手维护的 yaml,而是同一 chart 的布尔开关;`rm device-split-count args` 一并把 device-split-count 从启动参数移除(改走 device-config.yaml 的 `deviceSplitCount`)。
  <details><summary>代码依据 deployments/helm/.../templates/daemonset.yaml</summary>

  ```diff
  +        {{- if .Values.cdi.enabled }}
  +        - name: DEVICE_LIST_STRATEGY
  +          value: {{ .Values.cdi.deviceListStrategy }}
  +        - name: NVIDIA_DRIVER_ROOT
  +          value: {{ .Values.cdi.nvidiaDriverRoot }}
  +        - name: NVIDIA_CDI_HOOK_PATH
  +          value: {{ .Values.cdi.nvidiaHookPath }}
  +        - name: GDRCOPY_ENABLED
  +          value: "false"
  +        {{- end }}
  ```
  </details>
- **整仓 Helm 化 + OCI 发布**:新增 `deployments/helm/volcano-vgpu-device-plugin/`(daemonset / values / configmap-device / configmap-node / clusterrole(binding) / serviceaccount / _helpers.tpl / Chart.yaml,镜像 tag v1.12.0),设备/节点配置改由 `configmap-device.yaml`、`configmap-node.yaml` 模板从 values 渲染。新增 `.github/workflows/helm-release.yml`,用 `helm/chart-releaser-action` 发 gh-pages 仓库并 `helm push` OCI chart 到 GHCR。README 增"Version Compatibility Matrix"——volcano-vgpu **v1.12.0 及以下 ↔ volcano v1.15.0 及以下**。
  <details><summary>代码依据 README.md / helm-release.yml</summary>

  ```diff
  +| Volcano-vgpu | Volcano |
  +|--------------|---------|
  +| v1.12.0 and below | v1.15.0 and below |
  +helm install volcano-vgpu-device-plugin volcano-vgpu-device-plugin/volcano-vgpu-device-plugin \
  +    --set cdi.enabled=true
  ```
  </details>

### 后续发展方向 [AI]
- 去 handshake 把 volcano 集成路径的"节点活性/注册"语义从"双注解握手 + 时间戳"简化为"单注解幂等比对",证据只覆盖 device-plugin 上报侧的 register.go;未见 volcano scheduler 侧是否还有读 `node-vgpu-handshake` 的残留消费者(若有则需同步摘除,否则旧调度器读不到握手会误判节点失联)——本次 diff 不含 scheduler 代码,无法证实。
- CDI 走 `cdi.enabled` 开关 + GHCR OCI chart,说明该子项目正从"手贴 yaml"转向标准 Helm 交付,与主仓 chart 一致化;证据只覆盖部署清单与 CI,未见 CDI 注入在 device-plugin Go 侧(Allocate 响应里 CDIDevices)的对应改动。

## Project-HAMi/HAMi: 900e3a33 -> 834513e8
- 比较: 900e3a336f92b752a0fbce3fc3bea9d5f46127af -> 834513e8 | ahead=4 | files=5 | Release: v2.9.0

### AI 总结重点(源码 diff 为据)
- **调度器反亲和放宽(PR #1934)**:`charts/hami/templates/scheduler/deployment.yaml` 在 `leaderElect` 开启时,把同组件 Pod 的 `podAntiAffinity` 从硬约束 `requiredDuringSchedulingIgnoredDuringExecution` 改为软约束 `preferredDuringSchedulingIgnoredDuringExecution`(`weight: 100`,原 selector 包进 `podAffinityTerm`)。前→后:多副本 hami-scheduler 不再强制必须分散到不同节点——节点数不足时新副本可与旧副本同节点暂存,滚动升级不再因反亲和无法满足而卡 Pending。代价:极端单节点场景失去强 HA 隔离(降为尽力而为)。
  <details><summary>代码依据 charts/hami/templates/scheduler/deployment.yaml</summary>

  ```diff
  -          requiredDuringSchedulingIgnoredDuringExecution:
  -          - labelSelector:
  -              matchExpressions:
  -              - key: app.kubernetes.io/component
  -                operator: In
  -                values:
  -                - hami-scheduler
  -            topologyKey: "kubernetes.io/hostname"
  +          preferredDuringSchedulingIgnoredDuringExecution:
  +          - weight: 100
  +            podAffinityTerm:
  +              labelSelector:
  +                matchExpressions:
  +                - key: app.kubernetes.io/component
  +                  operator: In
  +                  values:
  +                  - hami-scheduler
  +              topologyKey: "kubernetes.io/hostname"
  ```
  </details>
- 其余 3 笔均为 CI/依赖噪声:e2e 清理脚本不再 `kubectl delete ns hami-system`(#1939,只 uninstall + 等 Pod 删除)、codecov-action v6→v7(#1935)、`golang.org/x/term` 0.43→0.44(#1937),无能力影响。

### 后续发展方向 [AI]
- 本期主仓零代码逻辑变化,只是部署形态的 HA 取舍。证据仅覆盖 charts 与 CI;未见 scheduler/device-plugin Go 侧任何改动,无趋势可推。

## 本期无实质改动(折叠)
<details><summary>3 个 repo 本日无新提交(HEAD 未变,仅保锚点)</summary>

- Project-HAMi/HAMi-core —— 02a9ac22,未动
- Project-HAMi/ascend-device-plugin —— 799eaa34,未动
- Project-HAMi/HAMi-WebUI —— 30c3ce14,未动(Release hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=834513e84e16be5f64936ce570dc153e086a1479 branch=master release=v2.9.0 scanned=2026-06-10 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=02a9ac22a438824b411e13ad4144fc152a1ec63b branch=main release=— scanned=2026-06-10 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-06-10 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-10 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-10 -->

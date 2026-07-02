# HAMi diff 雷达 2026-07-03

## 摘要
- **HAMi 昇腾软切迈出可观测性一步**:`ascend-device-plugin` 落地内置 vNPU Prometheus exporter(`:9395/metrics`),**仅 hami-vnpu-core 软切模式启用**,并把利用率从"全设备一个值"改成按设备 UUID 逐容器上报——软切分从"能切"补齐到"能看每片"。
- **HAMi 主仓两处企业级加固**:device-plugin 的 hostPID/hostNetwork/securityContext 从硬编码改为 helm values 可配(便于收紧 privileged/SYS_ADMIN 满足 PSA/合规);gpumem-percentage 越界从"静默不可调度"改为 admission 阶段直接报错 + 请求端 clamp。
- HAMi-core / volcano-vgpu / HAMi-WebUI 三仓本日无实质改动。

## 当日重要改变
- Project-HAMi/ascend-device-plugin [新能力] 新增内置 vNPU 指标 server(`:9395/metrics`),软切模式专属、按设备 UUID 逐容器报显存/AICore 利用率,并配套 headless Service + ServiceMonitor。https://github.com/Project-HAMi/ascend-device-plugin/commit/b82e1728f506803b4df9566a84c1ece2ce4a5849
- Project-HAMi/HAMi [新能力/企业级] device-plugin 安全上下文(hostPID/hostNetwork/securityContext)helm 可配化,为收紧特权/合规部署铺路(默认值不变)。https://github.com/Project-HAMi/HAMi/commit/0517f24624cd9bd7ab96b87d3cd17f585c4b62fe

## Project-HAMi/HAMi: 3b466ffa -> 430b458c
- 比较: 3b466ffa -> 430b458c | ahead=6 | files=15 | Release: v2.9.0
- 比较链接: https://github.com/Project-HAMi/HAMi/compare/3b466ffa742d749629cdc70f624c327cc98b6437...430b458c75c37092b2ea48c8b17bd6d1cfcf45f4

### AI 总结重点(源码 diff 为据)
- **device-plugin 特权配置从硬编码改为 helm values 驱动**(#1887):`daemonsetnvidia.yaml` 里 `hostPID: true`、`hostNetwork: false` 及三处容器(toolkit-validation initContainer、device-plugin 主容器、monitor 容器)的 `securityContext` 全部换成 `{{ .Values.devicePlugin.* }}` / `{{- with ... }}` 渲染。原来写死 `privileged: true / runAsUser: 0 / add: ["SYS_ADMIN"]`,现在下沉到 `values.yaml`(默认值照抄保持行为不变),让企业侧能按 PodSecurity/合规要求收紧或替换特权,而不必改 chart 模板。
  <details><summary>代码依据 charts/hami/templates/device-plugin/daemonsetnvidia.yaml</summary>

  ```diff
  -      hostPID: true
  -      hostNetwork: false
  +      hostPID: {{ .Values.devicePlugin.hostPID }}
  +      hostNetwork: {{ .Values.devicePlugin.hostNetwork | default false }}
  ...
  +          {{- with .Values.devicePlugin.securityContext }}
             securityContext:
  -            privileged: true
  -            allowPrivilegeEscalation: true
  -            capabilities:
  -              drop: ["ALL"]
  -              add: ["SYS_ADMIN"]
  +            {{- toYaml . | nindent 12 }}
  +          {{- end }}
  ```
  </details>
- **gpumem-percentage 越界从"静默不可调度"改成显式失败/收敛**(#1997):`pkg/device/nvidia/device.go` 新增 `validateMemoryPercentage`,在 `MutateAdmission` 入口对显存百分比资源做 0–100 校验,越界直接 `return false, error`(admission webhook 拒绝,用户立刻看到原因,而非 Pod 卡 Pending 无提示)。生成资源请求侧 `GenerateResourceRequests` 里再加一道兜底:`mempnums` 越界时 clamp 到 100 并 klog 报错,防止把异常值透传进环境变量。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  +	if err := dev.validateMemoryPercentage(ctr); err != nil {
  +		return false, err
  +	}
  ...
  +func (dev *NvidiaGPUDevices) validateMemoryPercentage(ctr *corev1.Container) error {
  +	if pct, ok := resourceValue(ctr, corev1.ResourceName(dev.config.ResourceMemoryPercentageName)); ok {
  +		if pct < 0 || pct > 100 {
  +			return fmt.Errorf("invalid %s value %d ... must be an integer between 0 and 100", ...)
  +		}
  ...
  +					if mempnums < 0 || mempnums > 100 {
  +						klog.ErrorS(nil, "memory percentage request out of range, clamping to 100", ...)
  +						mempnums = 100
  ```
  </details>
- **NUMA BusId 解析类型修正(uint8Slice → int8Slice)**:`register.go` / `rm/helper.go` / `rm/nvml_devices.go` 三处把包装 `nvml` 设备 BusId 的 `uint8Slice` 改为 `int8Slice`,并在拼接时 `byte(c)` 显式转换。这是随 go-nvml bump(0.13.0→0.13.3,#1993)带出的类型对齐——nvml C 结构里 `BusId` 是 `char`(有符号),原 `uint8` 包装在负值字节上会解析出错,影响 `/sys/bus/pci/.../numa_node` 路径拼接。属可靠性修复,非功能新增。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/rm/nvml_devices.go</summary>

  ```diff
  -	busID := strings.ToLower(strings.TrimPrefix(uint8Slice(info.BusId[:]).String(), "0000"))
  +	busID := strings.ToLower(strings.TrimPrefix(int8Slice(info.BusId[:]).String(), "0000"))
  ```
  </details>

### 后续发展方向 [AI]
- **HAMi 正把"部署期安全姿态"产品化**:继上期 monitor 端口声明后,本期把整条 device-plugin 特权链交给 values 控制,方向是让 chart 能在受限 PSA/合规集群里落地(去 privileged、可换 capability)。证据仅覆盖 chart 模板与 values 默认值,未见文档给出"最小权限推荐配置",实际能否非特权跑通仍需验证。
- **gpumem 百分比口径的健壮性补齐**,但校验只落在 NVIDIA 设备路径(`pkg/device/nvidia`),昇腾/AMD 侧是否同样校验百分比越界,diff 未覆盖;结合 2026-07-02 记录的"AMD 用 CU 个数、NVIDIA 用 SM/显存百分比"多套口径并存,跨厂商的输入校验统一仍是空白。

## Project-HAMi/ascend-device-plugin: 9f91d301 -> d7b365d2
- 比较: 9f91d301 -> d7b365d2 | ahead=2 | files=7 | Release: —
- 比较链接: https://github.com/Project-HAMi/ascend-device-plugin/compare/9f91d3013b3576b162cf0e942fb93b821576f97d...d7b365d2fce33fabefc779d24bab249d0cc4bbed

### AI 总结重点(源码 diff 为据)
- **新增内置 vNPU metrics server,且严格绑定软切模式**:`cmd/main.go` 在 `mgr.IsHamiVnpuCore()` 为真时,用带 panic-recover 的 goroutine 起 `monitor.StartMetricsServer(":9395", "/usr/local/hami-vnpu-core/containers")`;非软切模式明确 log 跳过("没有软切数据可导出")。即 exporter 是 **hami-vnpu-core 软切专属能力**,模板 vNPU/整卡模式不启用。
  <details><summary>代码依据 cmd/main.go</summary>

  ```diff
  +	if mgr.IsHamiVnpuCore() {
  +		go func() {
  +			defer func() {
  +				if r := recover(); r != nil {
  +					klog.Errorf("recovered from panic in vNPU metrics server: %v", r)
  +				}
  +			}()
  +			monitor.StartMetricsServer(":9395", "/usr/local/hami-vnpu-core/containers")
  +		}()
  +	} else {
  +		klog.Info("hami-vnpu-core disabled on this node; not starting the vNPU metrics server")
  +	}
  ```
  </details>
- **利用率从"全设备共用一个值"改为按设备 UUID 逐容器归属**:`collector.go` 原来所有容器都上报 `devices[0].AICorePct`(单值),现在建 `utilByUUID` map,每容器按其 `devUUID` 取对应物理卡的 AICore 利用率;`collectHostMetrics` 新增入参 `podMemByDevice`,在 device-share 模式下用 pod 聚合显存覆盖 host 读数(更准)。这修正了软切"多容器共卡"场景下利用率张冠李戴的问题。
  <details><summary>代码依据 internal/monitor/collector.go</summary>

  ```diff
  -	hostAICore := 0.0
  -	if len(devices) > 0 {
  -		hostAICore = float64(devices[0].AICorePct)
  +	utilByUUID := make(map[string]float64)
  +	for _, d := range devices {
  +		utilByUUID[d.UUID] = float64(d.AICorePct)
  ...
  -			ch <- prometheus.MustNewConstMetric(ctrDeviceUtilizationdesc, prometheus.GaugeValue, hostAICore, baseLabels...)
  +			ch <- prometheus.MustNewConstMetric(ctrDeviceUtilizationdesc, prometheus.GaugeValue, utilByUUID[devUUID], baseLabels...)
  ```
  </details>
- **设备识别从硬编码 310P 泛化到任意昇腾型号**:`container.go` 新增 `ascendDeviceResource`,遍历容器 resource 找 `huawei.com/Ascend*` 前缀(排除 `-core`/`-memory` 后缀)的资源名,并用它做读注解的 key;原代码写死只认 `pod.Annotations["huawei.com/Ascend310P"]`。这让 monitor 支持 910/310 等其他型号,不再只服务 310P。
  <details><summary>代码依据 internal/monitor/container.go</summary>

  ```diff
  +func ascendDeviceResource(pod *corev1.Pod, ctrName string) string {
  +	...
  +				if strings.HasPrefix(k, "huawei.com/Ascend") &&
  +					!strings.HasSuffix(k, "-core") && !strings.HasSuffix(k, "-memory") {
  +					return k
  ...
  -		if anno, ok := pod.Annotations["huawei.com/Ascend310P"]; ok {
  +		if key := ascendDeviceResource(pod, ctrName); key != "" {
  +			if anno, ok := pod.Annotations[key]; ok {
  ```
  </details>
- **配套 K8s 清单**:`ascend-device-plugin.yaml` 给插件容器声明 `monitorport`(9395)containerPort;`ascend-vnpu-monitor-integration.yaml` 新增 headless Service(`clusterIP: None`,按 `app.kubernetes.io/component` 选 Pod)暴露该端口,ServiceMonitor 按 label 选它。暴露 5 类指标:物理 NPU 显存/利用率 + 每容器 vNPU 显存(used/limit)/所在设备利用率。
  <details><summary>代码依据 ascend-vnpu-monitor-integration.yaml</summary>

  ```diff
  +apiVersion: v1
  +kind: Service
  +metadata:
  +  name: hami-ascend-device-plugin-metrics
  +spec:
  +  clusterIP: None
  +  ports:
  +    - name: monitorport
  +      port: 9395
  +      targetPort: monitorport
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾软切正沿"可观测性对齐 NVIDIA vGPU"补齐**:指标命名统一用 `hami_host_gpu_*` / `hami_vgpu_*` / `hami_container_device_*`(复用 GPU 语义描述 NPU),说明 HAMi 想给 N/昇腾提供同一套监控口径,便于 WebUI/Prometheus 统一消费。证据覆盖 collector/main/yaml 与 README,未见 Grafana dashboard 或 recording rule 具体内容(集成 yaml 提到 recording rules 但 hunk 未展开)。
- **每容器利用率仍是"共卡近似"而非"真实配额占用"**:README 明说软切多容器共卡时上报的是"该物理卡"的 AICore 利用率,即容器维度利用率≈整卡利用率,尚无法反映单容器实际算力占比。证据见 collector 用 `utilByUUID[devUUID]`(卡级)填充容器指标,未见按 CU/时间片的容器级细分。

## 本期无实质改动(折叠)
<details><summary>3 仓 EMPTY</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=430b458c75c37092b2ea48c8b17bd6d1cfcf45f4 branch=master release=v2.9.0 scanned=2026-07-03 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=8f3a89c67b037d8fdfe6c4cd4d8c4f0cd6504811 branch=main release=— scanned=2026-07-03 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-03 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=d7b365d2fce33fabefc779d24bab249d0cc4bbed branch=main release=— scanned=2026-07-03 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=8f42445d325736655d467842cb762b75f2612d25 branch=main release=hami-webui-1.2.0 scanned=2026-07-03 -->

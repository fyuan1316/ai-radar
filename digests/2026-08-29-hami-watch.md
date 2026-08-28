# HAMi diff 雷达 2026-08-29

## 摘要
- **HAMi 主仓落地 host PID broker(新增独立 package `hostpid`)**:device plugin 内起一个 root 权限 Unix socket 服务,用 `SO_PEERCRED` 把调用方的 host PID 直接回给 HAMi-core,替代原先"持 post-init 锁创建 CUDA primary context 探测 PID"的串行 fallback——多进程 `cuInit()` 并发瓶颈的架构级优化,默认关闭。
- volcano-vgpu-device-plugin 修监控 hook 路径:`HOOK_PATH` 从 `/tmp/vgpu` 迁到 `/usr/local/vgpu` 并挂载专用卷,同步修 lister 的 containers 目录拼接,与主 plugin 对齐(issue #153)。
- WebUI 任务列表过滤器现在同时匹配 Pod 名与容器名,修此前只能搜容器名的可用性缺陷。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 新增顶层 package `pkg/device-plugin/nvidiadevice/nvinternal/hostpid`(broker/protocol/config)+ `cmd/device-plugin/nvidia/hostpid_broker.go`,引入 host PID broker 协议 v1。证据见下。 https://github.com/Project-HAMi/HAMi/pull/2417

## Project-HAMi/HAMi: 8ca23d00 -> ebcd8ae0
- 比较: 8ca23d003f7a45650c4a49945a57166d4080f974 -> ebcd8ae0 | ahead=1 | files=19 | Release: v2.10.0
- 提交:feat: add host PID broker server and device plugin integration (#2417) https://github.com/Project-HAMi/HAMi/commit/ebcd8ae000d0ded373cad0ebfabb8289f2c5810a

### AI 总结重点(源码 diff 为据)
- **新增 `hostpid` package,定义 broker 线协议 v1**:请求 8 字节(magic `HPID` + version + command)、响应 12 字节(magic + version + status + host PID),大端编码;命令 1 = 取调用方 host PID,status 0/1 = 成功/非法请求。关键点:**client 从不发送 PID**,PID 由服务端从已连接 socket 的 peer credentials(`SO_PEERCRED`)读出,杜绝伪造。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/hostpid/protocol.go</summary>

  ```diff
  +const (
  +	protocolVersion uint16 = 1
  +	commandGetPID   uint16 = 1
  +	statusOK             uint16 = 0
  +	statusInvalidRequest uint16 = 1
  +	requestSize  = 8
  +	responseSize = 12
  +)
  +var protocolMagic = [4]byte{'H', 'P', 'I', 'D'}
  +func validRequest(request []byte) bool {
  +	return len(request) == requestSize &&
  +		string(request[:4]) == string(protocolMagic[:]) &&
  +		binary.BigEndian.Uint16(request[4:6]) == protocolVersion &&
  +		binary.BigEndian.Uint16(request[6:8]) == commandGetPID
  +}
  ```
  </details>

- **broker 服务端强约束 root + 单例锁**:`ListenDefault()` 若 `os.Geteuid() != 0` 直接报错;server 目录 `0711`、socket `0666`、一个 root 属主 `0600` 的 lock file 防两个 broker 互相顶替;并发 handler 上限 512(`maxHandlers`),事务超时 500ms。非 Linux 平台由 `broker_unsupported.go` 提供桩实现直接返回 "requires Linux"。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/hostpid/broker_linux.go</summary>

  ```diff
  +const (
  +	transactionTimeout  = 500 * time.Millisecond
  +	maxHandlers         = 512
  +	serverDirectoryMode = 0o711
  +	serverSocketMode    = 0o666
  +	serverLockMode      = 0o600
  +)
  +func ListenDefault() (*Broker, error) {
  +	if os.Geteuid() != 0 {
  +		return nil, errors.New("the host PID broker must run as root")
  +	}
  +	return listen(ServerSocketPath, 0)
  +}
  ```
  </details>

- **env gate 为精确字符串 `1`**:开关走环境变量 `LIBVGPU_HOSTPID_BROKER`,`Enabled()` 只认字面量 `"1"`,其它任何值(含空)都不启用 server/client。socket 路径:宿主侧 `/var/run/hami/hostpid/broker.sock`,容器侧只读 bind mount 到 `/tmp/vgpulock/hostpid/broker.sock`。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/hostpid/config.go</summary>

  ```diff
  +const (
  +	EnvironmentVariable = "LIBVGPU_HOSTPID_BROKER"
  +	ServerDirectory  = "/var/run/hami/hostpid"
  +	ServerSocketPath = ServerDirectory + "/broker.sock"
  +	ContainerDirectory  = "/tmp/vgpulock/hostpid"
  +	ContainerSocketPath = ContainerDirectory + "/broker.sock"
  +)
  +func Enabled(value string) bool { return value == "1" }
  ```
  </details>

- **device plugin 主流程接入 broker 生命周期**:`start()` 签名改为命名返回值 `(resultErr error)`,启动时 `startHostPIDBroker()`(未开 gate 返回 nil、不起协程),select 循环新增 `<-hostPIDBrokerDone` 分支——broker 意外退出即触发进程 exit;退出路径用 `errors.Join` 聚合 broker 的 `serveErr`、`stop()` 与 `stopPlugins` 错误,不再吞掉。`startPlugins` 多接一个 `hostPIDBroker` 参数下传给各 plugin。

  <details><summary>代码依据 cmd/device-plugin/nvidia/main.go</summary>

  ```diff
  -func start(c *cli.Context, o *options) error {
  +func start(c *cli.Context, o *options) (resultErr error) {
  +	hostPIDBroker, err := startHostPIDBroker()
  +	if err != nil {
  +		return fmt.Errorf("failed to start host PID broker: %w", err)
  +	}
  @@ select 循环
  +		case <-hostPIDBrokerDone:
  +			hostPIDBrokerFailureReported = true
  +			resultErr = hostPIDBroker.failure()
  +			goto exit
  ```
  </details>

- **`/tmp/vgpulock` 父目录做防符号链接/防替换的安全准备**:`prepareHostPIDLockParent()` 用 `O_NOFOLLOW|O_DIRECTORY` 打开 `/tmp`、校验属主为 trusted UID 0、再以父 FD 相对 `mkdirat` 创建 `vgpulock`(mode `01777` sticky),最后二次校验属主/类型/mode,拒绝准备期间被替换。据文档:broker 关闭时也会走此准备(供 HAMi-core 旧 fallback),准备失败则 allocation 失败。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/hostpid_broker.go + docs/develop/hostpid-broker.md</summary>

  ```diff
  +const hostPIDLockParentDirectory = "/tmp/vgpulock"
  +const hostPIDLockParentCreateMode = uint32(0o1777)
  +func prepareHostPIDLockParent(directory string, trustedOwner uint32) error {
  +	parentFD, err := unix.Open(parentDirectory,
  +		unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
  +	...
  +	if !ok || !parentInfo.IsDir() || parentStat.Uid != trustedOwner {
  +		return fmt.Errorf("parent directory is not owned by trusted UID %d", trustedOwner)
  +	}
  ```
  文档:"The chart rejects a configuration that enables the broker while disabling the device plugin host PID namespace." — chart 侧新增 `devicePlugin.hostPIDBroker.enabled`,并把 `LIBVGPU_HOSTPID_BROKER=1` 注入 device plugin 与每个拿到 HAMi-core 的 allocation。
  </details>

### 后续发展方向 [AI]
- 这是**软隔离链路的性能与安全双重加固**:NVML 只按 host PID 汇报进程,HAMi-core 需知道自身 host PID 才能记账显存/算力;原 fallback 靠"持锁建 CUDA context 探 PID"在高并发 `cuInit()` 下串行化,broker 用内核 `SO_PEERCRED` 一次 RTT 拿到、无需读宿主 procfs、也不信任客户端上报——瓶颈从"锁竞争"转成"一次 socket 往返"。证据覆盖 broker 服务端/协议/config 与 device plugin 接入,**未见 HAMi-core 侧的 client 实现**(需 HAMi-core 支持协议 v1 + `LIBVGPU_HOSTPID_BROKER` gate,本期 HAMi-core 仓 EMPTY,client 代码尚未在本雷达窗口出现)。
- 值得盯的落地信号:默认关闭 + 依赖容器运行时支持 `/tmp/vgpulock/hostpid` 的只读嵌套 bind mount,说明尚在灰度期。后续可留意 chart `values.yaml` 中 `hostPIDBroker` 是否转默认开、以及 HAMi-core 是否弃用旧 CUDA-context fallback(届时属 `[弃用/移除]` 信号)。证据仅覆盖本 PR 引入面,未展开 chart 全量。

## Project-HAMi/volcano-vgpu-device-plugin: 4fb76ba1 -> 32162c65
- 比较: 4fb76ba16a1744b161e9e2fbfc0b9ec3a546dd9b -> 32162c65 | ahead=2 | files=2 | Release: —
- 提交:fix: align monitor hook path with plugin for issue #153 https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/2517e93cb696

### AI 总结重点(源码 diff 为据)
- **监控 hook 路径与主 plugin 对齐**:部署 yaml 里 `HOOK_PATH` 从 `/tmp/vgpu` 改为 `/usr/local/vgpu`,并新增名为 `lib` 的卷挂到 `/usr/local/vgpu`;对应 Go 侧 `NewContainerLister()` 的 `containerPath` 从 `filepath.Join(hookPath, "containers")` 改为 `filepath.Join(hookPath, "/vgpu/containers")`。此前 monitor 与 plugin 对 hook 目录约定不一致,导致读不到 containers 记账目录(issue #153)。

  <details><summary>代码依据 deployments/static/volcano-vgpu-device-plugin.yml + pkg/monitor/nvidia/cudevshr.go</summary>

  ```diff
  -          value: "/tmp/vgpu"      # HOOK_PATH
  +          value: "/usr/local/vgpu"
  +        - name: lib
  +          mountPath: /usr/local/vgpu
  ---
  -		containerPath: filepath.Join(hookPath, "containers"),
  +		containerPath: filepath.Join(hookPath, "/vgpu/containers"),
  ```
  </details>

### 后续发展方向 [AI]
- 纯 bug 修复,把 Volcano 集成路径的 hook 目录约定统一到 `/usr/local/vgpu`,消除 monitor 侧 GPU 用量采集失效。证据仅 2 文件,未见新增能力;无 API/CRD 变更。方向上说明 HAMi×Volcano 路径仍在打磨监控数据链一致性,而非扩功能。

## Project-HAMi/HAMi-WebUI: fa9b560d -> 03121b80
- 比较: fa9b560dfbe6caba65d5af48151d4ba544c8730f -> 03121b80 | ahead=5 | files=6 | Release: hami-webui-1.2.0
- 提交:fix: filter task list by pod name https://github.com/Project-HAMi/HAMi-WebUI/commit/59eea00e813b · fix(task): show and search pod and container names https://github.com/Project-HAMi/HAMi-WebUI/commit/16a8229d4db6 · docs: add Japanese README https://github.com/Project-HAMi/HAMi-WebUI/commit/4bf0ba022dfc

### AI 总结重点(源码 diff 为据)
- **任务列表过滤器改为同时匹配 Pod 名与容器名**:后端新增 `matchesWorkloadName(podName, containerName, filter)`,空过滤放行,否则 `strings.Contains(podName, filter) || strings.Contains(containerName, filter)`;`GetAllContainers` 把原先只查 `container.Name` 的分支替换为该函数。一个 Pod 可含多容器,原逻辑会把 Pod 名从用户可见过滤中隐藏。

  <details><summary>代码依据 server/internal/service/container.go</summary>

  ```diff
  +func matchesWorkloadName(podName, containerName, filter string) bool {
  +	if filter == "" { return true }
  +	return strings.Contains(podName, filter) || strings.Contains(containerName, filter)
  +}
  @@ GetAllContainers
  -		if filters.Name != "" && !strings.Contains(container.Name, filters.Name) {
  +		if !matchesWorkloadName(container.PodName, container.Name, filters.Name) {
  			continue
  ```
  </details>

- **前端任务列表 workload 名展示改为 "appName / name" 去重拼接**:原先 `appName || name || '--'` 只显示其一,改为把 `appName`、`name` 去重后 `join(' / ')`,让 Pod 名与容器名同时可见可搜。

  <details><summary>代码依据 packages/web/projects/vgpu/views/task/admin/index.vue</summary>

  ```diff
  -      const workloadName = appName || name || '--';
  +      const workloadName = [appName, name]
  +        .filter((value, index, values) => value && values.indexOf(value) === index)
  +        .join(' / ') || '--';
  ```
  </details>

- 另:新增日文 README(`README_JA.md`)并在中/英 README 加日文入口链接,属国际化,无功能影响。

### 后续发展方向 [AI]
- WebUI 本期是可用性打磨(过滤维度补齐 Pod 名)+ i18n(日文文档),无架构/API 变化。补日文 README 是社区/商业化触达信号(继中英之后第三语言)。证据覆盖过滤链前后端与文档,未见新增视图或权限模型改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY(仅保锚点)</summary>

- Project-HAMi/HAMi-core:无新提交
- Project-HAMi/ascend-device-plugin:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=ebcd8ae000d0ded373cad0ebfabb8289f2c5810a branch=master release=v2.10.0 scanned=2026-08-29 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=de6ce39dc36246d4161e931ae2fd93929e676e55 branch=main release=— scanned=2026-08-29 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=32162c65332b649084b07894fa2c6101469012f5 branch=main release=— scanned=2026-08-29 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-08-29 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=03121b8056cd2a608d6a9418a2c6593ab91763f2 branch=main release=hami-webui-1.2.0 scanned=2026-08-29 -->

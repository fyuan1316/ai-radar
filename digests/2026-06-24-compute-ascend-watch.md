# 昇腾算力栈 diff 雷达 2026-06-24

## 摘要
- **mind-cluster 把"容器快照"从默认 noded 拆成单独的 opt-in DaemonSet**:新增 `noded-container-snapshot.yaml`(240 行,带 hostPID + criu/runc/containerd/dcmi 等一大票特权挂载),同时把这些挂载从默认 `noded.yaml` 里全部删掉。延续昨日落地的 checkpoint/restore 能力,今天做的是**部署面收敛**——快照所需的高权限只在专用变体里开,基线 noded 回归最小权限。
- **ascend-device-plugin 修复热复位"复位环"获取顺序 bug**:`getResetRingDevices` 把 `ringSize==1` 的提前返回挪到 A3/Atlas300I-Duo 分支**之后**,避免 A3/Duo 卡在 ringSize==1 时被误判为只复位单卡(新增 Duo 卡 UT 验证返回 2 张卡)。
- **npu-dra-plugin 把 DRA driver 的 profile/driver-name 配置抽成共享 `pkg/flags.DriverConfig`**(commit 标"解决codecheck问题",实为结构重构):webhook 与 kubeletplugin 两个入口共用同一份 device-profile/driver-name flag 定义,支持 gpu/npu profile 与 hard vNPU。
- 其余 7 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin)本日无新提交,保锚点。

## 当日重要改变
- **mind-cluster [架构方向] 容器快照部署独立化**:新增 `component/noded/build/noded-container-snapshot.yaml`,并从 `noded.yaml` 删除快照相关特权挂载(hostPID/criu/runc/containerd/dcmi/image-path…)。证据见下「AI 总结重点」。compare: https://gitcode.com/Ascend/mind-cluster/compare/65f4b19f231e5ce8510ccb6571c019ba45772455...0f88ecd66b0922e8e3c953def81460e04d9b9c27
- **mind-cluster [bugfix] ascend-device-plugin 热复位环顺序修正**:`hot_reset_manager.go` `getResetRingDevices` 调整 A3/Duo 分支与 `ringSize==1` 早返回的先后。
- **npu-dra-plugin [重构] DRA driver 配置集中化**:新增 `Ascend-npu-dra-plugin/pkg/flags/driverflags.go`(`DriverConfig{Profile,DriverName}`),两入口复用。compare: https://gitcode.com/openFuyao/npu-dra-plugin/compare/c6dc2c73fd29c1e9b43392cae51b60a6168f521e...b28f10a1e98ec0c2af8be45928e08e689d4a7fb4
- mind-cluster [版本] ascend-for-volcano 部署 yaml 把 vc-controller-manager 镜像从 v1.9.0 升到 v1.12.0(`volcano-v1.12.0.yaml`)。

## mind-cluster: 65f4b19f -> 0f88ecd6
- 比较: 65f4b19f231e5ce8510ccb6571c019ba45772455..0f88ecd6 | tag: v26.0.1 | commits=18 | truncated=false
- compare URL: https://gitcode.com/Ascend/mind-cluster/compare/65f4b19f231e5ce8510ccb6571c019ba45772455...0f88ecd66b0922e8e3c953def81460e04d9b9c27

### AI 总结重点(源码 diff 为据)

- **容器快照能力从默认 noded 剥离为独立 DaemonSet,基线 noded 去特权**:新增 `noded-container-snapshot.yaml` 保留 `hostPID: true` + 全套快照挂载(`/user/snapshot` image-path、`ascend-docker-runtime`、`/run/containerd`、`runc`、`criu`、`/usr/lib/criu` npu-plugin、`dcmi`、`cgroup`、`systemd`、`var-kubelet`…),RBAC 给 pods `get/list/watch/patch` + configmaps `create/update/delete`;而默认 `noded.yaml` 把上述挂载与 `hostPID`/`dev-shm` 一并删除。即昨日跨三层落地的 checkpoint/restore 现在按"是否需要快照"分两套部署,默认部署不再承担 criu/runc 这类高危依赖。
  <details><summary>代码依据 component/noded/build/noded.yaml (modified,删除快照挂载)</summary>

  ```diff
       serviceAccountName: noded
       hostNetwork: true
  -    hostPID: true
       initContainers:
  @@ volumeMounts 段 @@
  -            - name: image-path
  -              mountPath: /user/snapshot
  -            - name: ascend-docker-runtime
  -              mountPath: /usr/local/Ascend/Ascend-Docker-Runtime
  -            - name: containerd
  -              mountPath: /run/containerd
  -            - name: runc
  -              mountPath: /usr/local/bin/runc
  -            - name: criu
  -              mountPath: /usr/sbin/criu
  -            - name: npu-plugin
  -              mountPath: /usr/lib/criu
  -            - name: dcmi
  -              mountPath: /usr/local/dcmi
  -            - name: var-kubelet
  -              mountPath: /var/lib/kubelet
  ```
  </details>
  <details><summary>代码依据 component/noded/build/noded-container-snapshot.yaml (added,新增专用变体)</summary>

  ```diff
  +kind: ClusterRole
  +metadata:
  +  name: pods-noded-role
  +rules:
  +  - apiGroups: [""]
  +    resources: ["configmaps"]
  +    verbs: ["get", "create", "update", "list", "watch", "delete"]
  +  - apiGroups: [ "" ]
  +    resources: [ "pods" ]
  +    verbs: [ "get", "list", "watch", "patch" ]
  +---
  +kind: DaemonSet
  +    spec:
  +      hostNetwork: true
  +      hostPID: true
  ```
  </details>
  build 侧 `noded/build/build.sh` 同步把新 yaml 纳入版本替换与产物拷贝(`cp noded-container-snapshot.yaml output/...`)。

- **ascend-device-plugin 热复位环 bug 修复:A3/Duo 卡分支前移到 ringSize 判断之前**:`getResetRingDevices` 原先先算 `ringSize` 并在 `==1` 时直接返回单卡;改后把 `Ascend910A3`(`getA3AssociatedDevices`)与 Atlas300I-Duo(`getDuoCardDevices`)两个特化分支提到 `ringSize==1` 早返回之前。修复前 A3/Duo 卡若 ringSize 算成 1 会被错误地只复位故障单卡,漏掉同环associated/duo 设备。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/hot_reset_manager.go (modified)</summary>

  ```diff
   	deviceNum := len(groupDevice[devType])
  -	ringSize := m.getRingSize(faultDev, boardId, deviceNum)
  -	if ringSize == 1 {
  -		return []*common.NpuDevice{faultDev}, faultDev
  -	}
   	if common.ParamOption.RealCardType == api.Ascend910A3 {
   		return m.getA3AssociatedDevices(faultDev, groupDevice)
   	}
   	... // Atlas300I Duo 分支
   		return m.getDuoCardDevices(faultDev, groupDevice)
  +	ringSize := m.getRingSize(faultDev, boardId, deviceNum)
  +	if ringSize == 1 {
  +		return []*common.NpuDevice{faultDev}, faultDev
  +	}
   	return m.getHccsRingDevices(faultDev, ringSize, groupDevice)
  ```
  </details>
  新增 UT `TestGetResetRingDevicesDuoCard` 断言 `IsContainAtlas300IDuo` 为真时 `getResetRingDevices` 返回 2 张卡;`TestMarkNeedExternalOps` 断言 `markNeedExternalOps` 以 `device.WMAppend` 模式写 `ResetInfo.ManualResetDevs`。

- **ascend-for-volcano 部署对齐 Volcano v1.12.0**:新增/更新 `build/volcano-v1.12.0.yaml`,vc-controller-manager initContainer 镜像 `v1.9.0 → v1.12.0`;`testBuild.sh` 增加 `replace_node_predicate_v17`(对 v1.17 K8s 改 npu.go 的 `NewFitErrWithStatus` 返回)与 `go list -buildvcs=false`。说明昇腾 Volcano 插件正往 Volcano 1.12 / 新 K8s predicate 接口适配。
  <details><summary>代码依据 component/ascend-for-volcano/build/volcano-v1.12.0.yaml (modified)</summary>

  ```diff
  -          image: volcanosh/vc-controller-manager:v1.9.0
  +          image: volcanosh/vc-controller-manager:v1.12.0
  ```
  </details>

### 后续发展方向 [AI]
- 容器快照从"全在默认 noded"改为"独立 yaml",是工程化收口的明确信号:快照依赖 criu/runc/containerd/hostPID 这类高危面,拆出去后**默认部署回到最小权限**,要用快照才挂特权变体——这对企业级安全合规是利好(可按命名空间/节点池选择性开)。证据只覆盖部署 yaml 与 build 脚本,**未见**控制面如何选择把哪批节点跑成 snapshot 变体的调度/标签逻辑。
- 热复位环修复确认昇腾 device-plugin 仍在打磨 A3/Atlas300I-Duo 多卡复位的正确性(同环设备需整体复位),属稳定性维护而非新能力。
- ascend-for-volcano 向 Volcano v1.12.0 + K8s v1.17 predicate 适配,意味着昇腾调度插件在跟 Volcano 上游版本节奏;**hunk 未覆盖** npu.go 里 predicate 返回值实际改成什么(只见 testBuild 的 sed 替换脚本)。

## npu-dra-plugin: c6dc2c73 -> b28f10a1
- 比较: c6dc2c73fd29c1e9b43392cae51b60a6168f521e..b28f10a1 | tag: 1.0.1 | commits=3 | truncated=false
- compare URL: https://gitcode.com/openFuyao/npu-dra-plugin/compare/c6dc2c73fd29c1e9b43392cae51b60a6168f521e...b28f10a1e98ec0c2af8be45928e08e689d4a7fb4

### AI 总结重点(源码 diff 为据)

- **DRA driver 的 `device-profile`/`driver-name` 两个 CLI flag 抽成共享 `pkg/flags.DriverConfig`**:新增 `driverflags.go` 定义 `DriverConfig{Profile, DriverName}` 及 `Flags()`(带 `DEVICE_PROFILE`/`DRIVER_NAME` env)、`ApplyDefaults()`(driver-name 默认 = `profile + ".example.com"`)。webhook 与 kubeletplugin 两个 main 原本各自重复声明 `profile`/`driverName` 字段与 flag,现统一引用 `flags.driverConfig`。纯重构、行为不变(commit 标题"解决codecheck问题"完全没体现)。
  <details><summary>代码依据 Ascend-npu-dra-plugin/pkg/flags/driverflags.go (added)</summary>

  ```diff
  +type DriverConfig struct {
  +	Profile    string
  +	DriverName string
  +}
  +func (d *DriverConfig) Flags(validProfileNames []string) []cli.Flag {
  +	return []cli.Flag{
  +		&cli.StringFlag{Name: "device-profile", ... EnvVars: []string{"DEVICE_PROFILE"}},
  +		&cli.StringFlag{Name: "driver-name", ... EnvVars: []string{"DRIVER_NAME"}},
  +	}
  +}
  +func (d *DriverConfig) ApplyDefaults() {
  +	if d.DriverName == "" { d.DriverName = d.Profile + ".example.com" }
  +}
  ```
  </details>
  <details><summary>代码依据 cmd/ascend-npu-dra-kubeletplugin/main.go (modified,改用共享 config)</summary>

  ```diff
  -	cliFlags = append(cliFlags, driverFlags(flags)...)
  +	cliFlags = append(cliFlags, flags.driverConfig.Flags(validProfileNames)...)
  -		if flags.driverName == "" { flags.driverName = flags.profile + ".example.com" }
  +		flags.driverConfig.ApplyDefaults()
  ```
  </details>

- **保留 gpu/npu 双 profile 与 hard vNPU 路径**(本次未改逻辑,仅随重构迁移):`state.go` 中 `profile == "npu" && enableHardVNPU` 时用 `vnpu.NewNPUSMIManager()`,否则 `NoopVNPUManager`——昇腾 DRA 仍以 npu-smi 做硬切分 vNPU 管理。
  <details><summary>代码依据 cmd/ascend-npu-dra-kubeletplugin/state.go (modified)</summary>

  ```diff
  -	if config.flags.profile == "npu" && config.flags.enableHardVNPU {
  +	if config.flags.driverConfig.Profile == "npu" && config.flags.enableHardVNPU {
   		vm = vnpu.NewNPUSMIManager()
   	}
  ```
  </details>

### 后续发展方向 [AI]
- 这次是把 DRA driver 配置面收拢成可复用包,为后续多 profile(gpu/npu 之外可能扩 vCANN/其他形态)留扩展点;但本区间纯重构,**未见**新增 profile 或新 device 类型。证据只覆盖 flag/config 装配与测试改写,核心分配逻辑未动。
- 昇腾 DRA 走 npu-smi 硬 vNPU(`NewNPUSMIManager`)这一路线在本期得到再确认,与 HAMi 软切分路线形成对照——对标时注意 openFuyao 的 DRA 路径是"硬切分 + 原生 DRA",而非时分软隔离。

## 本期无实质改动(折叠)
<details><summary>7 个 openFuyao 仓本日无新提交</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=0f88ecd66b0922e8e3c953def81460e04d9b9c27 tag=v26.0.1 scanned=2026-06-24 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-06-24 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-24 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-24 -->
<!-- ANCHOR repo=vNPU sha=ed90d497b78be919aa5c571daf7b8914bc89c7fe tag=v0.1.0 scanned=2026-06-24 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-24 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b28f10a1e98ec0c2af8be45928e08e689d4a7fb4 tag=1.0.1 scanned=2026-06-24 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-24 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-06-24 -->
</content>
</invoke>

# NVIDIA 算力栈 diff 雷达 2026-09-22

## 摘要
- DRA 主线(dra-driver-nvidia-gpu)修多驱动共享 ResourceClaim 的健壮性:MIG 部分回滚现只拆本驱动放置的设备,按 `r.Driver == DriverName` 判定,不再误碰其他 DRA 驱动的分配结果。
- driver 容器化仅 RHEL10 UBI base 微版本 tag 上移(patch 级),无逻辑改动。
- 其余 7 仓 EMPTY:gpu-operator / container-toolkit / k8s-device-plugin / dcgm-exporter / DCGM / KAI-Scheduler 无新提交,mig-parted 有 2 提交但仅 bump/CI/merge。

## 当日重要改变
- kubernetes-sigs/dra-driver-nvidia-gpu [健壮性/DRA多驱动语义] `rollbackPartiallyPreparedMIGDevices` 循环内新增 `if r.Driver != DriverName { continue }`——把 ResourceClaim 显式当作可能"多驱动共占"来处理:Prepare() 整份 checkpoint claim.Status,回滚时结果里会混入本驱动没放置的设备,旧逻辑会拿别家的名字去做 MIG teardown。证据 `cmd/gpu-kubelet-plugin/device_state.go`,提交 mig: skip other drivers' results during partial rollback。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/1fc50b37bafb4fc30d92cfb6ca77faecd5c9fb76...83b9d60cf4eb325278948d826458227a95f59905

## kubernetes-sigs/dra-driver-nvidia-gpu: 1fc50b37 -> 83b9d60c
- 比较 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/1fc50b37bafb4fc30d92cfb6ca77faecd5c9fb76...83b9d60cf4eb325278948d826458227a95f59905 | ahead=2 | files=3 | Release: v0.5.0

### AI 总结重点(源码 diff 为据)
- `DeviceState.rollbackPartiallyPreparedMIGDevices` 在遍历 `pc.Status.Allocation.Devices.Results` 时,新增按驱动名过滤:结果的 `.Driver` 不等于本驱动 `DriverName` 就跳过,不进入后续 `NewMigSpecTupleFromCanonicalName` 解析和 MIG 拆除。前:对 claim 里全部结果无差别尝试拆 MIG;后:只处理本驱动放置的 MIG 设备。根因(见测试注释)是 Prepare() 把整份 claim.Status 一起 checkpoint,混合驱动 claim 会在这里留下本驱动没放置的结果。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  	for _, r := range pc.Status.Allocation.Devices.Results {
  +		if r.Driver != DriverName {
  +			continue
  +		}
  		devname := r.Device
  		ms, err := NewMigSpecTupleFromCanonicalName(devname)
  		if err != nil {
  ```
  </details>
- 测试用 NVML mock 的调用计数把"不该走到 teardown"锁死:新增 `deviceGetHandleByUUIDFunc/Calls`(device_health_test.go),`TestRollbackPartiallyPreparedMIGDevicesIgnoresOtherDrivers` 断言外部驱动那条 MIG 形状名字(另一块 GPU、另一 placement)必须让 `deviceGetHandleByUUIDCalls == 0`;并补"our own MIG name"用例防止 guard 把所有结果都跳过还能过测。测试特意用"另一 GPU + 另一 placement"的名字,以证明这里靠的是 Driver 字段而非 placement/名字比较。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state_test.go / device_health_test.go</summary>

  ```diff
  +func (m *mockNVMLLibrary) DeviceGetHandleByUUID(uuid string) (nvml.Device, nvml.Return) {
  +	m.deviceGetHandleByUUIDCalls++
  +	return m.deviceGetHandleByUUIDFunc(uuid)
  +}
  ...
  +		require.Zero(t, nvmllib.deviceGetHandleByUUIDCalls, "another driver's result must not reach MIG teardown")
  ```
  </details>

### 后续发展方向 [AI]
- 这条把 dra-driver 内部对 ResourceClaim 的假设从"单驱动独占"正式改成"可多驱动共占、各驱动只对自己 `DriverName` 的结果负责"——是 DRA 走向"一份 claim 里 GPU/网卡/其他厂商设备混排"的一个落地脚印。证据只覆盖 MIG **回滚**路径(rollbackPartiallyPreparedMIGDevices),未见 Prepare/Unprepare 主路径是否也已加同类 Driver 过滤,若未加则同源隐患仍在;需下期盯 device_state.go 的 prepare 侧。

## gpu-driver-container: 2e703a2e -> 575c9011
- 比较 https://github.com/NVIDIA/gpu-driver-container/compare/2e703a2ef0232fd865863ecd6eb3dfa8e9cc7636...575c9011c4fa4b94200c56818b1f97cdbcf610af | ahead=2 | files=1 | Release: —

### AI 总结重点(源码 diff 为据)
- 仅 `rhel10/Dockerfile` 的 `BASE_IMAGE` UBI10 微版本 tag 从 `10.2-1789459392` 抬到 `10.2-1789952991`,无 driver 编译/OS 矩阵逻辑改动,属跟随上游 UBI patch 的例行更新。
  <details><summary>代码依据 rhel10/Dockerfile</summary>

  ```diff
  -ARG BASE_IMAGE=registry.access.redhat.com/ubi10/ubi:10.2-1789459392
  +ARG BASE_IMAGE=registry.access.redhat.com/ubi10/ubi:10.2-1789952991
  ```
  </details>

## 本期无实质改动(折叠)
<details><summary>EMPTY / 仅 bump·CI·merge 的 repo(7 仓)</summary>

- NVIDIA/gpu-operator — 无新提交(HEAD 未动,Release v26.7.0)
- NVIDIA/nvidia-container-toolkit — 无新提交(Release v1.20.1)
- NVIDIA/k8s-device-plugin — 无新提交(Release v0.20.0)
- NVIDIA/dcgm-exporter — 无新提交(Release 4.8.4)
- NVIDIA/DCGM — 无新提交(master)
- NVIDIA/mig-parted — ahead=2 但仅 bump/CI/merge,无实质提交(HEAD 已移,锚点已更新,Release v0.15.0)
- kai-scheduler/KAI-Scheduler — 无新提交(Release v0.17.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=bf73d0763dcb3a76946699d382a179de386a3696 branch=main release=v26.7.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3a6c050d9c0c7b2516ce17e2190fb7e71b741f82 branch=main release=v1.20.1 scanned=2026-09-22 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=575c9011c4fa4b94200c56818b1f97cdbcf610af branch=main release=— scanned=2026-09-22 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1a7c1f8a9c074efd3ff2063a689195dea461f178 branch=main release=v0.20.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=83b9d60cf4eb325278948d826458227a95f59905 branch=main release=v0.5.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-09-22 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-22 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=1ac68c21e2f5e637c5d60e305079c3451811288a branch=main release=v0.15.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=90f9eb339926ae028ea3589ac451da4c8ccd05c2 branch=main release=v0.17.2 scanned=2026-09-22 -->

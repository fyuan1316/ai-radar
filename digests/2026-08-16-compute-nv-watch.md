# NVIDIA 算力栈 diff 雷达 2026-08-16

## 摘要
- **DRA driver 是本日唯一实质源**:webhook 准入开始校验 `VfioDeviceConfig`(GPU 直通/VFIO 配置正式纳入准入面),同时新增"非法 admin-access 申领"拒绝逻辑,并把"部分完成的 prepare"回滚拆成 MIG 专用 rollback、明确 VFIO 因配置幂等不回滚——DRA 路径正把 VFIO 直通与 DynamicMIG 打磨成一等公民。
- nvidia-container-toolkit 发布 **v1.20.0 正式版**(上期为 v1.20.0-rc.1),GA 版本落地。
- 其余 8 仓本日仅 TPN 文档重生成 / golang toolchain 升版 / 依赖 bump / CI,无功能级改动。

## 当日重要改变
- kubernetes-sigs/dra-driver-nvidia-gpu [API/准入] webhook `admitResourceClaimParameters` 新增 `*nvapi.VfioDeviceConfig` 分支,VFIO 直通设备配置首次进入准入校验路径。证据 `cmd/webhook/main.go` https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/acdc10f11753a2686f24ba07fcadccad0073de0e...d485fb70d00709811fba898acef76cf809b192b2
- kubernetes-sigs/dra-driver-nvidia-gpu [新能力] `Prepare()` 入口新增 `validateAdminAccessRequest(claim)`,非法 admin-access 申领在准备前即被拒。证据 `cmd/gpu-kubelet-plugin/device_state.go`(同上 compare)
- NVIDIA/nvidia-container-toolkit [版本跨档] Release v1.20.0-rc.1 → v1.20.0(GA)。https://github.com/NVIDIA/nvidia-container-toolkit/releases/tag/v1.20.0

## kubernetes-sigs/dra-driver-nvidia-gpu: acdc10f1 -> d485fb70
- 比较: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/acdc10f11753a2686f24ba07fcadccad0073de0e...d485fb70d00709811fba898acef76cf809b192b2 | ahead=12 | files=20 | Release: v0.4.1

### AI 总结重点(源码 diff 为据)
- **VFIO 直通配置纳入 webhook 准入**:`admitResourceClaimParameters` 的 config 类型分发里补上了 `*nvapi.VfioDeviceConfig`,此前只识别 GPU/MIG/ComputeDomain 系列。含义:通过 DRA 申领 VFIO 直通设备(把整卡 passthrough 给 VM/裸金属)时,其参数现在会被 admission webhook 校验,而非直接放行。

  <details><summary>代码依据 cmd/webhook/main.go</summary>

  ```diff
   		case *nvapi.MigDeviceConfig:
   			configInterface = castConfig
  +		case *nvapi.VfioDeviceConfig:
  +			configInterface = castConfig
   		case *nvapi.ComputeDomainChannelConfig:
   			configInterface = castConfig
  ```
  </details>

- **Prepare 入口前置校验 admin-access**:`DeviceState.Prepare()` 一进来就调用 `validateAdminAccessRequest(claim)`,失败直接返回错误,不再进入加锁/分配流程。把"非法管理员级申领"挡在资源准备之前。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
   func (s *DeviceState) Prepare(ctx context.Context, claim *resourceapi.ResourceClaim) ([]kubeletplugin.Device, error) {
  +
  +	if err := s.validateAdminAccessRequest(claim); err != nil {
  +		return nil, err
  +	}
  +
   	tplock0 := time.Now()
   	s.Lock()
  ```
  </details>

- **"部分完成的 prepare"回滚路径拆分,VFIO 明确不回滚**:原来 `Prepare()` 重试和 `Unprepare()` 共用一个拼写错误的 `unpreparePartiallyPrepairedClaim`。现在拆成两个语义清晰的函数:`Prepare()` 重试时走新的 `rollbackPartiallyPreparedClaim`(仅在 `DynamicMIG` feature gate 开启时回滚 MIG 动态设备),并在注释中明确"VFIO 设备的配置是幂等的,Prepare 期间不做回滚";`Unprepare()` 走改名后的 `unpreparePartiallyPreparedClaim`。含义:VFIO 直通与 MIG 动态切分的失败恢复语义被区别对待,避免对幂等的 VFIO 做无谓/危险的回滚。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
   	if exists && preparedClaim.CheckpointState == ClaimCheckpointStatePrepareStarted {
  -		if err := s.unpreparePartiallyPrepairedClaim(ctx, claimUID, preparedClaim, cp); err != nil {
  -			return nil, fmt.Errorf("unprepare failed for partially prepared claim %s failed: %w", ...)
  +		if err := s.rollbackPartiallyPreparedClaim(ctx, claimUID, preparedClaim, cp); err != nil {
  +			return nil, fmt.Errorf("rollback failed for partially prepared claim %s failed: %w", ...)
   		}
   	}
  +// Note: We do not attempt rollback of VFIO devices during Prepare() as its
  +// device configuration is idempotent.
  +func (s *DeviceState) rollbackPartiallyPreparedClaim(...) error {
  +	if featuregates.Enabled(featuregates.DynamicMIG) {
  +		migDevices := allocDevsForClaim.GetMigDynamicDevices()
  +		if len(migDevices) > 0 { ... rollbackPartiallyPreparedMIGDevices(...) }
  +	}
  +	return nil
  +}
  ```
  </details>

- **新增 MIG 静态/动态设备筛选器**:`AllocatableDevices` 上加了 `GetMigStaticDevices()` 与 `GetMigDynamicDevices()`,按 `MigStaticDeviceType`/`MigDynamicDeviceType` 分类。上面的回滚逻辑正是靠 `GetMigDynamicDevices()` 只挑动态 MIG 设备做回滚——静态 MIG(预切分)不在回滚范围。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/allocatable.go</summary>

  ```diff
  +func (d AllocatableDevices) GetMigStaticDevices() []*AllocatableDevice {
  +	for _, device := range d {
  +		if device.Type() == MigStaticDeviceType { devices = append(devices, device) }
  +	}
  +}
  +func (d AllocatableDevices) GetMigDynamicDevices() []*AllocatableDevice {
  +	for _, device := range d {
  +		if device.Type() == MigDynamicDeviceType { devices = append(devices, device) }
  +	}
  +}
  ```
  </details>

### 后续发展方向 [AI]
- DRA driver 正在把 **VFIO 整卡直通**当作与 GPU/MIG 并列的一等设备类型收口:先前它已存在于 config 类型里,本次补齐了"准入校验 + 失败恢复语义"两块。证据覆盖 webhook 分发与 Prepare/Unprepare 回滚路径,未见 VFIO 具体设备准备(reprepare)逻辑本身的改动。
- **DynamicMIG 仍是 feature gate 后的能力**:回滚只在 `featuregates.Enabled(DynamicMIG)` 时触发,说明动态 MIG 尚未默认开启,静态 MIG 与动态 MIG 的生命周期被刻意分离处理。证据仅覆盖回滚分支,未展开动态 MIG 的创建/切分主流程。

## 本期无实质改动(折叠)
<details><summary>8 仓:仅版本 bump / TPN 文档重生成 / toolchain 升版 / CI</summary>

- **NVIDIA/gpu-operator**(ahead=22):TPN 文档重生成(去掉 module@version 只留 module 名)、mig-manager 镜像 v0.14.4→v0.14.5、golang 1.26.5→1.26.6、dependabot 对 `NVIDIA/*` 加 cooldown 例外;无 API/CRD/功能改动。https://github.com/NVIDIA/gpu-operator/compare/248cabb6a717d75dceb022ea98079968f9572ffd...ed270f823c2ecbe6d4f854054db084d4b6491a4b
- **NVIDIA/nvidia-container-toolkit**(ahead=4):Release 转 GA v1.20.0(见上);代码侧仅 TPN 文档去版本号、e2e workflow 修 ssh key 处理(`trap rm` + `printf` 防换行泄漏),无 runtime hook 改动。https://github.com/NVIDIA/nvidia-container-toolkit/compare/02ccb62b0d828daaf3f4714f5d636773bfcf06aa...cb5d6990b8069e8ad9bdb67f9a2b3ff832d9531c
- **NVIDIA/gpu-driver-container**(ahead=2):RHEL9 UBI base image 版本号 bump(9.8-1786416589→9.8-1786631889),无预编译/OS 矩阵结构变化。
- **NVIDIA/mig-parted**(ahead=17):新增 Renovate 配置管理 golang toolchain、TPN 重生成、`deployments/container/Dockerfile` GOLANG_VERSION 1.22.8→1.26.6、修 OCI base image label 拼写(`org.opencontainers.base.name`→`image.base.name`);无 MIG 切分逻辑改动。
- **NVIDIA/k8s-device-plugin**:仅 bump/CI/merge(__EMPTY__)。
- **NVIDIA/dcgm-exporter**:无新提交。
- **NVIDIA/DCGM**:无新提交。
- **kai-scheduler/KAI-Scheduler**:无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=ed270f823c2ecbe6d4f854054db084d4b6491a4b branch=main release=v26.3.3 scanned=2026-08-16 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=cb5d6990b8069e8ad9bdb67f9a2b3ff832d9531c branch=main release=v1.20.0 scanned=2026-08-16 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=6c629a86a8ddf96a98085c8abad0406f1231e326 branch=main release=— scanned=2026-08-16 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=02811acf135e9ac0451d5d96efb9ebe52f7fe78d branch=main release=v0.19.3 scanned=2026-08-16 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=d485fb70d00709811fba898acef76cf809b192b2 branch=main release=v0.4.1 scanned=2026-08-16 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-16 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-16 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5c3505c4fe8170d06c726f90ef332c93131653f3 branch=main release=v0.14.5 scanned=2026-08-16 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=cea080fe6f7674f669bea907c8a92b5edeaa31b7 branch=main release=v0.17.0 scanned=2026-08-16 -->

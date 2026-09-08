# NVIDIA 算力栈 diff 雷达 2026-09-09

## 摘要
- 全栈无 API/CRD/ClusterPolicy 演进,均为小步维护:gpu-operator 让 mig-manager 的 host-driver 关停开关可被外部注解覆盖(解耦 host driver 生命周期);dra-driver 补了一整套 gpu-kubelet-plugin 单测并修了 compute-domain 的 cliqueID 竞态;KAI-Scheduler 修 binder 关停时 reservation sync 不再 panic。
- 五仓 EMPTY(driver-container/k8s-device-plugin/dcgm-exporter/DCGM/mig-parted),time-slicing/MPS/MIG 硬切分本期零演进。

## 当日重要改变
- NVIDIA/gpu-operator [行为变更] mig-manager 的 `WITH_SHUTDOWN_HOST_GPU_CLIENTS` 从"强制等于 IS_HOST_DRIVER"改为"外部已设则尊重外部值",配合提交 "Decouple host drivers and shutdown",让是否关停 host GPU clients 可与"是否 host driver"解耦。证据 assets/state-mig-manager/0420_configmap.yaml。https://github.com/NVIDIA/gpu-operator/commit/6e330ac55c4152fc95e04343cbbca4db14f6f12c
- kubernetes-sigs/dra-driver-nvidia-gpu [稳定性] compute-domain(IMEX/MNNVL fabric)通道配置改用 `CliqueID()` 访问器读 cliqueID,消除并发读裸字段的竞态。证据 cmd/compute-domain-kubelet-plugin/device_state.go。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/2aa7e2c95821b1e3df9f6b0ca345ae3f915c87bb
- kai-scheduler/KAI-Scheduler [稳定性] binder 启动协程改用请求 ctx 做 cache sync 与 reservation Sync,context 取消时静默退出而非 panic。证据 cmd/binder/app/app.go。https://github.com/kai-scheduler/KAI-Scheduler/commit/abbad9c727548d7780bd262e9c9805573e9751b4

## NVIDIA/gpu-operator: 08c40bc4 -> 6e330ac5
- 比较 08c40bc4..6e330ac5 | ahead=2 | Release: v26.7.0
### AI 总结重点(源码 diff 为据)
- mig-manager 初始化脚本原来把关停 host GPU clients 的开关**硬绑**到 `IS_HOST_DRIVER`(host 上装了 driver 就一定关),现在改成"外部环境变量优先、缺省才回退到 `IS_HOST_DRIVER`"。这让上层(operator 调度 host-driver 关停时序)可显式决定该 MIG 重配是否需要连带关停 host 上的 GPU 客户端进程,是"host driver 与 shutdown 解耦"的落点。
  <details><summary>代码依据 assets/state-mig-manager/0420_configmap.yaml</summary>

  ```diff
  -    export WITH_SHUTDOWN_HOST_GPU_CLIENTS=$IS_HOST_DRIVER
  +    export WITH_SHUTDOWN_HOST_GPU_CLIENTS=${WITH_SHUTDOWN_HOST_GPU_CLIENTS:-$IS_HOST_DRIVER}
  ```
  </details>
### 后续发展方向 [AI]
- 指向 gpu-operator 在做 host(预装)driver 与容器化 driver 混部下的关停时序治理:把"重配 MIG 是否打断 host 上 GPU 负载"交给上层控制。证据只覆盖 mig-manager configmap 这一处 env 传递,未见 operator controller 侧如何注入 `WITH_SHUTDOWN_HOST_GPU_CLIENTS`(那部分应在本区间外的 controller 代码,本次 diff 未含)。

## kubernetes-sigs/dra-driver-nvidia-gpu: 8ad4e66f -> 2aa7e2c9
- 比较 8ad4e66f..2aa7e2c9 | ahead=18 | files=10 | Release: v0.5.0
### AI 总结重点(源码 diff 为据)
- 唯一实质行为改动:`applyComputeDomainChannelConfigHostManaged` 判断非 fabric 节点(不属于 MNNVL clique、不注入 IMEX channel 设备)时,由直接读结构体裸字段 `s.computeDomainManager.cliqueID` 改为调 `CliqueID()` 访问器,配合提交标题消除 cliqueID 的并发读竞态。
  <details><summary>代码依据 cmd/compute-domain-kubelet-plugin/device_state.go</summary>

  ```diff
  -	if s.computeDomainManager.cliqueID == "" {
  +	if s.computeDomainManager.CliqueID() == "" {
  ```
  </details>
- 其余 ~1500 行全是 gpu-kubelet-plugin 新增/扩充单测(prepared/allocatable/partitions/driver/deviceinfo/device_state)。这些测试**反映的是既有能力面**而非新功能,但暴露了几个值得记的实现事实:(1) 存在 `DynamicMIG` feature gate,测试通过 `featuregates.FeatureGates().SetFromMap` 切换;(2) 设备类型枚举为 Gpu / MigStatic / MigDynamic / Vfio,MIG 静态与动态并存;(3) driver 按 API server 版本决定 ResourceSlice 拆分——k8s 1.35.0 为边界,≥1.35 走 split ResourceSlices、≤1.34 走 combined。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/allocatable_test.go / driver_test.go</summary>

  ```go
  // allocatable_test.go —— 设备类型 + DynamicMIG gate
  "gpu":         {AllocatableDevice{Gpu: &GpuInfo{}}, GpuDeviceType, false},
  "mig-dynamic": {AllocatableDevice{MigDynamic: &MigSpec{}}, MigDynamicDeviceType, true},
  "mig-static":  {AllocatableDevice{MigStatic: &MigDeviceInfo{}}, MigStaticDeviceType, true},
  "vfio":        {AllocatableDevice{Vfio: &VfioDeviceInfo{}}, VfioDeviceType, false},

  // driver_test.go —— TestShouldUseSplitResourceSlices
  "1.34 combined":           {gitVersion: "v1.34.5", wantSplit: false},
  "1.35.0 split (boundary)": {gitVersion: "v1.35.0", wantSplit: true},
  ```
  </details>
### 后续发展方向 [AI]
- 主线仍是 DRA 原生路径(非 HAMi 软切分)下把 GPU/MIG(静态+动态)/VFIO passthrough 统一到 ResourceClaim,并已为 k8s 1.35 的 split ResourceSlices 做好版本适配。本区间是"测试补齐 + 竞态修复"的稳定化节奏,无新设备类型或字段。证据只覆盖测试与一处 device_state 改动,未见 v0.5.0→下一版的功能提交。

## kai-scheduler/KAI-Scheduler: 57a0ca0d -> abbad9c7
- 比较 57a0ca0d..abbad9c7 | ahead=2 | files=5 | Release: v0.17.1
### AI 总结重点(源码 diff 为据)
- binder 启动时那个后台 goroutine 原来用 `context.Background()` 等 cache sync 并跑 `rrs.Sync`,失败即 `panic`;现改为用传入的 `ctx`:cache sync 未成功直接 return,`Sync` 出错也只在 `ctx.Err()==nil`(即非正常取消)时才报错+panic。效果是进程关停/context 取消时不再因 reservation sync 被打断而 panic。
  <details><summary>代码依据 cmd/binder/app/app.go</summary>

  ```diff
  -		app.manager.GetCache().WaitForCacheSync(context.Background())
  +		if !app.manager.GetCache().WaitForCacheSync(ctx) {
  +			return
  +		}
   		setupLog.Info("syncing resource reservation")
  -		err := app.rrs.Sync(context.Background())
  -		if err != nil {
  +		if err := app.rrs.Sync(ctx); err != nil && ctx.Err() == nil {
   			setupLog.Error(err, "unable to sync resource reservation")
   			panic(err)
   		}
  ```
  </details>
- 另一提交是发布工程:新增 `hack/generate-images-manifest.sh` + Makefile `images-manifest` 目标 + tag 触发的 CI job,发版时产出列出每组件×FIPS 变体×平台(amd64/arm64)镜像 digest 的 `images.yaml` 作为 release asset。属供应链/可复现性配套,非调度核心。
### 后续发展方向 [AI]
- 调度核心本期无演进(无 queue/reclaim/plugin 改动),两处均为运行稳定性与发布可追溯性。证据只覆盖 binder app.go 与发布脚本,未见 scheduler/podgroup 逻辑改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 仅文档</summary>

- NVIDIA/nvidia-container-toolkit:仅 CONTRIBUTING.md 增补 "重大改动先开 issue" 的贡献流程,无代码/runtime hook 改动。
- NVIDIA/gpu-driver-container:无新提交。
- NVIDIA/k8s-device-plugin:无新提交(time-slicing/MPS 配置面零演进)。
- NVIDIA/dcgm-exporter:无新提交(指标语义无变化)。
- NVIDIA/DCGM:无新提交。
- NVIDIA/mig-parted:无新提交(MIG 硬切分配置器零演进)。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=6e330ac55c4152fc95e04343cbbca4db14f6f12c branch=main release=v26.7.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=5b40a67c4ae3e727d6e663cbf72dc6e534b2f42b branch=main release=v1.20.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9ac64592151369a93da35b831322f193c03b13f5 branch=main release=— scanned=2026-09-09 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=4edf2b66ec53db87c36e035f82e5629b676893e3 branch=main release=v0.20.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=2aa7e2c95821b1e3df9f6b0ca345ae3f915c87bb branch=main release=v0.5.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-09-09 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-09 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=2098686586250d28c472aaa821643a069f8464ec branch=main release=v0.15.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=abbad9c727548d7780bd262e9c9805573e9751b4 branch=main release=v0.17.1 scanned=2026-09-09 -->

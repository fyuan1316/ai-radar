# NVIDIA 算力栈 diff 雷达 2026-10-17

## 摘要
- **L2 k8s-device-plugin** 修了 MIG 场景下的健康检查重复注册 bug:`checkHealth` 原先按 placedDevice 逐个去 `DeviceGetHandleByUUID(parent)` 并注册事件,一张被切成 N 个 MIG 实例的物理 GPU 会被重复注册 N 次事件;改为先 `groupByParent` 聚成 parent→subdevices,再按父 GPU 唯一一次注册,失败则把该父下所有子设备整体标记 unhealthy。纯正确性/幂等修复,无 API/CRD/调度语义改变。
- 其余 8 个源仓本期全无实质改动(gpu-operator / nvidia-container-toolkit / dra-driver-nvidia-gpu / KAI-Scheduler 等均无新提交),锚点原样续链。

## 当日重要改变
- 无命中弃用/API-CRD/架构方向/版本跨档信号。唯一代码改动为 k8s-device-plugin 的健康检查幂等修复(见下),属行为修正而非重要改变信号。

## NVIDIA/k8s-device-plugin: 0d020077 -> 1053da35
- 比较: 0d02007724768b4f4ac80cd8ad058d97a04000ee -> 1053da35 | ahead=2 | files=1 | Release: v0.20.1

### AI 总结重点(源码 diff 为据)
- **`nvmlResourceManager.checkHealth` 把事件注册从"按设备"改为"按父 GPU 去重"**。原逻辑在收集 placedDevices 的同一个循环里,对每个设备 `d` 用其父 UUID 调 `DeviceGetHandleByUUID(uuid)` 并 `RegisterEvents` —— 当一张物理 GPU 被切成多个 MIG 实例时,同一个父 GPU 句柄会被重复拿取并重复注册事件(每个 MIG 子设备一次)。新逻辑先把 `groupByParent(placedDevices)` 上移、构造 `parentToDeviceMap`,再遍历 `parentUUID`(每张父 GPU 仅一次)注册事件;任一步失败(取句柄失败 / 查不到 supported events / RegisterEvents 非 SUCCESS)时,改为 `for _, d := range subdevices { unhealthy <- d }` 把该父 GPU 下**所有**子设备整体打成 unhealthy,而非只推送当前单个 `d`。日志里的设备标识也从子设备 `d.ID` 改为 `parentUUID`,与"按父注册"语义对齐。
  <details><summary>代码依据 internal/rm/health.go</summary>

  ```diff
  +	}
  +	parentToDeviceMap := groupByParent(placedDevices)

  -		gpu, ret := r.nvml.DeviceGetHandleByUUID(uuid)
  +	for parentUUID, subdevices := range parentToDeviceMap {
  +		gpu, ret := r.nvml.DeviceGetHandleByUUID(parentUUID)
  		if ret != nvml.SUCCESS {
  			klog.Infof("unable to get device handle from UUID: %v; marking it as unhealthy", ret)
  -			unhealthy <- d
  +			for _, d := range subdevices {
  +				unhealthy <- d
  +			}
  			continue
  		}
  ...
  		case ret != nvml.SUCCESS:
  -			klog.Infof("Marking device %v as unhealthy: %v", d.ID, ret)
  -			unhealthy <- d
  +			klog.Infof("Marking device %v as unhealthy: %v", parentUUID, ret)
  +			for _, d := range subdevices {
  +				unhealthy <- d
  +			}
  		}
  	}
  -	parentToDeviceMap := groupByParent(placedDevices)
  ```
  </details>

### 后续发展方向 [AI]
- 这是 MIG 共享下 XID 事件监听路径的幂等/正确性收口:按父 GPU 注册一次事件,既避免对同一 nvml event set 重复 `RegisterEvents`(潜在报错或资源浪费),也让父 GPU 级故障能正确传播到其上全部 MIG 子设备。延续上期(v0.20.1,`disabledXIDs` 白名单语义修复)在 `internal/rm/health.go` 的持续打磨——健康检查在 MIG 多实例拓扑下的边界此前并不严谨。证据只覆盖 `checkHealth` 的注册段,未见 `groupByParent` 实现与事件消费侧(for-select 轮询)改动;无 time-slicing/MPS/DRA 配置面变化,Release 仍 v0.20.1(HEAD 为合入 PR #2054 的 merge commit)。来源:https://github.com/NVIDIA/k8s-device-plugin/pull/2054

## 本期无实质改动(折叠)
<details><summary>下列 repo 本期仅 bump/CI/merge 或无新提交,未单列正文</summary>

- NVIDIA/gpu-operator:无新提交。
- NVIDIA/nvidia-container-toolkit:无新提交。
- NVIDIA/gpu-driver-container:无新提交。
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交。
- NVIDIA/dcgm-exporter:无新提交。
- NVIDIA/DCGM:无新提交(master 分支)。
- NVIDIA/mig-parted:无新提交。
- kai-scheduler/KAI-Scheduler:无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=dbb11e85129b601afe9fb502ac25b062ad094abd branch=main release=v26.7.2 scanned=2026-10-17 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3e112b4af299bf72a1b23193b4f5c3321475dd6d branch=main release=v1.20.1 scanned=2026-10-17 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d6d82abedb448b8f67992f1b59c86f163df24772 branch=main release=— scanned=2026-10-17 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1053da35d5a67fdbc3f0ea0877b7178026048769 branch=main release=v0.20.1 scanned=2026-10-17 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=6d5bdb8f19c2e6f50fe8f282fa77816503cb0571 branch=main release=v0.5.1 scanned=2026-10-17 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-17 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-17 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-17 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=e496b7539d40d3c8428ce56d967933de4a9a0a05 branch=main release=v0.18.6 scanned=2026-10-17 -->

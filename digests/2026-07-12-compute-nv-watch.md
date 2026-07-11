# NVIDIA 算力栈 diff 雷达 2026-07-12

## 摘要
- **nvidia-container-toolkit 让「管理模式」CDI spec 也带上 CUDA 前向兼容 hook**:`ModeManagement` 之前显式禁用 `HookEnableCudaCompat`(管理容器不注入 CUDA compat),现在只禁用 `DisableDeviceNodeModificationHook`——管理模式 CDI spec 里新增 `enable-cuda-compat --host-driver-version=<ver>` 的 `createContainer` hook。意味着 gpu-operator 的管理类容器在驱动/CUDA 版本错配时也能走前向兼容库(#1933)。
- **mig-parted 把测试从已弃用的 `dgxa100.Server` mock 迁到通用 `nvml/mock/server`**:随 go-nvlib 0.11→0.12 bump,`nvml_test.go`/`config_test.go` 的类型断言从 `*dgxa100.Server`/`*dgxa100.Device` 改为 `*nvmlmock.Server`/`*nvmlmock.Device`。纯测试重构,MIG 切分逻辑本身无改动。
- 其余 7 仓 EMPTY:gpu-operator/k8s-device-plugin/dra-driver 仅 bump/CI(k8s-device-plugin files=300 全是依赖与 workflow bump),gpu-driver-container/dcgm-exporter/DCGM/KAI-Scheduler 无新提交。ClusterPolicy CRD 本期无字段变更。

## 当日重要改变
- NVIDIA/nvidia-container-toolkit [行为变更/新能力] 管理模式 CDI spec 由「禁用 CUDA compat hook」改为启用,`enable-cuda-compat` hook 现随管理设备一并注入,携 `--host-driver-version`(#1933)。https://github.com/NVIDIA/nvidia-container-toolkit/commit/dae2b8dfed6a211c24a0b0eaf1dbb17f62851191

## NVIDIA/nvidia-container-toolkit: 312b675b -> 3db41dec
- 比较: 312b675b7c06fe7f9cfb9a80ab647040516e8b70 -> 3db41dec | ahead=2 | files=3 | Release: v1.20.0-rc.1
- Compare: https://github.com/NVIDIA/nvidia-container-toolkit/compare/312b675b7c06fe7f9cfb9a80ab647040516e8b70...3db41dec03bf1179b4f7259f6a7037f7f158d39b

### AI 总结重点(源码 diff 为据)
- **管理模式(ModeManagement)不再屏蔽 CUDA 前向兼容 hook**:`populateOptions` 里管理模式的 `disabledHooks` 从 `[HookEnableCudaCompat, DisableDeviceNodeModificationHook]` 收窄为仅 `[DisableDeviceNodeModificationHook]`。此前的注释明确说「显式禁用启用 CUDA 兼容与设备节点修改的 hook」,改后只禁用设备节点修改。效果:生成 `management.nvidia.com/gpu` 这类管理 CDI spec 时,`enable-cuda-compat` 会作为 `createContainer` hook 注入(带 `--host-driver-version=<host 驱动版本>`)。管理容器(gpu-operator 自身的验证/管理组件)因此在容器内 CUDA 运行时新于宿主驱动时,能挂载前向兼容库运行,而非之前被一刀切禁用。
  <details><summary>代码依据 pkg/nvcdi/options.go</summary>

  ```diff
   	if o.mode == ModeManagement {
  -		// For management mode we explicitly disable the hooks that enable CUDA
  -		// compatibility and disable device node modifications.
  -		o.disabledHooks = append(o.disabledHooks, HookEnableCudaCompat, DisableDeviceNodeModificationHook)
  +		// For management mode we explicitly disable the hook that disables device node modifications.
  +		o.disabledHooks = append(o.disabledHooks, DisableDeviceNodeModificationHook)
   	}
  ```
  </details>
- **测试固化了新行为**:`lib_test.go`(Go)与 `toolkit_test.go`(YAML fixture)在管理 spec 的期望 hook 列表里新增 `enable-cuda-compat --host-driver-version=999.88.77` 一项,位置紧接 `create-symlinks` hook。确认注入点是 createContainer 生命周期、且依赖显式传入的 host 驱动版本参数。
  <details><summary>代码依据 pkg/nvcdi/lib_test.go</summary>

  ```diff
  +						{
  +							HookName: "createContainer",
  +							Path:     "/usr/bin/nvidia-cdi-hook",
  +							Args:     []string{"nvidia-cdi-hook", "enable-cuda-compat", "--host-driver-version=999.88.77"},
  +							Env:      []string{"NVIDIA_CTK_DEBUG=false"},
  +						},
  ```
  </details>

### 后续发展方向 [AI]
- 这是把「驱动/CUDA 版本错配容错」从普通工作负载容器延伸到管理容器的一步:以往管理面被认为紧贴宿主驱动、无需 compat,现在承认管理组件也可能带更新的 CUDA runtime。对我们产品的启示:若自研 GPU operator 有独立的管理/验证容器镜像,需评估其 CUDA 版本是否会超前于所纳管节点的驱动版本,前向兼容库的注入策略应覆盖管理面而非只覆盖用户 Pod。证据仅覆盖 `disabledHooks` 构造与测试期望,未见 `enable-cuda-compat` hook 内部对 host-driver-version 的具体判定逻辑(在 nvidia-cdi-hook 实现里,本 diff 未含)。

## mig-parted: bdb9a4bb -> b52cf9c9
- 比较: bdb9a4bbce2f1ac22533c074f081c5a539fc14f0 -> b52cf9c9 | ahead=5 | files=65 | Release: v0.14.3
- Compare: https://github.com/NVIDIA/mig-parted/compare/bdb9a4bbce2f1ac22533c074f081c5a539fc14f0...b52cf9c9ec9f904a5cf73974fd8fcd2a9e097c0a

### AI 总结重点(源码 diff 为据)
- **测试 mock 从弃用的 `dgxa100.Server` 迁到通用 `nvml/mock/server`(纯测试,随 go-nvlib 0.11→0.12)**:`pkg/mig/mode/nvml_test.go` 与 `pkg/mig/config/config_test.go` 新增 import `nvmlmock "github.com/NVIDIA/go-nvml/pkg/nvml/mock/server"`,把类型断言 `manager.nvml.(*dgxa100.Server)` → `(*nvmlmock.Server)`、`server.Devices[1].(*dgxa100.Device)` → `(*nvmlmock.Device)`。commit「remove references to deprecated structs」指的是 go-nvml 已弃用 dgxa100 专用 mock、转向泛化 mock server。MIG 切分/配置解析(config.go、mode 判定)本体无逻辑改动,信号文件全为 `_test.go`。
  <details><summary>代码依据 pkg/mig/config/config_test.go</summary>

  ```diff
  +	nvmlmock "github.com/NVIDIA/go-nvml/pkg/nvml/mock/server"
   ...
  -	n := m.nvml.(*dgxa100.Server)
  +	n := m.nvml.(*nvmlmock.Server)
   ...
  -	gpu1 := server.Devices[1].(*dgxa100.Device)
  +	gpu1 := server.Devices[1].(*nvmlmock.Device)
  ```
  </details>

### 后续发展方向 [AI]
- 无产品含义,属依赖升级的连带测试适配;仅记录以保锚点链。证据覆盖两处测试文件的断言替换,未见任何非测试代码变动。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓</summary>

- NVIDIA/gpu-operator — ahead=4,仅 bump/CI/merge(锚点前移),ClusterPolicy CRD 无变更
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — ahead=3,files=300 全为依赖/workflow bump,无实质提交
- kubernetes-sigs/dra-driver-nvidia-gpu — ahead=2,仅 bump/CI/merge
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM(master)— 无新提交
- kai-scheduler/KAI-Scheduler — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=be25c4f20c3b09d8eb15458897e56c4643e83176 branch=main release=v26.3.3 scanned=2026-07-12 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3db41dec03bf1179b4f7259f6a7037f7f158d39b branch=main release=v1.20.0-rc.1 scanned=2026-07-12 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=65b0904e77aa95ac77f62a735d8a7aff2e276148 branch=main release=— scanned=2026-07-12 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=3e20b8550803574f3df394a9c291cdc73329244c branch=main release=v0.19.3 scanned=2026-07-12 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=9001f17e513115a9366987bf5fd9f7850ac52368 branch=main release=v0.4.1 scanned=2026-07-12 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-12 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=b52cf9c9ec9f904a5cf73974fd8fcd2a9e097c0a branch=main release=v0.14.3 scanned=2026-07-12 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=b63badc941faf424756d2e4e0d2348fccbca4793 branch=main release=v0.14.7 scanned=2026-07-12 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-12 -->

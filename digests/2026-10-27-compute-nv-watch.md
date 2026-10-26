# NVIDIA 算力栈 diff 雷达 2026-10-27

## 摘要
- 又一近乎静默日:9 仓中 7 仓相对 10-26 锚点无新提交,gpu-operator 与 KAI-Scheduler 本期各 2/1 提交全为 merge/bump,唯一实质代码改动在 gpu-driver-container。
- 唯一改动是 driver 容器启动脚本的"跳过内核模块重载快路径"收紧:原先只看 `nvidia` 主模块已加载就跳过重载,现额外要求 `nvidia_uvm`/`nvidia_modeset`(以及开了 GPUDirect RDMA 时的 `nvidia_peermem`)也都已加载,否则不走快路径、老老实实重载——堵住"主模块在但配套模块缺失"时快路径误判为已就绪的半加载态。6 个 OS 矩阵(ubuntu22/24/26.04 + rhel8/9/10)同步改。
- 无 API/CRD/弃用/版本跨档/新 package 信号,当日重要改变为"无"。

## 当日重要改变
- 无

## NVIDIA/gpu-driver-container: 16ec7fee -> f5d915c1
- 比较: 16ec7fee338536f900ceee015f3991459f2a323b -> f5d915c1 | ahead=2 | files=6 | Release: —
- 比较链接 https://github.com/NVIDIA/gpu-driver-container/compare/16ec7fee338536f900ceee015f3991459f2a323b...f5d915c1324483b8166f6da5f9c40bc8299e8c9f

### AI 总结重点(源码 diff 为据)
- **`_should_skip_kernel_module_reload()` 快路径判据从"仅 nvidia 主模块"扩展为"全套必需模块"**:该函数决定 driver 容器重启/升级时能否跳过内核模块卸载+重载(fast path)。原逻辑只校验 `/sys/module/nvidia/refcnt` 与状态文件存在即认为模块已就绪可跳过;新增两道门——必须 `nvidia_uvm` 与 `nvidia_modeset` 的 refcnt 都在,且当 `_gpu_direct_rdma_enabled` 为真时 `nvidia_peermem` 的 refcnt 也在,任一缺失即 `return 1`(不跳过,执行完整重载)。注释点明动机:userspace-only 安装会让 pod 内 `/lib/modules/${KERNEL_VERSION}` 为空,此时若按旧判据走快路径会留下"主模块在、配套模块(UVM/modeset/peermem)缺失"的半加载态。6 个 OS 变体(ubuntu26.04/24.04/22.04 的 `nvidia-driver`、rhel10/9/8 的 `common.sh`)逐一同步,每处 +5/-0,改动完全一致。
  <details><summary>代码依据 rhel9/common.sh(ubuntu*/nvidia-driver 等 6 文件同形)</summary>

  ```diff
   _should_skip_kernel_module_reload() {
       [ -f /sys/module/nvidia/refcnt ] && [ -f /run/nvidia/nvidia-driver.state ] || return 1
  +    # The userspace-only install leaves /lib/modules/${KERNEL_VERSION} empty in this pod.
  +    [ -f /sys/module/nvidia_uvm/refcnt ] && [ -f /sys/module/nvidia_modeset/refcnt ] || return 1
  +    if _gpu_direct_rdma_enabled; then
  +        [ -f /sys/module/nvidia_peermem/refcnt ] || return 1
  +    fi
       local current_digest="${DRIVER_CONFIG_DIGEST:-}"
       [ -z "${current_digest}" ] && return 1
       local stored_digest=$(cat /run/nvidia/nvidia-driver.state 2>/dev/null || echo "")
  ```
  </details>
- 提交 https://github.com/NVIDIA/gpu-driver-container/commit/66381e3471e9b8d16583a9e1f0c557cb667ab07f (PR #1019 fix/peermem-fastpath-gate,作者 karthikvetrivel)

### 后续发展方向 [AI]
- 纯健壮性修复,无能力/架构含义:仅让 driver 容器在模块装载不完整时放弃快路径、回退完整重载,避免 GPUDirect RDMA/UVM 场景下的半加载静默故障。证据仅覆盖 `_should_skip_kernel_module_reload` 这一函数在 6 个 OS 脚本中的同步改动,未见 driver 安装流程/预编译矩阵本身的结构变化,也未动任何 CRD/API/配置面。无趋势可外推,仅可记一笔:快路径的正确性门槛在往"必须全套模块就位"收紧。

## 本期无实质改动(折叠)
<details><summary>7 仓无新提交 + gpu-operator/KAI-Scheduler 仅 merge/bump</summary>

- NVIDIA/gpu-operator(2 提交全为 merge/bump,无实质代码改动,v26.7.2)
- NVIDIA/nvidia-container-toolkit(2 提交全为 merge/bump,v1.20.1)
- NVIDIA/k8s-device-plugin(无新提交,v0.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交,v0.5.1)
- NVIDIA/dcgm-exporter(无新提交,4.8.4)
- NVIDIA/DCGM(无新提交,master)
- NVIDIA/mig-parted(无新提交,v0.15.1)
- kai-scheduler/KAI-Scheduler(1 提交仅 bump/CI,v0.16.14)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=e15471941743c5588e07fcc5f1415d5815e92b55 branch=main release=v26.7.2 scanned=2026-10-27 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=54640d8b9b3832ec3277c192d459c9d70847b1d9 branch=main release=v1.20.1 scanned=2026-10-27 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=f5d915c1324483b8166f6da5f9c40bc8299e8c9f branch=main release=— scanned=2026-10-27 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1053da35d5a67fdbc3f0ea0877b7178026048769 branch=main release=v0.20.1 scanned=2026-10-27 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=43ce288759a2748748b5c9cacd7a34a8b4e89648 branch=main release=v0.5.1 scanned=2026-10-27 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-27 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-10-27 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-27 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=374cbb796ecff07c4a9140e59286f3e3a280e84b branch=main release=v0.16.14 scanned=2026-10-27 -->
</content>

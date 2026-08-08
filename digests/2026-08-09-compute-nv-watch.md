# NVIDIA 算力栈 diff 雷达 2026-08-09

## 摘要
- 全天仅 mig-parted 一条实质提交(#449):给 systemd 版 MIG manager 在重配置前"清场 k8s 容器"的钩子加**运行时探活 + 命令超时**双重保护——运行时未装/未 active 直接跳过,所有 `docker`/`ctr` 调用统一套 `timeout 30s`,消除 docker socket 挂死导致的钩子死锁。
- 其余 8 仓无实质改动(gpu-operator/nvidia-container-toolkit/gpu-driver-container/k8s-device-plugin/dra-driver-nvidia-gpu/dcgm-exporter/DCGM/KAI-Scheduler 均无新提交)。
- 无 API/CRD、无新能力、无 breaking 信号。

## 当日重要改变
- 无(仅一条 systemd 部署脚本的健壮性修复,未命中弃用/API-CRD/架构/版本跨档/新能力任何信号)。

## NVIDIA/mig-parted: a268637f -> f35ad98c
- 比较: a268637ff387f4b47f298e1f8b06beaa263e3ce1 -> f35ad98c | ahead=2 | files=1 | Release: v0.14.4
- https://github.com/NVIDIA/mig-parted/pull/449
- https://github.com/NVIDIA/mig-parted/commit/f410d1383bae731dd3e55a23922ce2dfcb00aa84

### AI 总结重点(源码 diff 为据)
- 改动集中在 `deployments/systemd/utils.sh`——这是**非容器化(systemd 直装)部署路径**下 MIG manager 在应用 MIG 切分前"杀掉正在占用 GPU 的 k8s 容器"的清场逻辑,与 gpu-operator 容器化路径无关。核心是给 `kill_k8s_containers_via_docker_by_image` / `kill_k8s_containers_via_containerd_by_image` 两个函数加**前置探活**和**逐命令超时**两道防线:
  1. 新增 `nvidia-mig-manager::service::runtime_available(client, unit)`:先 `command -v ${client}` 判客户端(docker/ctr)是否安装,再 `systemctl -q is-active ${unit}` 判对应 systemd 单元(docker.service/containerd.service)是否活跃;任一不满足就打印 "Skipping container cleanup" 并 `return 1`。两个 kill 函数开头据此 `return 0` 提前跳过——**运行时不存在/未启动时不再盲目调用 CLI**。
  2. 新增 `cmd_timeout="${cmd_timeout:-30}"`(默认 30s,可环境变量覆盖),把 `docker images/ps/kill/rm`、`ctr image ls/container ls/task kill/task rm/container rm` 等**每一条运行时命令都包进 `timeout ${cmd_timeout}`**。
  - 修复的 bug:此前若节点上 docker CLI 存在但守护进程/socket 挂死(或 containerd 不可达),这些调用会**无限阻塞**,导致 MIG 重配置钩子整体死锁(PR 标题 "avoid deadlocks");现在最坏情况 30s 超时退出,且运行时缺失时直接优雅跳过。
  <details><summary>代码依据 deployments/systemd/utils.sh</summary>

  ```diff
  +cmd_timeout="${cmd_timeout:-30}"
  +
  +function nvidia-mig-manager::service::runtime_available() {
  +	local client="${1}"
  +	local unit="${2}"
  +	if ! command -v "${client}" > /dev/null 2>&1; then
  +		echo "Skipping container cleanup via ${client}: ${client} is not installed" >&2
  +		return 1
  +	fi
  +	systemctl -q is-active "${unit}"
  +	if [ "${?}" != "0" ]; then
  +		echo "Skipping container cleanup via ${client}: ${unit} is not active" >&2
  +		return 1
  +	fi
  +	return 0
  +}
  ```
  </details>
  <details><summary>代码依据 两个 kill 函数:前置探活 + timeout 包裹(docker 路径示例,containerd 路径同构)</summary>

  ```diff
   function nvidia-mig-manager::service::kill_k8s_containers_via_docker_by_image() {
  +	nvidia-mig-manager::service::runtime_available docker docker.service
  +	if [ "${?}" != "0" ]; then
  +		return 0
  +	fi
  +
   	for i in ${__image_names[@]}; do
  -		images+=("$(docker images --format "{{.ID}} {{.Repository}}" | grep "${i}" | ...)")
  +		images+=("$(timeout "${cmd_timeout}" docker images --format "{{.ID}} {{.Repository}}" | grep "${i}" | ...)")
   	done
   	for i in ${images[@]}; do
  -		local containers="$(docker ps --format "{{.ID}} {{.Image}}" | grep "${i}" | ...)"
  +		local containers="$(timeout "${cmd_timeout}" docker ps --format "{{.ID}} {{.Image}}" | grep "${i}" | ...)"
  -			docker kill ${containers}
  +			timeout "${cmd_timeout}" docker kill ${containers}
  ```
  </details>

### 后续发展方向 [AI]
- 纯健壮性/正确性收口,无能力或架构演进。证据只覆盖 systemd 部署脚本(`deployments/systemd/utils.sh`)一个文件,未触及 mig-parted 的 Go 主体(切分引擎、config 解析、CRD)——未见对 MIG 切分策略、config schema 或容器化 gpu-operator 路径的任何改动。信号价值在于:硬切分风向标仓本期没有能力面变化,方向仍是把既有部署路径的边缘失败模式(运行时缺失/挂死)逐个堵死。

## 本期无实质改动(折叠)
<details>
- NVIDIA/gpu-operator — 无新提交
- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- kai-scheduler/KAI-Scheduler — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=cfabcc9a8c4cc071a7120d320d0d8db79984a166 branch=main release=v26.3.3 scanned=2026-08-09 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a996390117806acd2a73fd0e5b3e6a17755f3ae4 branch=main release=v1.20.0-rc.1 scanned=2026-08-09 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=dd8eab6bdea9de694423120038415b81357555dc branch=main release=— scanned=2026-08-09 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=04fc23c27961f42346bcba90e7d00fc2ed818fa0 branch=main release=v0.19.3 scanned=2026-08-09 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=95932046683719c43b6a0dd9613c2e5aad5d6703 branch=main release=v0.4.1 scanned=2026-08-09 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-09 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-09 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=f35ad98cc3718a432fd5d1e49d20dbc28fcaedcd branch=main release=v0.14.4 scanned=2026-08-09 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=d5bc503a146317e51037d89775d77172c6d12f71 branch=main release=v0.17.0 scanned=2026-08-09 -->

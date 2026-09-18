# NVIDIA 算力栈 diff 雷达 2026-09-19

## 摘要
- **dra-driver-nvidia-gpu**:ComputeDomain(IMEX)两处正确性硬化——(1)clique 清理不再仅凭 clique-watch 判死,改为按 label 回查活 Pod 二次确认、出错保留成员,修复跨机架换节点时误删仍在注册的 daemon;(2)把 CD UID 折成短哈希嵌进每个 daemon 的 DNS 主机名(`compute-domain-daemon-<hash>-%04d`),让同一 IMEX 域内不同 ComputeDomain 的主机名不再相撞,从命名层阻断跨 job 串扰。
- **gpu-driver-container**:driver 容器加"守护状态"外置文件 `/run/nvidia/validations/.driver-daemons-status`(load→Ready / init/shutdown→NotReady),给上层校验探针一个明确就绪信号;并对 R615+ 分支强制 `proprietary→open` 内核模块回退。
- 其余 7 仓(gpu-operator/container-toolkit/k8s-device-plugin/dcgm-exporter/DCGM/mig-parted/KAI-Scheduler)本期无实质改动。

## 当日重要改变
- dra-driver-nvidia-gpu [新能力/正确性] 每个 ComputeDomain 的 daemon DNS 名注入 CD-UID 哈希,防同域内跨 job 通信串扰 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/036bd28149b7f9102a876a68550d4f823133832d
- gpu-driver-container [新能力] precompiled driver 增 `.driver-daemons-status` 就绪状态文件,供上层校验 https://github.com/NVIDIA/gpu-driver-container/commit/a275a76bff2cc1c273a597a83542b4b59380138c
- gpu-driver-container [架构方向] R615 及以上驱动分支不再支持 proprietary 内核模块,自动回退 open https://github.com/NVIDIA/gpu-driver-container/commit/9fcc603ff0fe0c999429cd565e4eb556c0d4254a

## kubernetes-sigs/dra-driver-nvidia-gpu: 2b0257cc -> 1fc50b37
- 比较: 2b0257cc -> 1fc50b37 | ahead=5 | files=7 | Release: v0.5.0
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/2b0257ccc35d54968756fb0db10c6740ae923826...1fc50b37bafb4fc30d92cfb6ca77faecd5c9fb76

### AI 总结重点(源码 diff 为据)
- **clique 清理从"单一 watch 判死"改为"回查活 Pod 二次确认",且引入 `podMatchesClique` 归属判定**。原 `cleanupClique` 只看有 running daemon pod 的节点集合 `runningNodes`,不在集合里的 daemon 直接进 `removedNodes` 删除;新逻辑对每个"疑似消失"的 daemon,再按 `computeDomainLabelKey` label selector 拉一次当前 Pod 列表 `livePods`,只有确认该节点上无匹配本 clique 的 Pod 才删,List 出错则直接 return 保留全部成员。归属判定新函数 `podMatchesClique` 要求域 label 相等、且 clique label 要么缺失(尚未打标)要么相等——这解决了"独立的 pod-watch 与 clique-watch 在注册期短暂不一致导致误删"的竞态。
  <details><summary>代码依据 cmd/compute-domain-controller/cdstatus.go</summary>

  ```diff
  	for _, daemon := range clique.Daemons {
  		if _, exists := runningNodes[daemon.NodeName]; exists {
  			updatedDaemons = append(updatedDaemons, daemon)
  -		} else {
  -			removedNodes = append(removedNodes, daemon.NodeName)
  +			continue
  +		}
  +		// Independent pod and clique watches can disagree during registration.
  +		// Confirm removals against current pods, retaining membership on errors.
  +		if livePods == nil {
  +			livePods, err = m.config.clientsets.Core.CoreV1().Pods(clique.Namespace).List(ctx, metav1.ListOptions{
  +				LabelSelector: labels.Set{computeDomainLabelKey: clique.Labels[computeDomainLabelKey]}.String(),
  +			})
  +			if err != nil { klog.Errorf(...); return }
  +		}
  +		if slices.ContainsFunc(livePods.Items, func(pod corev1.Pod) bool {
  +			return pod.Spec.NodeName == daemon.NodeName && podMatchesClique(&pod, clique)
  +		}) { updatedDaemons = append(updatedDaemons, daemon); continue }
  +		removedNodes = append(removedNodes, daemon.NodeName)
  	}
  +func podMatchesClique(pod *corev1.Pod, clique *nvapi.ComputeDomainClique) bool {
  +	if pod.Labels[computeDomainLabelKey] != clique.Labels[computeDomainLabelKey] { return false }
  +	cliqueID, exists := pod.Labels[computeDomainCliqueLabelKey]
  +	return !exists || cliqueID == clique.Labels[computeDomainCliqueLabelKey]
  +}
  ```
  </details>
- **DNS 名格式从全局常量 `compute-domain-daemon-%04d` 改为按域实例方法 `dnsNameFormat()`,前缀嵌入 CD-UID 的 FNV-32a 哈希**。`NewDNSNameManager` 新增入参 `cdUID`,构造时算 `computeDomainHash`(fnv32a → `rand.SafeEncodeString`,得 DNS-label 安全短串),生成的静态主机名变成 `compute-domain-daemon-<hash>-%04d`。`main.go` 里在 `IMEXDaemonsWithDNSNames` feature gate 下把 `flags.computeDomainUUID` 传入。效果:同一 IMEX 物理域里并存的两个 ComputeDomain,其 `/etc/hosts` 静态名不再共用同一序号命名空间,从主机名层面隔离跨 job 通信。选 `SafeEncodeString` 而非裸 hex 是为保证 DNS label 合法性(见后续 commit 48ed8c86)。
  <details><summary>代码依据 cmd/compute-domain-daemon/dnsnames.go</summary>

  ```diff
  -	dnsNameFormat = dnsNamePrefix + "%04d"
  -func NewDNSNameManager(cliqueID string, maxNodesPerIMEXDomain int, nodesConfigPath string) *DNSNameManager {
  +func NewDNSNameManager(cliqueID string, maxNodesPerIMEXDomain int, nodesConfigPath string, cdUID string) *DNSNameManager {
  +		domainHash:            computeDomainHash(cdUID),
  +func computeDomainHash(cdUID string) string {
  +	h := fnv.New32a(); _, _ = h.Write([]byte(cdUID))
  +	return rand.SafeEncodeString(fmt.Sprint(h.Sum32()))
  +}
  +func (m *DNSNameManager) dnsNameFormat() string {
  +	return dnsNamePrefix + m.domainHash + "-%04d"
  +}
  -	dnsName := fmt.Sprintf(dnsNameFormat, daemon.Index)
  +	dnsName := fmt.Sprintf(m.dnsNameFormat(), daemon.Index)
  ```
  </details>
- **新增 291 行表驱动测试 `cdstatus_test.go`**,覆盖 11 个 clique 成员保留/剔除场景(同 clique 保留、未就绪替换 Pod 保留、启动期尚无 clique label 保留、迁到别的 clique 剔除、同节点异域不误删、重叠 Pod 在不同 clique/域各自保留等),把上面两条竞态修复钉成回归用例。

### 后续发展方向 [AI]
- ComputeDomain/IMEX 这条线本期全是"多租户共域下的正确性与隔离"硬化:成员判定抗 watch 竞态、主机名按域隔离。方向指向 IMEX 域在生产里被多 job 并发复用的场景稳定性。证据只覆盖 cdstatus/dnsnames 两文件的 diff 与新测试,未见 API/CRD 字段增删(探测无命中),故属实现层加固而非新 CRD 能力。

## NVIDIA/gpu-driver-container: 03b7c1d1 -> 2e703a2e
- 比较: 03b7c1d1 -> 2e703a2e | ahead=6 | files=15 | Release: —
- https://github.com/NVIDIA/gpu-driver-container/compare/03b7c1d1be459bbfb1cbf1cebe8d54c232657ea5...2e703a2ef0232fd865863ecd6eb3dfa8e9cc7636

### AI 总结重点(源码 diff 为据)
- **precompiled driver 脚本新增 `_set_daemons_status()`,把驱动守护就绪状态外置成文件**。写 `/run/nvidia/validations/.driver-daemons-status`:`_load_driver` 末尾(fabric manager 起来后)写 `Ready`,`init()` 开头写 `NotReady`。全 6 个 OS 变体(ubuntu 22/24/26.04、rhel 8/9/10)一致落地。这给 operator/校验 initContainer 一个不依赖进程探测的显式就绪握手点,补齐 NVSwitch/fabricmanager 系统上"驱动+守护都就绪"的信号。
  <details><summary>代码依据 rhel9/precompiled/nvidia-driver</summary>

  ```diff
  +_set_daemons_status() {
  +    mkdir -p /run/nvidia/validations
  +    echo "${1}" > /run/nvidia/validations/.driver-daemons-status
  +}
   _load_driver() {
           nv-fabricmanager -c /usr/share/nvidia/nvswitch/fabricmanager.cfg || return 1
  +    _set_daemons_status "Ready"
   }
   init() {
  +    _set_daemons_status "NotReady"
       _load
   }
  ```
  </details>
- **R615 及以上驱动分支强制 `proprietary → open` 内核模块回退**。非 precompiled 与 precompiled 脚本(ubuntu 系)开头同增守卫:`DRIVER_BRANCH >= 615 && KERNEL_MODULE_TYPE == proprietary` 时打印警告并改成 `open`。这是 NVIDIA open kernel module 成为高版本唯一支持形态的落地信号,proprietary 内核模块进入尾声。
  <details><summary>代码依据 ubuntu26.04/nvidia-driver</summary>

  ```diff
   KERNEL_MODULE_TYPE=${KERNEL_MODULE_TYPE:-auto}
  +if [ "${DRIVER_BRANCH}" -ge 615 ] && [ "${KERNEL_MODULE_TYPE}" = "proprietary" ]; then
  +    echo "IMPORTANT: KERNEL_MODULE_TYPE=proprietary is not supported for driver branches R615 and later; using open instead"
  +    KERNEL_MODULE_TYPE=open
  +fi
  ```
  </details>
- **RHEL UBI base 镜像 renovate bump**(rhel8/9/10 Dockerfile 各 2 行),仅基镜像日期,无逻辑改动。

### 后续发展方向 [AI]
- driver 容器两条线:就绪状态可观测化(状态文件)+ 内核模块形态收敛(R615+ 仅 open)。前者证据在 6 个 OS 脚本对称新增同一函数,应会被 gpu-operator 侧的 validation 消费(本期 operator 仓 EMPTY,尚未见对接);后者只在 R615 阈值上硬编码,未见配置化开关。证据仅覆盖脚本 diff,未展开 operator 如何读该状态文件。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY</summary>

- NVIDIA/gpu-operator — 无新提交(Release v26.7.0)
- NVIDIA/nvidia-container-toolkit — 无新提交(Release v1.20.0)
- NVIDIA/k8s-device-plugin — 无新提交(Release v0.20.0)
- NVIDIA/dcgm-exporter — 无新提交(Release 4.6.0-4.8.3)
- NVIDIA/DCGM — 无新提交(master)
- NVIDIA/mig-parted — 无新提交(Release v0.15.0)
- kai-scheduler/KAI-Scheduler — 仅 bump/CI/merge(ahead=1,Release v0.17.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=93c0ff560ca71e761d6c1782d904765bb88de3db branch=main release=v26.7.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3a6c050d9c0c7b2516ce17e2190fb7e71b741f82 branch=main release=v1.20.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=2e703a2ef0232fd865863ecd6eb3dfa8e9cc7636 branch=main release=— scanned=2026-09-19 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=674f626b4a6bd353e0cb2e01b5ef6f9d75adb4f2 branch=main release=v0.20.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=1fc50b37bafb4fc30d92cfb6ca77faecd5c9fb76 branch=main release=v0.5.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=16ecae49e4d6174e556e768c87cd4e49d844b909 branch=main release=4.6.0-4.8.3 scanned=2026-09-19 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-19 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=f9613a3bb99dd2b9c01b41a1ebaf11ef17fdbc03 branch=main release=v0.15.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=90f9eb339926ae028ea3589ac451da4c8ccd05c2 branch=main release=v0.17.2 scanned=2026-09-19 -->

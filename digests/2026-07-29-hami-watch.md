# HAMi diff 雷达 2026-07-29

## 摘要
- 主仓 3 实质提交,核心是**调度分配正确性修复 #2105**:`fitInDevices` 里跨设备类型共享的 `devs` 累加器导致多类型设备请求时分配记录被污染,改为按类型取 `tmpDevs[k.Type]`——影响一个 Pod 同时申请多种异构设备(如 GPU+NPU)的场景。
- 安全加固两条:webhook 对 privileged 容器的拒绝逻辑收窄为"仅当同时申请 HAMi 设备才拒"并覆盖 initContainers(#2139);CI 全面按 commit SHA 钉住 actions/镜像/安装脚本(#2147,供应链加固)。
- HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI 四仓无新提交。

## 当日重要改变
- Project-HAMi/HAMi [新能力/修复] 多设备类型分配记录去污染,`fitInDevices` 不再把已处理类型的设备错误累加进后续类型 https://github.com/Project-HAMi/HAMi/pull/2105
- Project-HAMi/HAMi [安全] privileged 容器拒绝逻辑修正:只在"privileged + 申请 HAMi 设备"同时成立时 Deny,且纳入 initContainers https://github.com/Project-HAMi/HAMi/pull/2139

## Project-HAMi/HAMi: c343242d -> 37730dd7
- 比较: c343242d983151f8152e318f52ae4e6e388540f9 -> 37730dd7 | ahead=3 | files=27 | Release: v2.9.0
- https://github.com/Project-HAMi/HAMi/compare/c343242d983151f8152e318f52ae4e6e388540f9...37730dd7118970bb032273bb4d171003b2c684a3

### AI 总结重点(源码 diff 为据)
- **`fitInDevices` 修复跨设备类型的分配污染**(#2105)。旧代码在函数级声明了单个 `devs := device.ContainerDevices{}`,每轮设备类型循环都 `devs = append(devs, tmpDevs[k.Type]...)` 往同一个切片里累加,然后 `(*devinput)[k.Type] = append(..., devs)` 把这个**累积了前面所有类型**的 `devs` 写进当前类型的分配记录。结果:Pod 申请多种设备类型时,靠后类型的分配记录会混入前面类型的设备。新代码删掉共享 `devs`,直接 `(*devinput)[k.Type] = append(..., tmpDevs[k.Type])`,每个类型只记自己的设备。这是分配记录正确性 bug,单类型请求不受影响,多异构设备(GPU+NPU 同 Pod)才暴露。
  <details><summary>代码依据 pkg/scheduler/score.go</summary>

  ```diff
   func fitInDevices(node *NodeUsage, requests device.ContainerDeviceRequests, pod *corev1.Pod, nodeInfo *device.NodeInfo, devinput *device.PodDevices) (bool, string) {
  -	devs := device.ContainerDevices{}
   	total, totalCore, totalMem := int32(0), int32(0), int32(0)
   ...
  -			devs = append(devs, tmpDevs[k.Type]...)
   		} else {
   			return false, reason
   		}
  -		(*devinput)[k.Type] = append((*devinput)[k.Type], devs)
  +		(*devinput)[k.Type] = append((*devinput)[k.Type], tmpDevs[k.Type])
   	}
  ```
  </details>
- **webhook privileged 拒绝逻辑重写**(#2139)。旧逻辑在容器循环里遇到 privileged 容器时 `continue` 跳过——即把该容器排除出设备变更,但**不阻断**整个 Pod 准入。新逻辑抽出 `privilegedContainerName`(先查 initContainers 再查 containers)与 `isPrivilegedContainer` 两个 helper,先算出是否存在 privileged 容器,再走设备变更循环;最后 `if hasPrivileged && hasResource` 才 `admission.Denied`。语义从"静默跳过 privileged 容器"变为"privileged 容器 + 申请了 HAMi 设备 ⇒ 拒绝整个 Pod",且覆盖面从 containers 扩到 initContainers。纯无 HAMi 资源的 privileged Pod 不再被误伤(`hasResource=false` 时放行)。
  <details><summary>代码依据 pkg/scheduler/webhook.go</summary>

  ```diff
  +	privilegedName, hasPrivileged := privilegedContainerName(pod)
   	hasResource := false
  -	for idx, ctr := range pod.Spec.Containers {
  +	for idx := range pod.Spec.Containers {
   		c := &pod.Spec.Containers[idx]
  -		if ctr.SecurityContext != nil {
  -			if ctr.SecurityContext.Privileged != nil && *ctr.SecurityContext.Privileged {
  -				klog.Warningf(...+" - Denying admission as container %s is privileged", ...)
  -				continue
  -			}
  -		}
   		for _, val := range device.GetDevices() { ... }
   	}
  +	if hasPrivileged && hasResource {
  +		return admission.Denied(fmt.Sprintf("container %s is privileged", privilegedName))
  +	}
  +func privilegedContainerName(pod *corev1.Pod) (string, bool) {
  +	for _, ctr := range pod.Spec.InitContainers { if isPrivilegedContainer(&ctr) { return ctr.Name, true } }
  +	for _, ctr := range pod.Spec.Containers { if isPrivilegedContainer(&ctr) { return ctr.Name, true } }
  +	return "", false
  +}
  ```
  </details>
- **CI 供应链加固:actions/镜像/脚本一律按 SHA 钉死**(#2147)。所有 workflow 里 `uses: actions/checkout@v7` 等 tag 引用改成 `@<40位commit-sha> # v7`,并给 checkout 加 `persist-credentials: false`;镜像从 `golang:1.26.5-bookworm`、`nvidia/cuda:...`、`moby/buildkit:master` 改成带 `@sha256:` digest 的不可变引用;`hack/util.sh` 的 helm 安装脚本从裸 `curl ... | bash` 改为下载到临时文件、`sha256sum -c` 校验后再执行并钉版本 v3.8.1。属 OpenSSF scorecard "Pinned-Dependencies" 项的系统性清理,非功能改动。
  <details><summary>代码依据 hack/util.sh</summary>

  ```diff
  -  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  +  local get_helm_ref="8eb65528be9bcf8c40096d386c6eef901537f56f"
  +  local get_helm_sha256="38b65f882d9cae3891755bdb03becc6a01ae6f9cb24826c191f219ddfee70a5d"
  +  get_helm_script=$(mktemp); trap 'rm -f "${get_helm_script}"' EXIT
  +  curl -sSfL ".../helm/${get_helm_ref}/scripts/get-helm-3" -o "${get_helm_script}"
  +  echo "${get_helm_sha256}  ${get_helm_script}" | sha256sum -c -
  +  bash "${get_helm_script}" --version "v3.8.1"
  ```
  </details>

### 后续发展方向 [AI]
- 调度器分配路径的正确性还在补 corner case:#2105 是典型的"函数级共享可变状态跨迭代污染"缺陷,暴露出 `fitInDevices`/`devinput` 这套多类型设备分配的数据流缺测试覆盖(本次同带 score_test.go +88 行)。方向是把多异构设备(GPU+NPU 同 Pod)当一等场景验证——证据只覆盖 score.go 这一处切片赋值与其单测,未见其他分配路径是否有同类共享累加器。
- 安全面从"运行时隔离"外扩到"准入策略 + 供应链"两条线:#2139 明确了 HAMi 不允许 privileged 容器抢占其托管设备(且不误伤无关 privileged Pod),#2147 把 CI 依赖钉死。两者都是走向企业级合规(scorecard 评分、准入基线)的信号;证据只覆盖 webhook.go 与各 workflow/util.sh,未见是否配套加 e2e 或 policy 文档。

## 本期无实质改动(折叠)
<details><summary>4 仓无新提交</summary>

- Project-HAMi/HAMi-core:无新提交(时分软切分内核本期静默)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交(release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=37730dd7118970bb032273bb4d171003b2c684a3 branch=master release=v2.9.0 scanned=2026-07-29 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=52f33fc7fa1fbb3f08148ab076d0e7447bec7f2a branch=main release=— scanned=2026-07-29 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-29 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ed35e1c4b003795de84ba942f6965fa269e866b3 branch=main release=— scanned=2026-07-29 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-29 -->

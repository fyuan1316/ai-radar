# 昇腾算力栈 diff 雷达 2026-09-11

## 摘要(3 条内)
- npu-exporter 修补进程级指标的一个可观测性缺口:设备上**无进程运行时**(`ProcNum==0`)以前直接跳过、不产出任何进程级指标,现在改为仍上报一条 value=0、进程 id 为空、但**带默认容器 ID**的 `npu_chip_info_process_*` 指标——保证"卡已被容器占用但暂无活跃进程"的场景在 Prometheus 里可见(不再指标缺失)。同一提交把硬编码的 label 下标(-1/-2/-3)全部换成命名常量并修了 `cardLabelWiht…` 拼写。
- npu-dra-plugin / ub-network-device-plugin 各一笔纯 CVE 修复:grpc 升到 v1.83.2 修 CVE-2026-84303/84304/84445,构建基镜像 golang 1.24→1.25;无功能/API 改动。
- 其余 7 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext + mind-cluster 其他 component)本期无实质代码改动;mind-cluster 区间内另有 ascend-clusterops-agent 新子项目("part nine")与 RL 实例级故障恢复/volcano 超节点亲和等**资料(docs)**提交,均不落 component 代码,暂不研判。

## 当日重要改变(命中信号才列)
- mind-cluster [新能力] npu-exporter 无进程时补发进程级空指标(带默认容器 ID),消除"卡被占用但无活跃进程→指标缺失"盲区。证据:`component/npu-exporter/collector/metrics/collector_for_npu.go`。https://gitcode.com/Ascend/mind-cluster/compare/94600c37549cec594313a636fb31b51395a58759...72e2192ffdf90a6c3a33606e99c651b38fbf73cd
- npu-dra-plugin [安全] grpc→v1.83.2 修 CVE-2026-84303/84304/84445,golang 基镜像 1.24→1.25。证据:`Ascend-npu-dra-plugin/build/Dockerfile`。https://gitcode.com/openFuyao/npu-dra-plugin/compare/f3cfd270f0dda85b259f4041d6c99824920e17e5...5d7339c517d971eaeb0b915bd19ed3d90db3c44c
- ub-network-device-plugin [安全] 同批 grpc CVE 修复,构建 golang 1.24.5→1.25.10。证据:`cmd/ub-network-device-plugin/Dockerfile`。https://gitcode.com/openFuyao/ub-network-device-plugin/compare/ef44c337d16e208fc1557b8e56a77447f30bc2a7...5dd79f3952dcb2a01c455feb953fe8d5b5b07af9

## mind-cluster: 94600c37 -> 72e2192f
- 比较 / 最新 Release:94600c37..72e2192f | tag: v26.2.0.beta.1 | commits=14 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/94600c37549cec594313a636fb31b51395a58759...72e2192ffdf90a6c3a33606e99c651b38fbf73cd
### AI 总结重点(源码 diff 为据)
- **`updateProcessInfoForPrometheus` 新增 `ProcNum==0` 分支**:此前无进程时函数在 `doUpdateMetric(...descDevProcessNum)` 上报"进程数=0"后直接 `return`,不产出任何 `descDevProcessInfo`(进程级)指标。现改为取 `containerInfos[0]` 作默认容器、经 `getDefaultProcessLabel` 生成 label,补发一条进程 id 为空("")、value=0、但带该容器 ID 的进程级指标。行为差异:被容器持有但当前无活跃进程的 NPU,从"进程级指标完全缺失"变为"有一条零值占位指标",方便上层区分"卡空闲"与"卡被占用但进程未起"。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_npu.go</summary>

  ```diff
   	doUpdateMetric(ch, timestamp, devProcessInfo.ProcNum, cardLabel, descDevProcessNum)
  +	if devProcessInfo.ProcNum == 0 {
  +		var defaultInfo container.DevicesInfo
  +		if len(containerInfos) > 0 {
  +			defaultInfo = containerInfos[0]
  +		}
  +		processCardLabel, containerID := getDefaultProcessLabel(cardLabel, defaultInfo)
  +		doUpdateMetric(ch, timestamp, 0, append(processCardLabel, "", containerID), descDevProcessInfo)
  +		return
  +	}
  	for i := int32(0); i < devProcessInfo.ProcNum; i++ {
  ```
  </details>
- **label 下标去魔数 + 拼写修复**:常量 `cardLabelWihtContainerInfoLen` 更名为 `cardLabelWithContainerInfoLen`;清空 container/pod/namespace 三段 label 时,原来的 `len-1/len-2/len-3` 改成用已有命名常量 `containerNameIndexOffsetInCardLabel`/`podNameIndexOffsetInCardLabel`/`namespaceIndexOffsetInCardLabel`。纯可读性/一致性重构,行为不变。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_npu.go</summary>

  ```diff
  -	newCardLabel[len(newCardLabel)-1] = ""
  -	newCardLabel[len(newCardLabel)-2] = ""
  -	newCardLabel[len(newCardLabel)-3] = ""
  +	newCardLabel[len(newCardLabel)-containerNameIndexOffsetInCardLabel] = ""
  +	newCardLabel[len(newCardLabel)-podNameIndexOffsetInCardLabel] = ""
  +	newCardLabel[len(newCardLabel)-namespaceIndexOffsetInCardLabel] = ""
  ```
  </details>
- 配套单测新增 `TestGetDefaultProcessLabel` / `TestUpdateProcessInfoForPrometheusNoProcess`(`collector_for_npu_test.go` +111 行),覆盖"容器名可拆成 ns_pod_container 三段"与"名字不合法/零值容器信息→保持空 name+ID"两类边界,并引入 `client_model/go` 读取实测 label 值断言——说明这次是带回归保护的正式行为变更,不是临时补丁。
### 后续发展方向 [AI]
- npu-exporter 在持续打磨"进程↔容器"归属的指标完整性(本次补零值占位、上批修空缓存 panic),方向是让 NPU 进程级指标在各种边界(无进程/名字不规范)下都不缺行、可被 Prometheus 稳定采集。证据只覆盖 npu-exporter 单文件 diff,未见调度/device-plugin 侧改动;区间内 ascend-clusterops-agent 新项目与 RL 故障恢复、volcano PC16 超节点亲和均为 docs 提交,代码尚未进入 component/,方向待后续 diff 确认。

## npu-dra-plugin: f3cfd270 -> 5d7339c5
- 比较 / 最新 Release:f3cfd270..5d7339c5 | tag: v26.6.0 | commits=3 | truncated=false
- https://gitcode.com/openFuyao/npu-dra-plugin/compare/f3cfd270f0dda85b259f4041d6c99824920e17e5...5d7339c517d971eaeb0b915bd19ed3d90db3c44c
### AI 总结重点(源码 diff 为据)
- 纯安全依赖升级:grpc 升至 v1.83.2 修 CVE-2026-84303/84304/84445(go.mod/go.sum 变更被 helper 过滤,未展开),构建基镜像 `golang:1.24-bookworm`→`golang:1.25-bookworm`(Dockerfile 与 Dockerfile_pipeline 同步)。无 DRA ResourceClaim / 调度逻辑改动。
  <details><summary>代码依据 Ascend-npu-dra-plugin/build/Dockerfile</summary>

  ```diff
  -FROM golang:1.24-bookworm AS builder
  +FROM golang:1.25-bookworm AS builder
  ```
  </details>
### 后续发展方向 [AI]
- 本期仅 CVE 维护,DRA 接入能力无演进;证据只覆盖 Dockerfile,昇腾原生 DRA 路径的功能变化需等 `Ascend-npu-dra-plugin/pkg` 侧 diff。

## ub-network-device-plugin: ef44c337 -> 5dd79f39
- 比较 / 最新 Release:ef44c337..5dd79f39 | tag: 1.0.2 | commits=2 | truncated=false
- https://gitcode.com/openFuyao/ub-network-device-plugin/compare/ef44c337d16e208fc1557b8e56a77447f30bc2a7...5dd79f3952dcb2a01c455feb953fe8d5b5b07af9
### AI 总结重点(源码 diff 为据)
- 与 npu-dra-plugin 同批的 grpc CVE-2026-84303/84304/84445 修复;构建 golang 版本 `1.24.5`→`1.25.10`,并补了 Dockerfile 末尾缺失的换行。UB fabric device-plugin 逻辑无改动。
  <details><summary>代码依据 cmd/ub-network-device-plugin/Dockerfile</summary>

  ```diff
  -ARG BUILDER_VERSION=1.24.5
  +ARG BUILDER_VERSION=1.25.10
  ```
  </details>
### 后续发展方向 [AI]
- 仅维护性升级,UB 超低时延网络多机训练 fabric 能力无演进;证据只覆盖 Dockerfile。

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext:本期无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=72e2192ffdf90a6c3a33606e99c651b38fbf73cd tag=v26.2.0.beta.1 scanned=2026-09-11 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=vNPU sha=d88907ed4061c5d63babbb79b453a368b55f14d6 tag=v0.1.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=npu-dra-plugin sha=5d7339c517d971eaeb0b915bd19ed3d90db3c44c tag=v26.6.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-11 -->

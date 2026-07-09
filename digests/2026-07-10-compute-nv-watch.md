# NVIDIA 算力栈 diff 雷达 2026-07-10

## 摘要
- **gpu-operator 是今天唯一有真代码料的仓**:node 标签 reconciler 重构为「两阶段收敛」——当节点 GPU 发现状态(`nvidia.com/gpu.present`)在本轮被改写时,Reconcile 提前 return,把依赖该标签的 owner 分配(`AssignOwners`)推迟到 informer 缓存看到更新后再跑,修掉了 "GPU 标签更新后 NVIDIADriver owner 分配用到陈旧缓存" 的时序 bug。同期把 R535 驱动作为 EOL 从 OLM CSV manifest 删除。
- **KAI-Scheduler 上企业级合规:FIPS**。新增 `-fips` 镜像变体与 `global.fips` helm 开关,用 Go 原生 `GOFIPS140=v1.0.0`(CMVP 校验过的 Go Cryptographic Module)编译,`-fips` 后缀正交于版本 pin。对标 OAI 的安全合规能力这条值得记。
- **nvidia-container-toolkit 切了 v1.20.0-rc.1**(v1.19.1→v1.20.0 minor 跨档),但今天的实际 diff 只有版本号 + CHANGELOG + 测试 mock 迁移(dgxa100→mockserver),昨日已报的 IMEX/MIG-DRI 等能力是 CHANGELOG 聚合、非新 hunk。其余 6 仓 EMPTY。

## 当日重要改变
- NVIDIA/gpu-operator [弃用/移除] R535 驱动作为 EOL 从 OLM ClusterServiceVersion 删除:`driver-image-535` / `DRIVER_IMAGE-535`(两处 relatedImages 与 env)整条移除,gpu-operator 官方镜像清单不再带 R535 驱动。https://github.com/NVIDIA/gpu-operator/commit/ee622d5c1f6a035e8968677a49e8102fd94e88f4
- kai-scheduler/KAI-Scheduler [新能力] FIPS-enabled 镜像 + `global.fips` helm 选项(#1868):每个 release 并行发一套 `-fips` 后缀镜像,Go FIPS 140-3 原生模式编译,helm 侧新增 `kai-scheduler.imageTag` 模板统一给所有服务镜像 tag 追加 `-fips`。https://github.com/kai-scheduler/KAI-Scheduler/commit/4e644c4dfcc87f9b44d1d1af22fa83e00e73ab08
- NVIDIA/nvidia-container-toolkit [版本跨档] v1.19.1 → v1.20.0-rc.1(`LIB_TAG: dev→rc.1`),进入 1.20 发布候选。https://github.com/NVIDIA/nvidia-container-toolkit/compare/32a6bc582f23ae4f3ade2b482e77ae9915d457ed...803579e789235ec5a8b453cb237c8bfc9fd9b55b

## NVIDIA/gpu-operator: 16638954 -> ee622d5c
- 比较: 1663895412fa5edaec69260e23689c81d31095cd -> ee622d5c | ahead=10 | files=19 | Release: v26.3.3
- Compare: https://github.com/NVIDIA/gpu-operator/compare/1663895412fa5edaec69260e23689c81d31095cd...ee622d5c1f6a035e8968677a49e8102fd94e88f4

### AI 总结重点(源码 diff 为据)
- **node 标签收敛改为两阶段,修 owner 分配的陈旧缓存时序**:新增 `gpuNodeLabelsUpdateResult{totalPatchedNodeCount, gpuDiscoveryStateChangedNodeCount}`,`labelGPUNodes` 现返回该结果。Reconcile 里当 `gpuDiscoveryStateChangedNodeCount > 0`(即本轮改写了 `nvidia.com/gpu.present` 发现状态)时,记一条 debug 日志后 **提前 `return reconcile.Result{}, nil`**,把依赖 `gpu.present` 的后续操作(注释点名 `AssignOwners` 靠它找 GPU 节点)推迟到 informer 缓存观察到这批节点更新之后的下一轮再执行。即"先落 GPU 发现标签、等缓存一致、再分配 driver owner",避免 owner 分配读到还没刷新的节点标签。
  <details><summary>代码依据 controllers/nodelabeling_controller.go</summary>

  ```diff
  +// gpuNodeLabelsUpdateResult reports total node patches and the subset where GPU
  +// discovery state changed. The discovery state is stored in nvidia.com/gpu.present,
  +// which AssignOwners uses to find GPU nodes, so dependent operations are deferred
  +// until the informer cache observes those node updates.
  +type gpuNodeLabelsUpdateResult struct {
  +	totalPatchedNodeCount             int
  +	gpuDiscoveryStateChangedNodeCount int
  +}
   ...
  -	if err := nlc.labelGPUNodes(ctx); err != nil {
  +	gpuLabelUpdateResult, err := nlc.labelGPUNodes(ctx)
  +	if err != nil {
   		return reconcile.Result{}, err
   	}
  +	if gpuLabelUpdateResult.gpuDiscoveryStateChangedNodeCount > 0 {
  +		r.Log.V(consts.LogLevelDebug).Info("GPU discovery state used by owner assignment updated; dependent node label operations will run after the node update event", ...)
  +		return reconcile.Result{}, nil
  +	}
  ```
  </details>
- **触发判据从散装布尔重构成 `nodeLabelUpdateReasons` 结构 + `needsUpdate()`**:原先 predicate 里一串 `xxxLabelChanged ||` 被收进 `getNodeLabelUpdateReasons(oldLabels,newLabels)` 统一计算,含昨日刚加的 `migCapableLabelChanged` 及 `gpuCommonLabelMissing/Outdated/Changed`、`commonOperandsLabelChanged`、`gpuWorkloadConfigChanged`、`osTreeLabelChanged`、`nvidiaDriverOwnerLabelChange`。纯结构重构,判据集合不变,可读性/可测性提升(配套 `nodelabeling_controller_test.go` +203 行)。
  <details><summary>代码依据 controllers/nodelabeling_controller.go</summary>

  ```diff
  +func getNodeLabelUpdateReasons(oldLabels, newLabels map[string]string) nodeLabelUpdateReasons {
  +	return nodeLabelUpdateReasons{
  +		gpuCommonLabelMissing:        hasGPULabels(newLabels) && !hasCommonGPULabel(newLabels),
  +		...
  +		migCapableLabelChanged:       hasMIGCapableGPU(oldLabels) != hasMIGCapableGPU(newLabels),
  +		nvidiaDriverOwnerLabelChange: oldLabels[consts.NVIDIADriverOwnerLabel] != newLabels[consts.NVIDIADriverOwnerLabel],
  +	}
  +}
  ```
  </details>
- **R535 驱动 EOL 下架**:`bundle/manifests/gpu-operator-certified.clusterserviceversion.yaml` 删掉 `driver-image-535` relatedImage 与 `DRIVER_IMAGE-535` env(-4 行),官方 OLM bundle 只留 default 与 580 两条驱动线。另新增一套 RC 发布基建(`release-rc-assets.yaml` workflow + `update-csv-images.py`/`validate-olm-release-metadata.py`/`merge-yaml.py` 脚本,共 +820 行),纯 CI,产品面无关。
  <details><summary>代码依据 bundle/manifests/gpu-operator-certified.clusterserviceversion.yaml</summary>

  ```diff
  -    - name: driver-image-535
  -      image: nvcr.io/nvidia/driver@sha256:659d9315957ffa2a3f2a003716f066f6a1b3c06ae5557192148ed410dc1b9a6e
   ...
  -                  - name: "DRIVER_IMAGE-535"
  -                    value: "nvcr.io/nvidia/driver@sha256:659d9315957ffa2a3f2a003716f066f6a1b3c06ae5557192148ed410dc1b9a6e"
  ```
  </details>

### 后续发展方向 [AI]
- 两阶段收敛是把 operator 的 node 标签闭环从"一轮做完"改成"标签先行、owner 后置"的最终一致模型,方向上更耐大规模节点 churn 与 informer 延迟;但证据只覆盖 Reconcile 的 early-return 与结构定义,`labelGPUNodes` 内如何统计 `gpuDiscoveryStateChangedNodeCount`(hunk 截断,未见)、下一轮 owner 分配靠什么重新入队,均未在本次 diff 内。R535 下架坐实 gpu-operator 驱动矩阵收敛到 580+default 两线,历史 535 用户需迁移。未命中 `clusterpolicy_types.go`,ClusterPolicy API 面本期无增删。

## NVIDIA/nvidia-container-toolkit: 32a6bc58 -> 803579e7
- 比较: 32a6bc582f23ae4f3ade2b482e77ae9915d457ed -> 803579e7 | ahead=5 | files=20 | Release: v1.20.0-rc.1
- Compare: https://github.com/NVIDIA/nvidia-container-toolkit/compare/32a6bc582f23ae4f3ade2b482e77ae9915d457ed...803579e789235ec5a8b453cb237c8bfc9fd9b55b

### AI 总结重点(源码 diff 为据)
- **本期实际 diff 只有 RC 切版 + 测试 mock 迁移,无产品逻辑改动**:`versions.mk` 把 `LIB_TAG` 从 `dev` 改到 `rc.1`(即 v1.20.0-rc.1 打包),CHANGELOG 追加 v1.20.0-rc.1 段落;唯一代码提交 `[no-relnote] move away from deprecated types in mock nvml pkg` 把测试里 `dgxa100.Server/Device` 换成通用 `mock/server.Server/Device`(go-nvml mock 包 API 迁移),仅 `lib-nvml_test.go`/`generate_test.go` 受影响。
  <details><summary>代码依据 versions.mk + pkg/nvcdi/lib-nvml_test.go</summary>

  ```diff
  -LIB_TAG := dev
  +LIB_TAG := rc.1
   ...
  -		setupMock          func(*dgxa100.Server)
  +		setupMock          func(*mockserver.Server)
  -					(d.(*dgxa100.Device)).IsMigDeviceHandleFunc = ...
  +					(d.(*mockserver.Device)).IsMigDeviceHandleFunc = ...
  ```
  </details>
- **CHANGELOG 披露 v1.20.0-rc.1 的完整范围(多为往期已并入,非今日 hunk)**:含昨日已报的 `Validate imex channels for CDI/JIT-CDI mode`、WSL2 驱动 store 发现;以及此前未单列的几条 CDI 注入面动作——`[CDI Hooks] add ability to specify OCI hook type`(CDI hook 可指定 OCI hook 类型)、`Add ability to disable CDI hooks in jit-cdi mode`(jit-cdi 模式可关 CDI hooks)、`feat: drop nvidia-cdi-hook shell shim`(去掉 shell shim)、`[nri] only restrict management CDI devices to the toolkit namespace`(management CDI 设备只限 toolkit 命名空间)、`Allow multiple driver library paths`。这些是 release note 聚合,今日 compare 未含其代码 hunk。
  <details><summary>代码依据 CHANGELOG.md(v1.20.0-rc.1 段)</summary>

  ```diff
  +## v1.20.0-rc.1
  +- Validate imex channels for CDI/JIT-CDI mode
  +- [CDI Hooks] add ability to specify OCI hook type
  +- feat: drop `nvidia-cdi-hook` shell shim
  +- Add ability to disable CDI hooks in jit-cdi mode
  +- [nri] only restrict management CDI devices to the toolkit namespace
  +- Allow multiple driver library paths
  ```
  </details>

### 后续发展方向 [AI]
- 1.20 进 RC,主线是 CDI/JIT-CDI 注入面的可配置化(OCI hook 类型可选、jit-cdi 下可关 hooks、management 设备命名空间收窄)+ 多驱动库路径。这些能力的真实代码要回溯 v1.19.1→现在的历史区间才有 hunk,本次小增量看不到。标注:今日证据仅版本字符串、CHANGELOG 文本与测试 mock 迁移,无功能 hunk。

## kai-scheduler/KAI-Scheduler: e5b7c565 -> 4e644c4d
- 比较: e5b7c56584f9ef897bee1e8dc6af492342ac7e3c -> 4e644c4d | ahead=1 | files=13 | Release: v0.14.7
- Compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/e5b7c56584f9ef897bee1e8dc6af492342ac7e3c...4e644c4dfcc87f9b44d1d1af22fa83e00e73ab08

### AI 总结重点(源码 diff 为据)
- **FIPS-enabled 镜像变体成为一等发布物(#1868)**:构建侧 `base.mk` 加 `FIPS?=0`,置 1 时 `override VERSION := ${VERSION}-fips`;`golang.mk` 在 `FIPS=1` 时给容器构建注入 `GOFIPS140=v1.0.0`。CI 新增 `build-and-push-fips` job,仅在 tag 触发,`make build FIPS=1` 双架构构建后用 `go version -m` 校验二进制带 `GOFIPS140=v1.0.0` 否则失败。即每次 release 并行出一套 `-fips` 后缀镜像,用 Go 原生 FIPS 140-3(CMVP 校验的 Go Cryptographic Module v1.0.0,运行时默认 `GODEBUG=fips140=on`)。
  <details><summary>代码依据 build/makefile/base.mk + golang.mk</summary>

  ```diff
  +FIPS?=0
  +ifeq ($(FIPS), 1)
  +override VERSION := ${VERSION}-fips
  +endif
   ...
  +ifeq ($(FIPS), 1)
  +DOCKER_GO_BASE_COMMAND += -e GOFIPS140=${GOFIPS140_VERSION}
  +endif
  ```
  </details>
- **helm 侧新增 `kai-scheduler.imageTag` 模板,`global.fips=true` 时给所有服务镜像 tag 追加 `-fips`**:该 helper 按 `显式 tag → global.tag → Chart.AppVersion` 解析,再于 `global.fips` 为真时拼 `-fips`,使 FIPS 选择正交于版本 pin。binder/podgrouper/queuecontroller/admission/operator/nodescaleadjuster 等所有服务与 hook Job 的镜像行统一改走此 helper。`values.yaml` 加 `global.fips: false` 默认项。
  <details><summary>代码依据 deployments/kai-scheduler/templates/_helpers.tpl</summary>

  ```diff
  +{{- define "kai-scheduler.imageTag" -}}
  +{{- $tag := .tag | default .root.Values.global.tag | default .root.Chart.AppVersion -}}
  +{{- if .root.Values.global.fips -}}{{- $tag = printf "%s-fips" $tag -}}{{- end -}}
  +{{- $tag -}}
  +{{- end -}}
   ...
  -        tag: {{ .Values.binder.image.tag | default .Values.global.tag | default .Chart.AppVersion }}
  +        tag: {{ include "kai-scheduler.imageTag" (dict "root" $ "tag" .Values.binder.image.tag) }}
  ```
  </details>

### 后续发展方向 [AI]
- FIPS 是明确的企业级/政府/受管行业合规信号(对标 OAI 的安全合规栈):KAI 走 Go 原生 FIPS 140-3 而非绑 RHEL/BoringCrypto,`-fips` 后缀正交于版本 pin 让用户可无痛切换。对我们产品的启示:调度器/算力组件若要进合规客户,FIPS 变体镜像 + 一个 `global.fips` 式的统一开关是低成本可抄的做法。证据覆盖构建/CI/helm 全链,未涉及调度器运行时逻辑(FIPS 只换编译模式,不改行为)。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓</summary>

- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM(master)— 无新提交
- NVIDIA/mig-parted — ahead=2,仅 bump/CI/merge(锚点前移)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=ee622d5c1f6a035e8968677a49e8102fd94e88f4 branch=main release=v26.3.3 scanned=2026-07-10 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=803579e789235ec5a8b453cb237c8bfc9fd9b55b branch=main release=v1.20.0-rc.1 scanned=2026-07-10 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=65b0904e77aa95ac77f62a735d8a7aff2e276148 branch=main release=— scanned=2026-07-10 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=10fd1c08afa74932e0f949e540eca9d9953d9cec branch=main release=v0.19.3 scanned=2026-07-10 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=2607fc64e99547f604f201b66cefc06eab45090e branch=main release=v0.4.1 scanned=2026-07-10 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-10 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=e64447f98070fe9e510488b2a55f0a197e632777 branch=main release=v0.14.3 scanned=2026-07-10 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=4e644c4dfcc87f9b44d1d1af22fa83e00e73ab08 branch=main release=v0.14.7 scanned=2026-07-10 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-10 -->

# 昇腾算力栈 diff 雷达 2026-08-27

## 摘要
- **mind-cluster 落地"全栈组件版本自上报 → clusterd 聚合分布"能力**:新增 `common/version` 包(`Info`/`VersionSummary` 结构),8 个组件的 build.sh 统一经 `-X ...version.*` ldflags 注入版本;各组件把版本写进节点 annotation,clusterd 每分钟聚合成 `version -> 节点数` 分布落到集群 ConfigMap(带 sha256 变更检测防抖 + 只存计数防 CM 膨胀)。这是运维可观测性侧的新能力,便于灰度/滚动升级时看版本收敛。
- device-plugin 顺手改了两处行为:`cardTypeAnnotator` 提到 annotator 组首位、base 设备信息 annotation 双写**去掉了 `sanitizeLabelValue` 净化**(改写原始 JSON)。
- 其余 8 仓本期无实质改动(npu-dra-plugin 有新提交但仅 merge/bump)。

## 当日重要改变
- mind-cluster [新能力] 新增 `component/ascend-for-volcano/common/version/version.go`(`Info` 结构 + `Get()`/`ToJSON()`/`VersionSummary`),clusterd 每分钟把各组件版本聚合成分布写 ConfigMap;证据见下 `informer.go`。https://gitcode.com/Ascend/mind-cluster/commit/8ac97f0cc7db321ef8665077721fbf24975e753a
- mind-cluster [行为变更] device-plugin base 设备信息 annotation 双写去掉 `sanitizeLabelValue()`,直接写 `string(mashaledNpuInfo)`;annotator 组把 `cardTypeAnnotator` 提到首位。证据见下 `manager.go`。https://gitcode.com/Ascend/mind-cluster/commit/8ac97f0cc7db321ef8665077721fbf24975e753a

## mind-cluster: d0eaf52e -> 8ac97f0c
- 比较: d0eaf52e..8ac97f0c | tag: v26.1.0 | commits=24 | truncated=false
- 比较页:https://gitcode.com/Ascend/mind-cluster/compare/d0eaf52edaa03fdd29bd4d9cdf0f1d0bf4e080e5...8ac97f0cc7db321ef8665077721fbf24975e753a

### AI 总结重点(源码 diff 为据)
- **新增 `common/version` 包,定义组件版本自描述模型**。`Info` 结构含 `Version/GitCommit/GitBranch/BuildOS/BuildArch/GoVersion` 六字段;`Get()` 在字段未由编译期注入时用 `runtime.GOOS/GOARCH/Version()` 兜底;`ToJSON()` 做序列化。这是后续所有"版本上报"的公共类型来源。
  <details><summary>代码依据 component/ascend-for-volcano/common/version/version.go(added)</summary>

  ```go
  func Get() Info {
      info := Info{Version: Version, GitCommit: GitCommit, ...}
      if info.BuildOS == "" { info.BuildOS = runtime.GOOS }
      if info.BuildArch == "" { info.BuildArch = runtime.GOARCH }
      if info.GoVersion == "" { info.GoVersion = runtime.Version() }
      return info
  }
  type Info struct {
      Version   string `json:"version"`
      GitCommit string `json:"gitCommit"`
      ...
  }
  ```
  </details>

- **8 个组件 build.sh 统一经 ldflags 注入版本元数据**。ascend-for-volcano / npu-exporter(以及提交里可见的 ascend-operator/infer-operator/noded/ascend-device-plugin/clusterd/ascend-docker-runtime)build.sh 都新增 `GIT_COMMIT/GIT_BRANCH/GO_VERSION` 采集,并在 `go build -ldflags` 里加 `-X .../version.Version=... -X .../version.GitCommit=...` 等注入项。即版本信息在**编译期**固化进二进制。
  <details><summary>代码依据 component/npu-exporter/build/build.sh(modified)</summary>

  ```diff
  +GIT_COMMIT=$(git rev-parse --verify HEAD 2>/dev/null || echo "unknown")
  +GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  +GO_VERSION=$(go version | awk '{print $3}')
   ...
  -            -X huawei.com/npu-exporter/v6/versions.BuildVersion=${build_version}_linux-${arch}" \
  +            -X huawei.com/npu-exporter/v6/versions.BuildVersion=${build_version}_linux-${arch} \
  +            -X ascend-common/common-utils/version.Version=${build_version} \
  +            -X ascend-common/common-utils/version.GitCommit=${GIT_COMMIT} \
  +            -X ascend-common/common-utils/version.GitBranch=${GIT_BRANCH} ...
  ```
  </details>

- **clusterd 新增版本聚合链路:节点 annotation → 集群 ConfigMap 版本分布**。`main.go` 起 `startVersionSummaryTicker`(1 分钟 ticker)周期调 `kube.UpdateVersionSummary`,并在 `main()` 里 `reportVersionToConfigMap(info, "clusterd")`(create,失败退避重试 3 次)。`informer.go` 的 `buildVersionSummary` 对 `device-plugin/k8s-rdma-shared-dp/noded` 三类组件,遍历节点 annotation(key=`ResourceNamePrefix+组件名+".version"`)统计 `version -> 节点数` 分布;`UpdateVersionSummary` 用 **sha256 对每组件数据做变更检测**,内容没变就跳过 patch,避免无谓写 API。`VersionSummary` 只存计数(不存节点列表)以防 ConfigMap 膨胀,并带一条 `kubectl ... | jq` 的 `QueryCommand` 便于人工核查。
  <details><summary>代码依据 component/clusterd/pkg/interface/kube/informer.go(modified)</summary>

  ```go
  func UpdateVersionSummary(lastHash map[string]string) {
      summary := buildVersionSummary()
      for compName, data := range summary {
          hash := hex.EncodeToString(sha256.Sum256([]byte(data))[:])
          if hash == lastHash[compName] { continue } // 内容未变跳过
          cm, _ := GetConfigMap(api.VersionName, api.DLNamespace)
          cm.Data[compName] = data
          PatchCMData(api.VersionName, api.DLNamespace, cm.Data)
          lastHash[compName] = hash
      }
  }
  func buildVersionSummary() map[string]string {
      targetComponents := []string{"device-plugin", "k8s-rdma-shared-dp", "noded"}
      // 遍历 nodes.Annotations[ResourceNamePrefix+comp+".version"] -> distribution[info.Version]++
      // VersionSummary{Type:"DaemonSet", Versions:distribution, TotalNodes:len(nodes), QueryCommand:...}
  }
  ```
  </details>

- **ascend-for-volcano 调度器在会话初始化时自上报版本(仅一次)**。`factory.go` 的 `InitNPUSession` 新增 `sHandle.reportVersion()`,内部 `FrameAttr.VersionOnceInit.Do(...)` 保证进程内只报一次;`reportVersionToConfigMap` 先 `CreateConfigMap`,遇 `IsAlreadyExists` 转 `PatchCMData`,失败指数退避(1s→2s→4s)重试 3 次。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/factory.go(modified)</summary>

  ```go
  func (sHandle *ScheduleHandler) reportVersion() {
      sHandle.FrameAttr.VersionOnceInit.Do(func() {
          info := version.Get()
          sHandle.reportVersionToConfigMap(info, "ascend-for-volcano")
      })
  }
  // reportVersionToConfigMap: CreateConfigMap -> IsAlreadyExists 则 PatchCMData -> backoff*=2 重试 3 次
  ```
  </details>

- **configmap.go 补齐 `CreateConfigMap` 与 `PatchCMData`(MergePatch)工具函数**,为上面两条上报链路提供 K8s 写入原语。`PatchCMData` 用 `types.MergePatchType` 只改 `data` 字段。
  <details><summary>代码依据 component/ascend-for-volcano/common/k8s/configmap.go(modified)</summary>

  ```go
  func PatchCMData(k8s kubernetes.Interface, name, namespace string, data map[string]string) (*v1.ConfigMap, error) {
      dataByte, _ := json.Marshal(data)
      patchBody := fmt.Sprintf(`{"data":%s}`, dataByte)
      return k8s.CoreV1().ConfigMaps(namespace).Patch(ctx, name, types.MergePatchType, []byte(patchBody), ...)
  }
  ```
  </details>

- **device-plugin:新增版本上报入口 + 两处 annotation 行为变更**。`manager.go` 新增 `AddVersionToNodeAnnotation` → `version.ReportVersionToNodeAnnotation`(把组件版本写节点 annotation,给 clusterd 聚合喂数据)。同时把 `cardTypeAnnotator` 从 annotator 组**末位提到首位**(改变多个 annotator 的执行/覆盖顺序);base 设备信息双写 `BaseDevInfoAnnoDeprecated`/`NPUBaseDevInfosAnnotation` 时**移除了 `sanitizeLabelValue()` 净化**,改写原始 `string(mashaledNpuInfo)`——annotation 不受 label 值字符集限制,去净化可保留完整 JSON,但需确认下游消费方按原始 JSON 解析。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/manager.go(modified)</summary>

  ```diff
   hdm.annotationGroup = annotation.NewAnnotationGroup(
  +    &cardTypeAnnotator{hdm: hdm},
       &baseInfoAnnotator{hdm: hdm},
       ...
  -    &cardTypeAnnotator{hdm: hdm},
   )
  ...
  -    annotation.BaseDevInfoAnnoDeprecated: sanitizeLabelValue(string(mashaledNpuInfo)),
  -    annotation.NPUBaseDevInfosAnnotation: sanitizeLabelValue(string(mashaledNpuInfo)),
  +    annotation.BaseDevInfoAnnoDeprecated: string(mashaledNpuInfo),
  +    annotation.NPUBaseDevInfosAnnotation: string(mashaledNpuInfo),
  ```
  </details>

- **仅 commit 标题、未在本期 patch 节选覆盖到的方向**(hunk 只取了 changes 最大的 8 个文件,以下靠提交标题,未逐行读代码):DPU 触发断点续训资料/故障检测章节重构、FD(Fault Diagnosis)"Enhanced diagnostic capabilities" part1-3、全局指标默认白名单更新、dpu-exporter 支持 1825 指标采集 part3、host device cni 原生版本。这些提交在区间内但主体改动可能落在文档或未进 top-8 的文件,以代码 diff 为准的部分仅上面版本上报链路。

### 后续发展方向 [AI]
- 版本自上报是**为灰度/滚动升级和现场排障服务的可观测性底座**:证据是 clusterd 聚合的目标组件恰是 DaemonSet 型(`device-plugin/k8s-rdma-shared-dp/noded`)且只存 `version->节点数` 分布 + 附 `kubectl jq` 查询命令,典型用于"看某组件版本在集群里是否收敛/有无残留旧版本"。证据只覆盖这三类 DaemonSet 组件的聚合,scheduler/clusterd 自身只做单点上报,未见 operator 类的聚合。
- `k8s-rdma-shared-dp` 出现在聚合目标里,呼应上期看到的 DPU/RDMA 接入方向——版本面板已把 RDMA 共享 device-plugin 纳入统一版本治理。证据仅一行常量,未见其 annotation 写入侧代码。

## 本期无实质改动(折叠)
<details><summary>展开 8 个 EMPTY 仓</summary>

- npu-operator:无新提交
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- vNPU:无新提交
- npu-node-provision:无新提交
- npu-dra-plugin:有新提交但仅 merge/bump/CI(锚点已推进到 1084df7c)
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=8ac97f0cc7db321ef8665077721fbf24975e753a tag=v26.1.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=npu-dra-plugin sha=1084df7c16dbb60173b0dbc8e4cd561dd45b430d tag=v26.6.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-27 -->

# 昇腾算力栈 diff 雷达 2026-06-16

## 摘要
- **vNPU 补齐 cgroup v2**:`findCgroupPath` 重构为 v1/v2 双版本路径查找,modern 发行版(systemd unified hierarchy)上 vNPU 的 pids/算力限制才能正确定位容器 cgroup——这是 vNPU 在新内核底座可用的硬前提。
- **npu-operator 修了 NodeD enable 标签清理的真 bug**:卸管(unmanaged)时此前用"标签值"当 key 去删,标签根本删不掉;现改为按 key 删,NodeD 启停标签生命周期才正确。
- **mind-cluster:ascend-for-volcano 收紧 jobPipelined gang 判断**——waiting+ready 任务数不足 MinAvailable 时直接 Reject(原为 Abstain),避免凑不够 gang 的作业被错误流水线化。

## 当日重要改变
- vNPU [新能力] 新增 cgroup v2 支持:抽出 `isCgroupV2()`、`findCgroupPathByBaseDir(baseDir,…)`,base 目录在 v1=`/sys/fs/cgroup/pids`、v2=`/sys/fs/cgroup` 间切换。证据 `xpu-device-plugin/pkg/api/runtime/service/service_impl.go`(MR!55)。 https://gitcode.com/openFuyao/vNPU/commit/a30d9493752c330db95f4258a1ea0fb9765977c6
- npu-operator [行为变更/缺陷修复] `updateNodeDEnableLabel` 卸管分支删错 key + 缺 nil-map 守卫,均已修。证据 `internal/controller/labels.go`(MR!101)。 https://gitcode.com/openFuyao/npu-operator/commit/335bc283068ac89cf190d7e8c1d7d87d2b300cbb
- mind-cluster [行为变更] ascend-for-volcano `jobPipelined` 增补 MinAvailable 不足即 Reject 的 gang 判断,并在 build.sh 给上游 volcano 注入 `PendingBestEffortTaskNum()` 同步逻辑。证据 `component/ascend-for-volcano/npu.go`。 https://gitcode.com/Ascend/mind-cluster/commit/c51d26973257ec1f93a693480775f272e1402cfc
- vNPU [数据模型变更] `XPUDevice` 字段 `Index/Id` → `PhysicID/DieID`(MR!57),向多 die NPU 设备建模靠拢;非 CRD/_types.go,属内部结构体重命名。

## mind-cluster: fe62b632 -> c51d2697
- 比较: fe62b632..c51d2697 | tag: v26.0.1 | commits=18 | truncated=false
- 区间提交还含:"Adding the CANN Fault Mode Library"、"k8s-rdma-shared-dev-plugin 掉卡故障上报"、"helm 部署适配 k8s-rdma-shared-dev-plugin,dp 和 volcano 1.12.0"——这些 commit 未落在 component/ 过滤后的信号文件里,**仅 commit 标题为据、未读 hunk**,下述研判只基于已见 patch。

### AI 总结重点(源码 diff 为据)
- **ascend-for-volcano:`jobPipelined` 从"过 JobReadyTag 即 Abstain"收紧为"任务总数不足 MinAvailable 即 Reject"**。原逻辑只要 `*job.JobReadyTag` 为真就 Abstain(不表态、放行后续插件);现新增 `WaitingTaskNum()+ReadyTaskNum() < MinAvailable → Reject`,即凑不齐 gang 的作业不再被允许进入 pipelined 态。配套 build.sh 用 sed 给上游 volcano 的 `npu.go` 把比较式改成把 `PendingBestEffortTaskNum()` 也计入分母(best-effort 任务也算进 gang 配额)。新增单测 05/06/07 覆盖"不足→Reject / 相等→Abstain / 超出→Abstain"。
  <details><summary>代码依据 component/ascend-for-volcano/npu.go</summary>

  ```diff
   	if !*job.JobReadyTag {
   		return util.Reject
   	}
  +	klog.V(util.LogInfoLev).Infof("job %s/%s WaitingTaskNum: %d, ReadyTaskNum: %d, MinAvailable: %d", ji.Namespace,
  +		ji.Name, ji.WaitingTaskNum(), ji.ReadyTaskNum(), job.MinAvailable)
  +	if ji.WaitingTaskNum()+ji.ReadyTaskNum() < job.MinAvailable {
  +		return util.Reject
  +	}
   	return util.Abstain
  ```
  </details>
  <details><summary>代码依据 component/ascend-for-volcano/build/build.sh</summary>

  ```diff
  +function replace_job_pipelined() {
  +    REPLACE_FILE="${GOPATH}/src/volcano.sh/volcano/pkg/scheduler/plugins/ascend-volcano-plugin/npu.go"
  +    sed -i "s/ji.WaitingTaskNum()+ji.ReadyTaskNum() < job.MinAvailable/ji.WaitingTaskNum()+ji.ReadyTaskNum()+ji.PendingBestEffortTaskNum() < job.MinAvailable/g" "$REPLACE_FILE"
  +}
  ```
  </details>
- **npu-exporter 配置文件路径外置**:`metricConfiguration.json` / `pluginConfiguration.json` 从镜像内 `/usr/local/` 移到 `/user/mind-cluster/npu-exporter-config/`(Dockerfile-310P-1usoc 两版同步,register.go 注释跟改)。指向把指标/插件配置改成可挂载目录的方向,便于运行期覆盖而非烧进镜像。
  <details><summary>代码依据 component/npu-exporter/build/Dockerfile-310P-1usoc</summary>

  ```diff
  -COPY ./metricConfiguration.json  /usr/local/metricConfiguration.json
  -COPY ./pluginConfiguration.json /usr/local/pluginConfiguration.json
  +COPY ./metricConfiguration.json  /user/mind-cluster/npu-exporter-config/metricConfiguration.json
  +COPY ./pluginConfiguration.json /user/mind-cluster/npu-exporter-config/pluginConfiguration.json
  ```
  </details>
- **ascend-operator / infer-operator 部署 yaml 加 `imagePullPolicy: Never`**:两个 operator 的 manager 容器默认不拉镜像,典型用于本地/离线镜像调试场景。
  <details><summary>代码依据 component/ascend-operator/build/ascend-operator.yaml</summary>

  ```diff
            image: ascend-operator:latest
  +         imagePullPolicy: Never
            name: manager
  ```
  </details>

### 后续发展方向 [AI]
- 调度侧在补 gang 语义的严谨性(MinAvailable 不足拒绝流水线 + best-effort 计入配额),证据只覆盖 ascend-for-volcano 的 `jobPipelined` 一处,未见 allocate/predicate 其余动作是否同步。
- 故障域在扩:CANN Fault Mode Library、rdma 掉卡上报为 commit 标题信号,**未读代码**;若属实,趋势是把"硬件/网络故障感知"往 device-plugin/exporter 链路下沉,值下期重点拉 hunk 确认。

## npu-operator: 83270337 -> 335bc283
- 比较: 83270337..335bc283 | tag: 1.2.0 | commits=5 | truncated=false

### AI 总结重点(源码 diff 为据)
- **修复 NodeD enable 标签清理逻辑的两处缺陷**:① 卸管分支原 `removeLabelIfExists(node.Labels, nodeDEnableLabelValue)` 误把标签"值"当 key 传入,导致 NodeD 置为 unmanaged 时标签删不掉;改为传 `nodeDEnableLabelKey` 才真正按 key 移除。② 增加 `node.Labels == nil` 守卫,空标签 map 节点首次打标不再 panic/丢写。配套单测从单一 "ok" 扩成 4 例(managed 加标签 / 已存在保持 / unmanaged 删 key / 空 map 初始化)。
  <details><summary>代码依据 internal/controller/labels.go</summary>

  ```diff
   func (r *NPUClusterPolicyReconciler) updateNodeDEnableLabel(node *corev1.Node) bool {
   	updated := false
  +	if node.Labels == nil {
  +		node.Labels = make(map[string]string)
  +	}
   
   	if r.instance.Spec.NodeD.Managed {
   		updated = addLabel(node.Labels, nodeDEnableLabelKey, nodeDEnableLabelValue)
   	} else {
  -		updated = removeLabelIfExists(node.Labels, nodeDEnableLabelValue)
  +		updated = removeLabelIfExists(node.Labels, nodeDEnableLabelKey)
   	}
  ```
  </details>
- README-zh 大幅补全在线/离线/源码三种安装路径(helm pull OCI、离线驱动固件 zip 从 npu-driver-installer 的 config.json 取、MindIO zip 从 npu-node-provision 取),纯文档,但侧面坐实 operator → driver-installer/node-provision 的物料依赖链。

### 后续发展方向 [AI]
- NodeD 标签生命周期此前是坏的(卸管删不掉),说明 NodeD 受管开关尚在打磨期;证据仅 labels.go 一处,未见 controller 其余对该标签的消费方是否依赖其准确性。

## vNPU: 8eb5e3c8 -> a30d9493
- 比较: 8eb5e3c8..a30d9493 | tag: v0.1.0 | commits=11 | truncated=false

### AI 总结重点(源码 diff 为据)
- **cgroup v2 双版本支持(核心能力)**:`findCgroupPath(podUID,containerID)` 重构为 `isCgroupV2()`(探测 `/sys/fs/cgroup/cgroup.controllers` 是否存在)+ `findCgroupPathByBaseDir(baseDir,…)`,base 目录 v1=`/sys/fs/cgroup/pids`、v2=`/sys/fs/cgroup`。同时把硬编码的 `cri-containerd-` 前缀、`.scope`/`.slice` 后缀抽成常量 `containerIdPrefix/containerIdSuffix`,并新增 "podUID:containerID 同级目录" 命中分支(适配 v2 的 `pod…:…slice` 单层布局)。vNPU 在容器 cgroup 上施加 pids/算力约束,故这是它在 cgroup v2 主机(新版 openEuler/Ubuntu)上能落地隔离的硬前提。
  <details><summary>代码依据 xpu-device-plugin/pkg/api/runtime/service/service_impl.go</summary>

  ```diff
  +	cgroupV1PidsBaseDir   = "/sys/fs/cgroup/pids"
  +	cgroupV2BaseDir       = "/sys/fs/cgroup"
  +	cgroupControllersFile = "/sys/fs/cgroup/cgroup.controllers"
  ...
  +func isCgroupV2() bool {
  +	_, err := os.Stat(cgroupControllersFile)
  +	return err == nil
  +}
  +
  +func findCgroupPathByBaseDir(baseDir, podUID, containerID string) (string, error) {
  ...
   		if strings.Contains(dirName, "pod") &&
  -			strings.Contains(dirName, podUID) &&
  -			strings.HasSuffix(dirName, ".slice") {
  +			strings.Contains(dirName, podUID) {
  +			if strings.Contains(dirName, containerID) {
  +				foundPath = path; found = true; return fs.SkipAll
  +			}
  ```
  </details>
- **`XPUDevice` 字段重命名 `Index/Id` → `PhysicID/DieID`**(common/device.go,MR!57):从泛化的索引/ID 改为"物理 ID + die ID"语义,贴近昇腾多 die 单卡的设备建模。属内部结构体重命名,非 CRD/_types.go,但对外暴露的设备标识口径会变。
- **新增整套 CI 流水线脚本/Dockerfile**(ci/pipeline 下 acl-client、xpu-exporter、npu-device-plugin、vc-scheduler/controller-manager/webhook-manager 共 6+ 个 build 脚本与镜像)。虽属构建噪声,但其内容暴露了 vNPU 的真实组件矩阵与配套版本:**CANN 8.5.1 + Ascend HDK 25.5.1(910b 驱动)**,且自带一份打了 patch 的 volcano(`volcano-vxpu` 插件、base 1.9.0)随产品发布。
  <details><summary>代码依据 ci/pipeline/script/build_acl_client.sh</summary>

  ```bash
  wget … CANN%208.5.1/Ascend-cann-toolkit_8.5.1_linux-${os_type}.run
  wget … Ascend%20HDK%2025.5.1/Ascend-hdk-910b-npu-driver_25.5.1_linux-${os_type}.run
  ```
  </details>

### 后续发展方向 [AI]
- vNPU 的隔离落点是"找到容器 cgroup 路径再施限",补完 cgroup v2 后下一步应是 v2 下 pids/算力 controller 的实际写入是否同步适配;证据只覆盖路径查找,未见限额写入侧改动。
- 自带 patch 版 volcano + vxpu 插件随产品发布,说明 vNPU 仍依赖对上游 volcano 打补丁而非纯插件接入,集成耦合度偏高,值得对标 HAMi 的接入方式。

## 本期无实质改动(折叠)
<details><summary>6 仓 EMPTY(仅保锚点)</summary>

- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- npu-node-provision:无新提交
- npu-dra-plugin:无新提交
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交
</details>

## 对我们产品的启示
- **昇腾 vNPU 正在补 cgroup v2 这种"现代底座可用性"短板**,我们若已支持 v2 即领先;若做昇腾虚拟化集成,需注意 vNPU 仍靠 patch volcano,而非干净的 scheduler 插件——耦合是其弱点也是我们差异化点。
- **operator 的 NodeD 标签生命周期此前是坏的**,反映 openFuyao 昇腾 operator 仍在早期打磨;企业级"节点受管开关"的可靠性是可对标的成熟度指标。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=c51d26973257ec1f93a693480775f272e1402cfc tag=v26.0.1 scanned=2026-06-16 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-06-16 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-16 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-16 -->
<!-- ANCHOR repo=vNPU sha=a30d9493752c330db95f4258a1ea0fb9765977c6 tag=v0.1.0 scanned=2026-06-16 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-16 -->
<!-- ANCHOR repo=npu-dra-plugin sha=7731787412babb25bc775efd57240e0239a58db9 tag=1.0.1 scanned=2026-06-16 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-16 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=c7e00375aff3e56f84243abc48c6e348dcb0728b tag=1.0.1 scanned=2026-06-16 -->
</content>
</invoke>

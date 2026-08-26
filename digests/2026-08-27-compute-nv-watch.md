# NVIDIA 算力栈 diff 雷达 2026-08-27

## 摘要
- KAI-Scheduler 落地两件事:① PodGroup 身份从"仅 name"改为"namespace+name"复合键,修跨命名空间同名 PodGroup 在调度器缓存里互相覆盖的正确性 bug(#2095);② 新增 `fipsMode=only` 运行时强制档 + CRD 新字段 `fipsOnly`,给每个容器注入 `GODEBUG=fips140=only`(#2101,[API/CRD变更])。
- gpu-operator 修 `gpuop-cfg` 校验无 GDS 配置的 ClusterPolicy 时 panic(#2792):`ImagePath` 加 nil/typed-nil 防御,`validateImages` 把 GDS 校验收进 `!= nil` 分支(GDS 本就是可选项)。
- 其余 7 仓(container-toolkit / driver-container / device-plugin / dra-driver / dcgm-exporter / DCGM / mig-parted)本期无新提交。

## 当日重要改变
- **kai-scheduler/KAI-Scheduler** [调度正确性] PodGroup 身份改用 `namespace+name` 复合键,消除跨 namespace 同名 PodGroup 在 `ClusterInfo` 缓存里 key 碰撞。证据 `pkg/scheduler/cache/cluster_info/cluster_info.go`,提交 https://github.com/kai-scheduler/KAI-Scheduler/commit/49dd9849c50f94624e543d10b78d880bbf614376 PR https://github.com/kai-scheduler/KAI-Scheduler/pull/2095
- **kai-scheduler/KAI-Scheduler** [API/CRD变更] `GlobalConfig` 新增 `fipsOnly *bool`,CRD `kai.scheduler_configs.yaml` 同步新增 `fipsOnly` 布尔字段;helm `global.fipsMode` 取值扩为 `on|only|off`。证据 `pkg/apis/kai/v1/global.go`,PR https://github.com/kai-scheduler/KAI-Scheduler/pull/2101
- **NVIDIA/gpu-operator** [稳定性] 无 GDS 配置的 ClusterPolicy 校验不再 panic;`ImagePath` 加 nil 防御。证据 `cmd/gpuop-cfg/validate/clusterpolicy/images.go`,PR https://github.com/NVIDIA/gpu-operator/pull/2792

## kai-scheduler/KAI-Scheduler: 920e8a01 -> 49dd9849
- 比较: 920e8a015168c31ccc811403a0323bd078e6c9d6 -> 49dd9849 | ahead=2 | files=20 | Release: v0.14.8
- 完整比较 https://github.com/kai-scheduler/KAI-Scheduler/compare/920e8a015168c31ccc811403a0323bd078e6c9d6...49dd9849c50f94624e543d10b78d880bbf614376

### AI 总结重点(源码 diff 为据)
- **PodGroup 身份从纯 name 升级为 namespace-scoped 复合键**。新增 `NewPodGroupID(namespace, name)` 用 `NewObjectKey` 拼 key;`snapshotPodGroups` 里所有构造点(`PodGroupInfo` 的 id、`ListPodByIndex` 的索引键、结果 map 的 key)全部从 `podGroup.Name` 切到该复合键,并把每个 `podInfo.Job` 显式绑到复合 `podGroupID`。此前两个不同 namespace 里同名 PodGroup 会在调度器快照的 `map[PodGroupID]` 里互相覆盖 —— 典型多租户下的静默错分。
  <details><summary>代码依据 pkg/scheduler/api/common_info/common.go + cluster_info.go</summary>

  ```diff
  +func NewPodGroupID(namespace, name string) PodGroupID {
  +	return PodGroupID(NewObjectKey(namespace, name))
  +}
  ```
  ```diff
  -		podGroupID := common_info.PodGroupID(podGroup.Name)
  +		podGroupID := common_info.NewPodGroupID(podGroup.Namespace, podGroup.Name)
   		...
  -		rawPods, err := c.dataLister.ListPodByIndex(podByPodGroupIndexerName, podGroup.Name)
  +		rawPods, err := c.dataLister.ListPodByIndex(podByPodGroupIndexerName, string(podGroupID))
   		...
  +			podInfo.Job = podGroupID
   			podGroupInfo.AddTaskInfo(podInfo)
  -		result[common_info.PodGroupID(podGroup.Name)] = podGroupInfo
  +		result[podGroupID] = podGroupInfo
  ```
  </details>
- **新增 FIPS 运行时强制档 `fipsMode=only`**。`GlobalConfig` 加 `FIPSOnly *bool`(默认 false),`FIPSOnlyEnv()` 在其为 true 时给每个 Deployment/DaemonSet 容器注入 `GODEBUG=fips140=only`。此前 `fipsMode=on` 只是选用 `-fips` 镜像变体(构建期 FIPS);`only` 在此之上做运行时强制 —— Go FIPS 140-3 模块遇到非批准算法直接 panic 而非降级。helm 模板 `kai-scheduler.imageTag` 的 `-fips` 后缀逻辑也从 `eq "on"` 放宽到 `ne "off"`(即 `on` 和 `only` 都追加)。
  <details><summary>代码依据 pkg/apis/kai/v1/global.go + pkg/operator/operands/common/common.go</summary>

  ```diff
  +	// FIPSOnly sets GODEBUG=fips140=only on every KAI container, enforcing FIPS 140-3 mode
  +	// at runtime instead of just using FIPS-built images. This can panic at runtime if any
  +	// non-approved cryptographic algorithm is used
  +	FIPSOnly *bool `json:"fipsOnly,omitempty"`
  ```
  ```diff
  +func FIPSOnlyEnv(global *kaiv1.GlobalConfig) []v1.EnvVar {
  +	if global == nil || !ptr.Deref(global.FIPSOnly, false) {
  +		return nil
  +	}
  +	return []v1.EnvVar{{Name: "GODEBUG", Value: "fips140=only"}}
  +}
  ```
  </details>

### 后续发展方向 [AI]
- PodGroup 复合键这一步是把 KAI 缓存层从"假设 name 全局唯一"迁到"namespace 隔离",是多租户正确性的基础修复;证据只覆盖 `snapshotPodGroups` 一处,未见是否还有其他以裸 `PodGroup.Name` 作 key 的路径(如 queue/绑定层),值得下一期盯 `cluster_info` 邻近文件是否继续替换。
- FIPS `only` 档是合规向企业能力的显式加码(NVIDIA 官方在 README 里主动警告运行时 panic 风险、声明"用户自负"),说明面向受监管客户(政府/金融)在推;证据只在 config/operator/helm 层,未见 KAI 依赖树是否已全部走批准算法,真实可用性取决于运行时不触雷。

## NVIDIA/gpu-operator: 9004c9d7 -> 7c0baff9
- 比较: 9004c9d75b6e78825be6bc744ed9ad56bdb41433 -> 7c0baff9 | ahead=7 | files=18 | Release: v26.7.0
- 完整比较 https://github.com/NVIDIA/gpu-operator/compare/9004c9d75b6e78825be6bc744ed9ad56bdb41433...7c0baff9dd7e1b4fe6019a09bf73c6e1034f4718

### AI 总结重点(源码 diff 为据)
- **修 `gpuop-cfg validate` 在 ClusterPolicy 未配 GDS 时 panic**。根因是 `validateImages` 无条件对 `spec.GPUDirectStorage`(可选,未配时为 nil)调 `ImagePath` 再拼 `-ubuntu22.04`;改为整段收进 `if spec.GPUDirectStorage != nil`。同时 `ImagePath` 加双重 nil 防御:interface 为 nil、以及 typed-nil 指针(用 `reflect` 判 `Kind()==Pointer && IsNil()`),防同类崩溃复现。顺带清理了 GDS 分支里冗余的二次类型断言(`config := spec.(*GPUDirectStorageSpec)` → 直接用 switch 绑的 `v`)。注意:`clusterpolicy_types.go` 虽命中 `_types.go` 信号路径,但本次只改 `ImagePath` 辅助函数,**无 CRD 字段增删**。
  <details><summary>代码依据 cmd/gpuop-cfg/validate/clusterpolicy/images.go + api/nvidia/v1/clusterpolicy_types.go</summary>

  ```diff
  -	// GPUDirectStorage
  -	path, err = v1.ImagePath(spec.GPUDirectStorage)
  -	...
  -	path += "-ubuntu22.04"
  -	err = validateImage(ctx, path)
  +	// GPUDirectStorage is optional and nil when GDS is omitted from the ClusterPolicy.
  +	if spec.GPUDirectStorage != nil {
  +		path, err = v1.ImagePath(spec.GPUDirectStorage)
  +		...
  +		path += "-ubuntu22.04"
  +		err = validateImage(ctx, path)
  +	}
  ```
  ```diff
   func ImagePath(spec interface{}) (string, error) {
  +	if spec == nil {
  +		return "", fmt.Errorf("invalid nil spec to construct image path")
  +	}
  +	value := reflect.ValueOf(spec)
  +	if value.Kind() == reflect.Pointer && value.IsNil() {
  +		return "", fmt.Errorf("invalid nil spec to construct image path: %T", spec)
  +	}
  ```
  </details>
- **仓库治理与 CI 权限收紧(非功能)**:新增 `GOVERNANCE.md`/`CODE_OF_CONDUCT.md`;GHA workflow 全面改最小权限(顶层 `contents: read`,按 job 再提权),`cherrypick.yml`/`renovate.yaml` 等受影响;Renovate 停掉 builder-stage 基础镜像的 digest-only 更新。均无产品行为变化。

### 后续发展方向 [AI]
- 这批是 v26.7.0 后的稳定性/治理补丁,无 ClusterPolicy schema 变动,说明 driver 容器化主线本期无架构动作;证据覆盖全部 4 条实质提交,未见 time-slicing/MPS→DRA 迁移信号。

## 本期无实质改动(折叠)
<details><summary>7 仓无新提交</summary>

- NVIDIA/nvidia-container-toolkit(无新提交)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=7c0baff9dd7e1b4fe6019a09bf73c6e1034f4718 branch=main release=v26.7.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=b5a4721daa18ec48fb3bcc2c9e04cbd6baff373a branch=main release=v1.20.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=06a208ca9747c82b1ba99b76ecdcf2469b0a0207 branch=main release=— scanned=2026-08-27 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=ad174fb06833406f841f7396ed8c450a1a38a9fd branch=main release=v0.20.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=71dd363545415dea363639ff9cea98b39afe7f80 branch=main release=v0.5.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-27 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-08-27 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=8bac7a587a30504efbce56f0416b0cd9330c618e branch=main release=v0.15.0 scanned=2026-08-27 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=49dd9849c50f94624e543d10b78d880bbf614376 branch=main release=v0.14.8 scanned=2026-08-27 -->

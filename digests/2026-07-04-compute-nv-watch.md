# NVIDIA 算力栈 diff 雷达 2026-07-04

## 摘要
- **nvidia-container-toolkit 把 `libnvidia-nvvm70.so` 补进 CDI spec 的挂载集**:新增 `getLegacyNVVMLibraryMounts()` 单独发现并挂载 legacy NVVM 库,合入 driver library discoverer——修容器内缺 NVVM 库导致 CUDA JIT/PTX 编译失败的场景。
- **nvidia-container-toolkit 修 config 覆写被回退的 bug**:`loadConfigToml` 载入配置后遍历所有 key 打 `valuesSet` 标记,防止已被用户修改的配置项在保存时被当成"未设置"而回退成默认值。
- **KAI-Scheduler 削减大规模 reclaim 内存**:minruntime 插件删掉两个 per-job-pair 保护缓存 map,只保留 per-queue-pair 的有效时长缓存;另修 GPU 共享 pod 名含点(`.`)时生成非法 ConfigMap volume 名。gpu-driver-container 仅 base image 日期 bump + renovate 分组配置(无功能变化)。其余 6 仓无实质改动。

## 当日重要改变
- NVIDIA/nvidia-container-toolkit [新能力] CDI spec 新增 `libnvidia-nvvm70.so.*` legacy NVVM 库挂载,补齐容器内 CUDA JIT 编译所需库 https://github.com/NVIDIA/nvidia-container-toolkit/compare/8b935002a31ca5ba892d6f2f255f9abe58d82b7a...69c285d7fd8f23e2a45bf64efe71e1bdaa61c1de

## NVIDIA/nvidia-container-toolkit: 8b935002 -> 69c285d7
- 比较 / 最新 Release:8b935002 -> 69c285d7 | ahead=6 | files=4 | Release: v1.19.1
### AI 总结重点(源码 diff 为据)
- **CDI spec 补 legacy NVVM 库挂载**:`NewDriverLibraryDiscoverer` 新增一步 `getLegacyNVVMLibraryMounts()`,把 `libnvidia-nvvm70.so.*` 作为独立 mounts 合入(与 versionSuffix / explicit 库并列 `discover.Merge`)。此前该库不在自动发现集里,容器内做 PTX→SASS 的 JIT 编译(依赖 NVVM)会因找不到 `libnvidia-nvvm70.so` 失败;现在通过 `driver.DriverLibraryLocator()` 定位并挂载。纯 CDI 可见性补齐,不改隔离语义。
  <details><summary>代码依据 pkg/nvcdi/driver-nvml.go</summary>

  ```diff
  +	legacyNVVMLibraryMounts, err := l.getLegacyNVVMLibraryMounts()
  +	if err != nil {
  +		return nil, fmt.Errorf("failed to get legacy nvvm library mounts: %w", err)
  +	}
   	libraries := discover.Merge(
   		versionSuffixLibraryMounts,
  +		legacyNVVMLibraryMounts,
   		explicitLibraryMounts,
   	)
  +func (l *nvcdilib) getLegacyNVVMLibraryMounts() (discover.Discover, error) {
  +	legacyNVMMLibrary := []string{
  +		"libnvidia-nvvm70.so.*",
  +	}
  +	driverLibraryLocator, err := l.driver.DriverLibraryLocator()
  +	...
  +	mounts := discover.NewMounts(l.logger, driverLibraryLocator, l.driver.Root, legacyNVMMLibrary)
  +	return mounts, nil
  +}
  ```
  </details>
- **修 config 保存时把用户改动回退成默认的 bug**:`loadConfigToml` 从"直接 `return loadConfigTomlFrom(tomlFile)`"改为载入后遍历 tree 的所有 key、递归调 `markKeysSet` 在 `valuesSet` 里逐个打标(含嵌套子树 `prefix.key`)。语义:从文件读进来的配置项现在都被视为"显式设置过",避免后续 Save 时因该项未标记 set 而按 default 写回,导致用户先前的修改被"revert"。
  <details><summary>代码依据 api/config/v1/toml.go</summary>

  ```diff
  -	return loadConfigTomlFrom(tomlFile)
  +	t, err := loadConfigTomlFrom(tomlFile)
  +	if err != nil { return nil, fmt.Errorf("failed to load specified config file: %w", err) }
  +	for _, key := range t.tree.Keys() {
  +		t.markKeysSet(key, "")
  +	}
  +	return t, nil
  +}
  +func (t *Toml) markKeysSet(key string, prefix string) {
  +	fullKey := key
  +	if prefix != "" { fullKey = prefix + "." + key }
  +	t.valuesSet[fullKey] = true
  +	if nextTree, ok := t.tree.Get(fullKey).(*toml.Tree); ok {
  +		for _, nextKey := range nextTree.Keys() { t.markKeysSet(nextKey, fullKey) }
  +	}
  +}
  ```
  </details>
### 后续发展方向 [AI]
- 两处都是运行时/配置面 correctness 修复,不涉及 CDI 隔离模型或 CRD。NVVM 补齐说明 toolkit 在收敛"容器内 CUDA 工具链完整性"(JIT 编译此前是盲区);config markKeysSet 则关系到 gpu-operator 通过 toolkit 下发/持久化配置时的幂等性,对上层 operator reconcile 的稳定性有正面意义。证据仅覆盖这两个 hunk 与配套 test,未见其他 runtime hook 改动;注:探测器把 `api/config/v1/toml.go` 标为 API 命中,但这是 toolkit 自身的配置解析库,非 K8s CRD 字段变更。

## kai-scheduler/KAI-Scheduler: bb9f733e -> f2bed2c2
- 比较 / 最新 Release:bb9f733e -> f2bed2c2 | ahead=3 | files=14 | Release: v0.16.2
### AI 总结重点(源码 diff 为据)
- **削减大规模 reclaim 的调度器内存**:minruntime 插件删除 `preemptProtectionCache`(`map[PodGroupID]bool`)与 `reclaimProtectionCache`(`map[PodGroupID]map[PodGroupID]bool`)两个 per-job-pair 保护缓存,以及配套的 `cachePreemptProtection` / `cacheReclaimProtection` 写入逻辑。`isReclaimMinRuntimeProtected` / `isPreemptMinRuntimeProtected` 改为每次直接算 `time.Now().Before(protectedUntil)`。行为不变(min-runtime 保护判定结果一致),但去掉了随 victim×pending job 对数量膨胀的缓存——大 reclaim 场景内存显著下降,有效时长仍按 queue pair 缓存(见 CHANGELOG #1808)。
  <details><summary>代码依据 pkg/scheduler/plugins/minruntime/minruntime.go</summary>

  ```diff
  -	preemptProtectionCache map[common_info.PodGroupID]bool
  -	reclaimProtectionCache map[common_info.PodGroupID]map[common_info.PodGroupID]bool
  ...
  -	if cached, ok := mr.reclaimProtectionCache[pendingJob.UID][victim.UID]; ok {
  -		return cached
  -	}
  ...
  -		protected := time.Now().Before(protectedUntil)
  -		mr.cacheReclaimProtection(pendingJob, victim, protected)
  -		return protected
  +		return time.Now().Before(protectedUntil)
  ```
  </details>
- **修点号 pod 名生成非法 ConfigMap volume 名(#1728)**:`GetConfigVolumeName` 从 `fmt.Sprintf("%v-vol", configMapName)` 改为先 `ToLower` 再用正则 `[^a-z0-9-]+` 替非法字符为 `-`、并 `Trim` 首尾 `-`,确保 volume 名是合法 DNS label;`generateConfigMapNamePrefix` 追加 `strings.TrimRight(baseName, ".-")` 去掉截断后残留的尾部 `.`/`-`。修 GPU 共享(fractional)pod 名含点时注入的 ConfigMap-backed volume 名非法导致 pod 无法创建。
  <details><summary>代码依据 pkg/binder/common/volumes.go</summary>

  ```diff
  +var invalidDNSLabelChars = regexp.MustCompile(`[^a-z0-9-]+`)
   func GetConfigVolumeName(configMapName string) string {
  -	return fmt.Sprintf("%v-vol", configMapName)
  +	volumeName := strings.ToLower(configMapName + "-vol")
  +	volumeName = invalidDNSLabelChars.ReplaceAllString(volumeName, "-")
  +	return strings.Trim(volumeName, "-")
   }
  ```
  </details>
- 第 3 个提交 `test(scheduler): add reclaim benchmark and topology coverage (#1748)` 为纯测试新增(reclaim topology / many-single-gpu / large-job 基准与拓扑覆盖用例),不含产品代码,略。
### 后续发展方向 [AI]
- 两处都是 v0.16 后的稳定性/规模化打磨:minruntime 去缓存指向 KAI 在往"大规模(数千 job)reclaim 内存可控"方向压,配合新增的 reclaim benchmark 测试(#1748)可见团队在系统性做 reclaim 路径的性能回归防护;volume 名 sanitize 则补 fractional GPU 共享在真实 pod 命名下的健壮性。证据覆盖 minruntime.go / volumes.go / config_map.go 三个 hunk + CHANGELOG,未见调度算法或 API 形态改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 低信号仓</summary>

- NVIDIA/gpu-driver-container — 仅 base image 日期 bump(resolute-20260421→20260627、noble-20260509.1→20260610、jammy-20260509→20260627)+ renovate.json 新增 RHEL UBI / Ubuntu base image 分组规则与版本正则约束,无驱动版本或构建逻辑变化
- NVIDIA/gpu-operator — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=7b38b13887ac4054d2f958d9e178d25f6b72ef8a branch=main release=v26.3.3 scanned=2026-07-04 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=69c285d7fd8f23e2a45bf64efe71e1bdaa61c1de branch=main release=v1.19.1 scanned=2026-07-04 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=102ce377e0478c58cb3927c28cfda685c6bd3425 branch=main release=— scanned=2026-07-04 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=10fd1c08afa74932e0f949e540eca9d9953d9cec branch=main release=v0.19.3 scanned=2026-07-04 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=884f41fdd20204ae2f194ba9a94cce4b4200110b branch=main release=v0.4.1 scanned=2026-07-04 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-04 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=944764a9e9685d82279eb2d1ee216b7b2451e213 branch=main release=v0.14.3 scanned=2026-07-04 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=f2bed2c23d06539e13a04271b8a20fec08a37546 branch=main release=v0.16.2 scanned=2026-07-04 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-07-04 -->

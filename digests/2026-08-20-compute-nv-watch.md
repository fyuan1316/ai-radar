# NVIDIA 算力栈 diff 雷达 2026-08-20

## 摘要
- **dra-driver-nvidia-gpu 发 v0.5.0(v0.4.1→v0.5.0 minor 跨档)**:本窗口最实质的代码改动是给 ComputeDomain 的 opaque claim config 里的 `DomainID` 加**路径穿越校验**(`ValidateDomainID`,拒绝 `/`、`.`、`..`)——DomainID 由 claim 作者控制且被当作磁盘路径组件,属安全加固;随 0.5.0 一并落地的 Fabric Manager 分区、consumable capacity、host-managed IMEX 在本窗口主要以**文档**形式出现(功能代码此前已合入)。
- **k8s-device-plugin 把 MIG 资源名匹配加 `^…$` 锚定**,修复子串误匹配:带 `-me`/`+me.all`/`+gfx` 后缀的 MIG profile 现在作为**独立 k8s 资源**暴露而非被 `1g.24gb` 吞掉——直接改变节点上报的资源面;同时 manifests 版本预备到 0.20.0(Release 仍 v0.19.3)。
- **DCGM 4.6.1** 新增模块命令校验层(按 module/subCommand/version 核对消息长度后再 dispatch,hostengine IPC 输入加固)+ TCP 连接改用 getaddrinfo 支持 **IPv6**;**container-toolkit** 新增从容器 state JSON 直读 rootfs,兼容 `--userns=nomap` 等 rootless 场景。gpu-operator 本期仅 CI 加固 + dcgm 镜像 digest 更新,无功能面改动。

## 当日重要改变
- kubernetes-sigs/dra-driver-nvidia-gpu [API/CRD变更·安全] 给 ComputeDomain opaque config 的 `DomainID` 新增 `ValidateDomainID`,拒绝路径分隔符/`.`/`..`/超长 label,堵住 claim 作者经 DomainID 做目录逃逸的路径穿越。证据 api/nvidia.com/resource/v1beta1/computedomainconfig.go。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/ddc71625fa872e49bbbe566a163f06ae3f990966...4400a6d5eb6abfcfd00efed51b275ff8b059511b
- kubernetes-sigs/dra-driver-nvidia-gpu [版本跨档] Release v0.4.1 → v0.5.0(minor),随附 Fabric Manager 分区(新 feature gate `FabricManagerPartitioning`,新 ResourceSlice 属性 `gpuModuleID`/`partition1|2|4|8`)、consumable capacity(`ConsumableShares` gate)、host-managed IMEX 模式文档。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/releases/tag/v0.5.0
- NVIDIA/k8s-device-plugin [缺陷·资源面] `wildCardToRegexp` 加 `^`/`$` 锚定,修复 MIG 资源模式子串误匹配(#1807),使带后缀的 MIG profile 独立暴露为 k8s 资源。证据 api/config/v1/resources.go。https://github.com/NVIDIA/k8s-device-plugin/compare/60b4e9192daf6725ba70e45252ff39ea1c768951...1b826acc6af3079d8923bac395c3124b8861a9a6
- NVIDIA/DCGM [安全·正确性] 新增 `DcgmModuleCommandValidation`,按 module/subCommand/version 校验 IPC 命令消息最小长度后再分发,并给 `HelperCreateFakeEntities` 加 `numToCreate > DCGM_MAX_HIERARCHY_INFO` 越界检查。证据 dcgmlib/src/DcgmModuleCommandValidation.cpp。https://github.com/NVIDIA/DCGM/compare/72fa3feaa67d716a75323a8f47c34ff3ee73f824...64df9f894541e426e416131a9820cae97aa4dd81
- NVIDIA/nvidia-container-toolkit [新能力·兼容] `internal/oci/state.State` 新增非标准 `Root` 字段,优先从容器 state JSON 直读 rootfs,避开 `--userns=nomap` 下打开 config.json 被拒(issue #648)。证据 internal/oci/state.go。https://github.com/NVIDIA/nvidia-container-toolkit/compare/26f29323af4658a1b97a97579ebc8e3cc5ec643b...bade31ea2f580be8f0b6daa970f8691635165246

## kubernetes-sigs/dra-driver-nvidia-gpu: ddc71625 -> 4400a6d5
- 比较: ddc71625 -> 4400a6d5 | ahead=11 | files=38 | Release: v0.4.1 → v0.5.0
- 比较页: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/ddc71625fa872e49bbbe566a163f06ae3f990966...4400a6d5eb6abfcfd00efed51b275ff8b059511b

### AI 总结重点(源码 diff 为据)
- **DomainID 路径穿越校验落地(安全硬化)**。原 `ComputeDomainChannelConfig.Validate`/`ComputeDomainDaemonConfig.Validate` 只查 `DomainID == ""`;新代码抽出公共 `ValidateDomainID`,用 `content.IsPathSegmentName` 拒绝含 `/`、`.`、`..` 的值,再用 `validation.IsValidLabelValue` 拒绝超长/非法 label(DomainID 也用作节点 label 值)。注释明确:DomainID 源自 claim 作者可控的 opaque device config,被 join 进磁盘路径,不校验即可经 `../` 逃逸目录。两个 Validate 都改为委托它。这是把「不可信输入→路径组件」的边界不变式补齐,属安全修复而非新功能。
  <details><summary>代码依据 api/nvidia.com/resource/v1beta1/computedomainconfig.go</summary>

  ```diff
  +func ValidateDomainID(domainID string) error {
  +	if domainID == "" {
  +		return fmt.Errorf("domainID cannot be empty")
  +	}
  +	if errs := content.IsPathSegmentName(domainID); len(errs) > 0 {
  +		return fmt.Errorf("domainID %q is not a valid single path component: %s", domainID, strings.Join(errs, ", "))
  +	}
  +	if errs := validation.IsValidLabelValue(domainID); len(errs) != 0 {
  +		return fmt.Errorf("domainID must be a valid label value: %s", strings.Join(errs, "; "))
  +	}
  +	return nil
  +}
  ...
   func (c *ComputeDomainChannelConfig) Validate() error {
  -	if c.DomainID == "" {
  -		return fmt.Errorf("domainID cannot be empty")
  -	}
  -	return nil
  +	return ValidateDomainID(c.DomainID)
   }
  ```
  </details>
  配套 `computedomainconfig_test.go`(+84)锁死用例:`.`、`..`、`../../../../../../escape-target/pwn`、`/etc/passwd`、`foo/../../bar`、`foo/bar` 全 expectError,UID 形态放行——把逃逸向量固化成回归测试。

- **v0.5.0 随附能力以文档形式出现(代码此前已落)**。本窗口 `site/content/docs` 大量新增/改写,是 0.5.0 发版文档,不是本区间的功能代码:
  - **Fabric Manager 分区**(新 `fabric-manager-partitioning.md`):新 feature gate `FabricManagerPartitioning`,把 full-GPU / VFIO claim 约束到 NVSwitch fabric 分区(HGX/单节点 NVL);claim 内所有物理 GPU 必须**恰好**匹配 FM 报告的一个分区,子集/跨界均 Prepare 失败。
  - **consumable capacity**(新 `consumable-capacity.md`):新 gate `ConsumableShares` + Helm `consumableShares`(memory/unlimited/正整数/disabled),让多个独立 ResourceClaim 分配同一物理 GPU/MIG,`allowMultipleAllocations: true`,对齐上游 `DRAConsumableCapacity`。与 time-slicing/MPS 的区别:这是调度器按容量记账的多分配,不是驱动侧 sharing config。
  - **host-managed IMEX**:ComputeDomain 新增 `hostManaged` vs 默认 `driverManaged` 模式;host-managed 下 controller 不建 per-domain daemon DaemonSet,当前仅提供域隔离 + channel 0。
  - ResourceSlice 属性文档新增 `gpuModuleID`、`partition1|2|4|8`、标准 `resource.kubernetes.io/numaNode`(替代旧 `numa` int)。
  <details><summary>代码依据 site/content/docs/reference/resourceslice-attributes.md</summary>

  ```diff
  +    gpuModuleID:
  +      int: 1                        # Fabric Manager GPU module ID, when enabled
  +    partition2:
  +      int: 4                        # ID of a reported size-2 FM partition
  ...
  -    numa:
  -      int: 0                        # NUMA node
  +    partition1:
  +      int: 8                         # ID of the size-1 Fabric Manager partition
  +    resource.kubernetes.io/numaNode:
  +      int: 0                         # NUMA node, when available
  ```
  </details>

### 后续发展方向 [AI]
- 证据覆盖 ValidateDomainID 代码 hunk + 0.5.0 文档,未逐一读 FM 分区/consumable capacity 的实现代码(它们在更早区间已合入,本窗口只见文档)。方向清晰:dra-driver 正把 NVSwitch 物理拓扑(FM 分区)与 DRA 原生共享(consumable capacity 多分配)同时纳管——前者是硬件级 fabric 隔离,后者是软共享的 DRA 化替代 time-slicing/MPS。可盯下一步 consumable capacity 是否从 Alpha 推进、以及 FM 分区匹配算法是否落到调度约束(本窗口仅见文档描述"恰好匹配一个分区"的规则)。

## NVIDIA/k8s-device-plugin: 60b4e919 -> 1b826acc
- 比较: 60b4e919 -> 1b826acc | ahead=10 | files=33 | Release: v0.19.3(manifests 已预备 0.20.0)
- 比较页: https://github.com/NVIDIA/k8s-device-plugin/compare/60b4e9192daf6725ba70e45252ff39ea1c768951...1b826acc6af3079d8923bac395c3124b8861a9a6

### AI 总结重点(源码 diff 为据)
- **MIG 资源模式匹配加锚定,消除子串误匹配(#1807)**。`wildCardToRegexp` 生成的正则原本无 `^`/`$`,`ResourcePattern.Matches` 用它做 `regexp.MatchString` 时,模式 `1g.24gb` 会子串命中 `1g.24gb-me`、`1g.24gb+me.all`、`x1g.24gb`。新代码在拼接前后各补 `^`/`$` 强制全串匹配。语义后果:带 `-me`(memory-enabled)/`+me.all`/`+gfx` 等后缀的 MIG profile 不再被基础 profile 吞并,而是各自暴露成独立的 `nvidia.com/mig-*` k8s 资源——直接影响节点上报的可调度资源面。
  <details><summary>代码依据 api/config/v1/resources.go</summary>

  ```diff
   func wildCardToRegexp(pattern string) string {
   	var result strings.Builder
  +	result.WriteString("^")
   	for i, literal := range strings.Split(pattern, "*") {
   		...
   	}
  +	result.WriteString("$")
   	return result.String()
   }
  ```
  </details>
  新增 `resources_test.go`(+148)固化不变式:exact match 通过、`1g.24gb` 不匹配 `1g.24gb-me`/`1g.24gb+me.all`/`x1g.24gb`、`-me`/`+me.all` 后缀模式匹配自身、`*` 仍匹配一切。

- **manifests 版本预备到 0.20.0(Release 尚未发)**。GFD daemonset/job 模板、Chart.yaml `version`/`appVersion` 从 0.19.3 → 0.20.0,CHANGELOG 补入完整 v0.20.0 块。CHANGELOG 列出的 0.20.0 头条(packed/distributed 分配策略、distinct 物理 GPU 打散、Rubin 架构支持 #1909、NFD chart→v0.19.0 用 OCI artifact)对应的功能代码不在本区间 diff 内(本窗口实质提交仅 MIG 锚定 fix + 版本 bump),故仅作版本预备信号记录,不逐条当代码依据。
  <details><summary>代码依据 CHANGELOG.md(仅供发版方向,非本窗口代码)</summary>

  ```diff
  +### v0.20.0
  +- Add configurable packed/distributed allocation policy for replicated and MIG resources (#1621)
  +- Add support for the Rubin architecture family (#1909)
  +- Update the Node Feature Discovery chart to v0.19.0 and use OCI artifacts (#1922)
  ```
  </details>

### 后续发展方向 [AI]
- 证据覆盖 resources.go 锚定 fix + 测试 + 版本 bump,未见 time-slicing/MPS/DRA 迁移的运行逻辑改动。这条 MIG fix 是 device-plugin 资源命名正确性的收口(避免后缀 profile 被静默合并),说明其在把 MIG 资源枚举做严;可盯 0.20.0 正式发版后 CHANGELOG 里 packed/distributed 分配策略的代码落点,那才是共享/分配策略的实质演进。

## NVIDIA/DCGM: 72fa3fea -> 64df9f89
- 比较: 72fa3fea -> 64df9f89 | ahead=1(4.6.1 squash 发版) | files=105 | branch=master | Release: —
- 比较页: https://github.com/NVIDIA/DCGM/compare/72fa3feaa67d716a75323a8f47c34ff3ee73f824...64df9f894541e426e416131a9820cae97aa4dd81

### AI 总结重点(源码 diff 为据)
- **新增模块命令校验层 `DcgmModuleCommandValidation`(IPC 输入加固)**。新文件用 `consteval MakeCommandMetadata<MsgT, Version>` 建立 (moduleId, subCommand, version)→期望消息尺寸的元数据表,`static_assert((Version & 0x00FFFFFF) == sizeof(MsgT))` 编译期锁定版本号低 24 位即为结构体大小;`DcgmHostEngineHandler` 引入它,在分发前按元数据校验请求最小长度与 dispatch buffer 长度。等于给 hostengine 收到的模块命令加了「长度/版本先验校验」这道闸,拦截畸形/过短消息。
  <details><summary>代码依据 dcgmlib/src/DcgmModuleCommandValidation.cpp(added +503)</summary>

  ```cpp
  template <typename MsgT, unsigned int Version>
  consteval ModuleCommandMetadata MakeCommandMetadata(dcgmModuleId_t commandModuleId, unsigned int commandSubCommand)
  {
      static_assert(static_cast<std::size_t>(Version & VERSION_SIZE_MASK) == sizeof(MsgT));
      ...
  }
  ```
  </details>
  配套 `DcgmHostEngineHandler` 给 `HelperCreateFakeEntities` 加越界检查(`numToCreate > DCGM_MAX_HIERARCHY_INFO` 直接返回 `DCGM_ST_BADPARAM`),并把旧的 `ResizeMsgBufferForSubCommand` switch 重构进新校验框架。
  <details><summary>代码依据 dcgmlib/src/DcgmHostEngineHandler.cpp</summary>

  ```diff
  +    if (createFakeEntities->numToCreate > DCGM_MAX_HIERARCHY_INFO)
  +    {
  +        log_error("Cannot create {} fake entities because the request only has room for {} entity entries.",
  +                  createFakeEntities->numToCreate, DCGM_MAX_HIERARCHY_INFO);
  +        return DCGM_ST_BADPARAM;
  +    }
  ```
  </details>

- **IPC TCP 连接改用 getaddrinfo,支持 IPv6**。`DcgmIpc.cpp` 新增 `GetConnectAddressFamilyHint`(数字字面量走 `AI_NUMERICHOST` 锁族)与 `ResolveTcpConnectCandidates`(DNS 名走 `AI_ADDRCONFIG`,让 IPv6-only 名解析出 AAAA 而非在强制 AF_INET 下失败)。原实现对连接目标族处理不足,IPv6-only 主机名会失败;新逻辑按候选地址族逐一尝试。
  <details><summary>代码依据 common/transport/DcgmIpc.cpp</summary>

  ```cpp
  int const familyHint = GetConnectAddressFamilyHint(hostname);
  hints.ai_family = familyHint;
  if (familyHint == AF_UNSPEC) { hints.ai_flags = AI_ADDRCONFIG; }
  else { hints.ai_flags = AI_NUMERICHOST; }
  ```
  </details>

- 其余大体量文件为**非语义改动**:`dcgm_core_structs.h`(±74)是 `DCGM_CORE_SR_*` 宏的列对齐重排(SR 编号与语义不变);`.clang-format`(+142)升级格式规则;`crosstool-ng` 工具链 1.26→1.28、toolchain Dockerfile 改用 `ADD --checksum` 固定依赖 URL/SHA(构建可复现性),均不影响运行时 GPU 监控语义。

### 后续发展方向 [AI]
- 证据覆盖新校验模块、IPC v6 解析、越界检查三处真实 hunk,未逐一展开 4.6.1 全部 105 文件(单 squash commit,余多为格式/工具链)。方向上 DCGM 在把 hostengine 的 IPC 命令入口做「长度/版本强校验 + 参数越界防护」,是底层健康/profiling 库的攻击面收敛;IPv6 IPC 则补齐纯 v6 集群的监控连通性。可盯后续该校验表是否扩展到 core 之外的 sysmon/health 等模块(本次 metadata 表以 core 子命令为主)。

## NVIDIA/nvidia-container-toolkit: 26f29323 -> bade31ea
- 比较: 26f29323 -> bade31ea | ahead=7 | files=52 | Release: v1.20.0
- 比较页: https://github.com/NVIDIA/nvidia-container-toolkit/compare/26f29323af4658a1b97a97579ebc8e3cc5ec643b...bade31ea2f580be8f0b6daa970f8691635165246

### AI 总结重点(源码 diff 为据)
- **从容器 state JSON 直读 rootfs,兼容 userns/rootless(唯一功能改动)**。`internal/oci/state.State` 从 `type State specs.State` 改为内嵌 struct 并加非标准 `Root string` 字段;新增私有 `getRoot()`:若 `s.Root != ""` 直接用,否则回落加载 minimal spec 读 `spec.Root.Path`。`GetContainerRoot` 改为走 `getRoot()`。注释点明:某些 OCI runtime(如 crun)会在 state JSON 里带 `root`,直接用它可避开 `--userns=nomap` 下打开 config.json 被权限拒绝(issue #648)。这是提升 rootless/userns 容器下 CDI/hook 拿 rootfs 的健壮性。
  <details><summary>代码依据 internal/oci/state.go</summary>

  ```diff
  -type State specs.State
  +type State struct {
  +	specs.State
  +	// Root is a non-standard extension included in the container state JSON by some
  +	// OCI runtimes (e.g., crun). ... avoiding the need to open config.json — which may
  +	// be permission-denied when running with user namespaces such as --userns=nomap (issue #648).
  +	Root string `json:"root,omitempty"`
  +}
  +
  +func (s *State) getRoot() (string, error) {
  +	if s.Root != "" {
  +		return s.Root, nil
  +	}
  +	spec, err := s.loadMinimalSpec()
  +	...
  +	if spec.Root != nil { return spec.Root.Path, nil }
  +	return "", nil
  +}
  ```
  </details>

- **"modernize code base"= 纯机械重构,零行为变化**。全仓 `interface{}` → `any`(含 `api/config/v1/toml.go` 的 `Get`/`Set`/`Unmarshal`、`pkg/config/toml`、docker/containerd engine、logger 接口)、`strings.HasPrefix+TrimPrefix` → `strings.CutPrefix`、`for i:=0;i<n;i++` → `for i:=range`。注意:重要改变探测器报的 `api/config/v1/toml.go`/`config.go` 命中**只是这轮 `any` 化**,非 API 语义变更,勿误判为 CRD/配置面改动。
  <details><summary>代码依据 api/config/v1/config.go</summary>

  ```diff
  -		if strings.HasPrefix(line, "ID_LIKE=") {
  -			value := strings.Trim(strings.TrimPrefix(line, "ID_LIKE="), "\"")
  +		if after, ok := strings.CutPrefix(line, "ID_LIKE="); ok {
  +			value := strings.Trim(after, "\"")
  ```
  </details>

### 后续发展方向 [AI]
- 证据覆盖 state.go 的 rootfs 直读 + 大面积 any 化重构,未见 CDI spec 结构或 hook 逻辑改动。方向上 toolkit 在补齐 rootless/userns(`--userns=nomap`)下的运行正确性——这是 GPU 容器化往非特权/rootless 收敛的一小步;可盯后续是否有更多 hook 路径消费这个 `Root` 字段(本次仅 `GetContainerRoot` 一处)。

## NVIDIA/gpu-operator: 11ebba47 -> 7ab78b49
- 比较: 11ebba47 -> 7ab78b49 | ahead=6 | files=19 | Release: v26.3.3
- 比较页: https://github.com/NVIDIA/gpu-operator/compare/11ebba478e102088f2e77d58a3d41f5a28254522...7ab78b49190ffaac5af656d911fb8e80e68cea15

### AI 总结重点(源码 diff 为据)
- **本期无功能面改动,两件事均非产品能力**:(1)`ci: pin GitHub Actions to commit SHA`——15 个 workflow 把 `actions/checkout@v7`、`docker/login-action@v4`、`NVIDIA/holodeck@v0.3.7` 等全部从浮动 tag 钉到具体 commit SHA(附 `# vX` 注释),属供应链/CI 加固;(2)`Update nvcr.io/nvidia/cloud-native/dcgm`——bundle CSV(±4)与 values.yaml(±2)里 dcgm 随附镜像 digest 更新(仅镜像 digest,helper 未截出该 hunk,依提交标题判定)。探测器报「无 API/CRD 路径命中」,ClusterPolicy/NVIDIADriver 的 `*_types.go` 无字段增删。
  <details><summary>代码依据 .github/workflows/image-builds.yaml</summary>

  ```diff
  -      - uses: actions/checkout@v7
  +      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
  ...
  -        uses: docker/login-action@v4
  +        uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4
  ```
  </details>

### 后续发展方向 [AI]
- 证据仅 CI 钉 SHA + dcgm 镜像 digest,无 CRD/driver 矩阵/能力改动。相对昨日(610 driver 分支纳入)本期 operator 不承载能力信号,是发版工程化间隙。要盯的仍是 ClusterPolicy CRD 字段与 driver 版本矩阵,本期均无。

## 本期无实质改动(折叠)
<details><summary>4 仓无新提交 / 仅 bump·CI·merge</summary>

- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/mig-parted(ahead=16/files=59,但实质提交经滤后仅 bump·CI·merge)
- kai-scheduler/KAI-Scheduler(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=7ab78b49190ffaac5af656d911fb8e80e68cea15 branch=main release=v26.3.3 scanned=2026-08-20 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=bade31ea2f580be8f0b6daa970f8691635165246 branch=main release=v1.20.0 scanned=2026-08-20 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=06a208ca9747c82b1ba99b76ecdcf2469b0a0207 branch=main release=— scanned=2026-08-20 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1b826acc6af3079d8923bac395c3124b8861a9a6 branch=main release=v0.19.3 scanned=2026-08-20 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=4400a6d5eb6abfcfd00efed51b275ff8b059511b branch=main release=v0.5.0 scanned=2026-08-20 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-20 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-08-20 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=e2d5ad1fc72b9d298ea6d04b885cf2d7dbe56941 branch=main release=v0.14.5 scanned=2026-08-20 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=2914d320160fbb389f69a2c2968a0a6acefb9f76 branch=main release=v0.14.8 scanned=2026-08-20 -->
</content>
</invoke>

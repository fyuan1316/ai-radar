# NVIDIA 算力栈 diff 雷达 2026-08-19

## 摘要
- gpu-operator 把 driver 分支 **610.57.04** 首次纳入 operator 默认镜像集(新增 `driver-image-610` / `DRIVER_IMAGE-610`),并把 595 分支默认版本推到 595.91.07——活跃 driver 矩阵从两档(default+580)扩到三档(+610),是本期最实质的能力信号。
- container-toolkit 修了 CDI 路径变换的**边界缺陷**:`/driver` 前缀会错误命中 `/driver-backup/...` 并被截成 `{targetRoot}/-backup/...`,改成按路径分隔符对齐比较——影响容器内 driver 库挂载正确性,偏安全/正确性修复。
- 其余动的两仓均为非功能改动:k8s-device-plugin 纯加 OCI 标准镜像标签,dra-driver-nvidia-gpu 纯补单测(checkpoint/root/types)+ Go 1.26.6 bump。无 API/CRD 字段变更、无 DRA 调度语义变化。

## 当日重要改变
- NVIDIA/gpu-operator [驱动矩阵扩展] operator 默认镜像集新增 610.57.04 driver 分支(`driver-image-610`),595 默认版跳 595.71.05→595.91.07。未触发弃用/CRD/版本跨档硬信号,但直接改变了 operator 开箱支持的 driver 版本面。证据 bundle CSV + values.yaml。https://github.com/NVIDIA/gpu-operator/compare/ed270f823c2ecbe6d4f854054db084d4b6491a4b...11ebba478e102088f2e77d58a3d41f5a28254522
- NVIDIA/nvidia-container-toolkit [缺陷/安全] CDI root 路径变换按路径组件边界匹配,修复兄弟目录(`/driver` vs `/driver-backup`)被误变换的问题,影响注入容器的 driver 库路径正确性。证据 pkg/nvcdi/transform/root/root.go。https://github.com/NVIDIA/nvidia-container-toolkit/compare/cb5d6990b8069e8ad9bdb67f9a2b3ff832d9531c...26f29323af4658a1b97a97579ebc8e3cc5ec643b

## NVIDIA/gpu-operator: ed270f82 -> 11ebba47
- 比较: ed270f82 -> 11ebba47 | ahead=4 | files=5 | Release: v26.3.3
- 比较页: https://github.com/NVIDIA/gpu-operator/compare/ed270f823c2ecbe6d4f854054db084d4b6491a4b...11ebba478e102088f2e77d58a3d41f5a28254522

### AI 总结重点(源码 diff 为据)
- **新增第三条 driver 镜像分支 610**。bundle CSV 的 `relatedImages` 与 operator env 里原本只有 default driver-image 和 driver-image-580 两条,本次并列插入 `driver-image-610`(env `DRIVER_IMAGE-610`),同时 default 与 580 两条的 digest 都刷新。含义:operator 对外声明的活跃 driver 版本矩阵从「default+580」扩为「default+580+610」,即 610 分支进入官方随 operator 分发的驱动集合,是预编译/驱动矩阵的实质扩张,不是单纯 digest bump。
  <details><summary>代码依据 bundle/manifests/gpu-operator-certified.clusterserviceversion.yaml</summary>

  ```diff
       - name: driver-image-580
  -      image: nvcr.io/nvidia/driver@sha256:f8e3dc9111c5a7a0cfac73e87d03c0b7b3d1e11f3b61654cca5461847660aa2c
  +      image: nvcr.io/nvidia/driver@sha256:fbbd829db234885d6f0026ca6fb6369f6875b0b91fc5e98d7752f31aeab5e470
  +    - name: driver-image-610
  +      image: nvcr.io/nvidia/driver@sha256:a35d05d5b984ad18713af957f87380ccbefd8f0bb5e6771fc7856e6a9e1d201f
  ```
  </details>
- **driver 默认版本上移**:helm `values.yaml` 与 `config/samples` 的 `driver.version` 从 595.71.05 → 595.91.07(同 595 分支内小版本推进);测试基线 `TARGET_DRIVER_VERSION` 580.159.04 → 580.178.04。即默认拉起的 driver 版本随之更新,非分支切换。
  <details><summary>代码依据 deployments/gpu-operator/values.yaml</summary>

  ```diff
     usePrecompiled: false
     repository: nvcr.io/nvidia
     image: driver
  -  version: "595.71.05"
  +  version: "595.91.07"
  ```
  </details>
- **NVIDIADriver 模板给 version 加 `| quote`**,修复 driver 版本号在 Helm 渲染时被当成 integer/float 的问题(commit "quote driver version so that its not considered integer/float")。这是 CRD 实例渲染健壮性修复:纯数字点分版本(如某些分支号)不加引号会被 YAML 解析成数值而丢失格式,不改 CRD schema,只改模板输出。
  <details><summary>代码依据 deployments/gpu-operator/templates/nvidiadriver.yaml</summary>

  ```diff
  -  version: {{ .Values.driver.version }}
  +  version: {{ .Values.driver.version | quote }}
  ```
  </details>

### 后续发展方向 [AI]
- 证据覆盖镜像清单+helm 值+模板,未见 ClusterPolicy/NVIDIADriver 的 `*_types.go` 字段增删(探测器报「无 API/CRD 路径命中」),故这是发行内容层(随附 driver 版本面)的推进,不是 CRD 能力演进。可盯的下一步是 610 分支是否随后带出对应的 precompiled 变体或 OS 矩阵扩展(本次仅镜像 digest,未见 driver-container 侧 OS 目录变化)。

## NVIDIA/nvidia-container-toolkit: cb5d6990 -> 26f29323
- 比较: cb5d6990 -> 26f29323 | ahead=4 | files=3 | Release: v1.20.0
- 比较页: https://github.com/NVIDIA/nvidia-container-toolkit/compare/cb5d6990b8069e8ad9bdb67f9a2b3ff832d9531c...26f29323af4658a1b97a97579ebc8e3cc5ec643b

### AI 总结重点(源码 diff 为据)
- **`transformPath` 前缀匹配改为路径组件边界匹配**。旧实现 `strings.HasPrefix(path, t.root)` 存在缺陷:root=`/driver` 会命中 `/driver-backup/lib.so`,`TrimPrefix` 后拼成 `{targetRoot}/-backup/lib.so`,把不该变换的兄弟目录错误重定向。新实现给 root 补尾部分隔符、并对 path 也补尾分隔符后再比较,既保证只在组件边界命中,又让「path 恰等于 root」的情形也能正确变换到 targetRoot。这是 CDI 生成时把宿主 driver 根路径重写进容器视图的核心逻辑,错误变换会导致库/设备路径挂错,属正确性兼安全边界修复。
  <details><summary>代码依据 pkg/nvcdi/transform/root/root.go</summary>

  ```diff
  -	if !strings.HasPrefix(path, t.root) {
  +	root := t.root
  +	if !strings.HasSuffix(root, string(filepath.Separator)) {
  +		root += string(filepath.Separator)
  +	}
  +	pathWithSeparator := path + string(filepath.Separator)
  +	if !strings.HasPrefix(pathWithSeparator, root) {
   		return path
   	}
  -	return filepath.Join(t.targetRoot, strings.TrimPrefix(path, t.root))
  +	return filepath.Join(t.targetRoot, strings.TrimPrefix(pathWithSeparator, root))
  ```
  </details>
- 配套新增 `root_test.go`(94 行)锁定了兄弟目录不变换、partial 组件不变换(`/driver` 不动 `/driverfoo`)、root 带尾斜杠、root=`/` 等边界用例,把这条不变式固化。
- README 补齐了三个既有 cdi-hook 的说明(非新代码,是文档补全):`enable-cuda-compat`、`disable-device-node-modification`(阻止容器内改 `/proc/driver/nvidia/params` 设备节点)、`update-application-profile`(通过 application profile 设 `EGLVisibleDGPUDevices` 限制容器内 EGL/Vulkan GPU 可见性)——对理解 toolkit 现有隔离/可见性控制面有参考价值。
  <details><summary>代码依据 cmd/nvidia-cdi-hook/README.md</summary>

  ```diff
  +* `enable-cuda-compat` - Ensure that the directory containing the CUDA compat libraries is added to the ldconfig search path if required.
  +* `disable-device-node-modification` - Ensure that the `/proc/driver/nvidia/params` file present in the container does not allow device node modifications.
  +* `update-application-profile` - Update driver settings through "application profiles". Currently, this hook sets `EGLVisibleDGPUDevices` to restrict EGL/Vulkan GPU visibility inside the container.
  ```
  </details>

### 后续发展方向 [AI]
- 证据只覆盖 root 变换函数+测试+文档,未见 hook 逻辑或 CDI spec 结构改动,故这是 CDI 生成正确性的收口,不是新能力。方向上 toolkit 把路径变换的边界不变式补测固化,说明其正在把 CDI 路径处理往「可回归验证」推;可盯后续是否把类似边界处理推广到 device/symlink 变换链的其它节点。

## NVIDIA/k8s-device-plugin: 43e8b82c -> 60b4e919
- 比较: 43e8b82c -> 60b4e919 | ahead=8 | files=81 | Release: v0.19.3
- 比较页: https://github.com/NVIDIA/k8s-device-plugin/compare/43e8b82cf79345b822e376d8f899009a270d038f...60b4e9192daf6725ba70e45252ff39ea1c768951

### AI 总结重点(源码 diff 为据)
- 唯一实质提交是 **"Add OCI standard image labels"**,纯镜像元数据/打包改动,零 device-plugin/time-slicing/MPS 逻辑变化(81 files 主要是 vendor/docs 噪声,信号文件仅 Dockerfile/workflow/Makefile)。Dockerfile 把旧的 ad-hoc LABEL 换成一整套 `org.opencontainers.image.*` 标准标签(source/title/vendor/version/created 等),并新增 `BUILD_TIMESTAMP` 构建参数注入 `created` 标签;workflow 把 `VERSION` 与带 arch 后缀的 `IMAGE_TAG` 拆开。属供应链/可追溯性打磨。
  <details><summary>代码依据 deployments/container/Dockerfile</summary>

  ```diff
  +ARG BUILD_TIMESTAMP
  ...
  -LABEL description="See summary"
  +LABEL org.opencontainers.image.source="https://github.com/NVIDIA/k8s-device-plugin.git"
  +LABEL org.opencontainers.image.created="${BUILD_TIMESTAMP}"
  +LABEL org.opencontainers.image.version="${VERSION}"
  ```
  </details>

### 后续发展方向 [AI]
- 证据仅镜像标签与构建参数,无 device-plugin 配置面/共享策略改动,本仓今日不承载能力信号。真正要盯的 time-slicing/MPS→DRA 迁移信号本次无。

## kubernetes-sigs/dra-driver-nvidia-gpu: d485fb70 -> ddc71625
- 比较: d485fb70 -> ddc71625 | ahead=8 | files=33 | Release: v0.4.1
- 比较页: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/d485fb70d00709811fba898acef76cf809b192b2...ddc71625fa872e49bbbe566a163f06ae3f990966

### AI 总结重点(源码 diff 为据)
- 本期改动**全是单测新增 + Go bump**,无 kubelet-plugin 运行逻辑改动:新增 `checkpoint_test.go`(182 行)、`types_test.go`(58 行),扩 `root_test.go`(+88),Dockerfile Go 1.26.5→1.26.6。功能行为不变,但测试固化了两处已存在的内部结构值得记录:
- checkpoint 存在 **V1/V2 双版本模型**,`ToLatestVersion()` 语义为「V2 存在则用 V2、V1 自动升级到 V2、两者都在时 V2 覆盖 V1」,V2 携带 `NodeBootID`(节点重启标识,用于 boot 后失效判定)——反映 DRA 驱动的 claim 状态持久化正在向带 boot-id 的 V2 checkpoint 演进。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/checkpoint_test.go</summary>

  ```diff
  +"v2 wins over v1 when both present": {
  +	in: &Checkpoint{
  +		V1: &CheckpointV1{PreparedClaims: PreparedClaimsByUIDV1{"uid-v1": {}}},
  +		V2: &CheckpointV2{NodeBootID: "boot-from-v2", PreparedClaims: PreparedClaimsByUID{"uid-v2": {}}},
  +	},
  +	wantBootID:   "boot-from-v2",
  ```
  </details>
- root 侧测试锁定 driver 库/二进制发现遵循 symlink(`libnvidia-ml.so.1` 经软链解析、软链指向目录/悬空软链均拒绝)、`getDevRoot` 存在 `dev` 目录才用其为 devRoot 否则回落 `/`——是 DRA 驱动在宿主根定位 driver 资产的既有行为被补测,非新逻辑。

### 后续发展方向 [AI]
- 证据全为测试与 Go 版本,未见 ResourceSlice/claim 分配算法改动,故这是 DRA 驱动补测试覆盖率的工程化动作。可从 V2 checkpoint 带 NodeBootID 推断其正把「节点重启后 prepared claim 失效」做成显式状态,后续值得盯 boot-id 失效逻辑是否落到 prepare/unprepare 主流程(本次仅见于测试数据结构)。

## 本期无实质改动(折叠)
<details><summary>5 仓无新提交 / 仅 bump·CI·merge</summary>

- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
- kai-scheduler/KAI-Scheduler(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=11ebba478e102088f2e77d58a3d41f5a28254522 branch=main release=v26.3.3 scanned=2026-08-19 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=26f29323af4658a1b97a97579ebc8e3cc5ec643b branch=main release=v1.20.0 scanned=2026-08-19 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=06a208ca9747c82b1ba99b76ecdcf2469b0a0207 branch=main release=— scanned=2026-08-19 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=60b4e9192daf6725ba70e45252ff39ea1c768951 branch=main release=v0.19.3 scanned=2026-08-19 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=ddc71625fa872e49bbbe566a163f06ae3f990966 branch=main release=v0.4.1 scanned=2026-08-19 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-19 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-19 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5c3505c4fe8170d06c726f90ef332c93131653f3 branch=main release=v0.14.5 scanned=2026-08-19 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=2914d320160fbb389f69a2c2968a0a6acefb9f76 branch=main release=v0.16.9 scanned=2026-08-19 -->
</content>

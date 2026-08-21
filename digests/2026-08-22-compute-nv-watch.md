# NVIDIA 算力栈 diff 雷达 2026-08-22

## 摘要
- **container-toolkit 补齐容器内 X.Org/图形栈可见性**:重构 `NewGraphicsMountsDiscoverer`,新增 `nvidia-xconfig` 二进制挂载,新增两个 EGL external-platform ICD(`20_nvidia_xcb.json`、`20_nvidia_xlib.json`,即 XCB/Xlib 平台),并把配置发现拆成"按标准容器路径重挂"逻辑——宿主机上装在非标准路径(如 `/usr/local/share`)的 nvidia 图形配置也会被挂到容器内 `/usr/share`(OpenCL icd 挂到 `/etc`),加载器才能发现。图形/远程渲染场景的可用性修复。
- **gpu-operator 修 manifest kind 解析的正确性坑**:把靠正则 `\b(\w*kind:\w*)\B.*\b` 抓 `kind:` 的老逻辑换成 `yaml.Unmarshal` 进 `metav1.TypeMeta` 的结构化解析,新增 `manifestKind()`。老正则会误命中 annotation 值里出现的 `kind:` 字样(新测试专门覆盖此 case);同时 Renovate 规则改为可通用更新所有 Dockerfile base 镜像 digest(不再只盯 golang 版本)。无 ClusterPolicy CRD 字段增删。
- 其余 7 仓无实质代码改动(mig-parted 仅 deps bump;device-plugin/dra-driver/dcgm/DCGM/KAI/driver-container 无新提交)。

## 当日重要改变
- NVIDIA/nvidia-container-toolkit [新能力·图形栈] 图形挂载发现器重构:新增 `nvidia-xconfig` 二进制挂载 + 两个 EGL external-platform ICD(`20_nvidia_xcb.json`/`20_nvidia_xlib.json`),并让非标准宿主路径的图形配置重定向挂载到容器内标准路径。证据 internal/discover/graphics.go。https://github.com/NVIDIA/nvidia-container-toolkit/compare/357b970814261fb17d9b4991b1d2636bce71d442...6429cdd3c1b40d6ea53bbee868a3e11f54d1f3a7
- NVIDIA/gpu-operator [正确性] manifest kind 探测从正则改结构化 `TypeMeta` 反序列化,修 annotation 内含 `kind:` 字样被误判的解析 bug。证据 controllers/resource_manager.go。https://github.com/NVIDIA/gpu-operator/compare/10ee5b3638b89e11e949412aafa5ba99279c3721...a22dbf671f2e26f9a1e342f8eea28e196235e110

## NVIDIA/nvidia-container-toolkit: 357b9708 -> 6429cdd3
- 比较: 357b970814261fb17d9b4991b1d2636bce71d442 -> 6429cdd3 | ahead=2 | files=2 | Release: v1.20.0
- 比较页: https://github.com/NVIDIA/nvidia-container-toolkit/compare/357b970814261fb17d9b4991b1d2636bce71d442...6429cdd3c1b40d6ea53bbee868a3e11f54d1f3a7

### AI 总结重点(源码 diff 为据)
- **图形挂载发现器结构重组:库/二进制/配置三路分开,新增 `nvidia-xconfig` 二进制**。原 `NewGraphicsMountsDiscoverer` 里 `configs`(基于 `driver.Configs()`)一把梭,现拆为 `libraries` + `binaries`(用 `ExecutableLocator` 定位 `nvidia-xconfig`)+ `newGraphicsConfigsDiscoverer` + `newVulkanConfigsDiscover` 四路 Merge。新增 xconfig 二进制意味着容器内可跑 X.Org 配置工具。
  <details><summary>代码依据 internal/discover/graphics.go</summary>

  ```diff
  -	configs := NewMounts(
  +	binaries := NewMounts(
   		logger,
  -		driver.Configs(),
  +		lookup.NewExecutableLocator(logger, driver.Root),
   		driver.Root,
   		[]string{
  +			"nvidia-xconfig",
  +		},
  +	)
  +	discover := Merge(
  +		libraries,
  +		binaries,
  +		newGraphicsConfigsDiscoverer(logger, driver),
  +		newVulkanConfigsDiscover(logger, driver),
  +	)
  ```
  </details>

- **新增 XCB/Xlib 两个 EGL external-platform ICD,并按"容器标准路径"重挂配置**。`newGraphicsConfigsDiscoverer` 用 `mountsToContainerPath{containerRoot: "/usr/share"}` 声明一组图形配置(glvnd egl_vendor、egl external_platform、nvoptix、X11 xorg.conf.d),其中**新增** `20_nvidia_xcb.json`、`20_nvidia_xlib.json`;OpenCL `nvidia.icd` 单独归到 `containerRoot: "/etc"`。关键语义:宿主机把这些文件装在非标准路径时,也会被挂到容器内的**标准位置**(测试用例证实 `/usr/local/share/...` → `/usr/share/...`),让容器内加载器无条件发现。全部配置发现器加了 `WithCache`。
  <details><summary>代码依据 internal/discover/graphics.go</summary>

  ```diff
  +	shareConfigs := WithCache(&mountsToContainerPath{
  +		locator: driver.Configs(),
  +		required: []string{
   			"glvnd/egl_vendor.d/10_nvidia.json",
   			"egl/egl_external_platform.d/15_nvidia_gbm.json",
  +			"egl/egl_external_platform.d/20_nvidia_xcb.json",
  +			"egl/egl_external_platform.d/20_nvidia_xlib.json",
   			"X11/xorg.conf.d/10-nvidia.conf",
  -			"OpenCL/vendors/nvidia.icd",
   		},
  +		containerRoot: "/usr/share",
  +	})
  +	etcConfigs := WithCache(&mountsToContainerPath{
  +		required: []string{"OpenCL/vendors/nvidia.icd"},
  +		containerRoot: "/etc",
  +	})
  ```
  </details>

### 后续发展方向 [AI]
- 证据覆盖 graphics.go 的发现器重构与 ICD 清单变化两处 hunk,未逐行读 graphics_test.go(+74)的全部断言。方向:container-toolkit 在把"容器内跑 X.Org/图形应用"这条路径做扎实——从只挂库,到挂配置工具二进制 + 补齐 XCB/Xlib EGL 平台 + 强制配置落到容器标准路径。这利好在容器里跑桌面/可视化/远程渲染的场景(非纯 compute)。证据只覆盖发现逻辑,未见 CDI spec 或 runtime hook 侧改动。

## NVIDIA/gpu-operator: 10ee5b36 -> a22dbf67
- 比较: 10ee5b3638b89e11e949412aafa5ba99279c3721 -> a22dbf67 | ahead=3 | files=3 | Release: v26.3.3
- 比较页: https://github.com/NVIDIA/gpu-operator/compare/10ee5b3638b89e11e949412aafa5ba99279c3721...a22dbf671f2e26f9a1e342f8eea28e196235e110

### AI 总结重点(源码 diff 为据)
- **manifest kind 探测从脆弱正则改为结构化 `TypeMeta` 反序列化(正确性)**。`addResourcesControls` 原先用 `regexp.MustCompile(`\b(\w*kind:\w*)\B.*\b`)` 在 manifest 字符串里抓第一处 `kind:` 再 split 取值——这会把 annotation 值里出现的 `kind:` 字样误当成资源 Kind。现新增 `manifestKind()`,用 `sigs.k8s.io/yaml` 反序列化到 `metav1.TypeMeta` 取 `.Kind`,并对空 Kind/解析失败显式报错(`panicIfError`)。新增测试专门覆盖 "kind-like text in another field" 与 JSON manifest 两种情形。
  <details><summary>代码依据 controllers/resource_manager.go</summary>

  ```diff
  +func manifestKind(manifest []byte) (string, error) {
  +	typeMeta := metav1.TypeMeta{}
  +	if err := yaml.Unmarshal(manifest, &typeMeta); err != nil {
  +		return "", fmt.Errorf("failed to decode manifest metadata: %w", err)
  +	}
  +	if typeMeta.Kind == "" {
  +		return "", fmt.Errorf("manifest is missing kind")
  +	}
  +	return typeMeta.Kind, nil
  +}
   ...
  -	reg := regexp.MustCompile(`\b(\w*kind:\w*)\B.*\b`)
   	for _, m := range manifests {
  -		kind := reg.FindString(string(m))
  -		slce := strings.Split(kind, ":")
  -		kind = strings.TrimSpace(slce[1])
  +		kind, err := manifestKind(m)
  +		panicIfError(err)
  ```
  </details>

- **Renovate 规则通用化,覆盖所有 Dockerfile base 镜像 digest(供应链/构建)**。`.github/renovate.json` 的 custom.regex 从只匹配 `FROM golang:X.Y.Z`(datasource `golang-version`)改为通用 `FROM <depName>:<ver>@sha256:<digest>` 捕获 depName/currentValue/currentDigest,datasource 改 `docker`;Go toolchain 分组的 matchPackageNames/matchDatasources 也扩到 `["go","golang"]`/`["golang-version","docker"]`。配合前几日"把 base 镜像钉 @sha256"的改动,Renovate 现能自动滚动这些 digest。
  <details><summary>代码依据 .github/renovate.json</summary>

  ```diff
  -        "FROM golang:(?<currentValue>\\d+\\.\\d+\\.\\d+)"
  +        "FROM (?<depName>\\S+):(?<currentValue>[^\\s@]+)@(?<currentDigest>sha256:[a-f0-9]{64})"
  -      "depNameTemplate": "go",
  -      "datasourceTemplate": "golang-version",
  +      "datasourceTemplate": "docker"
  ```
  </details>

### 后续发展方向 [AI]
- 证据覆盖 resource_manager.go 的 kind 解析改造与 renovate.json 两处 hunk。本窗口 operator 是纯工程质量修复(解析健壮性 + 构建期依赖自动化),无 ClusterPolicy/NVIDIADriver CRD 字段变化、无运行时能力增删(探测器报"无 API/CRD 路径命中")。承接昨日 v26.7.0 发版工程,可继续盯 26.7.0 正式发版时 CRD 是否随子组件新增字段。

## 本期无实质改动(折叠)
<details><summary>7 仓无实质代码改动(EMPTY / 仅 deps bump / 无新提交)</summary>

- NVIDIA/mig-parted(ahead=2/files=2,唯一提交是 `[deps] bump x/net, x/text and x/mod`——仅 go.mod/go.sum 依赖升级,无信号文件、无代码 hunk;HEAD 从 e2d5ad1f 前进到 bd7160f4,锚点已更新)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交,release 停在 v0.20.0)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交,release v0.5.0)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交,branch=master)
- kai-scheduler/KAI-Scheduler(无新提交,release v0.14.8)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=a22dbf671f2e26f9a1e342f8eea28e196235e110 branch=main release=v26.3.3 scanned=2026-08-22 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=6429cdd3c1b40d6ea53bbee868a3e11f54d1f3a7 branch=main release=v1.20.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=06a208ca9747c82b1ba99b76ecdcf2469b0a0207 branch=main release=— scanned=2026-08-22 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1b826acc6af3079d8923bac395c3124b8861a9a6 branch=main release=v0.20.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=d682267c7dd84a76c61663feeaf36d04ac6ebfef branch=main release=v0.5.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-22 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-08-22 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=bd7160f43f16462eeb21e1eda5e67b5b6b03fd7d branch=main release=v0.15.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=2914d320160fbb389f69a2c2968a0a6acefb9f76 branch=main release=v0.14.8 scanned=2026-08-22 -->
</content>
</invoke>

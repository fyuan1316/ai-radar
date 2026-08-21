# 昇腾算力栈 diff 雷达 2026-08-21

## 摘要
- **ascend-docker-runtime 打通"UB(Unified Bus / URMA 超低时延网络)驱动用户态库自动挂载"**:新增 `ub_driver.list`(libummu*/liburma*/urma/libnl*/urma_admin 等),安装脚本仅在宿主存在 `/sys/class/unified_bus`(即有 UB fabric 硬件)时下发该清单;prestart hook 依据环境变量 `DisableUBMountEnv` 与清单是否存在,决定把 UB 用户态库挂进容器——为多机训练走 UB fabric 的容器补齐用户态运行库。
- **配套的挂载安全硬化**:`readMountConfig` 支持 glob 通配(`*?[` → `filepath.Glob` + `EvalSymlinks`,且匹配项必须与 pattern 同目录),并新增 `checkSymlinkOwner`——符号链接及其 target 必须均属 root(UID 0)才允许挂载,否则跳过。UB 库多为通配 + 符号链接,这是把它们安全展开的前置。
- **injection-mode 配置源从运行时 `config.json` 迁到安装期 `install.info`**:runtime 不再读/写 `/etc/ascend-docker-runtime.d/config.json`,改为读可执行文件同目录的 `ascend_docker_runtime_install.info`(key=value,`injection-mode` 键),由 installer 在部署时写入。CDI/legacy 注入模式回归"安装期一次决定、单一事实源"。

## 当日重要改变
- mind-cluster [新能力] ascend-docker-runtime 支持 UB 驱动用户态文件自动挂载(URMA 超低时延网络多机训练底座),证据:新增 `component/ascend-docker-runtime/build/scripts/ub_driver.list`、`run_main.sh` 的 `prepare_ub_driver_list`、`hook/process/process.go` 的 `shouldMountUBDriverFiles`/`parseDisableUBMount`。 https://gitcode.com/Ascend/mind-cluster/compare/5fcb7b99c3f3662fa33a9acd62e4c2465863c895...98533d14f12746d39a27efb40549fbbc44d98a59
- mind-cluster [安全硬化] 挂载路径支持 glob 通配同时新增符号链接 root 属主校验(`expandGlobPath` + `checkSymlinkOwner`),防止经非 root 符号链接把非预期文件挂进容器。链接同上。
- mind-cluster [架构方向] injection-mode 从运行时 `config.json` 迁到安装期 `install.info`,`config.go` 改读 `os.Executable()` 同目录的 install.info,`run_main.sh` 安装/升级不再写 config.json、卸载不再删。链接同上。
- mind-cluster [新能力](commit 标题信号,本次 patch 节选未覆盖 `cdi/` 目录,不展开)`feat(cdi): add HostRoot path validation and configurable spec version/kind`——CDI 注入模式增加 HostRoot 路径校验与可配置 spec version/kind。链接同上。

## mind-cluster: 5fcb7b99 -> 98533d14
- 比较: 5fcb7b99..98533d14 | tag: v26.1.0 | commits=20 | truncated=false
- 本 task 8 个 component PATHPREFIX 内,本期仅 `component/ascend-docker-runtime` 有实质代码改动(其余命中的 infer-operator/FD 提交均为文档或本 task 范围外文件)。
- https://gitcode.com/Ascend/mind-cluster/compare/5fcb7b99c3f3662fa33a9acd62e4c2465863c895...98533d14f12746d39a27efb40549fbbc44d98a59

### AI 总结重点(源码 diff 为据)
- **UB 驱动用户态库清单 + 硬件门控下发**:新增 `ub_driver.list` 列出 URMA/UB 用户态运行库与工具(`libummu*`/`liburma*`/`/usr/lib64/urma`/`libnl*`/`urma_admin`/`urma_perftest`/`urma_ping`);`run_main.sh` 新增 `prepare_ub_driver_list`——**仅当宿主存在 `/sys/class/unified_bus`(即节点装了 UB fabric)** 时才把该清单拷进 runtime 配置目录并置 440,无 UB 硬件的节点不下发。构建脚本 `build.sh`/`build_pkg` 同步把 ub_driver.list 打进 run 包。
  <details><summary>代码依据 component/ascend-docker-runtime/build/scripts/run_main.sh / ub_driver.list(新增)</summary>

  ```diff
  +readonly UNIFIED_BUS_DIR="/sys/class/unified_bus"
  +function prepare_ub_driver_list() {
  +    if [[ -d "${UNIFIED_BUS_DIR}" ]]; then
  +        check_path ${ASCEND_RUNTIME_CONFIG_DIR}/ub_driver.list
  +        cp -f ./ub_driver.list ${ASCEND_RUNTIME_CONFIG_DIR}/ub_driver.list
  +        chmod 440 ${ASCEND_RUNTIME_CONFIG_DIR}/ub_driver.list
  +    fi
  +}
  # ub_driver.list:
  +/usr/lib64/libummu*
  +/usr/lib64/liburma*
  +/usr/lib64/urma
  +/usr/lib64/libnl*
  +/usr/bin/urma_admin
  ```
  </details>
- **prestart hook:按环境变量 + 清单存在性决定是否挂 UB 库,并强制放开软链**:`DoPrestartHook` 新增 `parseDisableUBMount(getValueByKey(env, api.DisableUBMountEnv))`("True"→禁用、""/"False"→启用、其他→报错);`shouldMountUBDriverFiles` 在未禁用且 `ubConfigFilePath` 存在时返回 true,则把 `ub_driver` 追加进 `mountConfigs`。**关键交互**:当 `allowLink=="False"` 却需要挂 UB 库时,强制把 `allowLink` 设回 `"True"`——因为 UB 用户态库(libummu*/liburma*)是符号链接,不放开软链就挂不进去。`process.go` 另把 `/usr/lib64` 加进 `ascendDriverLibPaths`。
  <details><summary>代码依据 component/ascend-docker-runtime/hook/process/process.go</summary>

  ```diff
  +	disableUBMount, err := parseDisableUBMount(getValueByKey(containerConfig.Env, api.DisableUBMountEnv))
  +	if shouldMountUBDriverFiles(disableUBMount) {
  +		mountConfigs = append(mountConfigs, ubDriverConfig)   // ubDriverConfig = "ub_driver"
  +	}
  ...
  +	if allowLink == "False" && shouldMountUBDriverFiles(disableUBMount) {
  +		hwlog.RunLog.Warnf("need UB driver files mounting, but allow link is False, will set allow link to True")
  +		allowLink = "True"
  +	}
  ```
  </details>
- **挂载路径新增 glob 展开 + 符号链接 root 属主校验(安全)**:`readMountConfig` 遇到含 `*?[` 的路径先走 `expandGlobPath`——`filepath.Glob` 匹配后逐个 `EvalSymlinks`,并要求解析出的真实路径**与 pattern 同目录**(`expectedDir` 校验,防止通配跨目录逃逸);新增 `checkSymlinkOwner`:若挂载项是符号链接,则符号链接自身与其 target 必须**均属 root(UID 0)**,否则跳过。避免容器借非 root 符号链接把宿主非预期文件挂入。这是 UB 库(通配 + 符号链接)能被安全挂载的前置硬化。
  <details><summary>代码依据 component/ascend-docker-runtime/hook/process/process.go</summary>

  ```diff
  +	if containsGlob(mountPath) {                       // strings.ContainsAny(path, "*?[")
  +		fileList, dirList := expandGlobPath(mountPath)
  +		fileMountList = append(fileMountList, fileList...)
  +		continue
  +	}
  +	if !checkSymlinkOwner(mountPath, stat) { continue }
  ...
  +func checkSymlinkOwner(match string, realStat os.FileInfo) bool {
  +	linkStat, _ := os.Lstat(match)
  +	if linkStat.Mode()&os.ModeSymlink == 0 { return true }   // 非软链直接放行
  +	if getFileUID(linkStat) != 0 || getFileUID(realStat) != 0 {
  +		return false                                          // 软链或 target 非 root → 拒挂
  +	}
  ```
  </details>
- **injection-mode 配置源:运行时 config.json → 安装期 install.info**:`config.go` 的 `Config.InjectionMode` 从读 JSON 文件 `api.RunTimeDConfigPath+"/config.json"` 改为读**可执行文件同目录**的 `ascend_docker_runtime_install.info`(`os.Executable()` 定位,`installInfoPath` 惰性解析、可测试覆写),按 key=value 解析 `injection-mode` 键。`run_main.sh` 的 install/upgrade 删掉写 `config.json` 的分支、uninstall 删掉 `rm config.json`;README 改为"用 `--injection-mode=cdi` 安装,模式记录在 install.info"。注入模式回归"安装期一次决定、单一事实源",运行时不再可篡改。
  <details><summary>代码依据 component/ascend-docker-runtime/runtime/process/config.go</summary>

  ```diff
  -type Config struct { InjectionMode string `json:"injectionMode"` }
  -var configFilePath = api.RunTimeDConfigPath + "/config.json"
  +type Config struct { InjectionMode string }
  +const installInfoFileName = "ascend_docker_runtime_install.info"
  +const injectionModeKey    = "injection-mode"
  +var installInfoPath = resolveInstallInfoPath   // os.Executable() 同目录
  -	data, err := os.ReadFile(configFilePath)     // 旧:读 JSON
  +	file, err := os.Open(filePath)               // 新:逐行读 install.info key=value
  ```
  </details>

### 后续发展方向 [AI]
- ascend-docker-runtime 这批的主线是 **UB/URMA 超低时延 fabric 的容器化落地**:runtime 补齐用户态库自动挂载(硬件门控 + 可 env 禁用 + 强制放开软链),与本 task 里长期 EMPTY 的 `ub-network-device-plugin`(内核态/设备面)形成"用户态库 + 设备插件"两端。方向是把 UB fabric 从主机级能力下沉成容器内可直接用的多机训练网络。证据覆盖 ub_driver.list + hook 挂载逻辑 + 硬件门控;未见 UB 设备号/网络拓扑如何暴露给容器(应在 ub-network-device-plugin 侧,本期该仓无提交)。
- 挂载子系统这次同时补 glob 与符号链接属主校验,说明 runtime 正把"挂什么进容器"从固定列表推向"通配 + 安全约束"的通用机制——UB 是第一个受益场景,后续 CANN/驱动库若也用通配清单可复用。证据仅覆盖 `expandGlobPath`/`checkSymlinkOwner` 两函数与其在 readMountConfig 的接入点,未见对已有 base.list 挂载路径的行为回归影响评估。
- injection-mode 迁到 install.info 是**安装态与运行态职责再切分**的信号:凡"安装期决定、运行期不应改"的参数(注入模式,未来可能含 UB 开关的默认值)都收敛到 installer 写的安装记录。证据覆盖 config.go/run_main.sh/README 三处;`DisableUBMountEnv` 目前仍走容器环境变量(运行期),尚未并入 install.info,二者边界待观察。

## 本期无实质改动(折叠)
- **vNPU**:本期 2 个提交(`!90 feat: add local build with NPU model selection` 等)均为**构建工具链/文档**改动,无功能 Go 代码:新增宿主机本地构建脚本 `ci/build.sh`(检测 CANN/HDK 环境、分组件编译打 tar+chart)、各 Dockerfile 引入 `LOCAL_ARTIFACTS=true` 跳过容器内编译复用 `ci/output/` 产物、构建基础镜像从定制 `golang:1.24.5-vnpu-cann-8.5.1-hdk-25.5.1` 换成通用 `golang:1.25.0`(编译移到宿主机做)、docs/user-guide 补本地构建说明、design 文档把 `vxpu`→`vnpu` 命名订正。均不涉及 vNPU 切分/调度能力,不展开。
- npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin —— 均无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=98533d14f12746d39a27efb40549fbbc44d98a59 tag=v26.1.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b33edd6dc28f0dc96f908ee7de414af931bb8fe1 tag=v26.6.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-21 -->

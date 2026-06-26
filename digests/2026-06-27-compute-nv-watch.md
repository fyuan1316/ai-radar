# NVIDIA 算力栈 diff 雷达 2026-06-27

## 摘要
- **gpu-driver-container 把驱动 OS 矩阵推进到 Ubuntu 26.04(resolute)**:新增 `ubuntu26.04/precompiled/` 整套预编译构建(nvidia-driver init 脚本 + 本地 apt 仓 + Dockerfile),CI 矩阵加入 7.0 LTS 内核 / 595 驱动分支,580 分支显式排除——这是下一代 LTS 内核+驱动的预热信号。
- **nvidia-container-toolkit 收紧 CDI ldconfig hook 生成**:没发现任何库目录时不再注入 update-ldcache hook(返回 nil),且 hook 改为带 `--folder` 精确指定库目录,而非空跑全局 ldconfig。
- **dra-driver-nvidia-gpu 仅文档**:为 v0.4.1 补 helm 升级路径与 hugo 版本参数化,无 API/代码改动(BootID checkpoint、ComputeDomain numNodes 可选等为 v0.4.0 既有特性的回顾)。

## 当日重要改变
- NVIDIA/gpu-driver-container [新能力] 新增 Ubuntu 26.04(resolute)预编译驱动容器全套构建,并把 7.0 LTS 内核纳入预编译矩阵;595 为该 dist 起始驱动分支(580 排除)。证据 `ubuntu26.04/precompiled/Dockerfile`、`.github/precompiled-matrix-config.json`、`Makefile`。 https://github.com/NVIDIA/gpu-driver-container/compare/d13e99f038cf9943c73e53e2b17af34883ae3ae3...f41a0200e00d232bd7e257b22600883346eea079
- NVIDIA/gpu-driver-container [新能力] vgpu-manager 支持构建期注入自定义 CA 证书(`CUSTOM_CA_CERTS_DIR` build arg + 各 OS `certs/` 目录),解决 TLS 拦截代理(MITM)环境下 apt/dnf 证书校验失败。证据 `Makefile`、`vgpu-manager/README.md`。 https://github.com/NVIDIA/gpu-driver-container/commit/f41a0200e00d232bd7e257b22600883346eea079
- NVIDIA/nvidia-container-toolkit [架构方向] CDI update-ldcache hook 改为"按需生成":无库目录则不注入,有则用 `--folder` 精确限定,缩小容器内 ldconfig 副作用面。证据 `internal/discover/ldconfig.go`。 https://github.com/NVIDIA/nvidia-container-toolkit/commit/41dd4444a23ffc387262e7159b4696fb688553a2

## NVIDIA/gpu-driver-container: d13e99f0 -> f41a0200
- 比较 / Release: https://github.com/NVIDIA/gpu-driver-container/compare/d13e99f038cf9943c73e53e2b17af34883ae3ae3...f41a0200e00d232bd7e257b22600883346eea079 | ahead=10 | files=22 | Release: —

### AI 总结重点(源码 diff 为据)
- **新增 Ubuntu 26.04(代号 resolute)预编译驱动容器**:`ubuntu26.04/precompiled/` 下新增 536 行 `nvidia-driver` init 脚本(含 NVLink5/NVSwitch 探测、fabricmanager/nscq/imex/nvlsm/nvsdm 安装)、`local-repo.sh`(把驱动及依赖 `apt-get download` 到本地 repo 后离线安装)、`Dockerfile`(基镜像 `ubuntu:resolute-*`,默认 `DRIVER_BRANCH=595 / DRIVER_VERSION=595.71.05 / KERNEL_VERSION=7.0.0-12-generic`)。
  <details><summary>代码依据 ubuntu26.04/precompiled/Dockerfile</summary>

  ```diff
  +ARG BASE_IMAGE=ubuntu:resolute-20260610
  +ARG DRIVER_BRANCH=595
  +ARG DRIVER_VERSION=595.71.05
  +ARG KERNEL_VERSION=7.0.0-12-generic
  +RUN mkdir -p /usr/local/repos && \
  +    /tmp/local-repo.sh download_driver_package_deps && \
  +    /tmp/local-repo.sh build_local_apt_repo && \
  +    /tmp/local-repo.sh fetch_nvidia_installer && \
  +    rm /etc/apt/sources.list.d/*
  +ENTRYPOINT ["nvidia-driver", "init"]
  ```
  </details>
- **构建系统与 CI 矩阵纳入 26.04 / 7.0 内核**:`Makefile` 的 `DISTRIBUTIONS` 加 `signed_ubuntu26.04`、`BASE_FROM` 加 `resolute`;`precompiled-matrix-config.json` 把 dist 扩到 `ubuntu26.04`、lts_kernel 加 `7.0`,并排除 580 分支构建 26.04(595 起步),同时排除 7.0×24.04、5.15/6.8×26.04 等不匹配组合。
  <details><summary>代码依据 .github/precompiled-matrix-config.json</summary>

  ```diff
  -  "dist": ["ubuntu22.04", "ubuntu24.04"],
  -  "lts_kernel": ["5.15", "6.8"],
  -  "exclude_build_matrix_pairs": [],
  +  "dist": ["ubuntu22.04", "ubuntu24.04", "ubuntu26.04"],
  +  "lts_kernel": ["5.15", "6.8", "7.0"],
  +  "exclude_build_matrix_pairs": [
  +    { "dist": "ubuntu26.04", "driver_branch": "580" }
  +  ],
  ```
  </details>
- **vgpu-manager 增加构建期自定义 CA 注入**:新增 `CUSTOM_CA_CERTS_DIR` build arg(默认空目录 `certs`,COPY 默认为 no-op),各 OS 下新增 `certs/.gitkeep`;面向企业 MITM 代理环境,无需改 Dockerfile 即可信任私有根证书。
  <details><summary>代码依据 Makefile / vgpu-manager/README.md</summary>

  ```diff
  +CUSTOM_CA_CERTS_DIR ?= certs
  ...
  +				--build-arg CUSTOM_CA_CERTS_DIR="$(CUSTOM_CA_CERTS_DIR)" \
  ```
  ```diff
  +### Building behind a TLS-intercepting (MITM) proxy
  +drop one or more PEM-encoded `*.crt` files into the `certs/` directory
  +inside the OS-specific build context (`vgpu-manager/<os>/certs/`)
  ```
  </details>

### 后续发展方向 [AI]
- 驱动容器栈正为 **Ubuntu 26.04 + 7.0 LTS 内核 + 595 驱动分支**铺路,预编译(signed)路径优先;预期 gpu-operator 侧后续会把 26.04 加入 driver toolkit 镜像 tag 矩阵(本期 gpu-operator EMPTY,尚未跟进)。证据只覆盖 driver-container 构建侧,未见 operator 编排侧改动。
- CA 注入与 NVLink5/NVSwitch/imex 安装逻辑表明对**超节点(NVL domain)+企业受控网络**场景的工程化加深;证据只在构建脚本层,未见运行时拓扑发现改动。

## NVIDIA/nvidia-container-toolkit: d0bf15cb -> 41dd4444
- 比较 / Release: https://github.com/NVIDIA/nvidia-container-toolkit/compare/d0bf15cb4bc7a6ad527752adb05df6e096d95a4f...41dd4444a23ffc387262e7159b4696fb688553a2 | ahead=2 | files=5 | Release: v1.19.1

### AI 总结重点(源码 diff 为据)
- **`ldconfig.Hooks()` 在无库目录时短路返回 `nil, nil`**:此前即使 `libraryFolders` 为空也会创建一个 `update-ldcache` CDI hook;现在发现不到库就不注入 hook,避免容器内无谓地跑 ldconfig。
  <details><summary>代码依据 internal/discover/ldconfig.go</summary>

  ```diff
   	libraryFolders := uniqueFolders(getLibraryPaths(mounts))
  +	if len(libraryFolders) == 0 {
  +		return nil, nil
  +	}
   	return d.hookCreator.Create(UpdateLDCacheHook, libraryFolders...).Hooks()
  ```
  </details>
- **测试印证 hook 现在携带 `--folder` 精确目录**:由测试期望可见,update-ldcache hook 参数从裸 `update-ldcache` 变为带 `--folder /usr/lib/aarch64-linux-gnu/nvidia` 等具体路径,即把 ldcache 更新限定到实际挂载的库目录。
  <details><summary>代码依据 pkg/nvcdi/lib-csv_test.go(测试,反映行为)</summary>

  ```diff
  -							Args:     []string{"nvidia-cdi-hook", "update-ldcache"},
  +							Args:     []string{"nvidia-cdi-hook", "update-ldcache", "--folder", "/usr/lib/aarch64-linux-gnu/nvidia"},
  ```
  </details>

### 后续发展方向 [AI]
- CDI 生成器朝**最小化容器内副作用**收敛:hook 只在有库时生成、且精确到目录。利好只挂少量库的精简注入(如纯 CUDA runtime 容器)。证据仅在 ldconfig discover 路径,未见 create-symlinks 等其他 hook 的同类收窄。

## NVIDIA/dra-driver-nvidia-gpu: 74b77854 -> a89291ec
- 比较 / Release: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/74b778541393353adbc6bd33b6a9839b04e077e4...a89291ec6dfffaf06d6bb3f9b46231c36086007e | ahead=2 | files=4 | Release: v0.4.1-rc.1

### AI 总结重点(源码 diff 为据)
- **纯文档:为 v0.4.1 发布更新升级/安装指引并参数化版本号**。`site/hugo.toml` 新增站点参数 `driver_version="0.4.1"` / `driver_release_tag="v0.4.1"`,install/upgrade 文档改用 `{{< param "driver_version" >}}` 模板,后续改版本只需改一处。upgrade.md 新增 v0.4.0→v0.4.1 的 helm upgrade 段(`--version` + `--set gpuResourcesEnabledOverride=true`)。**本期无 API/CRD/代码改动**(API/CRD 路径探测为空)。
  <details><summary>代码依据 site/hugo.toml</summary>

  ```diff
  +  # Latest published release. Update both when cutting a new release.
  +  driver_version = "0.4.1"       # Helm chart version (no "v" prefix; used with --version)
  +  driver_release_tag = "v0.4.1"  # GitHub release tag (used for source links)
  ```
  </details>
- 文档中回顾的"checkpoint 加 `BootID` 字段、`ComputeDomain` API 允许 `numNodes` 省略、chart 转 SemVer、v0.4.0 起不可降级"等均为 **v0.4.0 既有变更的复述**,非本期新代码,仅作上下文。

### 后续发展方向 [AI]
- DRA 驱动进入 **v0.4.x 文档/发布工程打磨期**,版本参数化降低发版成本;实质能力(ComputeDomain/IMEX、BootID checkpoint)上期已落地,本期无新增。证据仅 docs 与 hugo 配置,未见 `cmd/`、`api/`、helm 模板改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅 bump/CI/merge 或无新提交)</summary>

- NVIDIA/gpu-operator(ahead=4,仅 bump/CI/merge;ClusterPolicy CRD 无改动)
- NVIDIA/k8s-device-plugin(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/mig-parted(无新提交)
- kai-scheduler/KAI-Scheduler(ahead=1,仅 bump/CI/merge)
- NVIDIA/DCGM(master,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=a02dd1afd1bd394f74f667a7968a6cd42e527525 branch=main release=v26.3.3 scanned=2026-06-27 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=41dd4444a23ffc387262e7159b4696fb688553a2 branch=main release=v1.19.1 scanned=2026-06-27 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=f41a0200e00d232bd7e257b22600883346eea079 branch=main release=— scanned=2026-06-27 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=25e493580ca8d18413c7ec6a912d3bd2af2b135a branch=main release=v0.19.3 scanned=2026-06-27 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=a89291ec6dfffaf06d6bb3f9b46231c36086007e branch=main release=v0.4.1-rc.1 scanned=2026-06-27 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-27 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5dc3caa478807fec0fc6a2160ef9e8f056300e4e branch=main release=v0.14.2 scanned=2026-06-27 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=58708edb4083f81b35a3656327c021889f0d0829 branch=main release=v0.16.0 scanned=2026-06-27 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-27 -->

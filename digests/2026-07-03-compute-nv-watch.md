# NVIDIA 算力栈 diff 雷达 2026-07-03

## 摘要
- **gpu-driver-container 把昨天刚推的驱动分支补丁位 580.173.02 整体回退到 580.167.08**(Revert "containerize 580trd11"),CI matrix / versions.mk / PUBLISH_VERSIONS / image.yaml 全线同步——580.173.02 这个 datacenter 分支版本被撤下,预编译/发布重新钉回 580.167.08。
- **KAI-Scheduler 落地 Karta 集成设计文档**:为没有专属 pod-grouper 插件的工作负载提供声明式(no-code)分组路径,新增 `PodGroupDefinitionV2` / `GangSchedulingInstruction.podGroup` API 形态,native 插件优先、Karta 兜底、default grouper 最后——KAI 可扩展性方向信号。
- nvidia-container-toolkit driver 镜像构建支持 Podman;KAI 顺带删掉冗余 NaN 校验(ParseQuantity 已覆盖);dra-driver 仅文档改版无代码变更。其余 5 仓无实质改动。

## 当日重要改变
- NVIDIA/gpu-driver-container [版本回退] driver datacenter 分支从 580.173.02 回退到 580.167.08,撤销昨日 "containerize 580trd11",覆盖 5 处 CI/构建定义 https://github.com/NVIDIA/gpu-driver-container/compare/25b232fc...5f8425f3
- kai-scheduler/KAI-Scheduler [架构方向] 新增 `docs/developer/designs/Kai-no-code-grouping.md`,定义 Karta 声明式分组集成与 `PodGroupDefinitionV2` API 形态 https://github.com/kai-scheduler/KAI-Scheduler/pull/1773

## NVIDIA/gpu-driver-container: 25b232fc -> 5f8425f3
- 比较 / 最新 Release:25b232fc -> 5f8425f3 | ahead=8 | files=7 | Release: —
### AI 总结重点(源码 diff 为据)
- **driver 版本变量全线从 `580.173.02` 回退到 `580.167.08`**:`.common-ci.yml` 的 `DRIVER_VERSIONS`、三处 `.driver-versions*` parallel matrix、`versions.mk` 的 `DRIVER_VERSIONS ?=`、`.nvidia-ci.yml` 的 `PUBLISH_VERSIONS`、`.github/workflows/image.yaml` 的 driver matrix 全部改回旧补丁位。595.71.05 分支不动。这是对昨日 digest 记录的 "580.167.08→580.173.02 bump" 的完整撤销(Revert "containerize 580trd11"),说明 580.173.02 的容器化未通过验证被撤下。
  <details><summary>代码依据 .common-ci.yml / versions.mk</summary>

  ```diff
  -  DRIVER_VERSIONS: 580.173.02 595.71.05
  +  DRIVER_VERSIONS: 580.167.08 595.71.05
  -      - DRIVER_VERSION: [580.173.02, 595.71.05]
  +      - DRIVER_VERSION: [580.167.08, 595.71.05]
  -  PUBLISH_VERSIONS: 580.173.02
  +  PUBLISH_VERSIONS: 580.167.08
  ```
  </details>
- **renovate `allowedVersions` 正则放宽**:ubuntu22.04(jammy)/24.04(noble)的 base image tag 校验从 `-\d{8}` 扩展为 `-\d{8}(\.\d+)?`,即允许 `noble-20260509.1` 这类带小数后缀的日期 tag——配套下面 base image bump。
  <details><summary>代码依据 .github/renovate.json / ubuntu24.04/Dockerfile</summary>

  ```diff
  -            "allowedVersions": "/^noble(-\\d{8})?$/"
  +            "allowedVersions": "/^noble(-\\d{8}(\\.\\d+)?)?$/"
  -ARG BASE_IMAGE=ubuntu:noble-20260410
  +ARG BASE_IMAGE=ubuntu:noble-20260509.1
  ```
  </details>
### 后续发展方向 [AI]
- 580.173.02 被撤回意味着该分支的容器化(可能是 precompiled 或依赖矩阵)存在问题,短期 NVIDIA 会继续以 580.167.08 作为 580 datacenter 分支的落地版本;后续若再见 580.173.x 回归需关注其是否解决了本次回退暴露的问题。证据只覆盖版本变量与 base image bump,未见回退具体触发的构建失败细节。

## kai-scheduler/KAI-Scheduler: 6fc7f975 -> bb9f733e
- 比较 / 最新 Release:6fc7f975 -> bb9f733e | ahead=2 | files=3 | Release: v0.16.2
### AI 总结重点(源码 diff 为据)
- **新增 Karta 集成设计文档,给出声明式 no-code pod-grouping 路径**:workload owner 无需写专属 pod-grouper 插件,由 Karta 描述 workload 结构、KAI 翻译成标准 PodGroup/SubGroup/topology 约束。pod-grouper 选择顺序:native 插件命中 GVK 优先 → 否则匹配 Karta 定义 → 有效且含分组指令则用 Karta 插件 → 否则 default grouper 兜底。API 上保留 alpha 的 `podGroups` 格式并新增 `podGroup`(`PodGroupDefinitionV2`),二者并存时 `podGroup` 优先;`PodGroupMemberDefinition` 用 JQ 路径(`GroupByKeyPaths`)分组、JQ 表达式(`Filters`)选 pod。
  <details><summary>代码依据 docs/developer/designs/Kai-no-code-grouping.md</summary>

  ```diff
  +type GangSchedulingInstruction struct {
  +	// PodGroups defines the alpha grouping format that KAI still supports.
  +	PodGroups []PodGroupDefinition `json:"podGroups,omitempty"`
  +	// PodGroup defines the grouping, subgroup, and topology behavior used by
  +	// the KAI-native Karta integration.
  +	PodGroup *PodGroupDefinitionV2 `json:"podGroup,omitempty"`
  +}
  ```
  (hunk 截断于 212 行文档前 ~80 行,PodGroupDefinitionV2 具体字段未覆盖)
  </details>
- **删除冗余 NaN 校验**:`gpu_request_validator.go` 移除显式 `math.IsNaN(gpuFraction)` 分支及 `math` import,理由是随后的 `resource.ParseQuantity` 已拒绝 NaN——NaN 仍被拦下,只是报错信息改由 ParseQuantity 产出("must be a float written with a decimal point or a scientific notation ... given value: NaN")。这是昨日 digest 记录的 "gpu-fraction 注解校验挡 NaN" 的收尾清理,去掉重复判断。
  <details><summary>代码依据 pkg/binder/plugins/gpusharing/gpu-request/gpu_request_validator.go</summary>

  ```diff
  -	"math"
  -	if math.IsNaN(gpuFraction) {
  -		return fmt.Errorf("gpu-fraction annotation value must be a valid number. NaN is not allowed")
  -	}
  ```
  </details>
### 后续发展方向 [AI]
- Karta 集成把 KAI 的分组能力从"每种 workload 类型写一个 Go 插件"推向"元数据声明式定义",降低接入新 workload(如自定义 CRD、非标准 gang)的门槛;这是 KAI 走向通用调度平台的可扩展性铺垫。证据仅为设计文档(尚未见实现代码/CRD 落地),API 形态可能变;native 插件仍保留优先级,说明短期不替换现有专属逻辑。

## kubernetes-sigs/dra-driver-nvidia-gpu: 391d5ca8 -> 884f41fd
- 比较 / 最新 Release:391d5ca8 -> 884f41fd | ahead=2 | files=11 | Release: v0.4.1
### AI 总结重点(源码 diff 为据)
- **纯文档改版,无代码/API 变更**:11 个文件全在 `site/content/docs/`,内容为 Hugo shortcode 迁移(`{{< highlight bash >}}` → 三反引号 ```bash、blockquote Note → `{{% alert %}}`)、把产品名统一从 "NVIDIA DRA driver" 改为 "DRA Driver for NVIDIA GPUs"、修正相对链接。唯一实质性文档订正:time-slicing 指南把要启用的 feature gate 名从 `TimeSlicing` 更正为 `TimeSlicingSettings`(此前文档写错 gate 名)。
  <details><summary>代码依据 site/content/docs/guides/time-slicing.md</summary>

  ```diff
  -Enable the TimeSlicing feature gate with `helm upgrade`:
  +Enable the `TimeSlicingSettings` feature gate with `helm upgrade`:
  ```
  </details>
### 后续发展方向 [AI]
- 无功能信号;仅确认 v0.4.1 文档面在收敛 install/upgrade 命令统一走 OCI chart(`oci://registry.k8s.io/dra-driver-nvidia/charts/...`)。证据只覆盖文档,未见代码/CRD 改动。

## NVIDIA/nvidia-container-toolkit: 05e941df -> 8b935002
- 比较 / 最新 Release:05e941df -> 8b935002 | ahead=2 | files=1 | Release: v1.19.1
### AI 总结重点(源码 diff 为据)
- **driver/toolkit 镜像构建支持 Podman**:`docker/docker.mk` 引入 `DOCKER ?= docker` 变量(可 `make DOCKER=podman` 覆盖),并处理 Podman 特有差异——本地镜像前缀 `IMAGE_PREFIX := localhost/`(Podman 本地镜像存于 localhost/)、卷挂载加 `:z`(SELinux 主机可写)、`docker pull/run/images/rmi` 全改为 `$(DOCKER)`,并在 run 前补 `mkdir -p $(ARTIFACTS_DIR)`。纯构建工具链改动,不涉及 runtime/CDI 逻辑。
  <details><summary>代码依据 docker/docker.mk</summary>

  ```diff
  +DOCKER ?= docker
  +IMAGE_PREFIX := $(if $(filter podman,$(DOCKER)),localhost/,)
  +VOLUME_OPTS := $(if $(filter podman,$(DOCKER)),:z,)
  -	docker pull --platform=linux/$(ARCH) $(BASEIMAGE)
  +	$(DOCKER) pull --platform=linux/$(ARCH) $(BASEIMAGE)
  -	    -v $(ARTIFACTS_DIR):/dist \
  +	    -v $(ARTIFACTS_DIR):/dist$(VOLUME_OPTS) \
  ```
  </details>
### 后续发展方向 [AI]
- 便利性改动,方便在无 Docker 的 SELinux/RHEL 构建环境(Podman)出包;不影响运行时功能。证据仅一文件构建脚本。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅 bump/CI/merge 或无新提交)</summary>

- NVIDIA/gpu-operator — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/mig-parted — 仅 bump/CI/merge
- NVIDIA/DCGM — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=7b38b13887ac4054d2f958d9e178d25f6b72ef8a branch=main release=v26.3.3 scanned=2026-07-03 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=8b935002a31ca5ba892d6f2f255f9abe58d82b7a branch=main release=v1.19.1 scanned=2026-07-03 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=5f8425f367df00fc8f7b86481436b15536175f7d branch=main release=— scanned=2026-07-03 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=10fd1c08afa74932e0f949e540eca9d9953d9cec branch=main release=v0.19.3 scanned=2026-07-03 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=884f41fdd20204ae2f194ba9a94cce4b4200110b branch=main release=v0.4.1 scanned=2026-07-03 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-03 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=944764a9e9685d82279eb2d1ee216b7b2451e213 branch=main release=v0.14.2 scanned=2026-07-03 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=bb9f733e4e9dc0edeeb67ee6eccaac54706b23d9 branch=main release=v0.16.2 scanned=2026-07-03 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-07-03 -->

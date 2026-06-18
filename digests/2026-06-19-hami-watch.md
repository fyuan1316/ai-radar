# HAMi diff 雷达 2026-06-19

## 摘要
- HAMi 主仓本日唯一实质改动是构建链对齐:把 HAMi 与 HAMi-core 的 CUDA 编译/运行基础镜像从 `nvidia/cuda:12.x-*-ubuntu20.04` 统一迁到 `nvidia/cuda:13.3.0-cudnn-devel-ubi8`,包管理由 `apt-get` 换成 `dnf`(底座 Ubuntu→UBI8/RHEL 系),并 bump libvgpu 子模块。属工具链升级,无 Go 源码行为变化。
- HAMi-core / volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI 四仓本日无实质改动(无新提交)。

## 当日重要改变
- 无(本期改动为构建/工具链对齐 + 依赖 bump,未命中弃用/API-CRD/架构方向/版本跨档/新能力 任一信号)

## Project-HAMi/HAMi: b9ecc20d -> 38a9c428
- 比较: https://github.com/Project-HAMi/HAMi/compare/b9ecc20d12cb70b9d8e6df91c952b65fd5f5a2ac...38a9c428dd127474e885fce2174ba41edbfd5bef | ahead=3 | files=9 | Release: v2.9.0
- 实质 PR: https://github.com/Project-HAMi/HAMi/pull/1958 (build(docker): align HAMi with HAMi-core compile image)
- 另含一条被滤掉的 dependabot bump: k8s.io/kubelet 0.36.1 -> 0.36.2 https://github.com/Project-HAMi/HAMi/pull/1960

### AI 总结重点(源码 diff 为据)
- **CUDA 编译/运行基础镜像统一升档:12.x → 13.3.0,且 devel 镜像底座由 Ubuntu20.04 改为 UBI8(RHEL 系)**。`Dockerfile` / `Dockerfile.hamicore` 的 `nvbuild` 阶段 `ARG NVIDIA_IMAGE` 从 `nvidia/cuda:12.9.1-cudnn-devel-ubuntu20.04` 改为 `nvidia/cuda:13.3.0-cudnn-devel-ubi8`;`version.mk`(`12.3.2-devel-ubuntu20.04`→)、`hack/build.sh`(`12.2.0-devel-ubuntu20.04`→)、两个 CI workflow 同步对齐到同一 `13.3.0-cudnn-devel-ubi8`。即原本散落在 5 处、版本号还各不相同(12.9.1/12.3.2/12.2.0)的编译镜像被收敛为单一来源,与 HAMi-core 编译镜像保持一致。

  <details><summary>代码依据 docker/Dockerfile.hamicore + version.mk + hack/build.sh</summary>

  ```diff
  # docker/Dockerfile.hamicore & docker/Dockerfile (nvbuild 阶段)
  -ARG NVIDIA_IMAGE=nvidia/cuda:12.9.1-cudnn-devel-ubuntu20.04
  +ARG NVIDIA_IMAGE=nvidia/cuda:13.3.0-cudnn-devel-ubi8
  ...
  # version.mk
  -NVIDIA_IMAGE=nvidia/cuda:12.3.2-devel-ubuntu20.04
  +NVIDIA_IMAGE=nvidia/cuda:13.3.0-cudnn-devel-ubi8
  # hack/build.sh
  -export NVIDIA_IMAGE="nvidia/cuda:12.2.0-devel-ubuntu20.04"
  +export NVIDIA_IMAGE="nvidia/cuda:13.3.0-cudnn-devel-ubi8"
  ```
  </details>

- **构建步骤随底座切换重写:apt-get → dnf,并新增清理旧 build 目录**。底座从 Ubuntu 换到 UBI8 后,装 `cmake git` 的命令从 `apt-get update; apt-get install ... && rm -rf /var/lib/apt/lists/*` 改为 `dnf install -y cmake git && dnf clean all`;`build.sh` 前新增 `RUN rm -rf /libvgpu/build` 显式清掉子模块里残留的旧编译产物(避免缓存层带进陈旧 build)。运行阶段 `rm libcuda.so compat` 的路径也从 `cuda-12.6` 跟改到 `cuda-13.3`。

  <details><summary>代码依据 docker/Dockerfile.hamicore</summary>

  ```diff
   FROM $NVIDIA_IMAGE AS nvbuild
  +RUN dnf install -y cmake git && dnf clean all
   COPY ./libvgpu /libvgpu
   ...
   WORKDIR /libvgpu
  -ENV DEBIAN_FRONTEND=noninteractive
  -RUN apt-get -y update; apt-get -y --no-install-recommends install cmake git && rm -rf /var/lib/apt/lists/*
  +RUN rm -rf /libvgpu/build
   RUN bash ./build.sh
   ...
  -RUN rm -rf /usr/local/cuda-12.6/compat/libcuda.so*
  +RUN rm -rf /usr/local/cuda-13.3/compat/libcuda.so*
  ```
  </details>

- **libvgpu 子模块指针 bump(HAMi-core CUDA hook 内核)**。`libvgpu` 子模块从 `8c32de63` 指到 `a26e57e0`。libvgpu 即 HAMi-core 的软隔离 hook 本体,此处仅是 HAMi 主仓侧的指针推进,本 diff 未含 hook 源码 hunk,具体改了什么需到 libvgpu/HAMi-core 仓看(本期 HAMi-core 仓默认分支无新提交,改动应在 libvgpu 子仓)。

  <details><summary>代码依据 libvgpu (submodule)</summary>

  ```diff
  -Subproject commit 8c32de630b24f5f7d6355fbeb0034845d3bdafb7
  +Subproject commit a26e57e0061efed98d32310a8a7986935dc9098e
  ```
  </details>

### 后续发展方向 [AI]
- 本次是纯构建/发布工程动作:把 HAMi 主镜像与 HAMi-core 编译镜像收敛到同一 `cuda:13.3.0 + UBI8` 基线。方向含义有二:(1)**运行/编译底座向 RHEL(UBI8)系靠拢**,利于企业级/OpenShift 类环境的镜像合规与供应链审计;(2)**CUDA 主版本跨档 12→13**,意味着 HAMi-core 的 CUDA hook 需在 CUDA 13 ABI 下重新验证(libvgpu 子模块同步 bump 与此呼应)。证据只覆盖 9 个构建文件的 hunk,未见任何 Go 调度/device-plugin 逻辑改动,也未见 hook 源码——CUDA 13 下显存/算力切分行为是否有变,本 diff 无依据,需跟 libvgpu `a26e57e0` 的实际 diff 确认。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=38a9c428dd127474e885fce2174ba41edbfd5bef branch=master release=v2.9.0 scanned=2026-06-19 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=0831874bce5af56cefca7093dfb2f9f95d1970aa branch=main release=— scanned=2026-06-19 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-06-19 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-19 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-19 -->

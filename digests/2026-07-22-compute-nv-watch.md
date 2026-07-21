# NVIDIA 算力栈 diff 雷达 2026-07-22

## 摘要
- 本日无实质能力/接口改动:9 仓里 7 仓 EMPTY,余下 2 仓(gpu-driver-container、k8s-device-plugin)虽有非 bump 提交,但内容分别只是 **RHEL UBI 基镜像 digest 刷新**(9.8/10.2 版本不变,仅换更新的构建 digest)与 **CI pages 部署 workflow 的 input 声明修复**,均不触及 driver 预编译矩阵、device-plugin 逻辑、CRD 字段或指标语义。
- 无 CRD/外部 API 字段增删、无 time-slicing/MPS→DRA 迁移信号、无版本跨档;P0 的 KAI-Scheduler / dra-driver-nvidia-gpu / gpu-operator 主逻辑今日均无新提交。

## 当日重要改变
- 无

## NVIDIA/gpu-driver-container: 67e63a77 -> 2518686c
- 比较: https://github.com/NVIDIA/gpu-driver-container/compare/67e63a775b02587b749867b4f10fd6af56b411f0...2518686ce14b1ff85fa6a786644e94539398d931 | ahead=2 | files=2
### AI 总结重点(源码 diff 为据)
- **仅刷新 RHEL9/RHEL10 driver 构建镜像的 UBI 基镜像 digest**,未动 UBI 版本档(仍 9.8 / 10.2),也未改预编译/OS 支持矩阵——属周期性上游基镜像跟随,无能力信号。
  <details><summary>代码依据 rhel9/Dockerfile、rhel10/Dockerfile(各 +1/-1)</summary>

  ```diff
  - ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi:9.8-1784165989
  + ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi:9.8-1784625744
  ...
  - ARG BASE_IMAGE=registry.access.redhat.com/ubi10/ubi:10.2-1784094506
  + ARG BASE_IMAGE=registry.access.redhat.com/ubi10/ubi:10.2-1784581466
  ```
  </details>
### 后续发展方向 [AI]
- 无方向性信号:同版本 UBI digest 滚动是安全补丁跟随,非 OS 矩阵扩容。证据仅覆盖两个 Dockerfile 的 ARG 行,未见 precompiled/driver 版本矩阵变化。

## NVIDIA/k8s-device-plugin: 24816472 -> 8461b2e1
- 比较: https://github.com/NVIDIA/k8s-device-plugin/compare/248164727d5d8bac7024a8e12a13e69246cf0969...8461b2e1ea526922093155e5ad579b0a9d9bb66a | ahead=1 | files=1
### AI 总结重点(源码 diff 为据)
- **纯 CI 修复**:pages 部署 workflow 的 `workflow_dispatch` 下补了缺失的 `inputs:` 层级,使 `git_ref_to_deploy` 真正成为可从 Actions 面板传入的手动输入(此前该参数缩进错、未被识别)。不涉及 device-plugin / time-slicing / MPS 任何运行时逻辑。
  <details><summary>代码依据 .github/workflows/deploy-to-pages.yaml(+1/-0)</summary>

  ```diff
    workflow_dispatch:
  +   inputs:
        git_ref_to_deploy:
          description: The git reference to deploy
  ```
  </details>
### 后续发展方向 [AI]
- 无产品能力方向;仅文档站发布流程可用性修复。证据仅覆盖一个 workflow 文件。

## 本期无实质改动(折叠)
- NVIDIA/gpu-operator(ahead=2,仅 bump/CI/merge;Release v26.3.3)
- NVIDIA/nvidia-container-toolkit(无新提交;Release v1.20.0-rc.1)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交;Release v0.4.1)
- NVIDIA/dcgm-exporter(无新提交;Release 4.6.0-4.8.3)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(ahead=2,仅 bump/CI/merge;Release v0.14.4)
- kai-scheduler/KAI-Scheduler(无新提交;Release v0.16.4)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=4918a72c29a57edeb129156a6b300c6ac9767f5b branch=main release=v26.3.3 scanned=2026-07-22 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=1cddfb0dc179136cd720090f0a13e6ce0de611ed branch=main release=v1.20.0-rc.1 scanned=2026-07-22 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=2518686ce14b1ff85fa6a786644e94539398d931 branch=main release=— scanned=2026-07-22 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=8461b2e1ea526922093155e5ad579b0a9d9bb66a branch=main release=v0.19.3 scanned=2026-07-22 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=4d0b3898aa3a1940fa30dd1b16eb242d419be8d1 branch=main release=v0.4.1 scanned=2026-07-22 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-22 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-22 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=f484af1ba590265e0cb429ca71e3c08cb8374a5d branch=main release=v0.14.4 scanned=2026-07-22 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=d17b3fbe244a2eed41348224c1b230accc85b6ef branch=main release=v0.16.4 scanned=2026-07-22 -->

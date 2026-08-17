# NVIDIA 算力栈 diff 雷达 2026-08-18

## 摘要
- 全栈无功能级变化:9 仓中 7 仓无新提交,动的两仓(gpu-driver-container、KAI-Scheduler)均为非代码改动——前者纯 base 镜像/工具链版本刷新,后者纯文档(资源规划计算器)。
- KAI-Scheduler 上线了「调度器资源规划」文档+浏览器计算器,公开了 500/1000 节点两档实测资源画像(scheduler 内存到 8Gi、覆盖 8000 GPU / 90000 Pod 量级),对企业级容量规划有参考价值,但无调度算法/API 改动。
- 无 API/CRD 字段变更、无驱动容器化矩阵扩展、无 DRA/监控语义变化。

## 当日重要改变
无(两处改动分别为镜像/工具版本 bump 与文档新增,均未触发弃用/API/CRD/架构/版本跨档信号)。

## NVIDIA/gpu-driver-container: 6c629a86 -> 06a208ca
- 比较: 6c629a86 -> 06a208ca | ahead=8 | files=7 | Release: —
- 比较页: https://github.com/NVIDIA/gpu-driver-container/compare/6c629a86a8ddf96a98085c8abad0406f1231e326...06a208ca9747c82b1ba99b76ecdcf2469b0a0207

### AI 总结重点(源码 diff 为据)
- 纯维护性刷新,无驱动构建逻辑/OS 矩阵变化。改动是三条:(1) rhel8/9/10 及 vgpu-manager/rhel10 的 UBI base 镜像 tag 均在**同一 OS 版本内**(8.10 / 9.8 / 10.2)刷了构建 digest,不是新增/删除 OS 分支;(2) CI 里 buildx 从 v0.16.2 跳到 v0.36.1、regctl 从 v0.7.1 跳到 v0.11.5;(3) `versions.mk` 里 Go 从 1.26.5→1.26.6。`DRIVER_VERSIONS`(580.178.04 595.91.07 610.57.04)未动,即跟踪的活跃 driver 分支矩阵无变化。
  <details><summary>代码依据 rhel10/Dockerfile + versions.mk</summary>

  ```diff
  -ARG BASE_IMAGE=registry.access.redhat.com/ubi10/ubi:10.2-1786398253
  +ARG BASE_IMAGE=registry.access.redhat.com/ubi10/ubi:10.2-1786960026
  ```
  ```diff
  -GOLANG_VERSION := 1.26.5
  +GOLANG_VERSION := 1.26.6
  # DRIVER_VERSIONS ?= 580.178.04 595.91.07 610.57.04   (未改)
  ```
  </details>
  <details><summary>代码依据 .common-ci.yml</summary>

  ```diff
  -    -  export BUILDX_VERSION=v0.16.2
  +    -  export BUILDX_VERSION=v0.36.1
  -    - export REGCTL_VERSION=v0.7.1
  +    - export REGCTL_VERSION=v0.11.5
  ```
  </details>

### 后续发展方向 [AI]
- 证据仅覆盖镜像 tag / 工具版本行,无任何 Dockerfile 构建步骤或预编译逻辑改动,故本仓今日不承载能力信号,只是常规安全基线跟随上游 UBI 重建。真正值得盯的「预编译/OS 矩阵扩展」信号应看 `DRIVER_VERSIONS` 与新增 OS 目录,本次两者皆无。

## kai-scheduler/KAI-Scheduler: 38dd06fe -> 2914d320
- 比较: 38dd06fe -> 2914d320 | ahead=2 | files=11 | Release: v0.16.9
- 比较页: https://github.com/kai-scheduler/KAI-Scheduler/compare/38dd06fe520e0d422971f284ce117d9f2d818d06...2914d320160fbb389f69a2c2968a0a6acefb9f76

### AI 总结重点(源码 diff 为据)
- 全部是文档/网页资产,零 Go 代码、零 CRD 改动。核心是新增一套「调度器资源规划」资料:`docs/operator/resource-sizing.md`(实测起步画像表)+ `docs/operator/scheduler-memory-sizing.md`(内存计算公式)+ `docs/resource-sizing/` 下一个纯前端计算器(index.html/calculator.js/styles.css/test),外加一条 GitHub Pages 部署 workflow。另一条提交只是 karpenter.md 的拼写修正(perevent→prevent 等)。
- 有产品参考价值的是它把 KAI 各组件的**实测资源包络**公开成了两档 profile。500 节点档:scheduler 请求/限制 `2/4` CPU、`4Gi/7Gi` 内存,binder `250m/1`、`3Gi/4Gi`;1000 节点档:scheduler `3/5`、`7Gi/8Gi`。对应的压测规模为 500 档 ~46000 Pod / 8000 活跃 workload / 4000 GPU,1000 档 ~90000 Pod / 16000 workload / 8000 GPU——这是官方首次给出的 KAI 大规模容量参照点。
  <details><summary>代码依据 docs/operator/resource-sizing.md(起步 profile 表)</summary>

  ```diff
  +| Service    | 500 CPU     | 500 memory   | 1000 CPU    | 1000 memory  |
  +| Scheduler  | `2 / 4`     | `4Gi / 7Gi`  | `3 / 5`     | `7Gi / 8Gi`  |
  +| Binder     | `250m / 1`  | `3Gi / 4Gi`  | `1 / 2`     | `5Gi / 6Gi`  |
  +| PodGroup controller | `500m / omit` | `2Gi / 3Gi` | `1 / omit` | `3500Mi / 4Gi` |
  ```
  </details>
- 内存计算把开销拆成 `cache`(常驻集群对象)+ `scheduling reserve`(评估最大 job/回收模拟时的临时内存),并明确 scheduler 每个 shard 都 watch 全集群 Pod,故分片**不**摊薄 `totalPods` 项——这是理解 KAI 分片扩展性的一个关键约束。
  <details><summary>代码依据 docs/operator/scheduler-memory-sizing.md(cache 公式)</summary>

  ```diff
  +cache = 1
  +      + 0.16 * totalPods / 10,000
  +      + 0.01 * workloads / 1,000
  +      + 0.02 * eligibleNodes / 1,000
  +      + 0.04 * workloadPods / 10,000
  +# Every scheduler shard watches cluster-wide Pods, so sharding does not divide the totalPods term.
  ```
  </details>

### 后续发展方向 [AI]
- 证据只覆盖文档与前端计算器,未见任何调度逻辑/配置默认值改动,故这是运维就绪度(day-2 容量规划)打磨,不是能力演进。对我们产品的启示:若对标 KAI/Run:ai 做多租调度,需要同样能给出「按节点/Pod/GPU 规模的组件资源画像 + 分片不摊薄全局 watch」这类可交付给客户容量规划的材料;KAI 已把它做成可离线运行、不外传集群信息的浏览器工具,是企业信任度的加分项。方向上未见 KAI 触碰算法或 API,主线增量仍需盯后续代码提交。

## 本期无实质改动(折叠)
<details><summary>7 仓无新提交 / 仅 bump·CI·merge</summary>

- NVIDIA/gpu-operator(无新提交)
- NVIDIA/nvidia-container-toolkit(无新提交)
- NVIDIA/k8s-device-plugin(仅 bump/CI/merge,ahead=1)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=ed270f823c2ecbe6d4f854054db084d4b6491a4b branch=main release=v26.3.3 scanned=2026-08-18 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=cb5d6990b8069e8ad9bdb67f9a2b3ff832d9531c branch=main release=v1.20.0 scanned=2026-08-18 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=06a208ca9747c82b1ba99b76ecdcf2469b0a0207 branch=main release=— scanned=2026-08-18 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=43e8b82cf79345b822e376d8f899009a270d038f branch=main release=v0.19.3 scanned=2026-08-18 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=d485fb70d00709811fba898acef76cf809b192b2 branch=main release=v0.4.1 scanned=2026-08-18 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-18 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-18 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5c3505c4fe8170d06c726f90ef332c93131653f3 branch=main release=v0.14.5 scanned=2026-08-18 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=2914d320160fbb389f69a2c2968a0a6acefb9f76 branch=main release=v0.16.9 scanned=2026-08-18 -->
</content>

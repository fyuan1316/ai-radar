# NVIDIA 算力栈 diff 雷达 2026-07-16

## 摘要
- **dcgm-exporter 发大版本 4.6.0-4.8.3(底座 DCGM 4.6.0),把 DRA 与 MIG 的可观测能力补齐**:新增 DRA ResourceSlice v1 支持、扩展 DRA v1 + MIG 分配处理、支持在 MIG 设备上采集 pod label,RBAC 同步对齐"K8s metadata + DRA"权限。是上期 gpu-operator 把捆绑 DCGM 跳到 4.6.0/UBI10 之后,exporter 本体跟上到 DCGM 4.6.0 的收尾,DRA 原生路径的监控面正在成型。
- **两处指标口径变更值得盯仪表盘**:`Hostname` label 重命名为小写 `hostname`(现有 dashboard/告警按大写引用会断)、NVLink 带宽指标从 counter 改成 gauge(语义纠正,PromQL 里的 `rate()` 用法需改)。另新增 YAML 配置文件支持、VSOCK 远程 hostengine 连接、可配置 web 读写超时与 per-watch 轮询间隔。
- 其余 8 仓本期无实质代码改动:gpu-operator 仅 bump/CI;mig-parted、KAI-Scheduler 各有提交但纯 CI/发布流程加固(非生产代码);container-toolkit/gpu-driver-container/k8s-device-plugin/dra-driver-nvidia-gpu/DCGM 无新提交。

## 当日重要改变
- NVIDIA/dcgm-exporter [版本跨档][新能力] 发布 4.6.0-4.8.3(DCGM 4.6.0 + go-dcgm v1.4601.1);新增 DRA ResourceSlice v1 支持、扩展 DRA v1/MIG 分配处理、MIG 设备上 pod label 采集,RBAC 对齐 DRA。 https://github.com/NVIDIA/dcgm-exporter/compare/d5e5f510...181290c3
- NVIDIA/dcgm-exporter [API/CRD变更] 指标 label `Hostname` 重命名为 `hostname`(大小写破坏性变更,影响下游 dashboard/告警选择器)。 https://github.com/NVIDIA/dcgm-exporter/pull/655
- NVIDIA/dcgm-exporter [API/CRD变更] NVLink 带宽指标从 counter 纠正为 gauge(指标语义变化,PromQL rate() 用法失效)。 https://github.com/NVIDIA/dcgm-exporter/pull/658

## NVIDIA/dcgm-exporter: d5e5f510 -> 181290c3
- 比较 / Release: https://github.com/NVIDIA/dcgm-exporter/compare/d5e5f510...181290c3 | ahead=1 | files=300(API 截断) | Release 4.6.0-4.8.3
- **大区间概览(单 squash 合并 "DCGM-Exporter 4.6.0-4.8.3 (#711)",files 被 API 截断到 300,未逐文件读 hunk;以下基于 release note + 改动热点目录)**

### AI 总结重点(release note 为据,未读 hunk)
- **改动热点目录**:`internal/pkg`(94 文件,核心采集/渲染)、`internal/e2e`(60,新 E2E 框架)、`tests/*`(host/container/k8s/integration 全面扩测)、`deployment/templates`(5,Helm)、`.cursor/*`(agent 辅助开发指引)。核心逻辑集中在 `internal/pkg`。
- **DRA / MIG 监控面补齐(对我们产品最相关)**:release note 明列
  - Add DRA ResourceSlice v1 support(https://github.com/NVIDIA/dcgm-exporter/pull/654)
  - Expand DRA v1 and MIG allocation handling(https://github.com/NVIDIA/dcgm-exporter/pull/664)
  - Support pod-label collection on MIG devices(https://github.com/NVIDIA/dcgm-exporter/pull/660)
  - Align RBAC with Kubernetes metadata and DRA features
  即 exporter 现在能把指标关联到 DRA ResourceSlice v1 分配的 GPU 与 MIG 实例,DRA 原生路径不再是监控盲区。
- **指标口径两处破坏性/语义变更**(下游仪表盘需适配):
  - `Hostname` → `hostname` label 重命名(https://github.com/NVIDIA/dcgm-exporter/pull/655)
  - NVLink 带宽 counter → gauge(https://github.com/NVIDIA/dcgm-exporter/pull/658)
  - 另新增:cumulative XID error totals、cumulative clock-event totals、GPU-health severity/category 元数据、Grace CPU serial label。
- **运行时/配置能力增强**:YAML 配置文件支持、CLI/env 配置扩展、可配置 web 读写超时、per-watch 轮询间隔、combined device selectors、VSOCK 远程 hostengine 连接、热重载 + last-known-good 配置恢复。配置面从纯 CLI/env 扩到 YAML,更贴近 GitOps。
- **底座与打包**:DCGM 4.6.0 + go-dcgm v1.4601.1;Go 1.26.4;移除对 `github.com/pkg/errors` 直接依赖;Helm 增加配置文件支持与 image-digest 配置、service-account token 挂载可配置、ServiceMonitor 时序默认值更新。

### 后续发展方向 [AI]
- DRA ResourceSlice v1 + MIG allocation 的监控支持,标志 NVIDIA 全栈把"设备可见性"从 device-plugin 时代往 DRA 原生迁移的监控侧已就位——结合上期 gpu-operator 弃用 KataManager、mig-parted 加子系统级 device filter,整栈都在为 DRA/精细化 GPU 分配铺路。证据仅来自 release note(未读 hunk),DRA v1 指标的具体 label schema(如是否新增 `dra_resourceslice`/`claim` 维度)需下期在 exporter 稳定后逐文件确认。
- 两处指标口径变更(label 大小写、counter→gauge)属破坏性,若我们产品内置了 dcgm-exporter dashboard,升级到 4.6.0-4.8.3 需同步改选择器与 PromQL;这类"随大版本悄悄改指标语义"是 dcgm-exporter 的惯例风险,建议锁版本 + 变更评审。证据为 release note 明列条目,未见迁移兼容开关。

## 本期无实质改动(折叠)
<details><summary>CI-only / EMPTY / 无新提交仓(8 仓)</summary>

- NVIDIA/gpu-operator — 仅 bump/CI/merge(ahead=2,files=2),HEAD 前移到 557886b8,Release v26.3.3
- NVIDIA/mig-parted — 有 1 提交但纯 CI 加固:"Restrict cherry-pick comments to owners and members",给 `.github/workflows/cherrypick.yml` 收紧 permissions(默认 `{}`,仅在 job 级授权)并要求 `/cherry-pick` 评论作者为 OWNER/MEMBER,`add-labels-from-comment.js` 加 `trustedAssociations` 校验。无生产/API 代码。HEAD 前移到 90668a23,Release v0.14.3
- kai-scheduler/KAI-Scheduler — 有 2 提交但纯发布流程改造:切换到 changie CHANGELOG 片段机制(新增 release-prepare/release-publish/changelog-comment workflow、hack/changelog-*.sh)、"restore checkout v6 for fork backports"。全在 `.github/`、`hack/`、`CHANGELOG.md`、`.changes/`,无调度器/API 改动。HEAD 前移到 55d8aba0,Release v0.16.4
- NVIDIA/nvidia-container-toolkit — 无新提交(HEAD 3db41dec 未动,Release v1.20.0-rc.1)
- NVIDIA/gpu-driver-container — 无新提交(HEAD 1ea5e0fc 未动,Release —)
- NVIDIA/k8s-device-plugin — 无新提交(HEAD 24816472 未动,Release v0.19.3)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(HEAD 9001f17e 未动,Release v0.4.1)
- NVIDIA/DCGM(master)— 无新提交(HEAD 72fa3fea 未动)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=557886b885cf4ab2f5695b2ef80c95df94201624 branch=main release=v26.3.3 scanned=2026-07-16 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3db41dec03bf1179b4f7259f6a7037f7f158d39b branch=main release=v1.20.0-rc.1 scanned=2026-07-16 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=1ea5e0fca809020c7388ba1058d19ad3788e6aaf branch=main release=— scanned=2026-07-16 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=248164727d5d8bac7024a8e12a13e69246cf0969 branch=main release=v0.19.3 scanned=2026-07-16 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=9001f17e513115a9366987bf5fd9f7850ac52368 branch=main release=v0.4.1 scanned=2026-07-16 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-16 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=90668a237485113fdb77cadd825957ffbf3a3c1c branch=main release=v0.14.3 scanned=2026-07-16 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=55d8aba0106ea5c043c06700ebac6cc246ba6f11 branch=main release=v0.16.4 scanned=2026-07-16 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-16 -->

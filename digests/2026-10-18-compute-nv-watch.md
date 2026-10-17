# NVIDIA 算力栈 diff 雷达 2026-10-18

## 摘要
- 本期唯一实质改动落在 **L2 DRA 主线 dra-driver-nvidia-gpu**,且**仅文档**:合入 PR #1570 的 `docs: Release 0.5.1`,补齐 v0.5.0→v0.5.1 升级章节并把站点版本号从 0.5.0 推到 0.5.1。无任何 Go 代码/CRD/调度逻辑改动,文档明确声明 "v0.5.1 does not change the CRDs"。
- 文档侧透露一个能力点:v0.5.1 新增**可选** Helm value `resources.computeDomains.imex.config`,用于覆写 IMEX daemon 配置(升级不强制填,留空走默认)。属对既有 release 的说明,非本期新代码。
- 其余 8 个源仓本期全无新提交(gpu-operator / nvidia-container-toolkit / gpu-driver-container / k8s-device-plugin / dcgm-exporter / DCGM / mig-parted / KAI-Scheduler),锚点原样续链。

## 当日重要改变
- 无命中弃用/API-CRD/架构方向/版本跨档/新能力信号。dra-driver 本期为纯文档提交,`computedomain-imex` 的 IMEX 配置覆写能力早已随 v0.5.1 发布(上期锚点 release 即已是 v0.5.1),本期只是把升级指南补全,不计为代码级重要改变。

## kubernetes-sigs/dra-driver-nvidia-gpu: 6d5bdb8f -> 63e98d30
- 比较: 6d5bdb8f19c2e6f50fe8f282fa77816503cb0571 -> 63e98d30 | ahead=2 | files=2 | Release: v0.5.1

### AI 总结重点(源码 diff 为据)
- **纯文档:`site/content/docs/upgrade.md` 新增 "Upgrade from v0.5.0 to v0.5.1" 一节,`site/hugo.toml` 把站点参数 `driver_version`/`driver_release_tag` 从 0.5.0/v0.5.0 推到 0.5.1/v0.5.1**。升级文档明确三点语义:(1) v0.5.1 不动 CRD、不需要数据或 API 迁移,`helm upgrade -i ... --reuse-values` 直接原地升;(2) v0.5.1 **新增可选** Helm value `resources.computeDomains.imex.config`,用于对 IMEX daemon 配置做覆写,不填则沿用默认、升级照常工作;(3) 升级后给出校验清单(`helm status` / 驱动 pod Running+Ready / `kubectl get deviceclasses` / `kubectl get resourceslices` 仍在)。同一提交把旧的 "Upgrade from v0.4.1 to v0.5.0" 段落整体下移保留为历史。无 `*_types.go`/`config/crd`/`/crds/` 命中(探测器确认 "无 API/CRD 路径命中")。
  <details><summary>代码依据 site/content/docs/upgrade.md</summary>

  ```diff
  -## Upgrade from v0.4.1 to v0.5.0
  +## Upgrade from v0.5.0 to v0.5.1
  ...
  +v0.5.1 does not change the CRDs and does not require a data or API migration.
  +v0.5.1 adds the optional `resources.computeDomains.imex.config` value for IMEX daemon configuration overrides.
  +The upgrade works without this value.
  +To set overrides, refer to the [Helm values reference](reference/helm-values/#computedomain-imex).
  +
  +After the upgrade, verify the Helm release, driver pods, DeviceClasses, and node ResourceSlices:
  +
  +```bash
  +helm status nvidia-dra-driver-gpu -n nvidia-dra-driver-gpu
  +kubectl get pods -n nvidia-dra-driver-gpu
  +kubectl get deviceclasses
  +kubectl get resourceslices
  +```
  ```
  </details>
  <details><summary>代码依据 site/hugo.toml</summary>

  ```diff
  -  driver_version = "0.5.0"       # Helm chart version (no "v" prefix; used with --version)
  -  driver_release_tag = "v0.5.0"  # GitHub release tag (used for source links)
  +  driver_version = "0.5.1"       # Helm chart version (no "v" prefix; used with --version)
  +  driver_release_tag = "v0.5.1"  # GitHub release tag (used for source links)
  ```
  </details>

### 后续发展方向 [AI]
- 可读到的方向信号是 **ComputeDomain / IMEX 配置面正在从"固定内置"走向"可覆写"**:v0.5.1 把 IMEX daemon 配置提成一个可选 Helm value(`resources.computeDomains.imex.config`),这是 multi-node NVLink/GB200 这类跨节点 GPU 互联场景里,让用户按集群拓扑调 IMEX 的入口。但证据**仅来自升级文档**,未见实际 values.yaml/Go 侧的 config 解析代码(本次 diff 不含代码文件),无法确认覆写粒度与校验逻辑,也无法判断是否影响 ResourceSlice 生成。CRD 本期明确未动,DRA 共享/分片主线无进展。来源:https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/pull/1570  https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/6e8b77b021cb7b9d04619264a6ca61c3e1141692

## 本期无实质改动(折叠)
<details><summary>下列 repo 本期仅 bump/CI/merge 或无新提交,未单列正文</summary>

- NVIDIA/gpu-operator:无新提交。
- NVIDIA/nvidia-container-toolkit:无新提交。
- NVIDIA/gpu-driver-container:无新提交。
- NVIDIA/k8s-device-plugin:无新提交。
- NVIDIA/dcgm-exporter:无新提交。
- NVIDIA/DCGM:无新提交(master 分支)。
- NVIDIA/mig-parted:无新提交。
- kai-scheduler/KAI-Scheduler:无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=dbb11e85129b601afe9fb502ac25b062ad094abd branch=main release=v26.7.2 scanned=2026-10-18 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3e112b4af299bf72a1b23193b4f5c3321475dd6d branch=main release=v1.20.1 scanned=2026-10-18 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d6d82abedb448b8f67992f1b59c86f163df24772 branch=main release=— scanned=2026-10-18 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1053da35d5a67fdbc3f0ea0877b7178026048769 branch=main release=v0.20.1 scanned=2026-10-18 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=63e98d305bb66cb9f2a07a0669661329d320ee3f branch=main release=v0.5.1 scanned=2026-10-18 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-18 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-18 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-18 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=e496b7539d40d3c8428ce56d967933de4a9a0a05 branch=main release=v0.18.6 scanned=2026-10-18 -->

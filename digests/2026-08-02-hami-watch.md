# HAMi diff 雷达 2026-08-02

## 摘要
- 本日无实质能力变化。主仓 `HAMi` 仅 1 个 CI 提交(#2236),把 release workflow 的写权限从 workflow 级下放到 job 级(cosign keyless 签名 / release-notes 页面),属供应链最小权限收敛,**非 vGPU/vNPU 软切分能力改动**。
- HAMi-core、volcano-vgpu-device-plugin、ascend-device-plugin、HAMi-WebUI 四仓无新提交,时分软切分内核与两大生态集成路径本期静默。

## 当日重要改变
- 无(唯一改动为 CI 权限收敛,未命中弃用/API·CRD/架构/版本跨档/新能力任一信号)。

## Project-HAMi/HAMi: c7891ded -> 57bda659
- 比较: c7891ded -> 57bda659 | ahead=1 | files=3 | Release: v2.9.0(未变)
### AI 总结重点(源码 diff 为据)
- **把 release 系列 workflow 的高权限从 top-level `permissions:` 下移到具体 job**,遵循 GitHub Actions 最小权限原则:top-level 只保留 `contents: read`,`packages: write` + `id-token: write`(cosign keyless 签名所需)只授予 `docker-build` job;`call-release-notes.yaml` 里 `contents: write` 只授予 `generate-release-notes` job。改动前是整个 workflow(含所有 job)都持有写权限,改动后其余 job 无写权限,缩小了被注入/供应链攻击时的可写面。纯 CI/发布链改动,不触及 device-plugin、scheduler、HAMi-core hook 任何运行时代码。
  <details><summary>代码依据 .github/workflows/call-release-image.yaml</summary>

  ```diff
  -# id-token is needed for keyless cosign signing
   permissions:
     contents: read
  -  packages: write
  -  id-token: write

   jobs:
     docker-build:
       runs-on: ubuntu-latest
  +    # id-token is needed for keyless cosign signing
  +    permissions:
  +      contents: read
  +      packages: write
  +      id-token: write
  ```
  </details>
  <details><summary>代码依据 .github/workflows/call-release-notes.yaml</summary>

  ```diff
  -# updates the github release page
   permissions:
  -  contents: write
  +  contents: read

   jobs:
     generate-release-notes:
       runs-on: ubuntu-latest
  +    # updates the github release page
  +    permissions:
  +      contents: write
  ```
  </details>
- 提交:https://github.com/Project-HAMi/HAMi/pull/2236 · https://github.com/Project-HAMi/HAMi/commit/57bda659af113fb2941d5ae93ed2cceb3c9a67ec
### 后续发展方向 [AI]
- 无能力/架构层面信号可推断。证据仅覆盖 3 个 release workflow YAML 的权限作用域调整,未见任何 vGPU/vNPU、调度、hook 相关 diff;不宜从此提交外推产品方向。

## 本期无实质改动(折叠)
<details><summary>4 仓无实质改动</summary>

- Project-HAMi/HAMi-core:无新提交(CUDA hook 时分软切分内核本期静默)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交(昇腾 vNPU 虚拟化路径本期静默)
- Project-HAMi/HAMi-WebUI:无新提交(Release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=57bda659af113fb2941d5ae93ed2cceb3c9a67ec branch=master release=v2.9.0 scanned=2026-08-02 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=52f33fc7fa1fbb3f08148ab076d0e7447bec7f2a branch=main release=— scanned=2026-08-02 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-08-02 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ffadaa96270de157fbe461be321f7b17c79a16de branch=main release=— scanned=2026-08-02 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-02 -->

# HAMi diff 雷达 2026-07-23

## 摘要
- 低信号日:仅主仓 HAMi 4 个提交,全落在**供应链安全加固 + 文档**,无一行 Go/CRD/调度逻辑改动。方向信号=把发布链路做实(cosign 签名 + SBOM/provenance + OpenSSF Scorecard + workflow 最小权限),对标企业级"可信构建"合规项。
- 唯一有产品含义的实质改动是文档级的:prerequisites 删掉 `glibc < 2.30` 上限(#2102),意味着 HAMi-core CUDA hook 的宿主 OS 兼容边界向新发行版(glibc≥2.30 的 Ubuntu 20.04+/RHEL 9 等)放开——但本窗口 HAMi-core 仓 0 提交,属文档追平既成事实,非新代码。
- HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI 四仓 EMPTY,保锚点。

## 当日重要改变
- 无(4 提交均未命中 API/CRD/proposal/版本跨档/新 package 信号;签名与权限属 CI 供应链范畴,glibc 放宽为文档改动)。

## Project-HAMi/HAMi: 044a749f -> 6469365d
- 比较: 044a749f979d76dd2cb30b9c63f9f714185b2c2a -> 6469365d | ahead=4 | files=9 | Release: v2.9.0(未跨档)

### AI 总结重点(源码 diff 为据)
- **发布镜像开始 cosign 签名 + 生成 provenance/SBOM(#2110)**:`call-release-image.yaml` 与 `call-release-image-hamicore.yaml` 两条发布链路给 `docker/build-push-action` 打开 `provenance: mode=max` + `sbom: true`,并新增 `cosign sign --yes <REGISTRY>/<IMAGE>@<DIGEST>` 步骤(用 sigstore/cosign-installer 固定 commit SHA 钉版本)。即 HAMi 与 hami-core 两个镜像自此产出可验证的签名与来源证明——企业侧"镜像溯源/准入校验"能直接消费。
  <details><summary>代码依据 .github/workflows/call-release-image.yaml</summary>

  ```diff
        - name: Build & Pushing hami image
  +       id: build
          uses: docker/build-push-action@v7.3.0
          with:
              ...
              push: true
  +           provenance: mode=max
  +           sbom: true
              github-token: ${{ env.REGISTER_PASSWORD }}
  +
  +     - name: Install cosign
  +       uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2
  +
  +     - name: Sign hami image
  +       env:
  +         DIGEST: ${{ steps.build.outputs.digest }}
  +       run: cosign sign --yes "${REGISTRY}/${IMAGE_REPO}@${DIGEST}"
  ```
  </details>
- **新增 OpenSSF Scorecard 工作流 + README 徽章(#2095)**:新建 `.github/workflows/scorecard.yaml`,周一 cron + push[master] + branch_protection_rule 触发,`ossf/scorecard-action@v2.4.3` 跑分并 `publish_results: true` 上报到 OpenSSF REST(需 `id-token: write`),SARIF 上传 code-scanning。四份 README(含 ja/cn)加 Scorecard 徽章。信号:项目在冲 CNCF 毕业级安全评分。
  <details><summary>代码依据 .github/workflows/scorecard.yaml(新增)</summary>

  ```diff
  +name: OpenSSF Scorecard
  +on:
  +  branch_protection_rule:
  +  schedule:
  +    - cron: '30 2 * * 1'
  +  push:
  +    branches: [master]
  +permissions: read-all
  +    permissions:
  +      contents: read
  +      security-events: write # to upload SARIF results
  +      id-token: write # to publish results to the OpenSSF REST API
  +      - uses: ossf/scorecard-action@v2.4.3
  +        with:
  +          publish_results: true
  ```
  </details>
- **给残余工作流补最小 token 权限(#2094)**:`stale.yaml` 加 `issues: write` + `pull-requests: write`,`issue-translate.yaml` 加 `issues: write`——从"继承仓库默认(可能过宽)"收敛为顶层显式最小权限,正是 Scorecard "Token-Permissions" 项要求。与前一日(#2093 SECURITY-INSIGHTS、token 收敛)同一条供应链治理主线。
  <details><summary>代码依据 .github/workflows/stale.yaml</summary>

  ```diff
   on:
     schedule:
       - cron: '0 0 * * 2'
  +
  +permissions:
  +  issues: write
  +  pull-requests: write
  ```
  </details>
- **prerequisites 删除 glibc 上限 `< 2.30`(#2102,英/中/日三版 README)**:`glibc >= 2.17 且 < 2.30` → `glibc >= 2.17`。HAMi-core 的 `libvgpu.so` CUDA 拦截历史上受 glibc 符号版本约束卡在 2.30 以下,此处松绑意味官方确认软切分 hook 已可跑在更新的宿主(glibc≥2.30 的较新发行版)。注:本窗口 HAMi-core 仓无提交,此为文档追平,非本期代码变更。
  <details><summary>代码依据 README.md</summary>

  ```diff
   - Kubernetes >= 1.23
  -- glibc >= 2.17 and < 2.30
  +- glibc >= 2.17
   - Linux kernel >= 3.10
  ```
  </details>

### 后续发展方向 [AI]
- **供应链/合规成主仓近两日主旋律**:证据覆盖 cosign 签名、provenance/SBOM、Scorecard、workflow 最小权限四点,均指向 CNCF Sandbox→Incubating 的安全门槛。对我们产品的启示:若集成 HAMi 发布镜像,可开始在准入侧接 cosign verify + SBOM 消费,把"可信 GPU 虚拟化组件"写进合规叙事。**证据只覆盖 CI/发布链,未见运行时(hook/调度)有任何安全改动**。
- **glibc 上限松绑指向 HAMi-core 兼容矩阵扩张**,但仅文档层可见;要确认 hook 在新 glibc 的真实行为需等 HAMi-core 仓出对应 commit,当前无代码依据,未展开。

## 本期无实质改动(折叠)
<details><summary>4 仓 EMPTY(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=6469365dd409f568dbd9d675e01ebff5174ddaab branch=master release=v2.9.0 scanned=2026-07-23 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=06e698079335cffd0009f3c119bd95b012600ae5 branch=main release=— scanned=2026-07-23 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-23 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=f062939e14354a96fb8bfabd3c103d9d8f6de6c2 branch=main release=— scanned=2026-07-23 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-23 -->

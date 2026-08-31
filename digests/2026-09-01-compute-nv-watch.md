# NVIDIA 算力栈 diff 雷达 2026-09-01

## 摘要
- 无能力/架构级改动。当日实质变更集中在**供应链/合规两个边角**:gpu-driver-container 给全 OS 矩阵 Dockerfile 补齐 OCI 标准镜像标签(可溯源性),KAI-Scheduler 给 `fipsMode=only` 追加 `tlsmlkem=0` 修复 FIPS 下 TLS 握手全断的 bug。
- 其余 7 仓无实质提交或仅 bump/CI/merge;gpu-operator 唯一新提交是 CONTRIBUTING 流程文档,无代码信号。

## 当日重要改变
- 无(命中信号的均为 provenance/合规修复,非 API/CRD/架构变更)

## NVIDIA/gpu-driver-container: 06a208ca -> 63168bd0
- 比较 / Release: —(compare https://github.com/NVIDIA/gpu-driver-container/compare/06a208ca9747...63168bd0 ,主体 commit 731bf6cd PR https://github.com/NVIDIA/gpu-driver-container/pull/970 )
### AI 总结重点(源码 diff 为据)
- 给**所有 OS 变体**(rhel8/9/10、ubuntu22.04/24.04/26.04,含各自 precompiled 及 vgpu-manager 子矩阵,共 16 个 Dockerfile)统一补齐 `org.opencontainers.image.*` 系列标准标签(`title/description/vendor/version/revision/source/documentation/base.name/created`),并把原先占位的 `LABEL description="See summary"` 改成实义描述。新引入两个构建期 ARG:`DIST`(标识发行版,拼进 `image.version=${DRIVER_VERSION}-${DIST}`)与 `BUILD_TIMESTAMP`(填 `image.created`)。纯 provenance/可溯源元数据,不改 driver 构建逻辑。

  <details><summary>代码依据 ubuntu26.04/Dockerfile 等 16 个 Dockerfile 同构改动</summary>

  ```diff
  +ARG DIST=ubuntu26.04
  +ARG BUILD_TIMESTAMP
   LABEL version="${DRIVER_VERSION}"
  -LABEL description="See summary"
  +LABEL description="Provision the NVIDIA driver through containers"
  +LABEL org.opencontainers.image.created="${BUILD_TIMESTAMP}"
  +LABEL org.opencontainers.image.revision="${GIT_COMMIT}"
  +LABEL org.opencontainers.image.source="https://github.com/NVIDIA/gpu-driver-container.git"
  +LABEL org.opencontainers.image.version="${DRIVER_VERSION}-${DIST}"
  ```
  </details>
### 后续发展方向 [AI]
- 信号是 NVIDIA 在把 driver 镜像往**标准化 provenance**(OCI image spec)靠,便于下游 registry/扫描器/SBOM 工具按标准字段识别版本与来源。证据只覆盖 label 与 ARG 注入,未见签名/attestation 或 SBOM 生成流程改动。

## kai-scheduler/KAI-Scheduler: 98f95935 -> 99f938ed
- 比较 / Release v0.14.8(commit https://github.com/kai-scheduler/KAI-Scheduler/commit/99f938ed5bf1297650bccd0cc7e747575341b64a PR #2107)
### AI 总结重点(源码 diff 为据)
- 修复 `fipsMode=only` 下 KAI 组件**所有出站 TLS 握手被 panic 打断**的问题:把注入容器的 `GODEBUG` 从 `fips140=only` 改为 `fips140=only,tlsmlkem=0`。根因是 Go `crypto/tls` 默认的 FIPS-allowed 混合曲线 `X25519MLKEM768` 内部会调用非 FIPS 的裸 X25519 原语,在 `fips140=only` 下无条件报错,进而拖垮 client-go 到 API server 的连接;`tlsmlkem=0` 关掉该混合曲线绕开上游缺口(golang/go#78298、kubernetes#133743)。改动同时落在 Helm 模板 `_helpers.tpl` 的 `fipsOnlyEnv` 与 operator 侧 `common.go` 的 `FIPSOnlyEnv()` 两处生成路径,保持渲染一致。

  <details><summary>代码依据 pkg/operator/operands/common/common.go & _helpers.tpl</summary>

  ```diff
  - return []v1.EnvVar{{Name: "GODEBUG", Value: "fips140=only"}}
  + return []v1.EnvVar{{Name: "GODEBUG", Value: "fips140=only,tlsmlkem=0"}}
  ```
  ```diff
   - name: GODEBUG
  -  value: fips140=only
  +  value: fips140=only,tlsmlkem=0
  ```
  </details>
### 后续发展方向 [AI]
- 反映 KAI 的 FIPS-only 变体正被**推向真实集群可用**(此前 only 模式实际连 API server 都握手失败)。文档也补注这是上游 Go/k8s 已知缺口而非 KAI 特有,并警告若 API server 仅接受 `X25519MLKEM768` 仍会失败。证据只覆盖 GODEBUG 取值与文档,未见对 FIPS 镜像构建链或其它非 TLS 加密路径的改动。

## 本期无实质改动(折叠)
<details><summary>7 个 repo 本期无实质增量(EMPTY / 仅 bump·CI·merge / 仅文档,均保锚点)</summary>

- NVIDIA/gpu-operator — 唯一新提交为 CONTRIBUTING.md 增加"重大改动先开 issue"流程说明,无代码/CRD 信号(HEAD e6bac630,Release v26.7.0)
- NVIDIA/nvidia-container-toolkit — 无新提交(HEAD 仍 3121efcf,Release v1.20.0)
- NVIDIA/k8s-device-plugin — 无新提交(HEAD 仍 5a3b3d85,Release v0.20.0)
- kubernetes-sigs/dra-driver-nvidia-gpu — ahead=4/66 文件但全为 bump/CI/merge,无实质提交(HEAD ccb1632e,Release v0.5.0)
- NVIDIA/dcgm-exporter — 无新提交(HEAD 仍 181290c3,Release 4.6.0-4.8.3)
- NVIDIA/DCGM — 无新提交(HEAD 仍 64df9f89,分支 master)
- NVIDIA/mig-parted — ahead=2 仅 bump/CI/merge,无实质提交(HEAD 288cbe55,Release v0.15.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=e6bac6302f3db9fd1c31d285685fd61bdbbc37fd branch=main release=v26.7.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3121efcf04bfe6898daa13d06c3101b1adc22234 branch=main release=v1.20.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=63168bd04fdc30a77e16422d50a491f587636ac2 branch=main release=— scanned=2026-09-01 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=5a3b3d85a44ec0e493684c713218eaea07675601 branch=main release=v0.20.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=ccb1632e46522e9085f397106d9946a7dc7f39e8 branch=main release=v0.5.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-09-01 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-01 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=288cbe55b0a8408fe6a85b05fa31ebfa0168f23a branch=main release=v0.15.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=99f938ed5bf1297650bccd0cc7e747575341b64a branch=main release=v0.14.8 scanned=2026-09-01 -->

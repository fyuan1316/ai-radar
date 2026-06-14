# NVIDIA 算力栈 diff 雷达 2026-06-15

## 摘要
- 本日无实质代码改动:9 仓中 8 仓无新提交(EMPTY),仅 KAI-Scheduler 有 1 条**纯文档**提交(给 CONTRIBUTING.md 加 DCO 签名指引),不涉及算力栈代码/API/CRD。
- 当日重要改变:无。按空日约定,只归档保锚点,不推飞书。

## 当日重要改变
无(唯一提交为文档,无任何信号路径命中)。

## kai-scheduler/KAI-Scheduler: 964bf470 -> b54b6447
- 比较: 964bf470d46e31f5869de01efba7e69c10bd8dd5 -> b54b6447 | ahead=1 | files=1 | Release: v0.15.2
### AI 总结重点(源码 diff 为据)
- 仅给 `CONTRIBUTING.md` 追加一节 "Developer Certificate of Origin (DCO)",要求所有提交带 `-s` 签名(`Signed-off-by`),并给出 `git commit --amend -s` / `git rebase --signoff origin/main` 的补签命令。属社区流程文档,**无代码/调度逻辑/CRD 变化**。

  <details><summary>代码依据 CONTRIBUTING.md</summary>

  ```diff
  +## Developer Certificate of Origin (DCO)
  +
  +All commits must be signed off to certify you authored the change and agree to the [DCO](https://developercertificate.org/). Add `-s` to your commit command:
  +
  +```bash
  +git commit -s -m "feat: my change"
  +```
  +
  +**Fixing unsigned commits:**
  +
  +```bash
  +# Amend the last commit
  +git commit --amend -s
  +
  +# Sign all commits on your branch at once
  +git rebase --signoff origin/main
  +```
  ```
  </details>
- 提交: https://github.com/kai-scheduler/KAI-scheduler/pull/1692
### 后续发展方向 [AI]
- 仅为社区贡献流程规范化(强制 DCO),与调度能力无关。证据只覆盖此 1 个文档文件,本日 diff 未见任何 scheduler/plugin/CRD 代码改动。

## 本期无实质改动(折叠)
<details><summary>8 仓 EMPTY(仅保锚点)</summary>

- NVIDIA/gpu-operator(无新提交,Release v26.3.2)
- NVIDIA/nvidia-container-toolkit(无新提交,Release v1.19.1)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交,Release v0.19.2)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交,Release v0.4.1-rc.1)
- NVIDIA/dcgm-exporter(无新提交,Release 4.5.3-4.8.2)
- NVIDIA/DCGM(无新提交,master)
- NVIDIA/mig-parted(无新提交,Release v0.14.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=fed0b2a686a2b305d9cb485cd3f7bb343aae5296 branch=main release=v26.3.2 scanned=2026-06-15 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=59c042086ec213caba72dc7570facffc911f38dd branch=main release=v1.19.1 scanned=2026-06-15 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=5c00b0e6bdb2ddc35a9ebd96e1221abe25049798 branch=main release=— scanned=2026-06-15 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=8993bf00afc77b8d4e7e076dd27de45b71b6b9e7 branch=main release=v0.19.2 scanned=2026-06-15 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=dccc5fee48302b3522369acd598af57420fbd6a1 branch=main release=v0.4.1-rc.1 scanned=2026-06-15 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-15 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-15 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=abc8f3b67eea982370a8d0f60838feec0691e051 branch=main release=v0.14.2 scanned=2026-06-15 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=b54b644742d1043ed8fac5ee9650f19f295f1e65 branch=main release=v0.15.2 scanned=2026-06-15 -->

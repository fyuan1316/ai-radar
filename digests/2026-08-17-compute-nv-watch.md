# NVIDIA 算力栈 diff 雷达 2026-08-17

## 摘要
- 全栈基本静默:9 仓中 8 仓无新提交,唯一动的是 KAI-Scheduler,且只有 Helm chart 一处配置面小改。
- KAI-Scheduler 给 kai-config 加了 `global.daemonsetsTolerations`,让运维方能给「算子铺下去的 DaemonSet」(如 NUMA placement exporter)统一注 tolerations,而不必逐个 DaemonSet 改。
- 无 API/CRD 字段、无驱动容器化/DRA/监控语义变化。

## 当日重要改变
无(唯一改动为 Helm 配置项新增,未触发弃用/API/CRD/架构/版本跨档信号)。

## kai-scheduler/KAI-Scheduler: cea080fe -> 38dd06fe
- 比较: cea080fe -> 38dd06fe | ahead=2 | files=5 | Release: v0.16.9(releases API 现返 v0.16.9,较上期记录的 v0.17.0 回退,应为旧线 backport 补丁发布,非主线降级)
- 比较页: https://github.com/kai-scheduler/KAI-Scheduler/compare/cea080fe6f7674f669bea907c8a92b5edeaa31b7...38dd06fe

### AI 总结重点(源码 diff 为据)
- 在 kai-config 渲染模板 `_helpers.tpl` 里新增分支:当 `.Values.global.daemonsetsTolerations` 非空时,把它 `toYaml` 进 kai-config CR 的 `spec.global.daemonsetsTolerations`。语义是给「集群级 DaemonSet」(注释点名 NUMA placement exporter)提供一层统一 tolerations,由 operator 合并到各 DaemonSet 自身 tolerations 之前。此前只有 `global.tolerations` 一个入口,无法单独控制 DaemonSet 类工作负载的容忍度。PR #2076。
  <details><summary>代码依据 deployments/kai-scheduler/templates/_helpers.tpl</summary>

  ```diff
       tolerations:
         {{- toYaml .Values.global.tolerations | nindent 6 }}
       {{- end }}
  +    {{- if .Values.global.daemonsetsTolerations }}
  +    daemonsetsTolerations:
  +      {{- toYaml .Values.global.daemonsetsTolerations | nindent 6 }}
  +    {{- end }}
  ```
  </details>
  <details><summary>代码依据 deployments/kai-scheduler/values.yaml</summary>

  ```diff
     tolerations: []
  +  # Additional tolerations for cluster DaemonSets (e.g. NUMA placement exporter).
  +  # Merged ahead of each DaemonSet's own tolerations by the operator.
  +  daemonsetsTolerations: []
  ```
  </details>
- 另一条提交仅是把 `.cursor/` 加进 `.gitignore`(编辑器噪声,无功能影响)。

### 后续发展方向 [AI]
- 证据只覆盖 chart values → kai-config CR 的字段透传,未见 operator 侧消费 `spec.global.daemonsetsTolerations` 的 Go 代码 hunk,故「合并到各 DaemonSet 之前」这一行为仅凭 values.yaml 注释推断,未在本次 diff 里验证。方向上看,KAI 正把 DaemonSet 类附属组件(NUMA exporter 等)的调度约束从「硬编码/逐个配」收敛为全局可调,是可运维性打磨,而非调度算法能力变化。

## 本期无实质改动(折叠)
<details><summary>8 仓无新提交 / 仅 bump·CI·merge</summary>

- NVIDIA/gpu-operator(无新提交)
- NVIDIA/nvidia-container-toolkit(无新提交)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=ed270f823c2ecbe6d4f854054db084d4b6491a4b branch=main release=v26.3.3 scanned=2026-08-17 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=cb5d6990b8069e8ad9bdb67f9a2b3ff832d9531c branch=main release=v1.20.0 scanned=2026-08-17 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=6c629a86a8ddf96a98085c8abad0406f1231e326 branch=main release=— scanned=2026-08-17 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=02811acf135e9ac0451d5d96efb9ebe52f7fe78d branch=main release=v0.19.3 scanned=2026-08-17 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=d485fb70d00709811fba898acef76cf809b192b2 branch=main release=v0.4.1 scanned=2026-08-17 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-17 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-17 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5c3505c4fe8170d06c726f90ef332c93131653f3 branch=main release=v0.14.5 scanned=2026-08-17 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=38dd06fe520e0d422971f284ce117d9f2d818d06 branch=main release=v0.16.9 scanned=2026-08-17 -->
</content>
</invoke>

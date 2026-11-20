# HAMi diff 雷达 2026-11-21

## 摘要
- 当日只有 volcano-vgpu-device-plugin 有实质改动(PR #256、#263),**全部是文档和注释，没有 Go 代码改动**。有两个提交标题含 "drop",命中 [弃用/移除] 关键词，按规则列在下面。但删掉的是文档里写错的 `--gpu-strategy` flag 和 `GPU_MEMORY_FACTOR` 环境变量。核对 HEAD 的 `cmd/vgpu/main.go`:代码里本来就没有注册这两项，所以运行时行为没有变化。
- 文档首次写明 `volcano.sh/vgpu-memory` 的单位是"块"而不是 MB,1 块等于 `gpuMemoryFactor` MiB。device plugin 的 `--gpu-memory-factor` flag 和 Volcano scheduler 读取的 ConfigMap `gpuMemoryFactor` 是两份配置，必须手动保持一致。改了 factor 之后，已有的 Pod 请求含义随之改变，需要换算请求值并重建 Pod。
- 新增 `doc/karpenter.md`:用 Karpenter NodeOverlay(alpha)把 vGPU 扩展资源告诉 Karpenter,这样 GPU 节点池可以从 0 扩容。HAMi 主仓只有 libvgpu 子模块 bump 到 `6ef40c6`(#3496),也就是把昨天 HAMi-core 的 driver admission 客户端带进了主仓。其余 3 个仓库没有新提交。

## 当日重要改变
- volcano-vgpu-device-plugin [弃用/移除](仅文档更正，代码未变)。提交 1947d111 "docs: drop unregistered gpu-strategy flag and GPU_MEMORY_FACTOR env var" 和 14d400ed 从 `doc/design.md` 删掉了 `--gpu-strategy` / `$GPU_STRATEGY` 和 `$GPU_MEMORY_FACTOR` 两行。核对 HEAD 的 `cmd/vgpu/main.go`:代码中没有 `gpu-strategy` flag,`gpu-memory-factor` flag 也没有配置 `EnvVars`。所以这次删的是文档里本来就不生效的配置项。如果有用户照旧文档设置了 `GPU_MEMORY_FACTOR` 环境变量，这个设置此前一直被静默忽略。 https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/256
- 其余信号未命中：没有 API/CRD 路径改动、没有 proposal、没有新增顶层 package、没有版本跨档(HAMi v2.11.0、volcano-vgpu 1.13.0、WebUI v1.3.0 均未变)。

## Project-HAMi/volcano-vgpu-device-plugin: e5b0164c -> ad7518bf
- 比较: e5b0164caef64359ea10a7430a15008fa6be2ecb -> ad7518bf  | ahead=9 | files=7 | Release: volcano-vgpu-device-plugin-1.13.0(未变)
- 比较链接: https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/e5b0164caef64359ea10a7430a15008fa6be2ecb...ad7518bf612f8e5ba09fd9bca56761793324b8f7
- 涉及两个 PR:#256 gpuMemoryFactor 单位语义(https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/256)和 #263 Karpenter 从零扩容(https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/263)。7 个文件都是 doc、README、Helm values 注释和 examples 注释,**没有 .go 文件**。
- 对照：下面关于 flag 的结论，除了 diff,还对照了 HEAD `cmd/vgpu/main.go` 第 199-218 行的 flag 定义(https://github.com/Project-HAMi/volcano-vgpu-device-plugin/blob/ad7518bf612f8e5ba09fd9bca56761793324b8f7/cmd/vgpu/main.go)。

### AI 总结重点(源码 diff 为据)
- **文档里的 flag 表收敛到与代码一致**(`doc/design.md`)。删掉了 `--gpu-strategy`(env `$GPU_STRATEGY`,默认 `share`)这一行，以及 `number`/`share` 两种策略的示例和 `GPUStrategy` 配置文件示例。`--gpu-memory-factor` 的 Envvar 一列从 `$GPU_MEMORY_FACTOR` 改成 `-`,文档也明确写了 "There is no `GPU_MEMORY_FACTOR` environment variable"。HEAD 代码中 `cli.UintFlag{Name: "gpu-memory-factor", Value: 1}` 确实没有 `EnvVars`,flag 列表里也没有 gpu-strategy。结论：这是文档纠错，不是功能移除。提交: https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/1947d1113dddfb5ce97294530c742208dfefd21c
  <details><summary>代码依据 doc/design.md</summary>

  ```diff
  -| `--gpu-strategy`         | `$GPU_STRATEGY`         | `"share"`       |
  -| `--gpu-memory-factor`    | `$GPU_MEMORY_FACTOR`    | `1`             |
  +| `--gpu-memory-factor`    | `-`                     | `1`             |
   | `--config-file`          | `$CONFIG_FILE`          | `""`            |
  ...
  - - args: ["--gpu-strategy=number"] will let device plugin using the gpu-number strategy
  - - args: ["--gpu-strategy=share","--gpu-memory-factor=10"] will let device plugin using the gpu-share strategy, and memory factor is 10MB
  + - args: ["--gpu-memory-factor=10"] will let device plugin use 10 MiB memory blocks
  ```
  </details>
  <details><summary>对照 HEAD cmd/vgpu/main.go(非 diff,flag 定义原文)</summary>

  ```go
  		&cli.UintFlag{
  			Name:  "gpu-memory-factor",
  			Usage: "the default gpu memory block size is 1MB",
  			Value: 1,
  		},
  ```
  </details>
- **factor 有两个配置源，需要手动对齐**。新文档写明:`--gpu-memory-factor` 只改 device plugin 一侧的 factor。Volcano scheduler 从 ConfigMap `volcano-vgpu-device-config` 读取 `gpuMemoryFactor`。两边必须一致，改 ConfigMap 之后 device plugin 和 `volcano-scheduler` 都要重启。也就是说，调度器按块数记账和节点按块数注册，依赖的是两份相互独立的配置，代码里没有校验两者是否一致。
  <details><summary>代码依据 doc/design.md</summary>

  ```diff
  +The `--gpu-memory-factor` flag overrides only the device plugin's factor; Volcano
  +scheduler reads `gpuMemoryFactor` from the device ConfigMap (`volcano-vgpu-device-config`).
  +Keep both factors aligned and restart both the device plugin and
  +`volcano-scheduler` after changing the ConfigMap.
  ```
  </details>
- **`vgpu-memory` 的单位从"MB"改为"块"**(README、examples、values 注释同步修改)。hami-core 模式下，每个 vGPU 的显存上限 = `request * gpuMemoryFactor` MiB,请求值应按 `ceil(期望 MiB / factor)` 计算。MIG 模式下 plugin 不设置 `CUDA_DEVICE_MEMORY_LIMIT_<i>`,实际可用显存由 MIG 切片几何决定，可能大于请求值。节点注册的块数 = `sum(floor(每卡 MiB / factor))`,上限 60000(受 kubelet `ListAndWatch` 默认 gRPC 接收上限限制，这个 60000 约束旧文档里已经有)。新增的约束：暴露同一资源名的节点要用相同的 factor,否则同一个请求落到不同节点上，代表的显存不同。改 factor 之后，已有 manifest 要换算请求值，运行中的 Pod 要重建。
  <details><summary>代码依据 README.md / examples/vgpu-case02.yml</summary>

  ```diff
  -        volcano.sh/vgpu-memory: 3000 # optional: MB per vGPU
  +        volcano.sh/vgpu-memory: 3000 # optional: memory blocks per vGPU
  ...
  +memory limit per vGPU (MiB) = vgpu-memory request * gpuMemoryFactor
  +vgpu-memory request = ceil(desired memory in MiB / gpuMemoryFactor)
  ...
  +Use the same factor for every node that exposes the same memory resource name.
  +Otherwise, the same Pod request represents different memory limits depending
  +on the selected node.
  ```
  ```diff
  -        volcano.sh/vgpu-memory: 10240 #each GPU request 10G device memory
  +        volcano.sh/vgpu-memory: 10240 # 10 GiB with gpuMemoryFactor: 1
  ```
  </details>
- **新增 Karpenter 从零扩容指南**(`doc/karpenter.md`,PR #263)。Karpenter 在扩容模拟时只认识 `nvidia.com/gpu`,不认识 `volcano.sh/vgpu-number/memory/cores`。因此只请求 vGPU 资源的 Pod 匹配不到任何实例类型，会一直 Pending。方案是每种"GPU 型号 × 卡数"写一个 `karpenter.sh/v1alpha1 NodeOverlay`,在 `capacity` 里声明节点注册后会上报的三种扩展资源。数值建议从运行中节点的 allocatable 读取，因为 NVML 报告的显存小于标称值。overlay 声明的值偏大，会拉起放不下 Pod 的节点;偏小，只会让接近上限的 Pod 跳过该机型。文档写明的测试环境是 Karpenter 1.15.0 + Volcano v1.15.4 + plugin v1.13.0 on EKS。
  <details><summary>代码依据 doc/karpenter.md</summary>

  ```diff
  +| `volcano.sh/vgpu-number` | GPUs × `deviceSplitCount` |
  +| `volcano.sh/vgpu-memory` | Sum over GPUs of (memory in MiB as NVML reports it ÷ `gpuMemoryFactor`) |
  +| `volcano.sh/vgpu-cores` | GPUs × 100 × `deviceCoreScaling` (1 by default) |
  ...
  +  capacity:
  +    volcano.sh/vgpu-number: "8"
  +    volcano.sh/vgpu-memory: "5758"
  +    volcano.sh/vgpu-cores: "100"
  ```
  </details>

### 后续发展方向 [AI]
- 本期是"对齐文档与代码"的维护期，能力边界没有变化。Volcano 集成路径上的显存粒度仍然靠"每块注册一个合成设备"实现(属于 HAMi 软切分 + 扩展资源计数，不是 DRA)。60000 设备上限和"factor 两处配置"这两个约束，现在只写进了文档，还没有在代码里做校验或统一配置源。证据只覆盖本期 diff 和 HEAD 的 flag 定义，没有看到 scheduler 侧读取 ConfigMap 的代码改动，也没有看到任何一致性校验的实现。
- 合成设备计数模型在弹性场景下有额外成本：节点自动扩容器无法预知扩展资源，需要用 NodeOverlay 手工声明，每种机型 × 卡数一份，而且要从真实节点读取数值。这是扩展资源路径相对 DRA 路径(ResourceSlice 可以预先描述设备)的结构性短板。本期只有文档层面的补救，未见向 DRA 迁移的代码。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos</summary>

- `Project-HAMi/HAMi`:7482d491 -> db50ead6,仅 1 个依赖 bump。libvgpu 子模块从 `9bc18ca` 升到 `6ef40c6`(#3496,https://github.com/Project-HAMi/HAMi/commit/db50ead676875f95db018c00081e68189b5d1e0e)。`6ef40c6` 就是昨天 HAMi-core 合入 driver admission 客户端后的 HEAD,所以主仓镜像从这次起带上该客户端(默认关闭，需双 env 开启)。Release 仍是 v2.11.0。
- `Project-HAMi/HAMi-core`:无新提交(仍 6ef40c6e)
- `Project-HAMi/ascend-device-plugin`:无新提交(仍 9325759b / ascend-device-plugin-0.2.2)
- `Project-HAMi/HAMi-WebUI`:无新提交(仍 19a0f955 / v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=db50ead676875f95db018c00081e68189b5d1e0e branch=master release=v2.11.0 scanned=2026-11-21 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=6ef40c6e481b22057f6ac8fe0fbe54344ff34a6e branch=main release=— scanned=2026-11-21 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=ad7518bf612f8e5ba09fd9bca56761793324b8f7 branch=main release=volcano-vgpu-device-plugin-1.13.0 scanned=2026-11-21 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-21 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=19a0f955a652ba7f7e4af5a9315686829e884328 branch=main release=v1.3.0 scanned=2026-11-21 -->

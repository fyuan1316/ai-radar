# 任务:NVIDIA 算力栈 diff 雷达

## 目标
按 commit 区间跟踪 NVIDIA GPU 在 K8s 上的算力栈(驱动容器化 → device-plugin/DRA → 监控/拓扑 → 调度)的**代码级变化**,从 diff 判断功能趋势与重要改变。机制同 [hami-watch](./hami-watch.md)(diff-watch:每天、base..HEAD、`hack/diff-scan-gh.sh` 取数、LLM 只研判)。

## 与其他 task 的边界(硬约束)
- 本 task 管 **NVIDIA 供应商算力栈的代码实现**。
- HAMi 软虚拟化归 `hami-watch`;Ascend 归 `compute-ascend-watch`;通用 K8s 调度抽象/KEP(scheduler-plugins/kueue/DRA evolution/JobSet)与 NFD 仍归 `k8s-ai-infra`(新闻视角)。volcano 作为通用批调度也留在 k8s-ai-infra,本 task 不重复扫。

## 数据源(全部 GitHub,用 hack/diff-scan-gh.sh)
> 地址已逐个 API 核实(2026-06)。注意两处迁移、两处 archived。

| repo | 分支 | 层 | 优先级 | 说明 |
|---|---|---|---|---|
| `NVIDIA/gpu-operator` | main | L1 驱动容器化 | P0 | 编排 driver/toolkit/dcgm/mig 的总入口 |
| `NVIDIA/nvidia-container-toolkit` | main | L1 | P0 | 容器内 GPU 可见性的根,runtime hook |
| `NVIDIA/gpu-driver-container` | main | L1 | P1 | driver 容器镜像构建(预编译/OS 矩阵) |
| `NVIDIA/k8s-device-plugin` | main | L2 device-plugin | P0 | 经典 device plugin + time-slicing/MPS 配置面 |
| `kubernetes-sigs/dra-driver-nvidia-gpu` | main | L2 DRA | P0 | **原 NVIDIA/k8s-dra-driver-gpu,已迁 kubernetes-sigs**;GPU 共享/分片的未来主线 |
| `NVIDIA/dcgm-exporter` | main | L3 监控 | P1 | GPU 指标暴露事实标准 |
| `NVIDIA/DCGM` | master | L3 | P2 | 底层健康/profiling 库(注意分支是 master) |
| `NVIDIA/mig-parted` | main | L3 拓扑 | P1 | MIG 静态切分配置器,硬切分风向标 |
| `kai-scheduler/KAI-Scheduler` | main | L4 调度 | P0 | **原 NVIDIA/KAI-scheduler,已迁独立 org**;NVIDIA 开源(原 Run:ai)调度器 |

> 不跟(已 archived,API 确认):`NVIDIA/gpu-feature-discovery`(并入 k8s-device-plugin)、`NVIDIA/k8s-kata-manager`、`NVIDIA/nvidia-docker`(并入 container-toolkit)。

## 执行步骤 / 输出 / 重要改变信号 / 推送飞书 / 质量要求
**完全沿用 [hami-watch](./hami-watch.md) 的对应各节**,仅把 task 名换成 `compute-nv-watch`、DIGEST_FILE 换成 `digests/$(date +%Y-%m-%d)-compute-nv-watch.md`。要点重申:
- 每个 repo 跑 `./hack/diff-scan-gh.sh <repo> compute-nv-watch`;`__EMPTY__` 跳过正文但保锚点。
- 输出结构、`## 当日重要改变`、`## 扫描锚点`(含 EMPTY repo 锚点)一致。
- 空日(全 EMPTY)只归档不推飞书。
- NVIDIA 特有关注点:driver 容器化的 OS/预编译矩阵、time-slicing/MPS→DRA 的迁移信号、ClusterPolicy CRD 字段增删(`api/nvidia/v1/clusterpolicy_types.go` 是高价值信号文件)、dcgm 指标语义变化。

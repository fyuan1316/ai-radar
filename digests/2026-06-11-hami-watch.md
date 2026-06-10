# HAMi diff 雷达 2026-06-11

## 摘要
- 全家桶今日近乎静默:HAMi 主仓仅 1 笔 examples 整理(#1938),无 CRD/能力/调度逻辑变化;HAMi-core、volcano-vgpu、ascend-device-plugin、WebUI 四仓均无新提交。
- 唯一改动把根目录冗余的 `example.yaml` 与 `examples/nvidia/example.yaml` 合并为一份规范样例,顺带把演示镜像从 cuda11.7.1 升到 cuda12.5.0,并将"3 容器占位 Pod"换成真正跑 vectorAdd 的 Deployment。纯文档/样例,无功能影响。

## 当日重要改变
- 无(无 `[弃用/移除]`/`[API/CRD变更]`/`[架构方向]`/`[版本跨档]`/`[新能力]` 信号命中)。

## Project-HAMi/HAMi: 834513e8 -> 8d6644c9
- 比较: 834513e84e16be5f64936ce570dc153e086a1479 -> 8d6644c9 | ahead=1 | files=3 | Release: v2.9.0
- 提交: fix(examples): consolidate nvidia example and update changelog (#1938) https://github.com/Project-HAMi/HAMi/commit/8d6644c9445cf509563ccc5a60b57914a35ede60

### AI 总结重点(源码 diff 为据)
- 删除根目录 `example.yaml`(独立的 `gpu-test-workloads` 命名空间 + Deployment,带 `hostPID: true`、`priorityClassName: system-cluster-critical` 等特权配置),把样例统一收口到 `examples/nvidia/example.yaml`,消除两份重复样例。

  <details><summary>代码依据 example.yaml(removed +0/-59)</summary>

  ```diff
  -apiVersion: v1
  -kind: Namespace
  -metadata:
  -  name: gpu-test-workloads
  -...
  -          image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04
  -...
  -      hostPID: true
  -      priorityClassName: system-cluster-critical
  ```
  </details>

- `examples/nvidia/example.yaml` 由"单个 `gpu-pod`、3 个 `ubuntu:18.04` 容器(其中演示 `gpumem-percentage: 50` 与 `gpumem: 2000`、纯 sleep 不跑负载)"改写为 `Deployment cuda-sample-vector-add`,单容器跑 `while true; do /cuda-samples/vectorAdd; done`,资源请求收敛为 `nvidia.com/gpu: 1` + `nvidia.com/gpumem: 3000`,`gpucores`/`priority` 降为注释提示。演示镜像 cuda11.7.1-ubuntu20.04 → cuda12.5.0-ubuntu22.04。样例从"占位演示参数面"转为"可观测的真实运行负载",但不再演示 gpumem-percentage / 多容器分配写法。

  <details><summary>代码依据 examples/nvidia/example.yaml(modified +40/-28)</summary>

  ```diff
  -apiVersion: v1
  -kind: Pod
  -metadata:
  -  name: gpu-pod
  -spec:
  -  containers:
  -    - name: ubuntu-container
  -      image: ubuntu:18.04
  -      command: ["bash", "-c", "sleep 86400"]
  -      resources:
  -        limits:
  -          nvidia.com/gpu: 2
  -          nvidia.com/gpumem-percentage: 50
  -    - name: ubuntu-container0 ...
  -    - name: ubuntu-container1 ...
  -          nvidia.com/gpumem: 2000
  +apiVersion: apps/v1
  +kind: Deployment
  +metadata:
  +  name: cuda-sample-vector-add
  +spec:
  +  replicas: 1
  +  template:
  +    spec:
  +      containers:
  +        - name: cuda-sample-vector-add
  +          image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04
  +          args:
  +            - while true; do /cuda-samples/vectorAdd; done
  +          resources:
  +            limits:
  +              nvidia.com/gpu: 1
  +              nvidia.com/gpumem: 3000
  ```
  </details>

- `CHANGELOG.md` 仅把正文里引用样例的路径 `example.yaml` 改为 `examples/nvidia/example.yaml`,跟随上面的文件移动。

  <details><summary>代码依据 CHANGELOG.md(modified +1/-1)</summary>

  ```diff
  -See example.yaml for more details
  +See examples/nvidia/example.yaml for more details
  ```
  </details>

### 后续发展方向 [AI]
- 纯样例整理,不指向任何能力/架构变化;证据只覆盖 examples 与 CHANGELOG,未见 pkg/调度/CRD 改动。可推断 v2.9.0 后主仓进入文档/示例打磨期。要注意:新样例**删去了 `gpumem-percentage` 与多容器 vGPU 分配的演示**,后续若有人据样例学用法,百分比显存切分写法的可见度下降——属可用性细节,非能力回退。

## 本期无实质改动(折叠)
<details><summary>四仓无新提交</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release: hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=8d6644c9445cf509563ccc5a60b57914a35ede60 branch=master release=v2.9.0 scanned=2026-06-11 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=02a9ac22a438824b411e13ad4144fc152a1ec63b branch=main release=— scanned=2026-06-11 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-06-11 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-11 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-11 -->

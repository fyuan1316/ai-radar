# HAMi diff 雷达 2026-07-02

## 摘要
- HAMi 主仓落地 **AMD Instinct(ROCm)vGPU 设计草案**:首次把软切分能力扩到 N/华为之外的第三家 GPU 厂商,技术路线是 LD_AUDIT 拦截 + `ROC_GLOBAL_CU_MASK` 位图切 CU(而非 NVIDIA 的 LD_PRELOAD + SM 利用率百分比),显存走 `HIP_DEVICE_MEMORY_LIMIT`。目前节点锁/位图分配还是 stub(TODO)。
- 其余为工程小修:vGPU monitor 容器声明 metrics 端口(9394)使 Prometheus 可抓。
- HAMi-core / volcano-vgpu / ascend-device-plugin / HAMi-WebUI 四仓本日无实质改动。

## 当日重要改变
- Project-HAMi/HAMi [架构方向/新能力] 新增 AMD Instinct vGPU 设计草案 `docs/develop/amd-vgpu.md`,定义 AMD 专属注册/分配注解与 CU 位图切分协议,标志 HAMi 软切分向 ROCm 生态延伸。https://github.com/Project-HAMi/HAMi/commit/3b466ffa742d749629cdc70f624c327cc98b6437

## Project-HAMi/HAMi: 55846c8a -> 3b466ffa
- 比较: 55846c8a -> 3b466ffa | ahead=3 | files=4 | Release: v2.9.0
- 比较链接: https://github.com/Project-HAMi/HAMi/compare/55846c8afd245ad38baf38dd2b35920db9cf66de...3b466ffa742d749629cdc70f624c327cc98b6437

### AI 总结重点(源码 diff 为据)
- **新增第三家 GPU 厂商(AMD)的软切分设计草案**,与现有 NVIDIA 路径并存不冲突。核心技术选型:改用 `LD_AUDIT`(`la_symbind64`)而非 NVIDIA 的 `LD_PRELOAD`——原因是 ROCm 7.x 上 LD_PRELOAD 拦 HIP 符号会递归重入把 HIP 搞崩,LD_AUDIT 只拦跨库绑定可绕开。这是把 HAMi hook 模型移植到 ROCm 的关键分叉点。
  <details><summary>代码依据 docs/develop/amd-vgpu.md</summary>

  ```diff
  +**Why LD_AUDIT instead of LD_PRELOAD?**
  +In our prototype on ROCm 7.x, LD_PRELOAD broke HIP — interposing HIP symbols leads
  +to recursive re-entry through HIP-internal calls.
  +Switching to LD_AUDIT (`la_symbind64`), which intercepts only cross-library bindings,
  +resolved it. The existing NVIDIA LD_PRELOAD path is unchanged.
  ```
  </details>
- **算力切分口径与 NVIDIA 本质不同**:AMD 用 `amd.com/gpucores`=CU 个数(compute-unit count),不是 NVIDIA 的 SM 利用率百分比;落地手段是给每 pod 分配互不重叠的 CU 位图,容器启动时翻译成 `ROC_GLOBAL_CU_MASK`(hex 位图,如 `0x337f`)。位图分配是 **scheduler 职责**(需全局 device 分配态才能保证非重叠),device-plugin 只透传。这意味着 HAMi 调度器要为 AMD 新增位图分配器逻辑。
  <details><summary>代码依据 docs/develop/amd-vgpu.md</summary>

  ```diff
  +`amd.com/gpucores` is a **CU count**, not a percentage (contrast NVIDIA's SM-utilization %).
  +1. **The hard guarantee is non-overlap.** The scheduler
  +   assigns each pod a CU bitmap that does **not overlap** any other pod's bitmap ...
  +The count -> bitmap conversion is a **scheduler's** responsibility ...
  +The device-plugin simply passes the scheduler-decided mask through verbatim as `ROC_GLOBAL_CU_MASK`.
  ```
  </details>
- **协议层沿用 HAMi 现有多厂商约定**:节点注册走 `hami.io/node-amd-register`(DeviceInfo JSON 数组,`mode: hami-core`),分配结果走 `hami.io/amd-devices-allocated`,CU 位图因不合标准 `UUID,Type,mem,cores` 编码而另开 `amd.com/cu-mask` JSON 注解(与 Ascend 的 `huawei.com/<model>` 同思路)。显存 `amd.com/gpumem`(MB)注入为 `HIP_DEVICE_MEMORY_LIMIT_<i>`。
  <details><summary>代码依据 docs/develop/amd-vgpu.md</summary>

  ```diff
  +Registered under `hami.io/node-amd-register`, in JSON format — an array of `DeviceInfo` ...
  +hami.io/amd-devices-allocated: <UUID>,AMDGPU,<memMB>,<cuCount>:;
  +amd.com/cu-mask: [{"uuid":"<UUID1>","cu_mask":"0x337f"},{"uuid":"<UUID2>","cu_mask":"0x00ff"}]
  +`amd.com/gpumem` (MB) ... is injected by the device plugin as `HIP_DEVICE_MEMORY_LIMIT_<i>` (value `<MB>m`).
  ```
  </details>
- **当前是草案、核心隔离尚未实现**:非重叠靠节点锁 `AMDDevices.LockNode`/`ReleaseNodeLock` 保证,但文中明确这些现在是 stub、返回 `nil`(TODO 未实现);且即便位图不重叠,残余干扰仍存在(非零干扰不保证);`amd-smi`/`rocm-smi` 读 sysfs/drm 无法被 LD_AUDIT 拦,容器内仍看到物理资源。
  <details><summary>代码依据 docs/develop/amd-vgpu.md</summary>

  ```diff
  +Exclusivity of CU bitmaps across pods on a device will be enforced
  +under a node lock (`AMDDevices.LockNode` and `ReleaseNodeLock`) ...
  +(These are currently stubs; the node-lock enforcement is not yet implemented — TODO.)
  +- **No `amd-smi` / `rocm-smi` virtualization.** These read sysfs/drm, not HIP ...
  ```
  </details>
- **vGPU monitor 容器补齐 metrics 端口**:daemonsetnvidia chart 给 monitor 容器显式声明 `containerPort: 9394 name: metrics`,让 Prometheus/ServiceMonitor 能按名抓指标(此前只有进程监听、Pod spec 无端口声明)。
  <details><summary>代码依据 charts/hami/templates/device-plugin/daemonsetnvidia.yaml</summary>

  ```diff
  +          ports:
  +            - name: metrics
  +              containerPort: 9394
  +              protocol: TCP
             resources:
           {{- toYaml .Values.devicePlugin.monitor.resources | nindent 12 }}
  ```
  </details>

### 后续发展方向 [AI]
- **软切分从"双厂商(N+昇腾)"走向"多厂商框架化"**:AMD 草案复用了 `node-<vendor>-register` / `<vendor>-devices-allocated` / 厂商专属注解 三段式协议,说明 HAMi 正把厂商适配沉淀为可插拔模式;下一步预计在 scheduler 侧新增 AMD 位图分配器 + device-plugin(草案倾向扩展 ROCm/k8s-device-plugin 而非另起,因 kubelet 不允许两个插件注册同一 `amd.com/gpu`)。证据只覆盖设计文档(docs/develop),未见任何 scheduler/device-plugin 生产代码落地,`LockNode`/位图分配器均为 TODO stub,能力尚不可用。
- **算力语义分裂待收敛**:AMD 用 CU 个数、NVIDIA 用 SM 百分比、昇腾 vNPU 上期(2026-07-01)刚改百分比满值口径,三套 core 语义并存,HAMi 调度层如何统一抽象(count vs percent)是后续架构看点。证据仅见 amd-vgpu.md 对比性描述,未见统一抽象层代码。

## 本期无实质改动(折叠)
<details><summary>4 仓 EMPTY</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=3b466ffa742d749629cdc70f624c327cc98b6437 branch=master release=v2.9.0 scanned=2026-07-02 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=8f3a89c67b037d8fdfe6c4cd4d8c4f0cd6504811 branch=main release=— scanned=2026-07-02 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-02 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9f91d3013b3576b162cf0e942fb93b821576f97d branch=main release=— scanned=2026-07-02 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=8f42445d325736655d467842cb762b75f2612d25 branch=main release=hami-webui-1.2.0 scanned=2026-07-02 -->
</content>

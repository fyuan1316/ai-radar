# NVIDIA 算力栈 diff 雷达 2026-06-13

## 摘要
- DCGM 把 4.5.3 整版以一个 squash 提交并入 master:健康监控新增 ConnectX(CX NIC)实体监控分支并把 watch 位宽从 V2 升到 V3;诊断侧补 EUD(Extended Utility Diagnostics)GPU/CPU 二进制探测,新增 Blackwell HGX B200 168GB 与 RTX PRO 6000 Blackwell 的 nvvs 诊断 SKU 配置。GPU 健康/巡检正往"网卡 + Blackwell 整机"维度铺。
- KAI-Scheduler 仅 CI/文档:发布校验矩阵把 K8s 支持窗口向下扩到 1.28~1.30,并新增 1.36.1;SUPPORT.md 落了一张 KAI↔K8s↔DRA 兼容矩阵。无调度算法代码改动。
- 其余 7 仓(gpu-operator、container-toolkit、gpu-driver-container、k8s-device-plugin、dra-driver-nvidia-gpu、dcgm-exporter、mig-parted)本期均无实质改动。

## 当日重要改变
- NVIDIA/DCGM [新能力] 健康监控加入 ConnectX 实体(`DCGM_FE_CONNECTX`)分支,watch 位计数常量 `DCGM_HEALTH_WATCH_COUNT_V2`→`V3`,把 NIC 纳入与 GPU 同一套健康巡检框架。证据 `modules/health/DcgmHealthWatch.cpp` https://github.com/NVIDIA/DCGM/commit/d646460fe8ac5f3b67daf4f27385fe7701187d23
- NVIDIA/DCGM [新能力] 诊断 SKU 库新增 Blackwell HGX B200 168GB(id 2909)与 RTX PRO 6000 Blackwell(Galaxy TS2,id 2bb4)的功耗/压力/PCIe/带宽门限。证据 `nvvs/diag-skus.yaml.in` https://github.com/NVIDIA/DCGM/commit/d646460fe8ac5f3b67daf4f27385fe7701187d23
- NVIDIA/DCGM [新能力] DiagManager 增 EUD(specializediag/cpueud)二进制存在性探测与 original_level 注入,为 long/xlong 套件下以 root 重跑 EUD 铺路。证据 `modules/diag/DcgmDiagManager.cpp` https://github.com/NVIDIA/DCGM/commit/d646460fe8ac5f3b67daf4f27385fe7701187d23

## NVIDIA/DCGM: 0869351a -> d646460f
- 比较: 0869351a7d89ff24e68c93b92a50d981cea15580 -> d646460f | ahead=1 | files=70 | 分支 master | Release: —(commit 标题 "DCGM 4.5.3 (#299)",内部版本 squash 镜像合入)

### AI 总结重点(源码 diff 为据)
- **健康监控新增 ConnectX(NIC)实体监控分支,watch 位宽 V2→V3**:`SetWatches`/`MonitorWatches` 原本只对 GPU/GPU_I/GPU_CI/CPU 实体循环 `DCGM_HEALTH_WATCH_COUNT_V2` 个位;现统一改为 `_V3`,并新增 `case DCGM_FE_CONNECTX` 调用 `SetConnectX(...)` 注册 `DCGM_HEALTH_WATCH_CONNECTX` 位。语义:把 ConnectX 网卡纳入 DCGM 统一健康框架,GPU 健康监控从"GPU+CPU+NVSwitch"扩到"+NIC"。
  <details><summary>代码依据 modules/health/DcgmHealthWatch.cpp</summary>

  ```diff
  -                for (unsigned int bitIndex = 0; bitIndex < DCGM_HEALTH_WATCH_COUNT_V2; bitIndex++)
  +                for (unsigned int bitIndex = 0; bitIndex < DCGM_HEALTH_WATCH_COUNT_V3; bitIndex++)
   ...
  +            case DCGM_FE_CONNECTX:
  +                for (unsigned int bitIndex = 0; bitIndex < DCGM_HEALTH_WATCH_COUNT_V3; bitIndex++)
  +                {
  +                    unsigned int bit = 1 << bitIndex;
  +                    switch (bit)
  +                    {
  +                        case DCGM_HEALTH_WATCH_CONNECTX:
  +                            tmpRet = SetConnectX(entities[i].entityGroupId, entities[i].entityId, ...);
  ```
  </details>
- **新增 NVLink5 计数字段是否需要聚合的判定函数**:`DcgmCMUtils.cpp` 加 `NvmlFieldRequiresNvLinkAggregate()`,对一大批 NVLink5 COUNT/effective error/BER/FEC_HISTORY 字段(`NVML_FI_DEV_NVLINK_COUNT_*`)返回 true。语义:NVLink5(Blackwell)代际新增的逐链路计数指标在缓存层需要做跨链路聚合,这是为新一代 NVLink 拓扑指标做的取数适配。
  <details><summary>代码依据 dcgmlib/src/DcgmCMUtils.cpp</summary>

  ```diff
  +bool NvmlFieldRequiresNvLinkAggregate(unsigned short nvmlFieldId) noexcept
  +{
  +    switch (nvmlFieldId)
  +    {
  +        case NVML_FI_DEV_NVLINK_COUNT_XMIT_PACKETS:
  +        ...
  +        case NVML_FI_DEV_NVLINK_COUNT_FEC_HISTORY_15:
  +            return true;
  +        default:
  +            return false;
  ```
  </details>
- **诊断 SKU 库新增两款 Blackwell 整机/工作站配置**:`nvvs/diag-skus.yaml.in` 追加 HGX B200 168GB(id 2909,PCIe gen5 x16、targeted_power 1000W、sm_stress 33843)和 RTX PRO 6000 Blackwell Max-Q(Galaxy TS2,id 2bb4,启用 fp16_gemm/fp64_gemm 混比)。语义:nvvs/dcgmi diag 可对这两款新硬件跑功耗/压力/PCIe/内存带宽门限校验,是 DCGM 跟进 Blackwell 出货的硬件支持信号。
  <details><summary>代码依据 nvvs/diag-skus.yaml.in</summary>

  ```diff
  +  - name: HGX B200 168GB
  +    id: 2909
  +    targeted_power:
  +      target_power: 1000.00
  +  - name: Galaxy TS2 # NVIDIA RTX PRO 6000 Blackwell Max-Q Workstation Edition
  +    id: 2bb4
  +      enable_fp16_gemm: true
  +      fp64_gemm_ratio: 0.6
  ```
  </details>
- **DiagManager 增 EUD 二进制探测与 original_level 注入**:新增 `SupportGpuEud()`/`SupportCpuEud()`,通过环境变量(`DCGM_EUD_BIN_PATH`/`DCGM_CPU_EUD_BIN_PATH`)或默认路径(`/usr/share/nvidia/diagnostic/specializediag`、`.../cpu/diagnostic/cpueud`)探测 EUD 可执行文件是否存在;`AddEudTestsOriginalLevel()` 在 long/xlong 套件下把测试原始 level 写进 `drd->testParms`,以便 EUD 以 root 重跑时 EudPlugin 能正确设置 profile。语义:把 EUD(厂商专用深度诊断)接入标准 diag 流程,按二进制是否落盘动态启用。
  <details><summary>代码依据 modules/diag/DcgmDiagManager.cpp</summary>

  ```diff
  +bool SupportGpuEud()
  +{
  +    std::string_view constexpr eudBinPath = "/usr/share/nvidia/diagnostic/specializediag";
  +    return CheckEnvOrPathExist("DCGM_EUD_BIN_PATH", eudBinPath);
  +}
  +dcgmReturn_t AddEudTestsOriginalLevel(dcgmRunDiag_v10 *drd, dcgmPolicyValidation_t runLevel)
  ```
  </details>
- **CacheManager 防越界 + C++20 ranges 重构**:`IsGpuMigEnabled` 在 `gpuId < m_numGpus` 之外补 `&& gpuId < m_gpus.size()` 防越界;多处 `for(i<m_numGpus)` 改为 `m_gpus | std::views::take(m_numGpus)`。纯健壮性/可读性改动,无行为变化。
  <details><summary>代码依据 dcgmlib/src/DcgmCacheManager.cpp</summary>

  ```diff
  -        if (gpuId < m_numGpus)
  +        if (gpuId < m_numGpus && gpuId < static_cast<unsigned int>(m_gpus.size()))
  ```
  </details>

### 后续发展方向 [AI]
- DCGM 这版的主轴是"超越 GPU 单体":ConnectX NIC 进健康框架 + NVLink5 逐链路计数聚合 + Blackwell 整机 diag 配置,指向以 GB200/B200 NVL 机柜为单位做"GPU+NVLink+NIC"整机健康巡检。对我们产品:若监控栈依赖 dcgm-exporter,后续需关注 ConnectX/NVLink5 新字段是否会经 exporter 暴露成新指标(本期 dcgm-exporter 仓未动,证据只覆盖底层 DCGM,未见 exporter 侧映射)。
- 证据边界:本仓改动是 4.5.3 整版 squash 单提交,逐文件 hunk 已截断(每文件 80 行),未逐一展开测试文件;ConnectX/EUD 的具体阈值与 exporter 暴露与否未在本 diff 内确认。

## KAI-Scheduler: 363ebfb0 -> 964bf470
- 比较: 363ebfb0f75297401d0d3a979321a2bac39773bb -> 964bf470 | ahead=1 | files=3 | Release: v0.15.2(提交 "ci: expand k8s support testing to 1.28+" #1687)

### AI 总结重点(源码 diff 为据)
- **本期为 CI/文档,无调度器代码改动**:`on-release.yaml` 发布校验矩阵向下补 K8s 1.30.4/1.29.8/1.28.13(均 default),并新增 1.36.1;kind-action v1.13→v1.14、kind v0.31→v0.32。`SUPPORT.md` 新增 KAI↔K8s↔DRA 兼容矩阵:v0.14.x/v0.15.x 线校验 1.31~1.35(1.32/1.33 带 dra-enabled),main 线再加 1.28~1.30 与 1.36.1。语义:对外承诺的 K8s 支持窗口下探到 1.28、上探到 1.36,DRA 仅在 1.32(v1beta1)/1.33(v1beta2)走 dra-enabled 双配置,1.34+ 视为 DRA GA。
  <details><summary>代码依据 .github/workflows/on-release.yaml + SUPPORT.md</summary>

  ```diff
  +          - k8s_version: v1.36.1
  +            feature_config: default
   ...
  +          - k8s_version: v1.30.4
  +          - k8s_version: v1.29.8
  +          - k8s_version: v1.28.13
  +| `main` / next unreleased line | `v1.28.13` ... `v1.33.4` (`default`, `dra-enabled`), `v1.34.0`, `v1.35.0`, `v1.36.1` |
  ```
  </details>

### 后续发展方向 [AI]
- 信号仅在支持矩阵层面:KAI 把 DRA 校验明确分档(1.32 v1beta1 / 1.33 v1beta2 / 1.34+ GA),说明其 DRA 适配按 K8s API 版本做了运行时分流——与我们对标 GPU 调度的 DRA 路线选型一致。本期无调度算法/插件代码改动,方向判断仅基于 CI 矩阵与 SUPPORT.md,未见 scheduler 源码佐证。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY(仅 bump/CI/merge 或无新提交)</summary>

- NVIDIA/gpu-operator(ahead=6,仅 bump/CI/merge)
- NVIDIA/nvidia-container-toolkit(无新提交)
- NVIDIA/gpu-driver-container(ahead=4,仅 bump/CI/merge)
- NVIDIA/k8s-device-plugin(ahead=2,仅 bump/CI/merge)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/mig-parted(ahead=6,仅 bump/CI/merge)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=fed0b2a686a2b305d9cb485cd3f7bb343aae5296 branch=main release=v26.3.2 scanned=2026-06-13 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=59c042086ec213caba72dc7570facffc911f38dd branch=main release=v1.19.1 scanned=2026-06-13 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=5c00b0e6bdb2ddc35a9ebd96e1221abe25049798 branch=main release=— scanned=2026-06-13 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=684cbd961a8ee3f34a4d86588c4eeac68f73cf56 branch=main release=v0.19.2 scanned=2026-06-13 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=749a743cea793f08688f871b69596c253374b0b6 branch=main release=v0.4.0 scanned=2026-06-13 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-13 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-13 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=abc8f3b67eea982370a8d0f60838feec0691e051 branch=main release=v0.14.2 scanned=2026-06-13 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=964bf470d46e31f5869de01efba7e69c10bd8dd5 branch=main release=v0.15.2 scanned=2026-06-13 -->

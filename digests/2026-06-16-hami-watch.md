# HAMi diff 雷达 2026-06-16

## 摘要
- HAMi 主仓新增**壁仞(Biren)GPU** 厂商支持(`pkg/device/biren`,资源名 `birentech.com/gpu`),但当前仅**整卡按数量分配**,无显存/算力软切分——是又一个"先接管调度、暂不软隔离"的新厂商接入。
- 新增 vLLM **跨 vGPU 张量并行**官方样例(单 Pod 申请 2 张 HAMi vGPU,`--tensor-parallel-size 2` + `--disable-custom-all-reduce`),验证 HAMi 切分出的 vGPU 可直接承载 TP 多 worker。
- 旧 `docs/`(含全部 `docs/proposals`)整体下线,迁到独立 website 仓,**属文档搬家非能力弃用**;其余 4 仓(HAMi-core/volcano/ascend/WebUI)无新提交。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 新增 `pkg/device/biren` 厂商驱动(245 行),实现 `device.Devices` 全套接口,接入 scheduler 设备注册表;整卡粒度,无 vmem/vcore。证据:`pkg/device/biren/device.go`、`pkg/scheduler/config/config.go`。https://github.com/Project-HAMi/HAMi/pull/1711
- Project-HAMi/HAMi [架构方向] `docs/proposals/*` 等全部 legacy 文档删除(superseded by project-hami/website)。属内容迁移,非 proposal/能力作废。https://github.com/Project-HAMi/HAMi/pull/1913

## Project-HAMi/HAMi: 5dca58eb -> df6ac09e
- 比较: 5dca58eb3d4c75806517ffe910c1c03ba6220af9 -> df6ac09e | ahead=4 | files=71 | Release: v2.9.0
- https://github.com/Project-HAMi/HAMi/compare/5dca58eb3d4c75806517ffe910c1c03ba6220af9...df6ac09e0420fd337133eb673d7fe72269dd194e

### AI 总结重点(源码 diff 为据)

- **新增 Biren 厂商驱动,但只做"整卡按数量分配",不做软切分**:`GenerateResourceRequests` 把 `Memreq=0`、`Coresreq=0`、`MemPercentagereq=100` 写死,即每个请求拿整卡显存/算力,无 per-vGPU 显存或时间片配额。`Fit` 仅按卡数 `Nums` 循环挑卡、靠 `dev.Count <= dev.Used` 判断卡是否被占满,`ScoreNode` 直接 `return 0`(无打分/拓扑/binpack)。对比 NVIDIA/昇腾路径有 memory+core 双维软切分,Biren 目前停在"调度接管、整卡独占"阶段。
  <details><summary>代码依据 pkg/device/biren/device.go</summary>

  ```go
  func (dev *BirenDevices) GenerateResourceRequests(ctr *corev1.Container) device.ContainerDeviceRequest {
      v, ok := ctr.Resources.Limits[BirenResourceCount]
      ...
      memnum := 0
      corenum := int32(0)
      mempnum := 100
      return device.ContainerDeviceRequest{
          Nums:             int32(n),
          Type:             BirenDevice,
          Memreq:           int32(memnum),       // 0:不限显存
          MemPercentagereq: int32(mempnum),      // 100:整卡
          Coresreq:         corenum,             // 0:不限算力
      }
  }

  func (br *BirenDevices) Fit(devices []*device.DeviceUsage, request ..., ...) (bool, ...) {
      for i, dev := range slices.Backward(devices) {
          ...
          if dev.Count <= dev.Used {            // 整卡占满即跳过,无 per-card 显存余量计算
              reason[common.CardTimeSlicingExhausted]++
              continue
          }
          if k.Nums > 0 { k.Nums--; tmpDevs[k.Type] = append(...) }
          if k.Nums == 0 { return true, tmpDevs, "" }
      }
  }

  func (dev *BirenDevices) ScoreNode(...) float32 { return 0 }   // 无打分策略
  ```
  </details>

- **资源声明走单一计数资源 `birentech.com/gpu`,无配套 `-memory`/`-core` 扩展资源**:常量定义了 in-use/no-use/UUID 选卡注解,但准入 `MutateAdmission` 只检查 `birentech.com/gpu` 这一个 limit 是否存在;helm 默认 `birenResourceName: "birentech.com/gpu"`,样例 Pod 也只声明 `birentech.com/gpu: 1`。印证整卡模型。
  <details><summary>代码依据 pkg/device/biren/device.go + charts/hami/values.yaml</summary>

  ```go
  const (
      BirenInUse     = "birentech.com/use-biren"
      BirenUseUUID   = "birentech.com/use-gpuuuid"
      ...
  )
  func (dev *BirenDevices) MutateAdmission(ctr *corev1.Container, p *corev1.Pod) (bool, error) {
      _, ok := ctr.Resources.Limits[corev1.ResourceName(BirenResourceCount)]
      return ok, nil   // 仅判断计数资源在场
  }
  ```
  ```yaml
  # charts/hami/values.yaml
  +birenResourceName: "birentech.com/gpu"
  +  biren:
  +    enabled: true
  +    customresources:
  +      - birentech.com/gpu
  ```
  </details>

- **接入方式沿用插件化设备注册表,零侵入主调度循环**:`config.go` 加 `BirenConfig` 字段 + 在 `InitDevicesWithConfig` 的设备构造列表追加一项工厂函数,helm `device-configmap.yaml` 注入 `biren.resourceCountName`。新增厂商不动核心调度代码,符合 HAMi 既有"每厂商一个 `device.Devices` 实现 + 注册表"模式。
  <details><summary>代码依据 pkg/scheduler/config/config.go</summary>

  ```go
  +  BirenConfig     biren.BirenConfig         `yaml:"biren"`
  ...
  +  {biren.BirenDevice, biren.BirenCommonWord, func(cfg any) (device.Devices, error) {
  +      birenConfig, ok := cfg.(biren.BirenConfig)
  +      if !ok { return nil, fmt.Errorf("invalid configuration for %s", biren.BirenCommonWord) }
  +      return biren.InitBirenDevice(birenConfig), nil
  +  }, config.BirenConfig},
  ```
  </details>

- **官方 vLLM 跨 vGPU 张量并行样例落地**:单容器 `nvidia.com/gpu: 2` 申请两张 HAMi vGPU 作为 TP worker,`--tensor-parallel-size 2` 且显式 `--disable-custom-all-reduce`(规避 vGPU 环境下自定义 all-reduce 的 NVLink/P2P 假设)。说明 HAMi 软切分出的 vGPU 已能直接跑多卡 TP 推理,但需关掉 custom all-reduce 走通用通信路径。
  <details><summary>代码依据 examples/nvidia/vllm_cross_vgpu.yaml</summary>

  ```yaml
  args:
    - vllm serve Qwen/Qwen2.5-3B-Instruct
      --tensor-parallel-size 2
      --gpu-memory-utilization 0.95
      --disable-custom-all-reduce
  resources:
    limits:
      nvidia.com/gpu: 2 # Use 2 HAMi vGPUs for tensor parallel workers
  ```
  </details>

### 后续发展方向 [AI]
- Biren 接入很可能是"先占调度位、后补软隔离"的两步走:当前 `Memreq/Coresreq` 写死整卡、`ScoreNode` 恒 0,后续若要对齐 NVIDIA/昇腾,需在驱动里引入 `-memory`/`-core` 扩展资源并实现打分。证据只覆盖本次新增的 device.go 静态逻辑,未见 Biren 侧 device-plugin / HAMi-core hook 是否同步提供用户态显存拦截。
- vGPU 上的多卡 TP 推理被官方背书为推荐用法(给出生产化样例),HAMi 的产品叙事正从"单卡切分省 GPU"扩到"切分后的 vGPU 仍可组多卡分布式推理"。证据仅为一个 example yaml,未见调度器对"同 Pod 多 vGPU 必须落不同物理卡"的硬约束代码,跨卡 TP 的拓扑/亲和保证待查。

## 本期无实质改动(折叠)

<details><summary>4 仓 EMPTY(无新提交)</summary>

- Project-HAMi/HAMi-core: 02a9ac22 -> 02a9ac22 | Release — | 无新提交
- Project-HAMi/volcano-vgpu-device-plugin: 6561f1c1 -> 6561f1c1 | Release — | 无新提交
- Project-HAMi/ascend-device-plugin: 799eaa34 -> 799eaa34 | Release — | 无新提交
- Project-HAMi/HAMi-WebUI: 30c3ce14 -> 30c3ce14 | Release hami-webui-1.2.0 | 无新提交

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)

<!-- ANCHOR repo=Project-HAMi/HAMi sha=df6ac09e0420fd337133eb673d7fe72269dd194e branch=master release=v2.9.0 scanned=2026-06-16 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=02a9ac22a438824b411e13ad4144fc152a1ec63b branch=main release=— scanned=2026-06-16 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-06-16 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-16 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-16 -->

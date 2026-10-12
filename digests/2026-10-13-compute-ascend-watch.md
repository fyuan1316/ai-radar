# 昇腾算力栈 diff 雷达 2026-10-13

## 摘要
- **2 仓有料**(其余 7 仓 EMPTY):
  - **mind-cluster**(18 commits)主线=**静态切分 vNPU 资源名识别的统一重构**——operator / ascend-for-volcano 过去用 `strings.Contains(name, "huawei.com/")`(前缀粗匹配)判断 NPU 资源,会把 `huawei.com/Ascend910-2c` 这类**静态切分 vNPU** 名字识别错/漏,导致"operator 获取 NPU 类型和数量"与"volcano 获取 NPU 任务类型和数量"出错;本次收敛到 `IsNPUResource` / `IsStaticVnpuResource`(正则 `Ascend910-([2-6]|8|10|12|16)c`、`Ascend310P-(1|2|4)c`)+ `commonutils.IsNPUResourceName`/`IsStaticCutResourceName` 的**语义化判据**,整卡 / 动态 npu-core / 静态切分三类资源一处判定。配套 clusterd 修静默故障重复上报(`dealFault` 返回 `faultExisted`,`occur` 已存在即 `continue` 跳过)。
  - **ub-network-device-plugin**(81 commits,50 文件**全部 added**——compare base 非祖先,实为 **UB/URMA 共享网络 device plugin 的首次完整开源代码落地**,非当日增量)。核心=**URMA(统一总线 RDMA)共享设备**的 K8s device plugin:`GetPreferredAllocation` 按 `HwResId`(物理 UB 口)聚簇优选、`ubse` socket 健康检查、kubelet checkpoint 恢复、listwatch 断连修复、grpc CVE 升级。
- 本日有实质改动 → 归档并推飞书。

## 当日重要改变

### Ascend/mind-cluster —— 静态切分 vNPU 资源识别统一 + 静默故障去重 [架构方向 / Bugfix]
锚点 `fe3bf792`(tag v26.1.1),区间 `aac1c915..fe3bf792`,18 commits、truncated=false。信号(限 `component/`):

**1. NPU 资源名判据从"前缀粗匹配"收敛为"语义化三态判定"(贯穿 operator + ascend-for-volcano)**

- `ascend-for-volcano/common/util/util.go`:`IsNPUResource` 新增 `AscendNPUCore`(动态 npu-core),并新增 `IsStaticVnpuResource`:
  ```go
  func IsNPUResource(res v1.ResourceName) bool {
      return res==NPUCardName || res==NPU310CardName || res==NPU910CardName || res==NPU310PCardName || res==AscendNPUCore
  }
  // IsStaticVnpuResource reports whether res is a static segmentation vNPU resource name, e.g. huawei.com/Ascend910-2c.
  func IsStaticVnpuResource(res v1.ResourceName) bool {
      return ascend910VirtualDevNameReg.MatchString(string(res)) || ascend310VirtualDevNameReg.MatchString(string(res))
  }
  ```
- `common/util/type.go` 新增两条正则(静态切分规格白名单):
  ```go
  ascend910VirtualDevNameReg = regexp.MustCompile(Ascend910 + "-([2-6]|8|10|12|16)c")
  ascend310VirtualDevNameReg = regexp.MustCompile(Ascend310P + "-(1|2|4)c")
  ```
- `plugin/job.go` 三处(`GetVCJobReqNPUTypeFromJobInfo` / `getVCTaskReqNPUTypeFromTaskInfo` / `validVirtualDevJob`)、`common/util/task.go` 的 `GetNPURequestFromTask`、`util.go` 的 `IsNPUTask`:统一把 `strings.Contains(k, util.HwPreName)` 替换为 `util.IsNPUResource(k) || util.IsStaticVnpuResource(k)`。`validJobFn` 里原来内联的两段 `ascend910/310VirtualDevNameReg.MatchString` 也收敛为 `util.IsStaticVnpuResource(...)`。
- operator 侧同构:`pkg/controllers/v1/utils.go` 的 `getContainerResourceReq` / `getContainerNPUResourceNameAndReq`、`pkg/ranktable/utils/util.go` 的 `podUseNpu`,把 `strings.Contains(rName, api.ResourceNamePrefix)` 换成 `commonutils.IsNPUResourceName(...)`。
- `pkg/controllers/v1/env.go` 的 `isVirtualResourceReq`:从"黑名单 nonVirtualResources(整卡四种)取反"改为"白名单 `IsStaticCutResourceName(name) || name==HuaweiNPUCore`";`setAscendVisibleDevicesEnv` / `addHcclSuperPodIdEnv` 的资源遍历也换用 `commonutils.IsNPUResourceName`(并把原 `if 命中{...}` 结构倒成 `if !命中 {continue}` 提前跳过)。

> 启示:昇腾把"资源名识别"从散落各处的字符串前缀匹配抽成 `ascend-common/common-utils` 的公共判据(`IsNPUResourceName`/`IsStaticCutResourceName`),三类资源(整卡 / 动态 `npu-core` / 静态切分 `AscendXXX-Nc`)一处定义。这正是我们自家产品接多形态加速卡资源时该抄的治理方式——避免"整卡能调度、切分卡在 operator/scheduler 任一环节被漏判"这类长尾 bug。静态切分规格白名单(910 只认 2/4/6/8/10/12/16c、310P 只认 1/2/4c)也顺带把非法切分规格挡在调度前。

**2. clusterd 静默故障重复上报修复** `component/clusterd/pkg/application/publicfault/fault_collector.go`:`dealFault` 签名从无返回值改为返回 `bool faultExisted`,`PubFaultCollector` 据此在"故障已存在且 assertion==Occur"时 `continue` 跳过重复处理并告警:
```go
faultExisted := dealFault(fault.Assertion, nodeName, faultKey, newFault)
if faultExisted && fault.Assertion == constant.AssertionOccur {
    hwlog.RunLog.Warnf("skip fault %s ... fault already existed", ...); continue
}
```
> 启示:集群级故障聚合要对"occur 重复上报"幂等,否则同一静默故障会反复触发下游路由/隔离。

### openFuyao/ub-network-device-plugin —— UB/URMA 共享网络 device plugin 首次开源落地 [新组件]
锚点 `021fe219`(tag 1.0.2)。compare `5dd79f39..021fe219`、81 commits,**50 文件全部 `added`**(base 非当前历史祖先,等同首次代码可见,非单日增量)。关键实现(逐文件读 patch):

- **`plugin/server.go` `GetPreferredAllocation`**:按 `HwResId`(物理 UB 硬件口 id)把可用设备聚簇,`sort` 优先选"可用 VF 最多的口"、同数再按 id 升序,然后逐口轮询取够 `AllocationSize` 个——即**同一物理口的多个共享设备尽量分到同一容器**的亲和分配(减少跨口通信)。`GetDevicePluginOptions` 开 `PreStartRequired=true` + `GetPreferredAllocationAvailable=true`。
- **`PreStartContainer` → `SetUrmaDevNetworkNS`**:分配后在 PreStart 阶段把 URMA 设备塞进容器网络 namespace。
- **`resource/device_map.go` + `resources.go`**:资源模型只有 `SHAREDs []Resource`(`Pattern`+`Name`),默认 `AddSHAREResource("*", URMAResource)`,资源名强制 `unifiedbus.com/` 前缀(见提交"resource type unified to unifiedbus.com/urma.vfe, only shareds type")。`buildSharedDeviceMap` 调 `urma.GetSharedDevice()` 按 pattern 匹配建图。
- **`plugin/health.go` `StartHealthServer`**:`/healthz` 校验 `/var/run/ubse/ubse.sock`、`/var/run/ubse/ubse_ubm.socket` 两个 ubse socket 存在性(缺则 503),`/readyz` 固定 ready。
- **其余主线提交**:kubelet checkpoint 恢复(重启后从 checkpoint 还原设备、V2 格式优先 V1 回退兼容 1.20 前后)、修"device plugin 与 kubelet listwatch 断连致节点资源归零"、EID 取不到时超时 30s 回退调 ubse、grpc 升级修 CVE-2026-84303/84304/84445/33186。

> 启示:这是昇腾/openEuler 侧 **UB(Unified Bus)超低时延 fabric** 纳入 K8s 的底层拼图——URMA = 统一总线 RDMA,`unifiedbus.com/urma.vfe` 作为可共享扩展资源,按物理口做分配亲和。与我们关注的多机训练网络(对标 RoCE/IB + GPUDirect)是同层能力;其"按 HwResId 聚簇优选 + PreStart 注入 netns + ubse socket 健康探针"的 device plugin 范式可直接参考。注意它仍是 P2、tag 1.0.2 早期,`GetPreferredAllocation` 对 `len(keys)==0` 等边界有保护但分配逻辑尚简。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY(无新提交)</summary>

- openFuyao/npu-operator — 无新提交(tag v26.6.0)
- openFuyao/npu-container-toolkit — 无新提交(tag v26.6.0)
- openFuyao/npu-driver-installer — 无新提交(tag v26.6.0)
- openFuyao/vNPU — 无新提交(tag v0.1.0)
- openFuyao/npu-node-provision — 无新提交(tag v26.6.0)
- openFuyao/npu-dra-plugin — 无新提交(tag v26.6.0)
- openFuyao/volcano-ext — 无新提交(tag v1.9.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=fe3bf7923fc9526fb1d8825f73d352435c9f055d tag=v26.1.1 scanned=2026-10-13 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.6.0 scanned=2026-10-13 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.6.0 scanned=2026-10-13 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-13 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-13 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-13 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-10-13 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-13 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=1.0.2 scanned=2026-10-13 -->
</content>
</invoke>

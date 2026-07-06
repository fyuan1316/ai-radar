# HAMi diff 雷达 2026-07-07

## 摘要
- HAMi 主仓 5 提交/9 文件:两处真实行为修正——调度准入 `fitResourceQuota` 现在对「单容器申请多张 GPU(reqnum>1)」按 req 倍数累加显存/算力配额(此前只统计 req==1 的容器,多卡请求被漏算);device-plugin 的 MIG 设备解析在拿不到 placement 时不再吞掉 NVML 错误而是原样上抛。
- 其余为文档/CI:回填 v2.4.0–v2.9.0 CHANGELOG、release-process typo、`docker/login-action` v4.2.0→v4.4.0。无 API/CRD/proposal 路径命中。
- HAMi-core、volcano-vgpu、ascend-device-plugin、HAMi-WebUI 四仓本期无新提交(EMPTY)。

## 当日重要改变(命中信号才列;无则写"无")
- 无(本期改动均未命中弃用/移除、API/CRD、架构方向、版本跨档、新能力信号;两处 bug 修正见下正文)

## Project-HAMi/HAMi: 430b458c -> 02ac4f03
- 比较: 430b458c75c37092b2ea48c8b17bd6d1cfcf45f4 -> 02ac4f03 | ahead=5 | files=9 | Release: v2.9.0
- https://github.com/Project-HAMi/HAMi/compare/430b458c75c37092b2ea48c8b17bd6d1cfcf45f4...02ac4f03bd8dca36074cfc52e8b99689e20d3523

### AI 总结重点(源码 diff 为据)
- **调度准入配额校验修复多卡漏算(#2001)**:`fitResourceQuota` 遍历容器统计 vGPU 显存/算力时,原判据是 `req == 1`——只有申请 1 张卡的容器才把它的 memory/core 计入配额,`reqnum>1`(单容器请求多张 vGPU)的容器直接被跳过,配额校验偏低。改后去掉 `req == 1` 门槛,只要拿到 `req` 就把 `memReq * req`、`coreReq * req` 按卡数倍数累加,配额准入对多卡请求才是准确的。
  <details><summary>代码依据 pkg/scheduler/webhook.go</summary>

  ```diff
   for _, ctr := range pod.Spec.Containers {
       req, ok := getRequest(&ctr, resourceName)
  -    if ok && req == 1 {
  +    if ok {
           if memReq, ok := getRequest(&ctr, memResourceName); ok {
  -            memoryReq += memReq
  +            memoryReq += memReq * req
           }
           if coreReq, ok := getRequest(&ctr, coreResourceName); ok {
  -            coresReq += coreReq
  +            coresReq += coreReq * req
           }
       }
   }
  ```
  </details>
- **MIG 设备解析失败不再掩盖 NVML 错误(#1999)**:`getMigDeviceParts` 在 NVML `Get*InstanceId` 拿不到 placement 后原样 `return parseMigDeviceUUID(uuid)` 兜底。新驱动分配的是不含 placement 信息的 opaque MIG UUID(如 `MIG-30d00c09-...`),legacy 正则解析会失败;旧逻辑直接把解析错误当结果返回,真正的 NVML 失败原因被吞。改后若 `parseMigDeviceUUID` 出错,则用 `fmt.Errorf` 把 NVML `ErrorString(ret)` 和解析错误一并包进去上抛,定位设备不可用的真因不再丢失。配套新增 `TestParseMigDeviceUUID`/`TestGetMigDeviceParts`(+164 行)覆盖 legacy/opaque/空串等 6 种 UUID 形态。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/rm/health.go</summary>

  ```diff
  -    return parseMigDeviceUUID(uuid)
  +    // Modern drivers assign opaque MIG UUIDs that carry no placement information,
  +    // so if parsing fails the NVML error above must not be masked.
  +    parentUUID, gi, ci, err := parseMigDeviceUUID(uuid)
  +    if err != nil {
  +        return "", 0, 0, fmt.Errorf("failed to get MIG device handle for %s: %s; %v", uuid, nvml.ErrorString(ret), err)
  +    }
  +    return parentUUID, gi, ci, nil
  ```
  </details>
- **文档/CI(非代码行为)**:CHANGELOG.md 回填 v2.4.0→v2.9.0 缺失条目(+174 行,#2007);release-process.md 修 typo 并把旧仓 URL `wawa0210/HAMi` 纠正为 `Project-HAMi/HAMi`(#2008);三个 release/scan workflow 把 `docker/login-action` 从 v4.2.0 升到 v4.4.0。

### 后续发展方向 [AI]
- 两处修正都指向 HAMi 软切分核心路径的**边界正确性**而非新能力:配额准入侧补齐"单容器多卡"这一直被忽略的请求形态(证据只覆盖 `fitResourceQuota` 一处 hunk,未见调度打分/分配环节是否也有同类 `req==1` 假设);device-plugin 侧顺应 NVIDIA 新驱动 opaque MIG UUID 趋势,把错误可观测性补回来(证据只覆盖 `getMigDeviceParts`,未展开 MIG 动态切分整链)。
- 无架构/CRD 层动作,v2.9.0 后主线目前是稳定性收口而非扩张;需持续跟踪 opaque MIG UUID 是否会推动 placement 获取路径进一步改造。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=02ac4f03bd8dca36074cfc52e8b99689e20d3523 branch=master release=v2.9.0 scanned=2026-07-07 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=8f3a89c67b037d8fdfe6c4cd4d8c4f0cd6504811 branch=main release=— scanned=2026-07-07 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-07 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=d7b365d2fce33fabefc779d24bab249d0cc4bbed branch=main release=— scanned=2026-07-07 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-07 -->

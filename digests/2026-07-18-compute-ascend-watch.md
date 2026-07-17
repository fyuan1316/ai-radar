# 昇腾算力栈 diff 雷达 2026-07-18

## 摘要
- **npu-exporter 把 legacy 兼容层收口为"仅 Prometheus"**:昨天新引入的 `enableLegacyMetrics`(Atlas 350 旧 `_X_Y` 后缀指标向后兼容开关)本期从 telegraf 上报路径撤出——删掉常量 `enableLegacyMetricStr`,并把它从 `paramValidInTelegraf()` 的合法参数白名单里移除,flag 帮助文案补上 "only support prometheus"。即 telegraf 模式起 legacy 指标不再是可配项,兼容能力锁死在 Prometheus 出口。同批补了 UB/网络/光模块三个 `*_legacy_test.go`(共 ~469 行)给昨天的兼容层补测试。
- **vNPU 修 device plugin 通知死锁**:`DeviceCache.notify` 原来持锁遍历 `notifyCh` 并阻塞式 `ch <- dev`,改为先在锁内快照非 nil channel 到本地切片、解锁、再在锁外逐个发送,消除"持锁做阻塞 channel 发送"的死锁风险。其余 7 仓无实质改动。

## 当日重要改变
- mind-cluster/npu-exporter [架构方向] legacy 指标开关 `enableLegacyMetrics` 从 telegraf 合法参数白名单移除、常量删除,帮助文案标注 "only support prometheus";兼容层作用域收窄到 Prometheus 出口。 https://gitcode.com/Ascend/mind-cluster/compare/30b8dc80...a1536c22
- vNPU/xpu-device-plugin [新能力] 修复 `DeviceCache.notify` 持锁阻塞发送导致的死锁:改为锁内快照 channel、锁外发送。 https://gitcode.com/openFuyao/vNPU/compare/4bd4002c...0a081832

## mind-cluster: 30b8dc80 -> a1536c22
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/30b8dc80...a1536c22 | tag: v26.1.0.beta.2 | commits=12 | truncated=false
- 信号集中在 `component/npu-exporter/`(其余为 docs/API 示例/断点续训文档等噪声,已过滤)

### AI 总结重点(源码 diff 为据)
- **legacy 指标不再走 telegraf**:`main.go` 删除 `const enableLegacyMetricStr = "enableLegacyMetrics"`,并把它从 `paramValidInTelegraf()` 内的 `presetParamsMap`(telegraf 模式允许的命令行参数集)里删除;同时 `flag.BoolVar` 的帮助字符串从"…Atlas 350 backward compatibility"补成"…backward compatibility, **only support prometheus**"。含义:`enableLegacyMetrics` 这个 flag 本体仍在(默认 false),但 telegraf 上报路径下它已不是被承认的参数,legacy `_X_Y` 后缀兼容仅在 Prometheus 出口生效。这是昨天"新增 EnableLegacyMetrics 兼容层 + telegraf 改 channel 流式"之后的收口动作(part-2)。
  <details><summary>代码依据 component/npu-exporter/cmd/npu-exporter/main.go</summary>

  ```diff
    const (
      ...
      defaultHccsBwProfilingTime = 200
  -   enableLegacyMetricStr      = "enableLegacyMetrics"
    )
  ```
  ```diff
    flag.BoolVar(&enableLegacyMetrics, "enableLegacyMetrics", false,
  -   "enable legacy metrics with _X_Y suffix for Atlas 350 backward compatibility")
  +   "enable legacy metrics with _X_Y suffix for Atlas 350 backward compatibility, only support prometheus")
  ```
  ```diff
    func paramValidInTelegraf() error {
      ...
        api.DeviceResetTimeout:     true,
  -     enableLegacyMetricStr:      true,
      }
  ```
  </details>
- **为昨天的 legacy 兼容层补齐单测**:新增 `collector_for_ub_legacy_test.go`(282 行)、`collector_for_network_legacy_test.go`(95 行)、`collector_for_optical_legacy_test.go`(92 行)。测试直接锁定了兼容层的关键契约:`EnableLegacyMetrics=false` 时一条都不吐;`=true` 时吐固定条数,且 **legacy 格式的 label 不含 udie/port 维度**(`convey.So(len(lastLabels), convey.ShouldEqual, len(cardLabel))`)——反证了昨天"新格式把 die/port 下沉为 label、旧格式保留 `_X_Y` 名字后缀"这条主线。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_network_legacy_test.go</summary>

  ```diff
  + convey.Convey("When EnableLegacyMetrics is true, correct number of metrics emitted", func() {
  +   colcommon.EnableLegacyMetrics = true
  +   initNetworkLegacyDesc()
  +   ...
  +   promUpdateNetInfoLegacy(ch, timestamp, netInfo, extendedLabel, 0)
  +   convey.So(callCount, convey.ShouldEqual, ascend950NetworkMetricNum)
  +   // legacy format should NOT include udie/port labels
  +   convey.So(len(lastLabels), convey.ShouldEqual, len(cardLabel))
  + })
  ```
  </details>

### 后续发展方向 [AI]
- 指标模型迁移进入"收口 + 补测"阶段:主线(die/port 转 label)已落地,本期把 legacy 兼容明确限定在 Prometheus 出口、并加测试固化行为。可预期后续兼容期结束会整段删 `*_legacy.go`。证据仅覆盖 main.go 参数校验与三个 test 文件,未见 `collector_for_*_legacy.go` 主体本期有改动。

## vNPU: 4bd4002c -> 0a081832
- 比较: https://gitcode.com/openFuyao/vNPU/compare/4bd4002c...0a081832 | tag: v0.1.0 | commits=2 | truncated=false

### AI 总结重点(源码 diff 为据)
- **修复 device plugin 通知死锁**:`DeviceCache.notify(dev)` 原实现是 `d.mutex.Lock()` → 遍历 `d.notifyCh` 逐个 `ch <- dev`(阻塞式发送)→ 最后 `d.mutex.Unlock()`。若某个消费者未及时收、channel 满,发送会阻塞在持锁状态,与其他要拿同一 mutex 的路径互锁。改为:锁内把非 nil 的 channel 快照进本地 `chs` 切片、立即 `Unlock()`,再在锁外遍历 `chs` 发送。经典的"缩小临界区、别在锁内做阻塞 I/O"修法。
  <details><summary>代码依据 xpu-device-plugin/pkg/plugin/cache.go</summary>

  ```diff
    func (d *DeviceCache) notify(dev *xpu.Device) {
      d.mutex.Lock()
  +   chs := make([]chan *xpu.Device, 0, len(d.notifyCh))
      for _, ch := range d.notifyCh {
  +     if ch != nil {
  +       chs = append(chs, ch)
  +     }
  +   }
  +   d.mutex.Unlock()
  +
  +   for _, ch := range chs {
        if ch != nil {
          ch <- dev
        }
      }
  -   d.mutex.Unlock()
    }
  ```
  </details>

### 后续发展方向 [AI]
- 又一处并发健壮性修复(继昨天 util 函数 bugfix 后),vNPU 切分主逻辑本期仍未动。证据仅此一个函数,无能力/架构信号。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓(7 仓)</summary>

- openFuyao/npu-operator — 无新提交(HEAD 53299373 未动,tag v26.6.0)
- openFuyao/npu-container-toolkit — 无新提交(HEAD d54256e0 未动,tag v26.6.0)
- openFuyao/npu-driver-installer — 无新提交(HEAD c898c929 未动,tag v26.6.0)
- openFuyao/npu-node-provision — 无新提交(HEAD 717ef777 未动,tag v26.6.0)
- openFuyao/npu-dra-plugin — 无新提交(HEAD 98f8fa5e 未动,tag v26.6.0)
- openFuyao/volcano-ext — 无新提交(HEAD c9be5c4c 未动,tag v1.9.0)
- openFuyao/ub-network-device-plugin — 无新提交(HEAD 263d6387 未动,tag v26.6.0)

另 mind-cluster 区间内还有断点续训/MindSpeed 适配文档、API 结果示例、菜单命名修正等提交,均落在 component/ 过滤外或仅 docs,未纳入研判。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=a1536c22c0e640650102185f9a0477c7013bb12a tag=v26.1.0.beta.2 scanned=2026-07-18 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-07-18 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-18 -->
<!-- ANCHOR repo=npu-driver-installer sha=c898c929187bba8051e2ebed87f609bc820ead68 tag=v26.6.0 scanned=2026-07-18 -->
<!-- ANCHOR repo=vNPU sha=0a081832850f64b192f6787a8b87f63cb1bf9e92 tag=v0.1.0 scanned=2026-07-18 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-18 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-18 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-18 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-18 -->

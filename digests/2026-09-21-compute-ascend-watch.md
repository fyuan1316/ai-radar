# 昇腾算力栈 diff 雷达 2026-09-21

## 摘要
- mind-cluster/npu-exporter 本期唯一有代码改动:`UpdateCache` 彻底删掉 metrics 缓存的 TTL 计算,全部改为「永不过期」——配合 "dcmi 接口超时场景可靠性" 提交,DCMI 采集超时时宁可保留旧值也不留空洞。
- 新增 UB 链路 ICRC 指标采集器(NetworkBandwidthCollector / NetworkLinkCollector),按训练卡 + 主板型号门控是否上报。
- 其余 8 个 openFuyao 仓全部无新提交(EMPTY)。本日有实质改动,推飞书。

## 当日重要改变
- mind-cluster [新能力] npu-exporter 新增 UB 链路故障 hccn_tool ICRC 指标解析(NetworkBandwidthCollector/NetworkLinkCollector),多机训练 fabric 可观测性增强 | https://gitcode.com/Ascend/mind-cluster/commit/6993b58a88
- mind-cluster [行为变更] metrics 缓存 TTL 机制被移除,缓存改为永不过期,牺牲新鲜度换 DCMI 超时下的连续性 | https://gitcode.com/Ascend/mind-cluster/commit/5af8c0a07f

## mind-cluster: 17c2878e -> 40e3cbf9
- 比较: 17c2878e4b47efeb699e7066c2910ab22abe4bf5..40e3cbf9 | tag: v26.1.1 | commits=16 | truncated=false
- 信号文件全部落在 component/npu-exporter,其余 commit 为 docs/亲和性说明/1825 最小权限/镜像 tag 补充等非代码改动。

### AI 总结重点(源码 diff 为据)
- **`UpdateCache` 删除按采集间隔算 TTL 的整段逻辑,缓存 TTL 一律写死 `-1`(永不过期)**,并删掉 `time` 导入。原逻辑:`TTL = interval * 2`,`collectOnceInterval` 项 TTL=-1(永不过期),其余下限 60s;现逻辑:所有 cacheKey 一律 `-1`。语义上 npu-exporter 缓存的 NPU 指标从此不再随采集间隔到期淘汰。结合提交标题 "增加 dcmi 接口超时场景可靠性" 判断:当底层 DCMI 设备接口调用超时/取不到值时,旧策略会让缓存到期后指标出现空洞,新策略保留上一次成功值直到下次成功刷新——用「可能陈旧」换「不断流」。
  <details><summary>代码依据 component/npu-exporter/collector/common/metrics_collector.go</summary>

  ```diff
  - 	// Calculate cache TTL based on collector interval: TTL = interval * 2
  - 	interval := GetCollectorInterval(cacheKey, defaultGroupInterval)
  - 	var ttl time.Duration
  - 	if interval == collectOnceInterval {
  - 		// means never overdue
  - 		ttl = -1
  - 	} else {
  - 		ttl = interval * double
  - 	}
  - 	// set min cache ttl is 60s
  - 	if ttl != -1 && ttl < defaultGroupInterval {
  - 		ttl = defaultGroupInterval
  - 	}
  - 	err = n.cache.Set(cacheKey, cacheInfo, ttl)
  + 	// -1 Cache never expires.
  + 	err = n.cache.Set(cacheKey, cacheInfo, -1)
  ```
  </details>
- **`setPhyId` 把 `chip.PhyId = phyID` 赋值提前到 error 判断之前**。原逻辑:`GetPhysicIDFromLogicID` 返回 error 时直接 return,`PhyId` 保持零值;新逻辑:无论是否 error 都先落上返回的 phyID(超时/失败时把接口给出的值也用上,不再丢成 0)。与上面的「超时可靠性」同一方向——减少异常路径下的字段空洞。
  <details><summary>代码依据 component/npu-exporter/collector/common/npu_collector.go</summary>

  ```diff
   func setPhyId(chip *HuaWeiAIChip, dmgr devmanager.DeviceInterface, deviceID int32) {
   	phyID, err := dmgr.GetPhysicIDFromLogicID(chip.LogicID)
  + 	chip.PhyId = phyID
   	if err != nil {
   		logSetError("phy ID", chip, deviceID, err, "get phy ID")
   		return
   	}
  - 	chip.PhyId = phyID
  ```
  </details>
- **新增 UB 链路 ICRC 指标采集器**:测试新增 `NetworkBandwidthCollector` / `NetworkLinkCollector` 的 `IsSupported` / `IsParallel` 用例,可反推出这两个采集器的门控规则——是否上报按 `IsTrainingCard` + 主板 ID(`Atlas9501DMainBoardID` 支持、`Atlas3501PMainBoardID` 不支持)判定,且带 `DcmiSupported` 标志、`IsParallel` 恒为 true(并行采集)。对应 910A3/910A5 训练卡。这是多机训练 UB fabric 的链路故障(ICRC 错误计数)可观测性。(证据来自新增 test,采集器实现文件未在本次 patch 节选的前 8 个信号文件中直接命中,行为以测试断言为准。)
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_test.go</summary>

  ```diff
  + func TestNetworkBandwidthCollectorIsSupported(t *testing.T) {
  + 	collectors := []colcommon.MetricsCollector{&NetworkBandwidthCollector{}, &NetworkLinkCollector{}}
  + 	// {910A3, isTrainCard:true → true} / {910A3, isTrainCard:false → false}
  + 	// {910A5, Atlas9501DMainBoardID, train → true} / {910A5, Atlas3501PMainBoardID, train → false}
  + }
  + func TestNetworkBandwidthCollectorIsParallel(t *testing.T) {
  + 	// bandwidth/status collector IsParallel == true, DcmiSupported == false
  + }
  ```
  </details>

### 后续发展方向 [AI]
- npu-exporter 明显在为「异常/超时下指标不断流」加固:TTL 永不过期 + 异常路径也落值,两处 diff 一致指向 DCMI 底层不稳时保住指标连续性。证据只覆盖 metrics_collector/npu_collector 两文件与缓存/PhyId 路径,未见对采集间隔配置项本身的改动,也未见缓存无限增长的清理/淘汰替代机制——需关注长跑下 cache 是否只增不减。
- UB fabric 可观测性(ICRC 链路故障)按训练卡型号(910A3/910A5 + 主板 ID)分档启用,方向是把超节点/多机训练网络健康纳入 npu-exporter。证据仅来自测试断言,采集器实现的具体 hccn_tool 调用与指标名未在本次节选覆盖。

## 本期无实质改动(折叠)
<details><summary>其余 8 repo EMPTY(无新提交)</summary>

- npu-operator | tag v26.6.0
- npu-container-toolkit | tag v26.6.0
- npu-driver-installer | tag v26.6.0
- vNPU | tag v0.1.0
- npu-node-provision | tag v26.6.0
- npu-dra-plugin | tag v26.6.0
- volcano-ext | tag v1.9.0
- ub-network-device-plugin | tag 1.0.2
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=40e3cbf93ee3e20c969537113f6d581359696498 tag=v26.1.1 scanned=2026-09-21 -->
<!-- ANCHOR repo=npu-operator sha=802e269728d3528e7864b4d8c04a915c12d1169b tag=v26.6.0 scanned=2026-09-21 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-21 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-21 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-21 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-21 -->
<!-- ANCHOR repo=npu-dra-plugin sha=5d7339c517d971eaeb0b915bd19ed3d90db3c44c tag=v26.6.0 scanned=2026-09-21 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-21 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-21 -->
</content>

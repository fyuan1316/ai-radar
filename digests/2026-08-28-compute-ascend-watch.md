# 昇腾算力栈 diff 雷达 2026-08-28

## 摘要
- **device-plugin 把节点标注/标签的 key 从 LogicID 切到 PhyID**:`getDieIDAnnotations`、`getChipSerialNumbers` 里 dieID/serial-number 注解 JSON 的 id 字段从逻辑 ID 改成物理 ID(PhyID),且 elabel 查询在 `CardID == -1` 时回退用 LogicID——修的是多卡/CardID 不可用场景下序列号挂错卡、id 不稳定的问题。
- **标签清洗职责在 DP 与调度器之间对调**:ascend-device-plugin 的 `chipNameLabeler` **去掉** `sanitizeLabelValue()` 改写原始 chip.name;ascend-for-volcano **新增** `SanitizeLabelValue()`(正则 `[^A-Za-z0-9\-_. ]` + 空格→`-`),并让 310P 调度校验把参照常量 `Atlas 300I Duo` 也过一遍清洗再比对。清洗从"写入端"移到"读取/比较端"。
- **infer-operator 容器改回 root 运行**:Dockerfile 删掉 `USER hwMindX` 与 chown,直接以 root 起 bash——权限收敛的反向调整,安全上是退步,需留意。

## 当日重要改变
- mind-cluster [行为变更] ascend-device-plugin 的 dieID/serial-number 注解 key 从 LogicID → PhyID,且 elabel 查询 CardID=-1 时回退 LogicID。证据 component/ascend-device-plugin/pkg/server/manager.go https://gitcode.com/Ascend/mind-cluster/commit/ee074e93d83ccdf32dd3a734621f4b61ad0f5e1a
- mind-cluster [架构方向/安全] infer-operator Dockerfile 移除 `USER hwMindX`/chown,容器改 root 运行。证据 component/infer-operator/build/Dockerfile.openeuler https://gitcode.com/Ascend/mind-cluster/commit/ee074e93d83ccdf32dd3a734621f4b61ad0f5e1a
- mind-cluster [行为变更] 标签清洗从 DP 写入端(去 `sanitizeLabelValue`)移到 volcano 读取端(新增 `SanitizeLabelValue`+310P 比对同步清洗)。证据 component/ascend-device-plugin/pkg/server/labelers.go、component/ascend-for-volcano/common/util/util.go https://gitcode.com/Ascend/mind-cluster/commit/ee074e93d83ccdf32dd3a734621f4b61ad0f5e1a

## mind-cluster: 8ac97f0c -> ee074e93
- 比较: 8ac97f0c..ee074e93 | tag: v26.1.0 | commits=20 | truncated=false
- 比较页: https://gitcode.com/Ascend/mind-cluster/compare/8ac97f0cc7db321ef8665077721fbf24975e753a...ee074e93d83ccdf32dd3a734621f4b61ad0f5e1a

### AI 总结重点(源码 diff 为据)
- **dieID / serial-number 注解的 map key 从逻辑 ID 统一切换为物理 ID(PhyID)**。`getDieIDAnnotations` 里 `ret[dieType][LogicID]` 改为 `ret[dieType][PhyID]`;`getChipSerialNumbers` 里 `serialNumbers[LogicID]` 改为 `serialNumbers[PhyID]`。对外暴露给消费者(调度/上报)的 id 从随进程/驱动可变的逻辑编号换成稳定的物理编号,避免重启后 id 漂移导致标注错位。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/manager.go</summary>

  ```diff
  -		ret[dieType][strconv.Itoa(int(dev.LogicID))] = dieID
  +		ret[dieType][strconv.Itoa(int(dev.PhyID))] = dieID
  ...
  -			serialNumbers[strconv.Itoa(int(dev.LogicID))] = elabelInfo.SerialNumber
  +			serialNumbers[strconv.Itoa(int(dev.PhyID))] = elabelInfo.SerialNumber
  ```
  </details>

- **`getChipSerialNumbers` 去重键与 elabel 查询增加 CardID 不可用回退**。旧逻辑用 `cardIDs[dev.CardID]` 去重、`GetCardElabelV2(dev.CardID)` 查询;新逻辑改为:`CardID != -1` 用 CardID(idType="cardID"),否则回退 `LogicID`(idType="logicID"),用统一的 `existIDs` 去重,查询也用回退后的 id。修的是 CardID 返回 -1(拿不到 cardID)时旧代码全部落到 `cardIDs[-1]` 只查一张卡、其余卡序列号丢失的 bug。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/manager.go</summary>

  ```diff
  -	cardIDs := make(map[int32]bool)
  +	existIDs := make(map[int32]bool)
   	for _, dev := range hdm.allInfo.AllDevs {
  -		if cardIDs[dev.CardID] {
  +		var id int32
  +		var idType string
  +		if dev.CardID != -1 {
  +			id = dev.CardID; idType = "cardID"
  +		} else {
  +			id = dev.LogicID; idType = "logicID"
  +		}
  +		if existIDs[id] {
   			continue
   		}
  -		cardIDs[dev.CardID] = true
  -		elabelInfo, err := hdm.manager.GetDmgr().GetCardElabelV2(dev.CardID)
  +		existIDs[id] = true
  +		elabelInfo, err := hdm.manager.GetDmgr().GetCardElabelV2(id)
  ```
  </details>

- **标签清洗职责从 device-plugin 写入端移到 volcano 读取/比较端**。DP 侧 `chipNameLabeler.Write` 删掉 `sanitizeLabelValue(chipInfo.Name)`,直接写原始 `chipInfo.Name`;volcano 侧新增 `SanitizeLabelValue`(正则 `labelSanitizeRegex = [^A-Za-z0-9\-_. ]` 剔非法字符 + 空格→`-`)。310P `chip310px2.CheckNodeNPUByTask` 里把参照常量 `Atlas300IDuoLabel`("Atlas 300I Duo")包一层 `SanitizeLabelValue` 再与节点 label 比对——即调度器现在按清洗后形态("Atlas-300I-Duo")做等值判断。方向是把"节点 label 值的规范化"收口到消费侧,让不同来源写入的 label 都在比较时归一。

  <details><summary>代码依据 labelers.go / util.go / type.go / frame.go</summary>

  ```diff
  # ascend-device-plugin/pkg/server/labelers.go —— DP 去掉写入端清洗
  -	writeValue(labels, sanitizeLabelValue(chipInfo.Name), label.NPUChipNameLabel, label.NPUChipNameLabelDeprecated)
  +	writeValue(labels, chipInfo.Name, label.NPUChipNameLabel, label.NPUChipNameLabelDeprecated)

  # ascend-for-volcano/common/util/util.go —— 新增读取端清洗
  +func SanitizeLabelValue(value string) string {
  +	invalidRegex := regexp.MustCompile(labelSanitizeRegex)
  +	sanitized := invalidRegex.ReplaceAllString(value, "")
  +	spaceRegex := regexp.MustCompile(` +`)
  +	sanitized = spaceRegex.ReplaceAllString(sanitized, "-")
  +	return sanitized
  +}

  # ascend-for-volcano/internal/npu/ascend310p/chip310px2/frame.go —— 比对同步走清洗
  -		if newLabel != util.Atlas300IDuoLabel {
  +		if newLabel != util.SanitizeLabelValue(util.Atlas300IDuoLabel) {
  ```
  </details>

- **infer-operator 容器从非 root(hwMindX)改回 root 运行**。Dockerfile 删除对二进制/协议文件的 `chown hwMindX:hwMindX`、删除 `USER hwMindX`,只保留 `chmod 500`,并把 chmod 750 目标从家目录改成 `/usr/local/bin/`,`.bashrc` 写入路径从 `/home/hwMindX/.bashrc` 改成 `~/.bashrc`(root 家目录)。ENTRYPOINT 仍以 root 起 bash。这是权限模型的反向调整——安全基线上是退步,产品侧若对标 OAI 的非特权容器要求需盯住。

  <details><summary>代码依据 component/infer-operator/build/Dockerfile.openeuler</summary>

  ```diff
  -RUN chown -R hwMindX:hwMindX /usr/local/bin/infer-operator /usr/local/agreement.txt &&\
  -    chmod 500 /usr/local/bin/infer-operator &&\
  +RUN chmod 500 /usr/local/bin/infer-operator &&\
       chmod 440 /usr/local/agreement.txt &&\
  -    chmod 750 /home/hwMindX &&\
  +    chmod 750 /usr/local/bin/ &&\
       echo 'umask 027' >> /etc/profile && \
  -    echo 'source /etc/profile' >> /home/hwMindX/.bashrc
  -
  -USER hwMindX
  +    echo 'source /etc/profile' >> ~/.bashrc
  ```
  </details>

- **配套测试补齐**:clusterd `informer_test.go` 新增 `TestBuildVersionSummary`(覆盖无节点/有 version 注解/JSON 解析失败三态,对应昨日的版本自上报聚合能力);ascend-device-plugin `manager_test.go` 新增 `TestGetChipSerialNumbers`(覆盖正常/查询失败跳过/空序列号/NA 值,对应上面 serial-number 改动)。纯测试,无功能改动。

### 后续发展方向 [AI]
- LogicID→PhyID 的 key 迁移意味着上报/调度侧对设备的稳定标识正在统一到物理编号;证据只覆盖 dieID/serial-number 两处注解,未见 device count/allocate 主链路是否同步改,后续需盯 `packServerInfo`/allocate 路径是否也换 PhyID。
- 标签清洗收口到消费端是短期兼容手段(容忍多来源 label),但 DP 写原始值 + 调度器比对时清洗,只覆盖了 310P `chip310px2` 一处比对;其余芯片型号/其它 label 消费点若未同步包 `SanitizeLabelValue`,会出现"写原始、比清洗"不一致。证据仅 310P 一处,未见全量比对点改造。
- infer-operator 改 root 是明确的权限回退,证据仅 Dockerfile 一处,未见 operator 运行时 SecurityContext/PSA 是否有补偿约束。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓本期 EMPTY(仅保锚点)</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin —— 均无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=ee074e93d83ccdf32dd3a734621f4b61ad0f5e1a tag=v26.1.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=npu-dra-plugin sha=1084df7c16dbb60173b0dbc8e4cd561dd45b430d tag=v26.6.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-28 -->

# HAMi diff 雷达 2026-07-24

## 摘要
- **HAMi 主仓补齐 NVSwitch 拓扑评分**:`pkg/device/nvidia/links.go` 的 `GetNVLink` 从"只认直连 GPU↔GPU 的 NVLink"扩展到"两卡都经 NVSwitch 互联也算 NVLink",填掉了原来 `// TODO(klueska): Handle NVSwitch semantics` 的空洞——DGX/HGX(经 NVSwitch full-mesh)机型的亲和性打分之前会被判成"无 NVLink",现在能正确识别。
- HAMi-core 仅 README 三语刷新 + CMake 最低版本 2.8.11→2.8.12,无 hook/隔离代码改动。
- volcano-vgpu / ascend-device-plugin / HAMi-WebUI 三仓无新提交。

## 当日重要改变
- Project-HAMi/HAMi [新能力] NVLink 拓扑探测新增 NVSwitch 路径,GPU 亲和性评分覆盖到 NVSwitch full-mesh 机型;证据 `pkg/device/nvidia/links.go`(新增 `countNvSwitchLinks`/`nvlinkCountToType`/`countMatchingLinks`)。https://github.com/Project-HAMi/HAMi/commit/9f2c88da39cd19b524ed2d359faf30dddd5af70c

## Project-HAMi/HAMi: 6469365d -> 9f2c88da
- 比较: 6469365dd409f568dbd9d675e01ebff5174ddaab -> 9f2c88da | ahead=1 | files=2 | Release: v2.9.0
- PR: fix(nvidia): detect NVLink through NVSwitch for topology scoring (#2103) https://github.com/Project-HAMi/HAMi/pull/2103

### AI 总结重点(源码 diff 为据)
- **`GetNVLink` 从"仅直连"改为"直连优先 + NVSwitch 兜底"两段式判定**。旧逻辑:遍历 `dev1` 的 NVLink 远端 PCI 列表,凡 BusID 命中 `dev2` 就用一个 18 分支的 `switch` 手工把 `nvlink` 递增一档(Single→…→Eighteen),命中不到就返回 `P2PLinkUnknown`,末尾还挂着 `// TODO(klueska): Handle NVSwitch semantics`。新逻辑:先用 `countMatchingLinks(pciInfos, dev2BusID)` 数直连链路数、经 `nvlinkCountToType` 转档,直连命中即返回;直连为 0 且 `dev1` 有启用的 NVLink 时,再对**两张卡各自**调 `countNvSwitchLinks` 判断是否"远端是 NVSwitch",只有**两卡都经 NVSwitch**(`viaSwitch1 && viaSwitch2`)才认定为 NVLink,链路档取两卡活跃数的 `min`。行为差异:DGX/HGX 这类 GPU 不直连、全靠 NVSwitch 互联的拓扑,以前一律被判 `P2PLinkUnknown`(亲和性评分丢分),现在能正确评为多路 NVLink。
  <details><summary>代码依据 pkg/device/nvidia/links.go</summary>

  ```diff
  -	nvlink := P2PLinkUnknown
  -	for _, pciInfo := range pciInfos {
  -		if pciInfo.BusID() != dev2BusID {
  -			continue
  -		}
  -		switch nvlink {
  -		case P2PLinkUnknown:
  -			nvlink = SingleNVLINKLink
  -		... (18 档手工递增) ...
  -		}
  -	}
  -	// TODO(klueska): Handle NVSwitch semantics
  -	return nvlink, nil
  +	direct := nvlinkCountToType(countMatchingLinks(pciInfos, dev2BusID))
  +	if direct != P2PLinkUnknown {
  +		return direct, nil
  +	}
  +	if len(pciInfos) == 0 {
  +		return P2PLinkUnknown, nil
  +	}
  +	links1, viaSwitch1, err := countNvSwitchLinks(dev1)
  +	... (dev2 同理) ...
  +	if viaSwitch1 && viaSwitch2 {
  +		return nvlinkCountToType(min(links1, links2)), nil
  +	}
  +	return P2PLinkUnknown, nil
  ```
  </details>
- **新增 `countNvSwitchLinks(dev)`:遍历 `nvml.NVLINK_MAX_LINKS`,对每条启用(`FEATURE_ENABLED`)的链路查远端设备类型,统计 `NVLINK_DEVICE_TYPE_SWITCH` 的数量并返回是否存在**。`NOT_SUPPORTED`/`INVALID_ARGUMENT` 的返回码被当作"该链路不可用"跳过而非报错——这是对不同代 GPU/驱动能力差异的健壮性处理。
  <details><summary>代码依据 pkg/device/nvidia/links.go</summary>

  ```diff
  +func countNvSwitchLinks(dev device.Device) (count int, viaSwitch bool, err error) {
  +	for i := range nvml.NVLINK_MAX_LINKS {
  +		state, ret := dev.GetNvLinkState(i)
  +		if errors.Is(ret, nvml.ERROR_NOT_SUPPORTED) || errors.Is(ret, nvml.ERROR_INVALID_ARGUMENT) {
  +			continue
  +		}
  +		... state != FEATURE_ENABLED -> continue ...
  +		deviceType, ret := dev.GetNvLinkRemoteDeviceType(i)
  +		...
  +		if deviceType == nvml.NVLINK_DEVICE_TYPE_SWITCH {
  +			count++
  +		}
  +	}
  +	return count, count > 0, nil
  +}
  ```
  </details>
- **18 档手工 `switch` 递增被 `nvlinkCountToType(n int)` 查表替换**:一个定长数组按 count 直接索引出 `P2PLinkType`,越界(`n<1 || n>=len`)返回 `Unknown`,注释标注"覆盖到 18 条 NVLink(当前上限 H100/B200)"。纯重构,行为等价,但消掉了那段最易出错的长 switch,并被 490 行新增单测 `links_test.go`(`Test_countMatchingLinks` 等)覆盖。
  <details><summary>代码依据 pkg/device/nvidia/links.go</summary>

  ```diff
  +func nvlinkCountToType(n int) P2PLinkType {
  +	types := [...]P2PLinkType{
  +		P2PLinkUnknown,
  +		SingleNVLINKLink, TwoNVLINKLinks, ThreeNVLINKLinks,
  +		... EighteenNVLINKLinks,
  +	}
  +	if n < 1 || n >= len(types) {
  +		return P2PLinkUnknown
  +	}
  +	return types[n]
  +}
  ```
  </details>

### 后续发展方向 [AI]
- **HAMi 的 GPU 亲和性调度正在补齐"大机型"拓扑感知**。此改动落在 HAMi 自身的 `pkg/device/nvidia`(NVSwitch 语义直接影响 numa/亲和性打分),不是 NVIDIA device-plugin/DRA 那条线;它把 DGX/HGX(GPU 全经 NVSwitch 互联)从拓扑评分盲区里救出来,意味着 HAMi 在这类高端整机上的多卡任务放置质量会提升。对我们产品的启示:若在 8×H100/HGX 上跑 HAMi 软切分,升到含此 commit 的版本后同机多卡亲和性打分才可信;v2.9.0 尚未含此提交(仍在 master,未进 release)。**证据只覆盖 `links.go` 的拓扑判定逻辑,未见调度器如何消费这个 `P2PLinkType`(评分权重、抢占策略未在本 diff 内),也未见 vNPU 侧有对应改动。**

## 本期无实质改动(折叠)
<details><summary>HAMi-core 仅文档 + 3 仓 EMPTY(保锚点)</summary>

- Project-HAMi/HAMi-core — 仅 README 三语(EN/CN/JA)刷新:加 build/style badge、补 Prerequisites/本地 `./build.sh` 构建说明、架构图换成 mermaid、新增 Contributing 段;`CMakeLists.txt` 最低版本 2.8.11→2.8.12;删两张架构 png。无 hook/隔离/显存算力切分代码改动。commit https://github.com/Project-HAMi/HAMi-core/commit/52f33fc7fa1fbb3f08148ab076d0e7447bec7f2a
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=9f2c88da39cd19b524ed2d359faf30dddd5af70c branch=master release=v2.9.0 scanned=2026-07-24 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=52f33fc7fa1fbb3f08148ab076d0e7447bec7f2a branch=main release=— scanned=2026-07-24 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-24 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=f062939e14354a96fb8bfabd3c103d9d8f6de6c2 branch=main release=— scanned=2026-07-24 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-24 -->
</content>
</invoke>

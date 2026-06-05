# HAMi diff 雷达 2026-06-06

## 摘要
- 仅 HAMi 主仓有 2 个提交,且**全是单测补充**(无生产代码改动):为调度器 `NodeScore.SnapshotDevice` 与节点锁 `setupNodeLockTimeout` 各补一组覆盖。其余 4 仓无新提交。
- 无信号命中(无 API/CRD/弃用/新能力)。两段测试间接固化了两处既有行为契约:SnapshotDevice 做**深拷贝快照**、NodeLock 超时**可经环境变量覆盖**。

## 当日重要改变
无

## Project-HAMi/HAMi: 8f0664b0 -> 5b7b91f7
- 比较: https://github.com/Project-HAMi/HAMi/compare/8f0664b0fac7d9a356d808a67a4640002bd24f7b...5b7b91f728c3e983f750fc991e546e24460b6d83 | ahead=2 | files=2 | Release: v2.9.0

### AI 总结重点(源码 diff 为据)
- 本期两提交均为 `_test.go`,**未改任何生产逻辑**;但测试断言反推出两处函数的行为契约,记录如下。
- `pkg/scheduler/policy` 的 `NodeScore.SnapshotDevice(DeviceUsageList) []*DeviceUsage` 是**深拷贝快照**:新测试在拿到 snap 后把原 `DeviceLists[i].Device.Usedmem` 改成 9999,断言 snap 内元素的 `Usedmem` 仍为原值——即 SnapshotDevice 返回的是与源对象隔离的副本,后续打分阶段对 snapshot 的读取不受并发改动源 DeviceUsage 影响。返回切片长度等于入参设备数(空列表→0)。
  <details><summary>代码依据 pkg/scheduler/policy/node_policy_test.go</summary>

  ```diff
  +func TestSnapshotDevice(t *testing.T) {
  +	ns := &NodeScore{}
  +	...
  +			snap := ns.SnapshotDevice(tt.devices)
  +			assert.Equal(t, tt.want, len(snap))
  +			for i, d := range snap {
  +				assert.Equal(t, tt.devices.DeviceLists[i].Device.ID, d.ID)
  +				originalUsedmem := d.Usedmem
  +				tt.devices.DeviceLists[i].Device.Usedmem = 9999
  +				assert.Equal(t, originalUsedmem, d.Usedmem)  // 改源不影响快照 = 深拷贝
  +			}
  ```
  </details>
- `pkg/util/nodelock` 的 `setupNodeLockTimeout()` 读环境变量 **`HAMI_NODELOCK_EXPIRE`** 来设全局 `NodeLockTimeout`:空值→保持默认;合法 duration(如 "10m")→生效;非法字符串(如 "notaduration")→**回退默认不报错**。即节点锁过期时间运维可调,且坏配置不会把超时刷成 0。
  <details><summary>代码依据 pkg/util/nodelock/nodelock_test.go</summary>

  ```diff
  +func TestSetupNodeLockTimeout(t *testing.T) {
  +	original := NodeLockTimeout
  +	tests := []struct{ name, env string; want time.Duration }{
  +		{"empty env uses default", "", original},
  +		{"valid duration sets timeout", "10m", 10 * time.Minute},
  +		{"invalid duration keeps default", "notaduration", original},
  +	}
  +	... t.Setenv("HAMI_NODELOCK_EXPIRE", tt.env); setupNodeLockTimeout()
  ```
  </details>

### 后续发展方向 [AI]
- 证据只覆盖**测试新增**,未见生产代码改动——本期是 v2.9.0 发版后的覆盖率补强(#1926/#1928),指向社区在为调度核心路径(节点打分快照、节点锁超时)补回归网,而非功能演进。未见任何 API/CRD/hook 切分能力变化。
- 提交链接:https://github.com/Project-HAMi/HAMi/commit/5b7b91f728c3e983f750fc991e546e24460b6d83 (#1926) ; https://github.com/Project-HAMi/HAMi/commit/e54796e88d2386c2c0fa924bdca3bfd0298e9996 (#1928)

## 本期无实质改动(折叠)
<details><summary>4 个 repo 本日无新提交(HEAD 未变,仅保锚点)</summary>

- Project-HAMi/HAMi-core —— 4bbd97ad,未动
- Project-HAMi/volcano-vgpu-device-plugin —— 7aba1850,未动
- Project-HAMi/ascend-device-plugin —— 799eaa34,未动
- Project-HAMi/HAMi-WebUI —— 30c3ce14,未动(Release hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=5b7b91f728c3e983f750fc991e546e24460b6d83 branch=master release=v2.9.0 scanned=2026-06-06 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=4bbd97ad48a5ca82149fe89787d2df7ac855e465 branch=main release=— scanned=2026-06-06 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=7aba185031fd2f6169885b9c94cfbe1dfc5b788f branch=main release=— scanned=2026-06-06 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-06 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-06 -->
</content>
</invoke>

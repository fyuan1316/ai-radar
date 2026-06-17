# HAMi diff 雷达 2026-06-18

## 摘要
- HAMi 主仓单点修复一个 leader 选举死锁/卡顿:把 `OnStartedLeading/OnStoppedLeading` 回调从「持 lease 锁内同步调用」改为「先解锁再调用」,并把调度器侧 `leaderNotify` 的阻塞 channel send 改为非阻塞 `select+default`。属调度器高可用健壮性补课,非新能力。
- HAMi-core / volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI 四仓本日无实质改动(无新提交)。

## 当日重要改变
- 无(本期改动未命中弃用/API-CRD/架构方向/版本跨档/新能力 任一信号;仅一处并发缺陷修复)

## Project-HAMi/HAMi: 5bfaee19 -> b9ecc20d
- 比较: 5bfaee19 -> b9ecc20d | ahead=4 | files=4 | Release: v2.9.0
- PR: https://github.com/Project-HAMi/HAMi/pull/1957
- Compare: https://github.com/Project-HAMi/HAMi/compare/5bfaee19fdcfae2f58bb35ebfd2f012d2615d667...b9ecc20d12cb70b9d8e6df91c952b65fd5f5a2ac

### AI 总结重点(源码 diff 为据)
- **leader 回调脱离 lease 锁执行,根治锁内阻塞导致的选举卡死**。`leaderManager` 的 `onAdd/onUpdate/onDelete` 原来全程 `m.leaseLock.Lock()` + `defer Unlock()`,在持锁状态下直接调用 `m.callbacks.OnStartedLeading()/OnStoppedLeading()`。改为:持锁只更新 `setObservedRecord`、把要调的回调取进局部变量 `callback`,**先 `m.leaseLock.Unlock()` 再在锁外 `callback()`**。这样回调若阻塞,不会再扣住 lease 锁、卡死后续 lease 观察事件的处理。

  <details><summary>代码依据 pkg/util/leaderelection/leaderelection.go</summary>

  ```diff
  	m.leaseLock.Lock()
  -	defer m.leaseLock.Unlock()
  -
  	m.setObservedRecord(lease)
  -	// Notify if we are the leader from the very begging
  -	if m.isHolderOf(lease) && m.callbacks.OnStartedLeading != nil {
  -		m.callbacks.OnStartedLeading()
  +	var callback func()
  +	if m.isHolderOf(lease) {
  +		callback = m.callbacks.OnStartedLeading
  +	}
  +	m.leaseLock.Unlock()
  +
  +	if callback != nil {
  +		callback()
  	}
  ```
  `onUpdate`(主→从/从→主切换)、`onDelete` 三处同构改造,均为「锁内取 callback、解锁、锁外调用」。
  </details>

- **调度器 `leaderNotify` 的阻塞发送改非阻塞,断开「无接收者就卡住回调」的链路**。`NewScheduler()` 里 `OnStartedLeading` 原本对无缓冲(或满)channel 做同步 `s.leaderNotify <- struct{}{}`;一旦此刻无 goroutine 接收,该 send 永久阻塞,叠加上面锁内调用就把整个 lease informer 卡死。改为 `select { case s.leaderNotify <- struct{}{}: default: }`——发不出去就丢弃、立即返回。

  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  		OnStartedLeading: func() {
  -			s.leaderNotify <- struct{}{}
  +			select {
  +			case s.leaderNotify <- struct{}{}:
  +			default:
  +			}
  		},
  ```
  </details>

### 后续发展方向 [AI]
- 两处改动是同一缺陷的两端互补修复(锁持有期最小化 + channel send 非阻塞化),指向 HAMi 调度器在**多副本 HA / leader 选举抖动**场景下的稳定性收敛,而非功能扩张。结合近期 HAMi-core 的 snprintf 安全硬化,可判断 HAMi 全家桶当前处于一轮以健壮性/正确性为主的"补课期"。证据只覆盖本区间这 4 文件中的 2 个核心 hunk,未见对 `leaderNotify` 接收端消费逻辑的改动——丢弃 notify 后调度器首次成为 leader 是否仍能正确触发一次全量 reconcile,本 diff 未给出依据,需看接收端实现确认非阻塞丢弃不会漏掉首次选举信号。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=b9ecc20d12cb70b9d8e6df91c952b65fd5f5a2ac branch=master release=v2.9.0 scanned=2026-06-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=0831874bce5af56cefca7093dfb2f9f95d1970aa branch=main release=— scanned=2026-06-18 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-06-18 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-18 -->

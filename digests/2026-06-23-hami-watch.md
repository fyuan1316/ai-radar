# HAMi diff 雷达 2026-06-23

## 摘要
- HAMi 主仓 4 提交、纯 bug fix/构建卫生,无 API/CRD/能力变化:`CheckUUID` 修正 useKey+noUseKey 同时存在时黑名单被忽略的逻辑;`CheckHealth` 修正 handshake 注解无时间戳时的 panic;Dockerfile 把残留的 cuda-12 引用对齐到已切的 cuda-13.3 基础镜像。
- HAMi-core、volcano-vgpu-device-plugin、ascend-device-plugin、HAMi-WebUI 四仓本期均无新提交。
- 方向无转向:今日改动集中在调度准入(UUID 准入/节点健康判定)的健壮性,属对存量软切分路径的加固,非新能力。

## 当日重要改变
- 无(未命中弃用/移除、API/CRD、架构方向、版本跨档、新能力任一信号;均为 fix/build)

## Project-HAMi/HAMi: 38a9c428 -> bf7faa2c
- 比较: 38a9c428dd127474e885fce2174ba41edbfd5bef -> bf7faa2c | ahead=4 | files=16 | Release: v2.9.0
- 比较链接: https://github.com/Project-HAMi/HAMi/compare/38a9c428dd127474e885fce2174ba41edbfd5bef...bf7faa2c6b1c70a6f7d124ae2752b107ecdbcd15

### AI 总结重点(源码 diff 为据)
- **`CheckUUID` 准入逻辑从"useKey 命中即短路返回"改为"白名单+黑名单都要满足"**(#1965)。旧版一旦 `annos[useKey]`(指定可用 UUID 列表)存在,就直接按白名单结果 `return`,导致 `noUseKey`(指定不可用 UUID 列表)在 useKey 也设了时被完全忽略;新版把两者拆成各自独立的否决项——白名单存在但 id 不在其中→`false`;黑名单存在且 id 在其中→`false`;都不否决才 `true`。同时把成员判定抽成 `match()` 闭包并对每个 UUID 做 `TrimSpace`,容忍逗号分隔列表里的空格。这是一处**准入语义修正**:此前用户同时设白/黑名单时,黑名单形同虚设。
  <details><summary>代码依据 pkg/device/devices.go</summary>

  ```diff
  func CheckUUID(annos map[string]string, id, useKey, noUseKey, deviceType string) bool {
  -	userUUID, ok := annos[useKey]
  -	if ok {
  -		userUUIDs := strings.Split(userUUID, ",")
  -		return slices.Contains(userUUIDs, id)
  +	match := func(list string) bool {
  +		return slices.ContainsFunc(strings.Split(list, ","), func(u string) bool {
  +			return strings.TrimSpace(u) == id
  +		})
  +	}
  +	if userUUID, ok := annos[useKey]; ok {
  +		if !match(userUUID) {
  +			return false
  +		}
  	}
  -	noUserUUID, ok := annos[noUseKey]
  -	if ok {
  -		noUserUUIDs := strings.Split(noUserUUID, ",")
  -		return !slices.Contains(noUserUUIDs, id)
  +	if noUserUUID, ok := annos[noUseKey]; ok {
  +		if match(noUserUUID) {
  +			return false
  +		}
  	}
  	return true
  }
  ```
  </details>

- **`CheckHealth` 对 handshake 注解的时间戳解析加了防御,消除 panic**(#1964)。旧版用 `strings.Split(handshake, "_")[1]` 直接取下标 1,当注解为 `Requesting` 但无 `_<时间戳>` 后缀时下标越界 panic;新版改用 `strings.Cut` 拿 `found` 标志、再对 `ParseInLocation` 检 `err`,任一失败都安全返回 `(true, false)`(视作健康、不触发后续超时逻辑)。属节点健康检查路径的健壮性修复。
  <details><summary>代码依据 pkg/device/devices.go</summary>

  ```diff
  	if strings.Contains(handshake, "Requesting") {
  -		formertime, _ := time.ParseInLocation(time.DateTime, strings.Split(handshake, "_")[1], time.Local)
  +		_, timestampStr, found := strings.Cut(handshake, "_")
  +		if !found {
  +			return true, false
  +		}
  +		formertime, err := time.ParseInLocation(time.DateTime, timestampStr, time.Local)
  +		if err != nil {
  +			return true, false
  +		}
  		if time.Now().Before(formertime.Add(time.Second * 60)) {
  			return true, false
  		}
  ```
  </details>

- **构建侧:多个 Dockerfile 修正 cuda 版本残留引用**(#1961)。基础镜像早已切到 `nvidia/cuda:13.3.0`,但 `apt-mark hold` 仍 hold `cuda-toolkit-12-config-common`、`rm -rf /usr/local/cuda-12.6/compat/libcuda.so*` 仍指向 12.6 路径,实际不生效;统一改为 `cuda-toolkit-13-config-common` 与 `cuda-13.3` 路径。涉及 Dockerfile、Dockerfile.withlib、Dockerfile.hamimaster、Dockerfile.hamicore。顺带 CI 把 `actions/checkout@v6` 升到 `@v7`。无运行时行为变化。
  <details><summary>代码依据 docker/Dockerfile.withlib</summary>

  ```diff
  FROM nvidia/cuda:13.3.0-base-ubuntu22.04
  RUN apt-get update && \
  -    apt-mark hold cuda-toolkit-config-common cuda-toolkit-12-config-common && \
  +    apt-mark hold cuda-toolkit-config-common cuda-toolkit-13-config-common && \
       DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && \
       ...
  -RUN rm -rf /usr/local/cuda-12.6/compat/libcuda.so*
  +RUN rm -rf /usr/local/cuda-13.3/compat/libcuda.so*
  ```
  </details>

### 后续发展方向 [AI]
- 准入链(`CheckUUID`)从"白名单优先短路"转向"白/黑名单各自独立否决",意味着 HAMi 在 UUID 级设备过滤上正把语义补全成可叠加规则;后续若扩展更多过滤维度(机型/拓扑标签),这套"逐项否决"的结构更易接。证据仅覆盖本次 diff 的 UUID 准入函数,未见调度器主流程或 CRD 侧对应改动。
- 健康检查(`CheckHealth`)的防御式改写说明 handshake 注解格式在真实环境里出现过非预期值;这是对存量软切分节点健康判定的加固,未触及 hook/时分切分内核(HAMi-core 本期无提交)。

## 本期无实质改动(折叠)

<details><summary>4 仓全部 EMPTY(自上次扫描无新提交)</summary>

- Project-HAMi/HAMi-core(main):0831874b 无新提交
- Project-HAMi/volcano-vgpu-device-plugin(main):6561f1c1 无新提交
- Project-HAMi/ascend-device-plugin(main):799eaa34 无新提交
- Project-HAMi/HAMi-WebUI(main,hami-webui-1.2.0):30c3ce14 无新提交

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)

<!-- ANCHOR repo=Project-HAMi/HAMi sha=bf7faa2c6b1c70a6f7d124ae2752b107ecdbcd15 branch=master release=v2.9.0 scanned=2026-06-23 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=0831874bce5af56cefca7093dfb2f9f95d1970aa branch=main release=— scanned=2026-06-23 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-06-23 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-23 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-23 -->

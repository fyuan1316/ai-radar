# 昇腾算力栈 diff 雷达 2026-07-11

## 摘要
- **vNPU 客户端自愈脚本重写为"配置驱动 + 全量自愈",并把 preload hook 纳入持续修复**:`client_update/acl-client-update.sh`(vNPU 运行时在节点/容器内保活 vCANN 拦截库与监控工具的自愈 agent)从一堆硬编码变量 + 手工 install 命令,改成 `FILES`/`SYMLINKS` 两张关联数组注册表;更关键的是修掉了旧逻辑里"libvruntime.so 存在时进 `while sleep 3600` 死循环、导致下方 5s 自愈 watch 循环永远不可达"的结构问题——现在 libvruntime.so / ld.so.preload 这两个 LD_PRELOAD 拦截文件也进了 5s 自愈注册表,漂移即修复。属 `[修复][健壮性]`。
- **同批把文件完整性校验从 sha256 降到 md5**(!73):`sync_file` 用 `md5sum` 比对源/目标,替换旧 `update_all_rx` 的 `sha256sum`。仅用于检测文件漂移(非安全用途),换 md5 是为降低每 5s 校验一遍所有文件的开销。
- **mind-cluster 本期 6 个提交全是文档类**(issue 模板、修 invalid url / 错误 python 版本、信息订正),按 component/ 前缀过滤后无任何组件代码改动,不写正文;tag 仍停 v26.1.0.beta.2。其余 7 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)无新提交。

## 当日重要改变
- vNPU [修复][健壮性] 客户端自愈脚本重写:LD_PRELOAD 拦截文件(libvruntime.so / ld.so.preload)由"仅安装一次"改为纳入 5s 周期自愈,移除旧代码中 libvruntime.so 存在即 `while sleep 3600` 死循环导致自愈 watch 不可达的问题;整体改为 `FILES`/`SYMLINKS` 配置驱动注册表。证据文件 client_update/acl-client-update.sh。https://gitcode.com/openFuyao/vNPU/compare/464c7358071a6cc48f463c10fedf6b2d4519a5f3...34f7965bb9e94b031b7afb2329fe3ff611e8c303
- vNPU [行为变更] 文件完整性校验 sha256 → md5(!73):`sync_file` 用 `md5sum` 检测源/目标漂移,替换旧 `sha256sum`。同上 compare 链接

## vNPU: 464c7358 -> 34f7965b
- 比较: https://gitcode.com/openFuyao/vNPU/compare/464c7358071a6cc48f463c10fedf6b2d4519a5f3...34f7965bb9e94b031b7afb2329fe3ff611e8c303 | tag: v0.1.0 | commits=2 | truncated=false

### AI 总结重点(源码 diff 为据)

- **`acl-client-update.sh` 从"硬编码变量 + 手工 install"重写为配置驱动注册表**。旧版把每个受管文件写成独立变量(`monitor_name`/`tool_name`/`root_monitor_path` …)再逐条 `install`/`ln`;新版引入两张关联数组:`FILES`(目标路径→源路径,含 enpu-monitor、xpu-client-tool、libvruntime.so、ld.so.preload、systemd-detect-virt)与 `SYMLINKS`(xpu-monitor→enpu-monitor),"加一个受管文件 = 加一行"。安装、自愈两处逻辑都改为遍历这两张表,消除了两处逻辑手工列表不一致的隐患。
  <details><summary>代码依据 client_update/acl-client-update.sh(注册表)</summary>

  ```diff
  +# File registry: destination -> source
  +declare -A FILES=(
  +    ["${WORK_BIN_PATH}/enpu-monitor"]="${ROOT_PATH}/enpu-monitor"
  +    ["${WORK_BIN_PATH}/xpu-client-tool"]="${ROOT_PATH}/xpu-client-tool"
  +    ["${WORK_LIB_PATH}/libvruntime.so"]="${ROOT_PATH}/libvruntime.so"
  +    ["${WORK_LIB_PATH}/ld.so.preload"]="${ROOT_PATH}/ld.so.preload"
  +    ["${WORK_BIN_PATH}/systemd-detect-virt"]="${ROOT_PATH}/systemd-detect-virt"
  +)
  +declare -A SYMLINKS=(
  +    ["${WORK_BIN_PATH}/xpu-monitor"]="enpu-monitor"
  +)
  ```
  </details>

- **修掉"preload 文件仅装一次、自愈 watch 永不可达"的结构缺陷**。旧版:`if [ -f libvruntime.so ]` 块内 `copy_preload_files` 装完 preload 后,尾部是 `while true; do sleep 3600; done` —— 一旦 libvruntime.so 存在,脚本就卡在这个空转死循环里,下方真正做 sha256 漂移检测的 `while true … sleep 5` 自愈 watch 循环**永远走不到**;即 vCANN 的 LD_PRELOAD 拦截库装上后不再被保活。新版删掉这个死循环,把 libvruntime.so / ld.so.preload 一并放进统一的 `FILES` 注册表,Step 4 自愈守护循环每 `HEAL_INTERVAL=5` 秒遍历全表 `sync_file` + `sync_symlink` 修复漂移。
  <details><summary>代码依据 旧的 sleep 3600 死循环被移除、preload 纳入自愈</summary>

  ```diff
  -if [ -f "${root_path}/libvruntime.so" ]; then
  -    if copy_preload_files libvruntime.so ld.so.preload; then ...
  -    install -m 555 "${root_path}/systemd-detect-virt" "${work_bin_path}/systemd-detect-virt"
  -    while true; do
  -        sleep 3600
  -    done
  -fi
  +# Step 4: Self-healing daemon loop
  +while true; do
  +    for dest in "${!FILES[@]}"; do
  +        sync_file "${FILES[${dest}]}" "${dest}"
  +    done
  +    for link in "${!SYMLINKS[@]}"; do
  +        sync_symlink "${link}" "${SYMLINKS[${link}]}"
  +    done
  +    sleep "${HEAL_INTERVAL}"
  +done
  ```
  </details>

- **完整性校验哈希 sha256 → md5,并抽出 `sync_file`/`sync_symlink` 两个幂等函数**。旧 `update_all_rx` 用 `sha256sum` 比对源/目标、不一致就重装;新 `sync_file` 改用 `md5sum`,且补齐"源缺失→报错返回 1、目标不存在→首装、md5 不同→restore"三态语义;`sync_symlink` 用 `readlink` 校验软链目标漂移即 `ln -fs` 重建。校验降到 md5 属性能取向(每 5s 全表校验,md5 更快,漂移检测非安全场景)。
  <details><summary>代码依据 sync_file:md5sum 替换 sha256sum</summary>

  ```diff
  -update_all_rx() {
  -  src_sha256=$(sha256sum "${1}" | awk '{ print $1 }')
  -  dest_sha256=$(sha256sum "${2}" | awk '{ print $1 }')
  -  if [ "${src_sha256}" != "${dest_sha256}" ]; then
  -    install -m 555 "${1}" "${2}"
  +sync_file() {
  +    local src="$1" dest="$2"
  +    if [ ! -f "${src}" ]; then echo "${src} missing!"; return 1; fi
  +    if [ ! -f "${dest}" ]; then install -m ${FILE_MODE} "${src}" "${dest}"; return 0; fi
  +    src_md5=$(md5sum "${src}" | awk '{ print $1 }')
  +    dest_md5=$(md5sum "${dest}" | awk '{ print $1 }')
  +    if [ "${src_md5}" != "${dest_md5}" ]; then
  +        install -m ${FILE_MODE} "${src}" "${dest}"
  ```
  </details>

### 后续发展方向 [AI]
- **vNPU 软切分的落地形态是"节点内自愈 agent 保活 LD_PRELOAD 拦截栈"**,与 HAMi-core 的 CUDA hook 思路同构:`libvruntime.so` + `ld.so.preload` 是 vCANN 侧对昇腾运行时的预加载拦截入口,`enpu-monitor`/`xpu-monitor`/`xpu-client-tool` 是配套监控与客户端工具。本次改动把这套拦截文件从"装一次"升级到"5s 漂移即修复",说明 vNPU 把"拦截库被误删/覆盖导致隔离失效"当作要主动兜底的运行时风险。证据覆盖注册表定义、死循环移除与自愈循环、md5 校验三处;未见 libvruntime.so 内部拦截逻辑本身的改动(本仓这批仅 shell 保活层)。
- **校验降到 md5 是纯性能取向、非能力变化**,但把安全相关的 preload 文件用弱哈希做完整性校验,在"防篡改"语义上是弱化(md5 可碰撞);若后续要防恶意替换拦截库而非仅防意外漂移,这里需要回到强哈希或签名校验。证据仅 sync_file 一处哈希算法替换。
- 本期昇腾栈其余组件(mind-cluster 全栈、npu-operator、驱动容器化诸仓)零代码改动,昨日的 SR-IOV 网络栈开源合入后进入静默期,未见后续 VF 分配/隔离实现的增量。

## 本期无实质改动(折叠)
<details><summary>mind-cluster(仅文档)+ 7 个 openFuyao 仓无新提交</summary>

- mind-cluster(f1816ec3 -> 524bacd2,commits=6 但全为文档:issue 模板/修 invalid url 与错误 python 版本/信息订正,component/ 前缀下无组件代码改动)
- npu-operator(335bc283,无新提交)
- npu-container-toolkit(d54256e0,无新提交)
- npu-driver-installer(9f400f3c,无新提交)
- npu-node-provision(717ef777,无新提交)
- npu-dra-plugin(98f8fa5e,无新提交)
- volcano-ext(c9be5c4c,无新提交)
- ub-network-device-plugin(263d6387,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=524bacd2a8001c65c1b351f0d581bd5e9f676403 tag=v26.1.0.beta.2 scanned=2026-07-11 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=v26.6.0 scanned=2026-07-11 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-11 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=v26.6.0 scanned=2026-07-11 -->
<!-- ANCHOR repo=vNPU sha=34f7965bb9e94b031b7afb2329fe3ff611e8c303 tag=v0.1.0 scanned=2026-07-11 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-11 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-11 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-11 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-11 -->

# 昇腾算力栈 diff 雷达 2026-10-28

## 摘要
- **mind-cluster 唯一的大块代码改动 = 容器运行时挂载支持"主机路径→容器路径"重映射**:ascend-docker-runtime(C CLI + Go hook)与 ascend-common/cdi/mount 三处同步新增 `hostPath:containerPath` 语法,此前只能原路径 bind mount;配套一组共享的目标路径安全校验(拒 `..`/`/`/多余 `:`、长度上界),堵 rootfs 逃逸。
- **mind-cluster 行为变更:ascend-for-volcano 的 pod-error 故障节点默认退避时长从 30s 改为 0s**,且无真实终止时间的 pod 不再被记为"发生过故障"——pod-error 退避默认近乎关闭。
- **openFuyao 侧当日全部是昇腾 950PR 适配的设计提案(design doc,未落代码)**:vNPU 与 npu-dra-plugin 各提交 950 适配设计,vNPU 另提交软切分算力优先级抢占调度设计(新 annotation `huawei.com/vnpu-priority`,在线/离线混部)。方向信号强,但本期仅文档。

## 当日重要改变
- mind-cluster [新能力] ascend-docker-runtime/CDI 挂载引擎新增 `hostPath:containerPath` 重映射 + 目标路径安全校验,改了 CLI 的 MountList 结构体与 Go hook 的 readMountConfig 解析。证据:component/ascend-common/cdi/mount/mount.go、component/ascend-docker-runtime/cli/src/main.c。https://gitcode.com/Ascend/mind-cluster/commit/6241d029f7c049db6be0baf051af9497c2fcebd2
- mind-cluster [行为变更] ascend-for-volcano pod-error 默认退避 `DefaultPodErrorToleranceAfterTime` 30→0,RecordPodError 对 faultTime<=0 由"补当前时间"改为"直接不记录"。证据:component/ascend-for-volcano/common/util/constants.go、common/cache/pod_error.go。https://gitcode.com/Ascend/mind-cluster/commit/6241d029f7c049db6be0baf051af9497c2fcebd2
- vNPU [架构方向] 新增设计提案《支持昇腾950系列》与《软切分算力优先级抢占调度》,仅 docs/design,未落代码。证据:docs/design/0002-support-Ascend-950.md、0003-support-VNPU-Priority-Preemption.md。https://gitcode.com/openFuyao/vNPU/commit/6282df8dde375d7ba17df8a2a1e66b8a17c5394d
- npu-dra-plugin [架构方向] 新增设计文档《Ascend 950PR DRA 插件适配》,仅 doc/,未落代码。证据:doc/ascend-950-dra-adaptation.md。https://gitcode.com/openFuyao/npu-dra-plugin/commit/f4b6f12153e346ee928bc05e22892f25f933bb7b

## mind-cluster: 1bcc4592 -> 6241d029
- 比较: 1bcc4592..6241d029 | tag: v26.2.0 | commits=8 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/1bcc459240f595c7d10e39eb2dc004eb1464f798...6241d029f7c049db6be0baf051af9497c2fcebd2

### AI 总结重点(源码 diff 为据)

- **挂载从"同路径 bind"升级为"主机路径→容器路径可重映射",语法 `hostPath[:containerPath]`,无 `:` 保持旧行为**。CDI 引擎新增 `ParseMountEntry` 解析该语法、`MountEntry` 新增 `ContainerPaths` 字段(与 `Paths` 1:1 对齐),Go hook 与 CDI 共用同一解析函数保持口径一致。
  <details><summary>代码依据 component/ascend-common/cdi/mount/mount.go</summary>

  ```diff
  + // ContainerPaths holds the in-container target path for each path in
  + // Paths (1:1 aligned); an empty string means same-path mount. Only the
  + // legacy list mode populates it via "hostPath[:containerPath]" entries.
  + ContainerPaths []string `json:"containerPath,omitempty"`
  ...
  + func ParseMountEntry(entry string) (string, string, error) {
  +   parts := strings.SplitN(entry, ":", 2)
  +   if len(parts) == 1 { ... return hostPath, "", nil }  // 旧行为:原路径挂载
  +   ... return hostPath, containerPath, nil
  + }
  ```
  </details>

- **目标容器路径做安全校验,堵 rootfs 逃逸/遮蔽**:`validateContainerPath`(Go)与 `CheckDstPath`(C)语义对齐——必须绝对路径、长度 < 1023/BUF_SIZE、不得含 `..`、不得为 `/`(否则遮蔽整个容器 rootfs)、不得含多余 `:`。两端共享上界 `MaxContainerPathLen=1023`,避免 hook/CDI 放行却被 CLI 拒。
  <details><summary>代码依据 component/ascend-docker-runtime/cli/src/main.c</summary>

  ```diff
  + STATIC bool CheckDstPath(const char *dst)
  + {
  +   size_t len = strlen(dst);
  +   if ((len <= 1) || (len >= BUF_SIZE) || (dst[0] != '/')) return false;  // 必须绝对路径且非 "/"
  +   if (strchr(dst, ':') != NULL) return false;                            // 多余 ':' 歧义
  +   return strstr(dst, "..") == NULL;                                      // 拒 ".." 防逃逸
  + }
  ```
  </details>

- **C 侧挂载表数据结构由定长字符串数组改为结构体数组**,为 dst(容器路径)腾出独立缓冲:`MountList.list` 从 `char list[MAX_MOUNT_NR][PATH_MAX]` 改为 `struct MountEntry list[MAX_MOUNT_NR]`,`MountEntry{ src[PATH_MAX]; dst[BUF_SIZE]; }`;`main.c` 新增 `SplitMountEntry` 用 `memchr` 在 PATH_MAX 内有界扫描 `:`。
  <details><summary>代码依据 component/ascend-docker-runtime/cli/src/basic.h</summary>

  ```diff
  + struct MountEntry
  + {
  +   char src[PATH_MAX];  // host path
  +   char dst[BUF_SIZE];  // container path; empty means same as src
  + };
    struct MountList {
      unsigned int count;
  -   char list[MAX_MOUNT_NR][PATH_MAX];
  +   struct MountEntry list[MAX_MOUNT_NR];
    };
  ```
  </details>

- **Go hook 的挂载配置解析接入统一解析**:`readMountConfig` 改为 `strings.TrimSpace` + 跳过空行/`#` 注释行(与 CDI `parseListFile` 对齐),调用 `parseMountEntry` 拆 host/container,glob 路径禁止带容器映射(`glob path does not support container mapping`),拼回 CLI 入参用 `buildMountEntry`。
  <details><summary>代码依据 component/ascend-docker-runtime/hook/process/process.go</summary>

  ```diff
  - mountPath := scanner.Text()
  + mountPath := strings.TrimSpace(scanner.Text())
  + if mountPath == "" || mountPath[0] == '#' { continue }  // 跳空行/注释
    ...
  + hostPath, containerPath, err := parseMountEntry(mountPath)
  + if containerPath != "" && containsGlob(hostPath) {
  +   return nil, nil, fmt.Errorf("mount entry %s: glob path does not support container mapping", hostPath)
  + }
  ```
  </details>

- **ascend-for-volcano pod-error 退避收紧为"默认不退避 + 只认真实故障时间"**。`DefaultPodErrorToleranceAfterTime` 30→0(引发上次重调度的节点默认不再被扣留);`RecordPodError` 对 `faultTime<=0` 由"补 `time.Now()`"改为"直接 return 不记录";`getPodFailedTime` 由返回 0 改为返回 error(无终止时间时让调用方回退、不误设 `PodFailedTime`);移除退避卡的日志级别 Debug→Warning。
  <details><summary>代码依据 component/ascend-for-volcano/common/cache/pod_error.go + common/util/constants.go</summary>

  ```diff
    if faultTime <= 0 {
  -   faultTime = time.Now().Unix()
  +   return
    }
  ---
  - DefaultPodErrorToleranceAfterTime = 30
  + DefaultPodErrorToleranceAfterTime = 0
  ```
  </details>

### 后续发展方向 [AI]
- 挂载重映射是**容器内 NPU 资源可见性布局的基础设施**:有了 `hostPath:containerPath` 后,驱动/固件/库文件可按容器内约定路径注入,不再被迫与主机同路径——这为多版本 CANN/固件并存、以及后续 950 新目录布局(见 openFuyao 侧 950 适配)铺路。证据覆盖解析/校验/数据结构三层,未见调用方(device-plugin 下发侧)如何生成带映射的 list,方向推断有边界。
- pod-error 退避默认归零 + 严格认定,说明昇腾重调度正从"保守扣留故障节点 30s"转向"交由上层(silent-fault 四态等)判定、减少误扣容量"。注释提到与 silent-unhealthy 容忍上界同构,但本期只动 pod-error 一支,未见 silent-fault 侧联动改动。

## openFuyao/vNPU: 60eb00c7 -> 6282df8d
- 比较: 60eb00c7..6282df8d | tag: v26.9.0 | commits=3 | truncated=false
- https://gitcode.com/openFuyao/vNPU/compare/60eb00c70ff741cbb4a3d06779b9995c441a67e6...6282df8dde375d7ba17df8a2a1e66b8a17c5394d

### AI 总结重点(源码 diff 为据)
- 本期**仅两份设计文档(docs/design),无代码落地**,以下为设计意图,不是已实现行为。
- **《0002 支持昇腾950系列》**:950PR 与 310/910 多处不兼容——NPU ID 改用 dev_id(logicID)、`npu-smi -i` 不再支持 `-c chip_id`;DCMI 全面重构为 V2(`dcmiv2_*`,与 V1 不兼容,950 只加载 V2);**950 不支持硬切分**,硬切路径直接报错;显存改自研 HBM(原按芯片名 "910" 子串判断会误走 DDR);配套 HDK 25.7.RC1 + CANN 9.1.0,mind-cluster 子模块需升到 v26.1.0(其 ascend-common 的 DCMI V1/V2 并存)。方案:logicID 作统一内部主键、DCMI 版本差异在封装层消化、芯片能力表替代散落的芯片名子串判断、节点注解双版本双写保滚动升级互通。
  <details><summary>代码依据 docs/design/0002-support-Ascend-950.md</summary>

  ```diff
  + | 2 | 不支持硬切分 | 950PR仅支持软切分,无硬切分模板,硬切部分需要直接返回错误 |
  + | 3 | DCMI接口全部为V2 | ... 仅提供dcmiv2_xx接口,不兼容原dcmi_xx接口 ... mind-cluster需升级到v26.1.0 |
  + | 6 | 芯片识别与显存 | 950PR使用自研HBM显存,现有芯片名"910"子串判断无法命中950,会误走DDR显存查询路径 |
  ```
  </details>
- **《0003 软切分算力优先级抢占调度》**:面向在线/离线混部,新增 Pod annotation `huawei.com/vnpu-priority`("1"高优/"0"普通),打通"Pod annotation→调度器校验→device-plugin→npu_info.config→vCANN"端到端链路。语义:**高优先级 vNPU 的算力调度模式全部失效**(vCANN 置 `core_limit_quota=0`、`sched_policy=3` best-effort),抢占同卡所有低优先级 vNPU(含 fixed-share 保底配额);**算力可超卖(高优不做配额声明/校验)、显存不可超卖(硬隔离、不可抢占)**;优先级不编码进 `vnpu-ids-new`(保持 7 字段格式),由 device-plugin 在 Allocate 时重读 Pod annotation,与既有 `vnpu-soft-scheduler-policy` 完全同构;需升级 ubs-virt 子模块到含 `vnpu_priority` 的 master。
  <details><summary>代码依据 docs/design/0003-support-VNPU-Priority-Preemption.md</summary>

  ```diff
  + | annotation键 | `huawei.com/vnpu-priority` |
  + | 取值 | `"1"`:高优先级(在线业务);`"0"`:普通服务(离线业务) |
  + 高优先级vNPU的算力调度模式配置全部失效(vCANN默认core_limit_quota=0、sched_policy=3,不受配额约束),凭优先级抢占算力
  + 算力可超卖、显存不可超卖
  ```
  </details>

### 后续发展方向 [AI]
- 两份设计共同指向**950PR 作为下一代主力卡的全栈使能**:vNPU 侧把 DCMI V2/logicID/能力表作为改造主线,且明确"硬切分在 950 上消失、只剩整卡+软切分"——意味着昇腾虚拟化重心从模板化硬切转向 vCANN 时间片软切。证据仅设计文档,实际 device-plugin/调度器代码改动待后续 commit 验证。
- 优先级抢占把"在线/离线混部 QoS"下沉到 vCANN 时间片层、K8s 只做契约透传,是对标 GPU 侧(MPS/MIG + 优先级)的混部能力补齐。设计强调"显存硬约束、算力可超卖",但抢占兜底(防饿死)声称在 vCANN 底层,本仓看不到,方向可信度受限于文档声明。

## openFuyao/npu-dra-plugin: 031dc691 -> f4b6f121
- 比较: 031dc691..f4b6f121 | tag: v26.9.0 | commits=2 | truncated=false
- https://gitcode.com/openFuyao/npu-dra-plugin/compare/031dc691f082fdb90610f77eab3bcf91ad8e9aa3...f4b6f12153e346ee928bc05e22892f25f933bb7b

### AI 总结重点(源码 diff 为据)
- 本期**仅一份设计文档(doc/),无代码落地**。《Ascend 950PR DRA 插件适配》与 vNPU 侧 950 适配同源,但聚焦 DRA 路径特有问题:
  - **CDI 注入的 `/dev/davinciN` 必须改用 logicID**(当前代码用 physicalID,950 上 davinciX 编号即 logicID,行为需变更);
  - **DCMI V1/V2 兼容用"运行时符号探测"**:加载 `libdcmi.so` 后先探 `dcmiv2_*` 符号集,缺失回退 V1,单二进制兼容混布节点,不依赖编译期驱动版本;
  - **UB 拓扑属性化**:950 的 2卡/4卡组经 UB 互联(老卡为 HCCS),用 `dcmiv2_get_topo_info_by_device_id` 取 UB 关系、上报 `topoUBGroupID`,并交付 UB 亲和的 DeviceClass/CEL 调度用例;
  - 芯片名确认为 `Ascend_950`(AICore 32、HBM 128GB),需补显存 HBM 分支与 PCIe DID 条目。
  <details><summary>代码依据 doc/ascend-950-dra-adaptation.md</summary>

  ```diff
  + 950 上 CDI 注入的 `/dev/davinciN` 必须用 **logicID**(当前代码用 physicalID,行为需变更)
  + **DCMI V1/V2 双版本兼容**:采用**运行时符号探测**——加载 `libdcmi.so` 后先探测 `dcmiv2_*` 符号集,缺失则回退 V1
  + **UB 拓扑属性化**:... `dcmiv2_get_topo_info_by_device_id`(拓扑类型含 `DCMI_TOPO_TYPE_UB`)... 上报 `topoUBGroupID` 属性
  ```
  </details>

### 后续发展方向 [AI]
- DRA 路径的 950 适配独立于 device-plugin 路径推进(两者并存),说明昇腾在 K8s 原生 DRA 上的投入持续;UB 拓扑进 DRA DeviceClass/CEL 是 950 多卡训练 fabric 感知调度的关键,对标 NVIDIA DRA + NVLink 拓扑。本期仅文档,运行时符号探测与 UB 属性的真实实现待后续 commit。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos(仅保锚点)</summary>

- npu-operator — 无新提交
- npu-container-toolkit — 无新提交
- npu-driver-installer — 无新提交
- npu-node-provision — 无新提交
- volcano-ext — 无新提交
- ub-network-device-plugin — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=6241d029f7c049db6be0baf051af9497c2fcebd2 tag=v26.2.0 scanned=2026-10-28 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-10-28 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-10-28 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-10-28 -->
<!-- ANCHOR repo=vNPU sha=6282df8dde375d7ba17df8a2a1e66b8a17c5394d tag=v26.9.0 scanned=2026-10-28 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-28 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f4b6f12153e346ee928bc05e22892f25f933bb7b tag=v26.9.0 scanned=2026-10-28 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-28 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=v26.9.0 scanned=2026-10-28 -->
</content>
</invoke>

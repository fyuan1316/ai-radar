# 昇腾算力栈 diff 雷达 2026-10-20

## 摘要
- **mind-cluster:ascend-device-plugin 删除"优雅容错"(GraceTolerance)整条代码链**——DevManager 接口、910/310/310P 实现、HotResetManager 大半接口与 HotResetTools 状态字段全部移除。device-plugin 正退回"纯设备管理",训练任务级故障容错职责上移到 TaskD + ClusterD。
- **mind-cluster 新增 docker/ascend-clusterops-agent 容器镜像**:把 ascend-faultdiag 封成"集群级一键故障诊断 agent"(agent-core + node-collector 合并镜像),一条 `kubectl ascend_diag` 跑完"采集→解析→诊断→上报",可选接 LLM 做根因总结。
- 其余 8 个 openFuyao 仓(npu-operator / vNPU / npu-dra-plugin / npu-driver-installer 等)本期均无新提交。

## 当日重要改变
- mind-cluster [弃用/移除] ascend-device-plugin 彻底移除 GraceTolerance/热复位容错代码(接口+实现+辅助函数),故障容错从 device-plugin 剥离。证据 commit 0d015d7dbbbd「【DP】删除优雅容错代码」 https://gitcode.com/Ascend/mind-cluster/commit/0d015d7dbbbd
- mind-cluster [新能力] 新增 ClusterOps Agent 容器镜像,封装 ascend-faultdiag 做集群级分布式故障诊断。证据 commit 3e024f7c8ede + docker/ascend-clusterops-agent/ https://gitcode.com/Ascend/mind-cluster/commit/3e024f7c8ede
- mind-cluster [架构方向] TaskD README 重写,明确 Manager-Agent-Worker 三层容错架构(依赖 ClusterD 故障检测 + MindIO Checkpoint),印证容错职责向 TaskD 收敛。证据 component/taskd/README.md(文档级,未见 .go 实现)。

## mind-cluster: 07e3f3cc -> e1ba83eb
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/07e3f3ccb778a76db838fc18344d77e8e1c47d0e...e1ba83eb9ed086e6caf73668b505dcf761989599 | tag: v26.2.0 | commits=12 | truncated=false

### AI 总结重点(源码 diff 为据)

- **device-plugin 不再实现"优雅容错":`DevManager` 接口删去 `GraceTolerance(context, map[string][]*common.NpuDevice)` 方法**,910/310/310P 三个 manager 的对应实现同步删除,`HwDevManager.graceTolerance` 包装器也删。即 device-plugin 启动后不再对训练任务做"检测故障设备→热复位→通知任务"的闭环。

  <details><summary>代码依据 ascendcommon.go / ascend910.go / manager.go</summary>

  ```diff
  // ascendcommon.go —— 从设备管理接口删除容错入口
   type DevManager interface {
   	GetNPUs() (common.NpuAllInfo, error)
   	DoWithVolcanoListAndWatch(map[string][]*common.NpuDevice, int)
  -	GraceTolerance(context.Context, map[string][]*common.NpuDevice)
   	SetDmgr(devmanager.DeviceInterface)

  // ascend910.go —— 删除 910 的 GraceTolerance 实现与全部热复位全局态
  -	isHotResetOn                        = false
  -	inResetDev                    int32 = -1
  -	isolateDevList                []int32
  -	resetTimeMap                  = &sync.Map{}
  -// GraceTolerance process training task with device fault gracefully
  -func (hnm *HwAscend910Manager) GraceTolerance(ctx context.Context, classifyDevs ...) { ... }

  // manager.go —— 删除 HwDevManager 层的 graceTolerance 调度包装
  -func (hdm *HwDevManager) graceTolerance(ctx context.Context, groupDevice map[string][]*common.NpuDevice) {
  -	hdm.manager.GraceTolerance(ctx, groupDevice)
  -	return
  -}
  ```
  </details>

- **`HotResetManager` 接口从"任务感知的热复位编排器"瘦身为"ConfigMap 同步器"**:删去 `GetResetDevNumOnce/GetDevIdList/GetDevProcessPolicy/GetFaultDev2PodMap/GetTaskNameByPod/GenerateTaskDevFaultInfoList/UpdateFaultDev2PodMap/UpdateGlobalDevFaultInfoCache/UpdateTaskDevListCache/...` 一整组任务/故障映射方法,只保留 `SyncResetCM` 与 `GetCMFromCache`;`HotResetTools` 结构体随之删掉 `resetDevNumOnce/allTaskDevList/allTaskDevFaultInfo/globalDevFaultInfo/taskPod/faultDev2PodMap/resetTask/resetDev` 等状态,仅留 `queue/podIndexer/cmIndexer/jobs/noResetCmPodKeys`。

  <details><summary>代码依据 ascendtolerance.go</summary>

  ```diff
   type HotResetManager interface {
  -	GetResetDevNumOnce() (int, error)
  -	GetDevIdList(string) []int32
  -	GetFaultDev2PodMap() (map[int32]v1.Pod, error)
  -	GenerateTaskDevFaultInfoList(devIdList []int32, rankIndex string) ([]*common.TaskDevInfo, error)
  -	UpdateGlobalDevFaultInfoCache([]*common.NpuDevice, []int32) error
  -	...
   	SyncResetCM(context.Context, *kubeclient.ClientK8s)
   	GetCMFromCache(string) (*v1.ConfigMap, error)
   }
   type HotResetTools struct {
  -	resetDevNumOnce     int
  -	allTaskDevFaultInfo map[string][]*common.TaskDevInfo
  -	globalDevFaultInfo  map[int32]*common.DevFaultInfo
  -	faultDev2PodMap     map[int32]v1.Pod
  +	queue            workqueue.RateLimitingInterface
  +	podIndexer       cache.Indexer
  +	cmIndexer        cache.Indexer
   }
  ```
  </details>

- **删除设备"忙/复位计数"辅助函数**:`reset_info_mgr.go` 删 `IsDevBusy`、`AddBusyDev`、`AddResetCnt`;`ascendcommon.go` 删 `getResetInfoData`(解析 reset ConfigMap 的 RankList);`ascend910.go` 删 `getResetTime`。这些是原容错闭环里"判定设备可否复位/累加复位次数/读任务级 reset 信息"的工具,随主逻辑一并下线。

  <details><summary>代码依据 reset_info_mgr.go</summary>

  ```diff
  -// IsDevBusy check whether one device is busy, for example in reset, wait third party reset or wait manually reset
  -func IsDevBusy(logicID int32) bool { ... }
  -// AddBusyDev add a new busy device
  -func AddBusyDev(logicID int32) { ... }
  -// AddResetCnt add device reset count
  -func AddResetCnt(logicID int32) { ... }
  ```
  </details>

- **新增 ClusterOps Agent 镜像(docker/ascend-clusterops-agent):把 ascend-faultdiag 产品化为集群级诊断服务**。Dockerfile 用单镜像双角色——`SERVICE=agent-core`(管理节点,HTTP 9700 + gRPC 9710,维护 job-pod 中心关系缓存与挂载表、并发下发采集指令、聚合后调 `ascend-fd diag` 出报告)或 `SERVICE=node-collector`(计算节点,gRPC 9720,按 manifest 采机内/共享存储日志并本地 `ascend-fd parse`);用户侧为 `kubectl-ascend_diag`/`kubectl-clusterops` 插件,一条命令跑完 job 级诊断,可选接 LLM 总结根因。与 clusterd 一致以 uid 9000 `hwMindX` 非登录用户运行。

  <details><summary>代码依据 docker/ascend-clusterops-agent/v26.2.0/Dockerfile(新增)</summary>

  ```dockerfile
  # Ascend ClusterOps Agent merged image: one Dockerfile builds agent-core
  # (SERVICE=agent-core, HTTP 9700 + gRPC 9710) or node-collector
  # (SERVICE=node-collector, gRPC 9720). Set SERVICE explicitly in k8s manifests.
  ARG SERVICE=agent-core
  ENV SERVICE=${SERVICE}
  # dmidecode: node-collector SMBIOS collection; passwd: useradd/usermod
  RUN useradd -d /home/hwMindX -u 9000 -m -s /usr/sbin/nologin hwMindX
  RUN pip install --no-cache-dir /home/hwMindX/ascend_faultdiag-*.whl \
      /home/hwMindX/agent_core-*.whl /home/hwMindX/node_collector-*.whl
  ```
  </details>

### 后续发展方向 [AI]
- **故障容错在昇腾栈内明确分层并从 device-plugin 剥离**:device-plugin 回归"设备发现+上报+ConfigMap 同步",训练任务级容错(进程级在线恢复/热切换/弹性训练/进程级重调度)交给 TaskD(训练进程内 Manager-Agent-Worker),集群故障检测/恢复决策交给 ClusterD,离线日志诊断交给新的 ClusterOps Agent。证据覆盖 device-plugin 的 .go 删除 + clusterops-agent Dockerfile;TaskD/ClusterD 的"承接"目前只有 README/文档佐证,未见其 .go 实现 diff,方向判断待后续 component/taskd、component/clusterd 的代码增量确认。
- **诊断能力向"可运维产品"演进**:ClusterOps Agent 提供 kubectl 插件 + 结果缓存(`--refresh` 强刷)+ 可选 LLM 根因总结,对标 GPU 侧"节点诊断/健康检查"工具链。对我们产品的启示:昇腾底座正把"故障根因定位"做成开箱即用的集群服务(非散落日志人工排查),我们若做多厂商纳管,诊断入口(kubectl/控制台)与结果缓存/LLM 总结是可对标的产品点。证据仅 OVERVIEW.md + Dockerfile(镜像与能力描述),未见诊断调度的 Go 源码。

## 本期无实质改动(折叠)
<details><summary>8 个仓无新提交</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:比较 base..HEAD 无新提交。
- 另:mind-cluster 本期还有 CI 变更(build_job_compile.sh「增加 actions 并发以及抢占策略配置」)与大量 docs/zh/scheduling 文档更新,非产品代码,略。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=e1ba83eb9ed086e6caf73668b505dcf761989599 tag=v26.2.0 scanned=2026-10-20 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.6.0 scanned=2026-10-20 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.6.0 scanned=2026-10-20 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-20 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-20 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-20 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-10-20 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-20 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=1.0.2 scanned=2026-10-20 -->
</content>
</invoke>

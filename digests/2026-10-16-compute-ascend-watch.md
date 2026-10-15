# 昇腾算力栈 diff 雷达 2026-10-16

## 摘要
- **mind-cluster 本期仍是 infer-operator 的健壮性 + 安全加固,无能力/架构/API 改动**:①`getNewStatus` 在 `Spec.Replicas` 为 nil 时回退 `common.DefaultReplicas`,堵住"role.replicas 被移除后重调度路径直接 `updateStatus`、绕过校验"导致的解引用 panic——这是继昨日(10-15)快照控制器 `stsSpec.Replicas` 空指针修复之后,**连续第二天修 infer-operator 的 nil Replicas panic**,只是换了另一条状态更新路径;②infer-operator 日志目录加固:init 容器对 `/var/log/mindx-dl/infer-operator` 递归 `chown -R root:root`,主容器 securityContext 补 `runAsUser:0 / runAsGroup:0`。
- 其余 8 仓(openFuyao 全部:npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期**无新提交**,全 EMPTY。
- 无 `[弃用/移除]`/`[API/CRD变更]`/`[架构方向]`/`[新能力]` 信号命中,当日重要改变为"无"。

## 当日重要改变
- 无(本期仅 panic 防御 + 日志目录属主加固,未命中重要改变信号)。

## mind-cluster: 363fcc79 -> 28399af5
- 比较:363fcc79..28399af5 | tag: v26.1.1 | commits=8 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/363fcc798b562c2d85ef3eb39703b043261bc8fd...28399af5e4b11af64be2a49406da1ffde8e99863

### AI 总结重点(源码 diff 为据)

- **infer-operator `getNewStatus` 修 nil `Spec.Replicas` panic:为空时回退 `common.DefaultReplicas`**。原代码 `newStatus.Replicas = *instanceSet.Spec.Replicas` 直接解引用。改为先 `replicas := common.DefaultReplicas`,仅当 `instanceSet.Spec.Replicas != nil` 才覆盖。新增单测的注释点明了触发场景:**当 InferService 的 `role.replicas` 被删除、而旧 status 仍保留副本数时,重调度路径会对受影响的 InstanceSet 直接调 `updateStatus`、绕过 validate**,此时 `Spec.Replicas` 已是 nil。
  <details><summary>代码依据 component/infer-operator/pkg/controller/v1/instanceset_controller.go</summary>

  ```diff
  +	replicas := common.DefaultReplicas
  +	if instanceSet.Spec.Replicas != nil {
  +		replicas = *instanceSet.Spec.Replicas
  +	}
  +
  	newStatus = *instanceSet.Status.DeepCopy()
  -	newStatus.Replicas = *instanceSet.Spec.Replicas
  +	newStatus.Replicas = replicas
  	newStatus.ObservedGeneration = instanceSet.Generation
  ```
  </details>
  配套单测 `TestGetNewStatusWithNilSpecReplicas`:`Spec.Replicas=nil` 时 Reconcile 不 panic、`newStatus.Replicas == common.DefaultReplicas`、condition 为 `InstanceSetReady=False`。证据边界:与昨日修复的是**不同函数**(昨日是 snapshot 控制器 `TrackInstanceSet` 入参的 `stsSpec.Replicas`,今日是 `getNewStatus` 的顶层 `Spec.Replicas`),说明 nil Replicas 解引用在 infer-operator 里是散落多处的同类隐患,仍在逐点收口;本期未见是否已系统性排查所有解引用点。

- **infer-operator 日志目录属主加固:init 容器递归 chown + 主容器显式以 root 运行**。init 容器原命令对 `/var/log/mindx-dl/infer-operator` 只建目录+chmod 750,本次末尾追加 `chown -R root:root /var/log/mindx-dl/infer-operator`(递归纠正已有内容属主);同时主容器 securityContext 新增 `runAsUser:0 / runAsGroup:0`,使运行态 UID/GID 与日志目录属主一致。提交标题「init容器设置日志目录属主为 root」。
  <details><summary>代码依据 component/infer-operator/build/infer-operator.yaml</summary>

  ```diff
  -          command: ['sh', '-c', 'mkdir -p /var/log/mindx-dl && chmod 755 ... && chmod 750 /var/log/mindx-dl/infer-operator']
  +          command: ['sh', '-c', 'mkdir -p /var/log/mindx-dl && chmod 755 ... && chmod 750 /var/log/mindx-dl/infer-operator && chown -R root:root /var/log/mindx-dl/infer-operator']
  ...
             securityContext:
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: false
  +            runAsUser: 0
  +            runAsGroup: 0
               capabilities:
                 drop: ["All"]
  ```
  </details>
  证据边界:这是部署清单(build/*.yaml)层面的权限对齐,非控制器逻辑;只保证日志目录读写属主一致,未改变 `drop: ["All"]`/`allowPrivilegeEscalation:false` 等其余约束。

### 后续发展方向 [AI]
- infer-operator(推理实例编排)本期延续"状态更新路径的 nil 防御"主线——连续两日修 `Replicas` 解引用 panic,触发源都是**副本字段可被下发端省略/删除**而控制器某些路径默认其非空。方向上昇腾在把 InstanceSet 的 replicas 语义从"必填"向"可缺省+defaulting 兜底"迁移,但目前是逐函数打补丁而非在准入/defaulting 层统一兜底;证据只覆盖 `getNewStatus` 与(昨日的)快照 `TrackInstanceSet` 两处,未见是否有统一的 webhook defaulting。
- 日志目录属主加固属安全合规基线收口(与本期另一条「修改资料安全合规内容」文档提交同期),非能力演进。
- openFuyao 侧(npu-operator / vNPU / npu-container-toolkit / npu-driver-installer 等)连续多日零提交,驱动容器化与 NPU 虚拟化方向本期无增量信号可读。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(保锚点)</summary>

- npu-operator:无新提交
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- vNPU:无新提交
- npu-node-provision:无新提交
- npu-dra-plugin:无新提交
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=28399af5e4b11af64be2a49406da1ffde8e99863 tag=v26.1.1 scanned=2026-10-16 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.6.0 scanned=2026-10-16 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.6.0 scanned=2026-10-16 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-16 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-16 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-16 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-10-16 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-16 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=1.0.2 scanned=2026-10-16 -->
</content>
</invoke>

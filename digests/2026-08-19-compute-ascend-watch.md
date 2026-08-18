# 昇腾算力栈 diff 雷达 2026-08-19

## 摘要
- **昇腾容器运行时新增 CRI-O 支持**:ascend-docker-runtime 安装/卸载脚本 + `crio_process.go` 打通 `--install-scene=crio`,把 Ascend runtime 注入 `/etc/crio/crio.conf.d/99-ascend-runtime.conf`,并给 CRI-O runtime 写入 `monitor_env` PATH——补齐 docker/containerd/isula 之外的第四种运行时。
- **clusterd 对"软共享设备(Chip1SoftShareDev)"抑制作业汇总 ConfigMap 写入**:软切分场景下的 pod/podGroup 不再触发 job summary CM 的增删,降低高并发建 pod 时的无效 CM churn。
- ascend-for-volcano 适配 volcano 1.15;openFuyao 全部 8 仓无新提交。

## 当日重要改变
- mind-cluster [新能力] ascend-docker-runtime 增加 CRI-O 安装场景(`--install-scene=crio`),运行时配置落到 `crio.conf.d/99-ascend-runtime.conf` 并注入 `monitor_env`。证据:`component/ascend-docker-runtime/install/process/crio_process.go`、`build/scripts/run_main.sh`。 https://gitcode.com/Ascend/mind-cluster/compare/0035c85eb1fc47667187aad4ef1dbfc1c5328cf0...ec460dc60d38bd07f71563ca3edef0b63762d44d
- mind-cluster [架构方向] ascend-for-volcano 适配 Volcano 1.15(新增 `component/ascend-for-volcano/build/volcano-v1.15.0.yaml`,type.go 放开 `AffinityConfig` 注解)。上游调度器版本抬档。

## mind-cluster: 0035c85e -> ec460dc6
- 比较: 0035c85e..ec460dc6 | tag: v26.1.0 | commits=18 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/0035c85eb1fc47667187aad4ef1dbfc1c5328cf0...ec460dc60d38bd07f71563ca3edef0b63762d44d

### AI 总结重点(源码 diff 为据)
- **ascend-docker-runtime 打通 CRI-O 运行时**:`run_main.sh` 新增 `CRIO_CONFIG_DIR=/etc/crio` 与 `--install-scene=crio` 分支,install() 里为 crio 建 `crio.conf.d/` 并把目标配置写到 `99-ascend-runtime.conf`;`uninstall.sh` 对应加 crio 恢复分支。这是把昇腾运行时从 docker/containerd/isula 扩到 CRI-O 的第四条落地路径。
  <details><summary>代码依据 component/ascend-docker-runtime/build/scripts/run_main.sh</summary>

  ```diff
  +CRIO_CONFIG_DIR=/etc/crio
  ...
  +            elif [[ "${INSTALL_SCENE}" == "crio" ]]; then
  +                echo "[INFO] install scene is 'crio'."
  +                [[ ! -d ${CRIO_CONFIG_DIR}/crio.conf.d ]] && mkdir -p -m 750 ${CRIO_CONFIG_DIR}/crio.conf.d
  +                SRC="${CRIO_CONFIG_DIR}/crio.conf.d/99-ascend-runtime.conf.${PPID}"
  +                DST="${CRIO_CONFIG_DIR}/crio.conf.d/99-ascend-runtime.conf"
  ...
  +            elif [ "$3" == "--install-scene=crio" ]; then
  +                INSTALL_SCENE=crio
  ```
  </details>
- **CRI-O runtime 表里注入 `monitor_env` PATH**:constant.go 新增 `monitorEnvKey="monitor_env"` 与固定 `pathEnvValue="PATH=/usr/local/sbin:...:/bin"`,`crio_process.go` 的 `addCriORuntime` 在设置 runtime_path 后额外写 `monitor_env`——让 CRI-O 拉起的 ascend runtime 能在受控 PATH 下找到监控/注入相关二进制(docker/containerd 场景走 daemon 环境,CRI-O 需显式给)。
  <details><summary>代码依据 component/ascend-docker-runtime/install/process/crio_process.go</summary>

  ```diff
   	tree.SetPath(crioRuntimePath(name, crioRuntimePathKey), path)
  +	monitorEnvPath := []string{pathEnvValue}
  +	tree.SetPath(crioRuntimePath(name, monitorEnvKey), monitorEnvPath)
   	tree.SetPath([]string{crioSectionKey, crioRuntimeSectionKey, crioDefaultRuntimeKey}, name)
  ```
  </details>
- **clusterd 软共享设备场景跳过作业汇总 ConfigMap 写入**:`GetJobKeyAndNameByPG` 重构为 `GetJobInfoByPG`(多返回 owner `Kind`);新增 `pod.CheckPodIsNotSoftShareDev`;`podGroupMessage`/`podMessage` 里,当 pod 注解 `SchedulePolicyAnnoKey == Chip1SoftShareDev`(单芯软切分)或 owner 为 Pod 且软共享时直接 return,不再 `uniqueQueue.Store`。对应"减少 pod 高并发创建下的无效 cm 创建和删除"——软切分设备本就共享一张卡,汇总 CM 无意义,过滤掉减少 informer 抖动。
  <details><summary>代码依据 component/clusterd/pkg/application/jobv2/queue.go</summary>

  ```diff
  +	key, _, kind := podgroup.GetJobInfoByPG(newPGInfo)
  +	if key == "" { ...; return }
  +	if kind == PodOwnerKind {
  +		if !pod.CheckPodIsNotSoftShareDev(key) { ...; return }
  +	} else if newPGInfo.Annotations != nil &&
  +		newPGInfo.Annotations[api.SchedulePolicyAnnoKey] == api.Chip1SoftShareDev { ...; return }
  ...
  -	uniqueQueue.Store(pod.GetJobKeyByPod(newPodInfo), queueOperatorUpdate)
  +	if jobKey := pod.GetJobKeyByPod(newPodInfo); jobKey != "" {
  +		if newPodInfo.Annotations != nil && newPodInfo.Annotations[api.SchedulePolicyAnnoKey] == api.Chip1SoftShareDev { return }
  +		uniqueQueue.Store(jobKey, queueOperatorUpdate)
  +	}
  ```
  </details>
- **ascend-for-volcano 适配 Volcano 1.15 + 亲和性放开到 Pod**:新增内嵌 `volcano-v1.15.0.yaml`(19308 行,引入 volcano 1.15 部署清单);plugin/type.go 把 `util.AffinityConfig` 加进允许透传的注解键集合,配合"亲和性支持 Pod"——让裸 Pod(非 vcjob)也能带亲和配置进调度。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/type.go</summary>

  ```diff
   		util.InferServiceScheduleAnnoKey,
  +		util.AffinityConfig,
   	}
  ```
  </details>
- **npu-exporter PCIe 采集去噪**:`PcieCollector.IsSupported` 删掉一处 `logForUnSupportDevice` 调用(适配 atlas350/ubx PCIe 采集,不再对不支持设备刷日志)。纯日志清理,无采集逻辑变化。

### 后续发展方向 [AI]
- 运行时侧明确在补齐 **CRI-O 生态**(OpenShift/裸 K8s 默认 CRI 是 CRI-O),这是昇腾往非 docker 底座渗透的信号;`monitor_env` 的显式注入说明 CRI-O 下监控链路需单独适配,值得盯 crio_process.go 后续是否还要补 hook/CDI 注入路径。证据只覆盖安装脚本 + toml 注入,未见 CDI 模式下 crio 的设备注入实现。
- 调度侧"软共享(Chip1SoftShareDev)"作为一等公民在 clusterd 里被特殊处理,配合 ascend-for-volcano 亲和性放开到裸 Pod,方向是**单芯软切分 + Pod 级细粒度调度**。证据只覆盖 CM 写入抑制与注解键放开,未见软切分本身的算力/显存分配逻辑(在 vNPU/for-volcano plugin 内,本期未动)。

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin —— 均无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=ec460dc60d38bd07f71563ca3edef0b63762d44d tag=v26.1.0 scanned=2026-08-19 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-08-19 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-19 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-19 -->
<!-- ANCHOR repo=vNPU sha=f5869cd17c57b8392b97fc76a7879a1a9a1eb81f tag=v0.1.0 scanned=2026-08-19 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-19 -->
<!-- ANCHOR repo=npu-dra-plugin sha=90c70b32b9b368efc2cc26bda1209e4f275a804c tag=v26.6.0 scanned=2026-08-19 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-19 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-19 -->

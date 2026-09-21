# 昇腾算力栈 diff 雷达 2026-09-22

## 摘要
- **容器快照(container snapshot)成为本期主线**:`ascend-docker-runtime` 新增 `addDeviceForCntrSnap`,当业务面下发 `GRUS_SNAPSHOT_IMAGE_PATH` 时把 `/dev/lqdcmi_pcidev` 注入容器 OCI spec;`noded` 同步识别 `Dockerfile-container-snapshot` 标记。两组件联动,指向"容器级快照/热迁移"能力落地。
- **clusterops-agent 故障诊断从 workerN 命名切到 host_ip**:诊断产物目录与归档名由 `worker0/1…` 改为机器 IP(如 `51.38.66.67`),诊断报告直接可读到"哪台机",多机训练故障定位可用性提升。
- 其余为可靠性/精度修补:`faultdiag` 给 kernel.log 补 device_os.log 时间参照做时间精确化;`ascend-operator` 修 ranktable 版本文件路径校验用错变量的 bug;`container-manager` 补 4 个单测。8 个 openFuyao 仓全部无新提交。

## 当日重要改变
- **mind-cluster [新能力] 容器快照设备注入**:runtime 新增 `lqdcmi_pcidev` 设备常量 + `addDeviceForCntrSnap()`,按环境变量 `GRUS_SNAPSHOT_IMAGE_PATH` 门控注入。证据 `component/ascend-docker-runtime/runtime/process/process.go`、`component/noded/main.go`。https://gitcode.com/Ascend/mind-cluster/compare/40e3cbf93ee3e20c969537113f6d581359696498...b3fbd192b9a785c689d5c3857ffbed5eca756cb4
- **mind-cluster [可靠性修复] ranktable 路径校验用错变量**:`writeVersion` 里 `CheckPath(r.path)` 改为 `CheckPath(versionPath)`,原来校验的是目录而非要写的版本文件路径。证据 `component/ascend-operator/pkg/ranktable/common/common.go`。

## mind-cluster: 40e3cbf9 -> b3fbd192
- 比较: `40e3cbf9..b3fbd192` | tag: v26.1.1 | commits=34 | truncated=true(files=300,超出 GitCode 单次响应上限,以下按 `component/` 内可见 patch 研判,for-volcano 重调度等提交源码被截断未覆盖)
- 源链接:https://gitcode.com/Ascend/mind-cluster/compare/40e3cbf93ee3e20c969537113f6d581359696498...b3fbd192b9a785c689d5c3857ffbed5eca756cb4

### AI 总结重点(源码 diff 为据)

- **容器快照:运行时按需注入 `/dev/lqdcmi_pcidev`**。新增设备常量 `lqdcmi = "lqdcmi_pcidev"`;新增 `addDeviceForCntrSnap(spec)`,仅当容器 env 里存在 `GRUS_SNAPSHOT_IMAGE_PATH` 时才把 `devicePath+lqdcmi` 加进 spec(否则直接 return nil,不影响普通容器);并挂到主流程 `addDevice()` 末尾。这是"快照专用设备"的按需暴露,`lqdcmi`(疑为快照/热迁移用的轻量 dcmi PCI 设备)只在快照镜像场景才出现在容器里。
  <details><summary>代码依据 component/ascend-docker-runtime/runtime/process/process.go</summary>

  ```diff
  +	lqdcmi               = "lqdcmi_pcidev"
   )
  +func addDeviceForCntrSnap(spec *specs.Spec) error {
  +	if getValueByKey(spec.Process.Env, common.GRUS_SNAPSHOT_IMAGE_PATH) == "" {
  +		return nil
  +	}
  +	dPath := devicePath + lqdcmi
  +	if err := addDeviceToSpec(spec, dPath, dPath); err != nil {
  +		hwlog.RunLog.Errorf("add lqdcmi_pcidev to spec error: %v", err)
  +		return nil
  +	}
  +	return nil
  +}
  @@ addDevice
  +	if err := addDeviceForCntrSnap(spec); err != nil {
  +		return fmt.Errorf("failed to add device to spec for container snapshot: %v", err)
  +	}
  ```
  </details>

- **noded 启动期识别快照镜像标记**。新增常量 `containerSnapshotLabel = "/usr/local/Dockerfile-container-snapshot"`,`main()` 启动时若该文件存在则打日志 "dependent image build for container snapshot"。即 noded 镜像里会预置该 Dockerfile 作为"这是快照依赖镜像"的标识位,与 runtime 的快照设备注入配套,构成"noded 侧标记 + runtime 侧设备注入"的一整套容器快照路径。
  <details><summary>代码依据 component/noded/main.go</summary>

  ```diff
  +	containerSnapshotLabel = "/usr/local/Dockerfile-container-snapshot"
  @@ func main()
  +	if utils.IsExist(containerSnapshotLabel) {
  +		hwlog.RunLog.Info("dependent image build for container snapshot")
  +	}
  ```
  </details>

- **clusterops-agent 诊断产物按 host_ip 组织**。`upload.py` 的 `_result` 结构新增 `host_ip` 字段;上传归档从 `parse-result-{job}-{node}.tar.gz` 改为 `parse-result-{ns}-{job}-{host_ip}.tar.gz`(host_ip 为空时回落 node)。`tools.py` 的 `assemble_diag_input` 把抽取目录从 `worker{idx}` 重命名为机器 host_ip(如 `51.38.66.67`),陈旧目录清理条件也从"以 worker 开头且非 worker-"放宽到"任何非 worker- 目录"。效果:ascend-fd 诊断报告里 worker 名直接是机器 IP,多机训练里能一眼看出哪台机出故障,而非无语义的 worker0/1。
  <details><summary>代码依据 component/ascend-clusterops-agent/agent-core/tools.py</summary>

  ```diff
  -    Layout: {WORK_ROOT}/{YYYYMMDD}/{namespace}_{job}/diag-input/worker{idx}/
  +    Layout: {WORK_ROOT}/{YYYYMMDD}/{namespace}_{job}/diag-input/{worker_name}/
  +    (worker_name = the machine host_ip, e.g. 51.38.66.67 ... falls back to workerN)
  -    dst = diag_input / f"worker{worker_idx}"
  +    name = r.get("host_ip") or f"worker{worker_idx}"
  +    dst = diag_input / name
  ```
  </details>

- **faultdiag 给 kernel.log 做时间精确化**。`NpuHistoryLogParser` 新增 `time_reference_map` 与一组正则:用 device_os.log 里首条 `[ERROR] KERNEL(pid,组): <实际时间> [<开机时长>]` 行,建立"开机时长 T0 ↔ 实际墙钟 W0"参照,再据 kernel.log 行首的开机时长换算出真实时间。新增常量 `HIST_DEVICE_OS_PATH_ARRAY = ("log","slog","debug","device_os.log")` 定位参照文件。修的是"离线场景 kernel.log 只有相对开机时长、无法对齐墙钟时间"的问题。
  <details><summary>代码依据 component/ascend-faultdiag/.../parser/npu_device_parse.py</summary>

  ```diff
  +    _DEVICE_OS_REAL_TIME_PATTERN = re.compile(r"KERNEL\([^)]*\):\s*([^ ]+)")
  +    _DEVICE_OS_UPTIME_PATTERN = re.compile(r"\[(\d+\.\d+)\]")
  +    def __init__(self, params: dict):
  +        super().__init__(params)
  +        self.time_reference_map = {}
  ```
  </details>

- **ascend-operator ranktable 路径校验 bugfix**。`writeVersion()` 里把 `commonutils.CheckPath(r.path)` 改成 `CheckPath(versionPath)`——原先校验的是 `r.path`(目录)而非实际要写入的版本文件 `versionPath`,修正后校验对象与写入对象一致。对应提交"fix ranktable version文件的路径校验"。
  <details><summary>代码依据 component/ascend-operator/pkg/ranktable/common/common.go</summary>

  ```diff
  -		_, err = commonutils.CheckPath(r.path)
  +		_, err = commonutils.CheckPath(versionPath)
  ```
  </details>

- **container-manager 补单测(仅测试)**。新增 `containerd_test.go`/`docker_test.go`/`parse_test.go`/`workflow_test.go` 4 个测试文件(合计 ~900 行),无源码逻辑改动(本期 `container-manager` 下非测试 `.go` 改动数为 0)。对应"test(container-manager): 添加单测",是对容器管理层的测试兜底加固。

### 后续发展方向 [AI]
- **容器快照/热迁移是新增能力线**:runtime 的 `GRUS_SNAPSHOT_IMAGE_PATH` 门控 + `lqdcmi_pcidev` 专用设备 + noded 的快照镜像标记,三处配套指向昇腾要做"容器级快照"(可能服务于训练断点续训/故障快速恢复或任务热迁移)。证据只覆盖"设备注入 + 启动标记"两端,快照的创建/恢复主逻辑(Grus 侧)未在本仓可见 patch 内,方向确定但闭环未见。
- **故障诊断持续向多机可读性打磨**:host_ip 命名是继此前"multi-worker dump 契约"之后又一步,诊断产物正从"能跑"走向"运维可直接消费"。属工程打磨,非架构变化。
- **for-volcano 本期仅打包**:可见改动只有 `build.sh` 与 volcano-v1.9.0/v1.12.0 的 v26.2.0 Dockerfile 新增;提交里的"volcano 1.15/1.12 重调度故障修复"源码因 truncated 被截断,未覆盖,需下期小区间复扫确认。

## 本期无实质改动(折叠)
<details><summary>无新提交的 repo</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:8 仓均无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=b3fbd192b9a785c689d5c3857ffbed5eca756cb4 tag=v26.1.1 scanned=2026-09-22 -->
<!-- ANCHOR repo=npu-operator sha=802e269728d3528e7864b4d8c04a915c12d1169b tag=v26.6.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=npu-dra-plugin sha=5d7339c517d971eaeb0b915bd19ed3d90db3c44c tag=v26.6.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-22 -->
</content>
</invoke>

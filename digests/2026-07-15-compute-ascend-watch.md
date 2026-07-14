# 昇腾算力栈 diff 雷达 2026-07-15

## 摘要
- 三个 openFuyao 仓有实质代码改动,主线是 **把写死的宿主机路径/选择器参数化**:vNPU 把驱动目录 `/usr/local/Ascend` 和 `npu-smi` 路径改成可配置(适配 immutable OS,驱动不再固定落在 `/usr/local`),npu-operator 移除硬编码 `nodeSelector: masterselector=dls-master-node` 让 operator 可调度到任意节点。这延续了 07-15 hami-watch 里"昇腾 npu-smi 定位/补挂路径"同一主题——整个昇腾生态正在拆掉对固定驱动布局的假设。
- npu-driver-installer 加了一条 `unzip` 存在性预检,属健壮性小修。
- mind-cluster 区间 10 提交但 `component/` 过滤后零信号文件(全是 docs/BMC 故障码用例/docker 镜像说明);其余 5 个 openFuyao 仓无新提交。

## 当日重要改变
- vNPU [新能力/OS 适配] 支持 immutable OS:驱动目录与 npu-smi 路径由 values.yaml 参数化(`npu.driverHostPath` / `npu.npuSmiHostPath`),device-plugin daemonset 不再写死 `/usr/local/Ascend`;并从 client-update daemonset 移除多余的 `ascend` hostPath 挂载。https://gitcode.com/openFuyao/vNPU/commit/2198069bc1f294730a18b6d2c3bc44985f8031b9
- npu-operator [部署/调度] 移除硬编码 `nodeSelector: masterselector=dls-master-node`,operator Pod 不再被钉在 dls-master-node,改由外部值控制。https://gitcode.com/openFuyao/npu-operator/commit/53299373d36e46a82415a093cde55e7df240d7f7

## npu-operator: 335bc283 -> 53299373
- 比较: https://gitcode.com/openFuyao/npu-operator/compare/335bc283068ac89cf190d7e8c1d7d87d2b300cbb...53299373d36e46a82415a093cde55e7df240d7f7 | tag: v26.6.0 | commits=2

### AI 总结重点(源码 diff 为据)
- Helm 模板 `charts/npu-operator/templates/operator.yaml` 删除了写死的 `nodeSelector.masterselector: dls-master-node`。此前 operator Deployment 被强制调度到打了 `masterselector=dls-master-node` 标签的节点(DLS 主节点),删除后调度不再受该硬约束,可由集群实际拓扑或后续 values 覆盖决定落点。MR 标题称"make nodeSelector configurable",但本 patch 只见"移除硬编码"这一步,未见新增可覆盖的 `.Values.operator.nodeSelector` 渲染块(hunk 未覆盖到,可能在同文件他处或后续提交)。
  <details><summary>代码依据 charts/npu-operator/templates/operator.yaml</summary>

  ```diff
        hostPID: true
        hostNetwork: true
  -      nodeSelector:
  -        masterselector: dls-master-node
        serviceAccountName: npu-operator
  ```
  </details>

### 后续发展方向 [AI]
- 从"解绑 dls-master-node"看,npu-operator 正在脱离早期 DLS(深度学习服务)一体化部署的隐式假设,向"可部署到任意 K8s 集群"演进。证据只覆盖到 nodeSelector 移除这一处,是否补上真正的 values 化开关未在本区间 diff 中见到,需下期跟踪 chart values。

## vNPU: 34f7965b -> 2198069b
- 比较: https://gitcode.com/openFuyao/vNPU/compare/34f7965bb9e94b031b7afb2329fe3ff611e8c303...2198069bc1f294730a18b6d2c3bc44985f8031b9 | tag: v0.1.0 | commits=2

### AI 总结重点(源码 diff 为据)
- `charts/vnpu/values.yaml` 新增两个可配置项 `npu.driverHostPath: /usr/local/Ascend`、`npu.npuSmiHostPath: /usr/local/bin/npu-smi`,把原先散在各 daemonset 里写死的宿主机路径提到 values 顶层。device-plugin daemonset 的 `ascend` 卷与 `npu-smi` 卷路径改为引用 `{{ .Values.npu.driverHostPath }}` / `{{ .Values.npu.npuSmiHostPath }}`。目的是适配 immutable OS——驱动/工具不再假定固定落在 `/usr/local`,运维可指到只读根之外的真实安装位置。
  <details><summary>代码依据 charts/vnpu/values.yaml + npu-device-plugin-daemonset.yaml</summary>

  ```diff
  # values.yaml
   npu:
     nodeSelector:
       huawei.com/vnpu: ready
  +  driverHostPath: /usr/local/Ascend
  +  npuSmiHostPath: /usr/local/bin/npu-smi

  # npu-device-plugin-daemonset.yaml
        - name: ascend
          hostPath:
  -          path: /usr/local/Ascend
  +          path: {{ .Values.npu.driverHostPath }}
        - name: npu-smi
          hostPath:
            type: File
  -          path: /usr/local/bin/npu-smi
  +          path: {{ .Values.npu.npuSmiHostPath }}
  ```
  </details>
- `charts/vnpu/templates/npu-client-update-daemonset.yaml` 移除了 `ascend`(`/usr/local/Ascend`)hostPath 挂载,client-update 容器仅保留 `/opt/xpu`。说明 npu-client 更新流程不再需要直接触碰驱动目录,减少了对宿主机布局的耦合面。
  <details><summary>代码依据 charts/vnpu/templates/npu-client-update-daemonset.yaml</summary>

  ```diff
          volumeMounts:
          - name: opt-xpu
            mountPath: /opt/xpu
  -        - name: ascend
  -          mountPath: /usr/local/Ascend
        volumes:
          - name: opt-xpu
            hostPath:
              path: /opt/xpu
  -        - name: ascend
  -          hostPath:
  -            path: /usr/local/Ascend
  ```
  </details>

### 后续发展方向 [AI]
- vNPU 正在把"驱动/工具的宿主机落点"从代码常量升级为部署期参数,这是接入 immutable OS(如 openEuler/边缘只读根)和多样化底座的前置条件,和 hami-watch 侧"昇腾 npu-smi 定位"是同一波适配。证据只覆盖 chart 层路径参数化,未见 vNPU 切分内核(vCANN/算力配额)逻辑改动,虚拟化能力边界本期无变化。

## npu-driver-installer: 9f400f3c -> c898c929
- 比较: https://gitcode.com/openFuyao/npu-driver-installer/compare/9f400f3c1a514f003d684f003da08176fd4ba156...c898c929187bba8051e2ebed87f609bc820ead68 | tag: v26.6.0 | commits=2

### AI 总结重点(源码 diff 为据)
- `npu-driver-operate.sh` 的 `fetch_package()` 在解压前新增 `unzip` 命令存在性检查,缺失时以 `fatal_log` 明确报错并提示手动安装,避免驱动包提取阶段因环境缺 unzip 而报晦涩错误。纯健壮性防御,无功能面变化。
  <details><summary>代码依据 npu-driver-operate.sh</summary>

  ```diff
       mkdir -p "$INSTALL_WORK_DIR"

  +    if ! command -v unzip &> /dev/null; then
  +        fatal_log "unzip command not found. Please install unzip manually or check the system repository."
  +    fi
  +
       if [ "$MODE" != "online" ]; then
  ```
  </details>

### 后续发展方向 [AI]
- 容器化驱动安装脚本在补齐前置依赖自检,反映 npu-driver-installer 逐步硬化以覆盖更杂的宿主机环境(离线/最小化镜像)。仅一处小修,无方向性信号。

## 本期无实质改动(折叠)
<details><summary>mind-cluster 仅 docs/BMC/docker、5 个 openFuyao 仓无新提交</summary>

- mind-cluster(cf01efb1..2ff98492,10 提交但 component/ 过滤后零信号文件:容器快照资料移动、BMC 故障码/光模块诊断用例、docker 镜像概述更新、docs 修订;昇腾组件源码零改动,锚点推进至 2ff98492)
- npu-container-toolkit(d54256e0,无新提交)
- npu-node-provision(717ef777,无新提交)
- npu-dra-plugin(98f8fa5e,无新提交)
- volcano-ext(c9be5c4c,无新提交)
- ub-network-device-plugin(263d6387,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=2ff984926465fdb8f439f09bb3f32ec720382f6e tag=v26.1.0.beta.2 scanned=2026-07-15 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-07-15 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-15 -->
<!-- ANCHOR repo=npu-driver-installer sha=c898c929187bba8051e2ebed87f609bc820ead68 tag=v26.6.0 scanned=2026-07-15 -->
<!-- ANCHOR repo=vNPU sha=2198069bc1f294730a18b6d2c3bc44985f8031b9 tag=v0.1.0 scanned=2026-07-15 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-15 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-15 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-15 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-15 -->

# 昇腾算力栈 diff 雷达 2026-08-02

## 摘要
- 仅 `npu-dra-plugin` 一处改动:把 DRA vNPU 切分配置从 values.yaml 里一坨不透明的 `draConfig` 多行字符串,重构成结构化、可被 Helm 分别取值/覆盖的 `softShareMounts`(挂载列表)+ `nodes`(按 k8s 节点名索引的切分表)两个字段,configmap 模板改用 `toYaml`/`range` 渲染。同时把默认镜像仓 `swr_addr` 从占位 `localhost` 改成真实的 `cr.openfuyao.cn/openfuyao`。
- 其余 8 仓(mind-cluster / npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin)均无新提交。

## 当日重要改变
- npu-dra-plugin [架构方向] DRA 切分配置由整块字符串改为结构化 values,节点切分表从内嵌 `draConfig` 提升为独立的 `nodes` map,并可被 Helm 逐节点覆盖;配套默认镜像仓落地 cr.openfuyao.cn。证据:charts/npu-dra-driver/values.yaml + templates/configmap.yaml,提交 https://gitcode.com/openFuyao/npu-dra-plugin/commit/ec9d2c2742e8c09f732ffa9b3d8dcede648f4009

## npu-dra-plugin: 77ab67d1 -> b6d9bffb
- 比较: 77ab67d12eec260d2eb208409e80c0b62cc1ec70..b6d9bffb | tag: v26.6.0 | commits=2 | truncated=false
- 提交:https://gitcode.com/openFuyao/npu-dra-plugin/commit/ec9d2c2742e8c09f732ffa9b3d8dcede648f4009

### AI 总结重点(源码 diff 为据)
- **DRA profile 配置从"单值不透明字符串"改成"结构化多字段"**。改前 values.yaml 里 `npuDraPlugin.draConfig` 是一整段 YAML 文本(用 `|` 块标量塞进去 softShareMounts + nodes),Helm 只能整块替换、无法单独覆盖某一节点或某一挂载项;改后拆成两个平级字段 `softShareMounts`(列表)和 `nodes`(map),各自成为可独立 `--set`/覆盖的 values 键。这让"按节点定制切分策略"从"重写整段字符串"降级为"改一个 map 条目",是配置面板/GitOps 友好化的重构。
  <details><summary>代码依据 charts/npu-dra-driver/values.yaml</summary>

  ```diff
  -  # DRA profile 配置 (dra.config 内容)
  -  draConfig: |
  -    softShareMounts:
  -    - hostPath: /opt/xpu/lib/libboundscheck.so
  -      containerPath: /lib/libboundscheck.so
  -      options: [rw, rbind]
  -    ...
  -    nodes:
  -      n1:
  -        - physicalId: 0
  -          vnpuMode: full
  +  # DRA profile 配置
  +  # 软切分挂载项
  +  softShareMounts:
  +  - hostPath: /opt/xpu/lib/libboundscheck.so
  +    containerPath: /lib/libboundscheck.so
  +    options: [rw, rbind]
  +  ...
  +  # 节点 NPU 切分配置, key 为 k8s 节点名
  +  nodes:
  +    k8s-master:
  +    - physicalId: 0
  +      vnpuMode: full
  ```
  </details>
- **configmap 模板从"直接 indent 整块字符串"改成"遍历结构化 values 拼 dra.config"**。改前模板只是把 `.Values.npuDraPlugin.draConfig` 原样 `indent 4` 贴进 configmap;改后用 `toYaml`+`nindent` 渲染 softShareMounts,并用 `range $nodeName, $configs := .Values.npuDraPlugin.nodes` 逐节点展开 nodes——最终产出的 `dra.config` 内容形态不变,但来源从"用户手写字符串"变成"模板从结构化 values 组装",消除了字符串缩进易错点。
  <details><summary>代码依据 charts/npu-dra-driver/templates/configmap.yaml</summary>

  ```diff
   data:
     dra.config: |
  -{{ .Values.npuDraPlugin.draConfig | indent 4 }}
  +    softShareMounts:
  +{{- with .Values.npuDraPlugin.softShareMounts }}
  +{{- toYaml . | nindent 4 }}
  +{{- end }}
  +    nodes:
  +{{- range $nodeName, $configs := .Values.npuDraPlugin.nodes }}
  +      {{ $nodeName }}:
  +{{- toYaml $configs | nindent 8 }}
  +{{- end }}
  ```
  </details>
- **默认镜像仓从占位符改成真实地址**。`basic.swr_addr` 从 `localhost` 改为 `cr.openfuyao.cn/openfuyao`,说明 openFuyao 侧已有对外镜像源,chart 开箱即可拉到 npu-dra-driver 镜像,不再要求用户先自建 registry。示例节点 key 也从抽象的 `n1` 改成 `k8s-master`,贴近真实集群命名。
  <details><summary>代码依据 charts/npu-dra-driver/values.yaml</summary>

  ```diff
   basic:
  -  swr_addr: "localhost"
  +  swr_addr: "cr.openfuyao.cn/openfuyao"
     namespace: npu-dra-driver
  ```
  </details>

### 后续发展方向 [AI]
- 这是昨天(2026-08-01)刚落地的昇腾 DRA vNPU 软/硬切分栈的**紧跟收尾重构**,方向是让"按节点按卡的 full/soft/hard 三态切分"配置从"字符串黑盒"走向"可声明式管理"——下一步大概率是把 `nodes` map 进一步接到 CRD 或 operator 自动填充,而非停留在 Helm values 手填。证据只覆盖 chart(values + configmap 模板)两文件,未见 Go 侧解析 dra.config 的代码有对应改动,故"三态语义(full/soft/hard + schedulingPolicy: elastic)"本身是否变化无 diff 依据、判定不变。
- 默认镜像仓落地对外地址 = openFuyao 该组件从"内部自测"迈向"可被外部按文档直接部署"的信号;可留意后续是否补 CI 推镜像/版本 tag 对齐 v26.6.0。

## 本期无实质改动(折叠)
- mind-cluster / npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin:均无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=68cce2d667052820b17381aa9ad6751e3c459df1 tag=v26.1.0 scanned=2026-08-02 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-08-02 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-02 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-02 -->
<!-- ANCHOR repo=vNPU sha=5366f8e44a2f114584ed0f0099a25cf487aa63b7 tag=v0.1.0 scanned=2026-08-02 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-02 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b6d9bffb26ce91cef9e7ceb70736f7eddbfa6a58 tag=v26.6.0 scanned=2026-08-02 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-02 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-02 -->

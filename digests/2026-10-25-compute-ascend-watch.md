# 昇腾算力栈 diff 雷达 2026-10-25

## 摘要
- 本期**无任何生产代码改动**。唯一有新提交的仓是 `Ascend/mind-cluster`(eb251a57 → c144488f,2 次提交:1 merge + 1 文档),改动仅 1 个文件:DRA 最佳实践中文文档 `docs/zh/scheduling/.../ascend_dynamic_resource_allocation_best_practice/01_deploying_dra_and_running_task.md`(+3/-2)。device-plugin / docker-runtime / for-volcano / operator / npu-exporter / noded / clusterd / infer-operator / DRA driver / common 这些核心算力组件的生产代码本期零改动。
- 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)相对上期(2026-10-24)锚点**全部无新提交**,HEAD SHA 逐一比对一致。
- 虽为文档单改,但内容本身是一个**上游 K8s DRA API 结构对齐**信号:昇腾把 ResourceClaimTemplate 示例里的 `deviceClassName`/`count` 从 `requests[]` 顶层下沉到新的 `exactly:` 子块(见下)。这是 K8s DRA GA 后 `DeviceRequest` 拆分为 `exactly`/`firstAvailable` 的 API 面,昇腾文档在跟进。证据只覆盖文档,未见对应 DRA driver 生产代码 hunk。

## 当日重要改变
- 无(本期无生产代码改动,无 API/CRD/架构级 diff 命中)。下述 DRA 文档对齐列为软信号,记在正文,不计入重要改变。

## mind-cluster: eb251a57 -> c144488f
- 比较: eb251a57b56bc12d38a729441295b697a944231d..c144488f | tag: v26.2.0 | commits=2 | truncated=false
- 源链接:https://gitcode.com/Ascend/mind-cluster/compare/eb251a57b56bc12d38a729441295b697a944231d...c144488fabc83fa79ca0e811df77a26c8c2d13b3

### AI 总结重点(源码 diff 为据)
- **[软信号] 昇腾 DRA 最佳实践文档把 ResourceClaim 的设备请求结构从"扁平 `deviceClassName`+`count`"改为嵌套 `exactly:` 子块**,即 `spec.devices.requests[].exactly.{deviceClassName, count}`。这对齐的是 K8s 1.33+ DRA 的 `DeviceRequest` API:请求被拆成 `exactly`(精确匹配一个 DeviceClass)与 `firstAvailable`(优先级备选列表)两种互斥形态,旧的顶层 `deviceClassName`/`count` 写法被收编进 `exactly`。`deviceClassName` 取值 `npu.huawei.com` 不变(由 `ascend-dra-driver.yaml` 部署时自动创建的 DeviceClass)。**仅文档改动,未见 DRA driver(`component/ascend-dynamic-resource-allocation`)生产代码随动 hunk**——需下期关注 driver 侧对新 request 结构的解析是否已落地。
  <details><summary>代码依据 docs/zh/scheduling/.../13_ascend_dynamic_resource_allocation_best_practice/01_deploying_dra_and_running_task.md</summary>

  ```diff
           devices:
             requests:
             - name: npu              # 请求名称,Pod中通过该名称引用
  -            deviceClassName: npu.huawei.com   # 引用DRA组件部署时创建的DeviceClass
  -            count: 1               # 请求的NPU数量,按需修改
  +            exactly:
  +              deviceClassName: npu.huawei.com # 引用DRA组件部署时创建的DeviceClass
  +              count: 1                        # 请求的NPU数量,按需修改
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾 DRA 文档跟进上游 `exactly`/`firstAvailable` 请求拆分,说明其 DRA 路径在向 K8s DRA GA(1.34)API 靠拢。证据只覆盖示例 YAML,无法判定 driver 是否已支持 `firstAvailable`(优先级备选)这一更有价值的新形态——这关系到"同一 ResourceClaim 里按优先级降级申请不同规格 NPU"的能力。对我们产品的启示:若对标 OAI 做 DRA 原生 NPU/GPU 申请,需同步适配 1.33+ 的 `exactly` 嵌套结构,旧的扁平写法在新版 kube-apiserver 上会被拒。下期重点盯 `component/ascend-dynamic-resource-allocation` 生产代码(参见 [[ascend-dra-pathprefix-gap]])。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓均无新提交;mind-cluster 核心组件生产代码零改动</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:compare base..HEAD 无新提交,HEAD SHA 与上期一致。
- mind-cluster 的 device-plugin / docker-runtime / for-volcano / operator / npu-exporter / noded / clusterd / infer-operator / DRA driver / common 本期生产代码零改动,仅 1 个 DRA 中文文档被改。

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=c144488fabc83fa79ca0e811df77a26c8c2d13b3 tag=v26.2.0 scanned=2026-10-25 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-10-25 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-10-25 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-10-25 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v26.9.0 scanned=2026-10-25 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-25 -->
<!-- ANCHOR repo=npu-dra-plugin sha=031dc691f082fdb90610f77eab3bcf91ad8e9aa3 tag=v26.9.0 scanned=2026-10-25 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-25 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=v26.9.0 scanned=2026-10-25 -->

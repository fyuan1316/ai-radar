# 昇腾算力栈 diff 雷达 2026-08-08

## 摘要
- 本期唯一实质代码信号在 **npu-dra-plugin**(昇腾接 K8s DRA):两处 fix——①把 vCANN-RT 安装器镜像地址从占位的 `docker.io/library/acl_client_update:1.0.0` 修正为真实仓库 `cr.openfuyao.cn/openfuyao/vnpu/acl-client-update:latest`,让 vCANN 运行时安装器能真正拉到镜像;②给 DRA 芯片能力表 `chipCapabilities` **补上 Ascend910C 的硬切分(vNPU)模板**(vir05_1c_16g / vir10_3c_32g),把 910C 纳入 DRA 侧可切分芯片。信号见 `charts/npu-dra-driver/values.yaml` + `manifests/deploy/01-configmap.yaml`。
- mind-cluster 区间有 2 提交但仅一条 docker 发布说明(镜像概述更新),限定 `component/` 后**无产品代码改动**,本期按无实质变化处理。
- 其余 7 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin)均无新提交。

## 当日重要改变
- npu-dra-plugin [能力扩展] DRA 芯片能力表新增 **Ascend910C 硬切分模板**:`chipCapabilities` 增加一条 `chipName: Ascend910C`(totalAiCore=20 / totalAiCpu=6 / totalMemoryMi=32768),带两档切分模板 `vir05_1c_16g`(5 core/1 cpu/16G)与 `vir10_3c_32g`(10 core/3 cpu/32G)。意味着昇腾 DRA 路径开始覆盖 910C 芯片的 vNPU 切分声明。证据:`Ascend-npu-dra-plugin/manifests/deploy/01-configmap.yaml`、`charts/npu-dra-driver/values.yaml`;提交 https://gitcode.com/openFuyao/npu-dra-plugin/commit/f844a86497b2
- npu-dra-plugin [部署修复] vCANN-RT 安装器镜像地址修正:`vcannrtInstaller.image` 从占位的 `docker.io/library` + `acl_client_update:1.0.0` 改为实际仓库 `cr.openfuyao.cn/openfuyao/vnpu` + `acl-client-update:latest`(注意 name 从下划线改连字符)。属让 DRA 驱动 chart 开箱能拉到 vCANN 运行时安装器的落地修复。证据:同上两个文件;提交 https://gitcode.com/openFuyao/npu-dra-plugin/commit/268d5fc08633

## npu-dra-plugin: ae80e4f1 -> c5cb370f
- 比较: `ae80e4f1..c5cb370f` | tag: v26.6.0 | commits=3 | truncated=false
- 3 提交去掉 PR 合流重复后即两件事:vCANN-RT 安装器镜像地址修正(!33)、chipCapabilities 补 910C 硬切分模板。

### AI 总结重点(源码 diff 为据)
- **910C 进入 DRA 切分能力表**:`values.yaml` 与运行期 `01-configmap.yaml` 同步在 `chipCapabilities` 尾部追加 Ascend910C 条目。此前该表只列了别的芯片(如 vir10_3c_16g 系列),这次显式声明 910C 整卡规格(20 AiCore / 6 AiCpu / 32768 Mi)及两档硬切分:`vir05_1c_16g`、`vir10_3c_32g`。configmap 是插件运行时读的实配,values 是 chart 入参,两处同改说明是"部署默认值 + 运行配置"一起落,能力可直接生效。

  <details><summary>代码依据 Ascend-npu-dra-plugin/manifests/deploy/01-configmap.yaml(values.yaml 同构)</summary>

  ```diff
       - chipName: Ascend910C
  +      totalAiCore: 20
  +      totalAiCpu: 6
  +      totalMemoryMi: 32768
  +      templates:
  +        - { name: vir05_1c_16g, aiCore: 5, aiCpu: 1, memoryMi: 16384 }
  +        - { name: vir10_3c_32g, aiCore: 10, aiCpu: 3, memoryMi: 32768 }
  ```
  </details>

- **vCANN-RT 安装器镜像改指真实 openFuyao 仓**:`vcannrtInstaller.image` 三个字段全改——`swr_addr` 由 `docker.io/library` 换成 `cr.openfuyao.cn/openfuyao/vnpu`,`name` 由 `acl_client_update` 换成连字符风格 `acl-client-update`,`version` 由固定 `1.0.0` 改成 `latest`。这是把此前占位/私搭的镜像坐标对齐到社区正式镜像仓,属可拉取性修复,非能力变更。

  <details><summary>代码依据 Ascend-npu-dra-plugin/charts/npu-dra-driver/values.yaml</summary>

  ```diff
   vcannrtInstaller:
     image:
  -    swr_addr: "docker.io/library"
  -    name: acl_client_update
  -    version: "1.0.0"
  +    swr_addr: "cr.openfuyao.cn/openfuyao/vnpu"
  +    name: acl-client-update
  +    version: "latest"
  ```
  </details>

### 后续发展方向 [AI]
- npu-dra-plugin 正沿着"**用 K8s DRA 声明昇腾 vNPU 切分**"这条线补芯片覆盖:先把 910C 的整卡规格与硬切分模板写进能力表,配合 vCANN-RT 安装器镜像落地,DRA 路径对 910C 的可用性在推进。证据仅覆盖能力表 + 镜像坐标两处 YAML,未见调度/分配逻辑代码改动,不能推断切分执行链路已完备——只是声明侧先就位。
- 对我们产品的启示:昇腾把 vNPU 切分同时压在 HAMi(vNPU 注解路径)与自家 DRA 插件(chipCapabilities 模板)两条线上,DRA 侧用"芯片能力表 + 命名模板(virXX_Yc_Zg)"表达切分规格,粒度是 AiCore/AiCpu/Memory 三元组。若我们做昇腾多租切分,可对标这套模板命名与 DRA DeviceClass 表达方式,评估走 DRA 还是走注解。`latest` tag 用于安装器镜像不利可复现,企业交付宜钉版本。

## 本期无实质改动(折叠)
<details><summary>mind-cluster(限定 component 后无产品代码改动)+ 7 个 openFuyao 仓无新提交</summary>

- mind-cluster — 区间 2 提交仅 docker 发布说明(26.1.0 镜像概述更新),`component/` 下无信号文件
- npu-operator — 无新提交
- npu-container-toolkit — 无新提交
- npu-driver-installer — 无新提交
- vNPU — 无新提交
- npu-node-provision — 无新提交
- volcano-ext — 无新提交
- ub-network-device-plugin — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=1aa04bb11642a630a16ba9ac88f392e4b3982e96 tag=v26.1.0 scanned=2026-08-08 -->
<!-- ANCHOR repo=npu-operator sha=7cddacb58841f285c6f719e2d7a5cb235be32cdb tag=v26.6.0 scanned=2026-08-08 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-08 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-08 -->
<!-- ANCHOR repo=vNPU sha=f5869cd17c57b8392b97fc76a7879a1a9a1eb81f tag=v0.1.0 scanned=2026-08-08 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-08 -->
<!-- ANCHOR repo=npu-dra-plugin sha=c5cb370fbc8d4201e352cadacefc5a2f82d15f39 tag=v26.6.0 scanned=2026-08-08 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-08 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-08 -->

# 昇腾算力栈 diff 雷达 2026-07-26

## 摘要
- 本期低信号:三仓有改动但均非能力级。**vNPU** 延续 07-24 的健壮性主题——把 device-plugin 里 `GetXPUUsage` 查芯片信息失败时的 `log.Fatalf`(会 `os.Exit` 拖垮整个进程)改成 `log.Errorf` + 返回 error,单芯片 DCMI 查询失败不再连累整插件。
- **mind-cluster** component 侧本窗口只动 Dockerfile:`shadow`→`shadow-utils` 包名修正(6+ 组件)、npu-exporter 310P-1usoc 把 `usermod root -s /usr/sbin/nologin` 收成 `/bin/false`(root 登录 shell 硬化)。无 Go 代码改动。
- **npu-container-toolkit** 仅把 ascend-docker-runtime 构建的 `ARG VERSION` 从 7.3.0 抬到 26.0.0(对齐 CANN 26.0.0 新版本号体系),非逻辑改动。
- 无 API/CRD/架构/弃用/版本跨档信号命中。

## 当日重要改变(命中信号才列;无则写"无")
- 无(本期改动均为构建/日志健壮性,未命中重要改变信号)

## vNPU: f37099fb -> 79931f49
- 比较 / 最新 Release:https://gitcode.com/openFuyao/vNPU/compare/f37099fbc69589fa5473a7b98d315cc66b30f45e...79931f49395007d6ede88492ea3bbd48bedb6758 | tag v0.1.0
### AI 总结重点(源码 diff 为据)
- `xpu-device-plugin/pkg/plugin/xpu/npu.go` 的 `GetXPUUsage()`:DCMI `DcGetChipInfo` 失败分支由 `log.Fatalf` 改 `log.Errorf`。原代码 Fatalf 触发 `os.Exit(1)`,其后的 `return ...err` 是死代码——任一芯片 DCMI 查询失败即整插件退出;改后仅记错并把 error 上抛给调用方,单芯片查询失败不再 crash 进程。这是 07-24"device-plugin 生命周期干净退出"的同类收敛。
  <details><summary>代码依据 xpu-device-plugin/pkg/plugin/xpu/npu.go</summary>

  ```diff
    chipInfo, err := dm.DcGetChipInfo(cardID, deviceID)
    if err != nil {
  -   log.Fatalf("dcmi DcGetChipInfo failed: %v, cardID: %v, deviceID: %v", err, cardID, deviceID)
  +   log.Errorf("dcmi DcGetChipInfo failed: %v, cardID: %v, deviceID: %v", err, cardID, deviceID)
      return types.DeviceUsageInfo{}, nil, err
    }
  ```
  </details>
### 后续发展方向 [AI]
- 证据只覆盖 `GetXPUUsage` 一处 Fatalf→Errorf,未见切分算法/vCANN 资源计算改动。方向仍是把 v0.1.0 的进程健壮性边界磨平(让 device-plugin 在部分芯片异常时降级而非整体退出),非新增切分能力。

## mind-cluster: c5ec0ca9 -> 8c6371e3
- 比较 / 最新 Release:https://gitcode.com/Ascend/mind-cluster/compare/c5ec0ca9f56c625b153ce6c5c2767c831c4e257b...8c6371e325e92989eed27d87d26f212ff3751051 | tag v26.1.0.beta.2 | commits=16
### AI 总结重点(源码 diff 为据)
- 本窗口 component/ 下的信号文件**全是 `.openeuler` Dockerfile**,无 Go 代码。两类改动:(1) 包名 `shadow`→`shadow-utils`——openEuler 24.03 里提供 useradd/usermod 的包名是 shadow-utils,原 `yum install shadow` 装的是密码库而非工具,构建期实际缺 usermod;覆盖 npu-exporter/noded/clusterd/infer-operator/ascend-operator/ascend-device-plugin。(2) npu-exporter 310P-1usoc 镜像把 root 登录 shell 从 `/usr/sbin/nologin` 换 `/bin/false`(更彻底禁止 root 交互登录)。
  <details><summary>代码依据 component/npu-exporter/build/Dockerfile-310P-1usoc.openeuler</summary>

  ```diff
  - yum install -y shadow && \
  + yum install -y shadow-utils && \
    ...
  - usermod root -s /usr/sbin/nologin
  + usermod root -s /bin/false
  ```
  </details>
### 后续发展方向 [AI]
- 证据仅覆盖 Dockerfile 构建与镜像用户硬化,commit 区间另有 presmoke bugfix 与 docs 改动但均不落在 component 代码路径。方向是 x86 openEuler+UMDK 镜像构建链路修复,非组件行为变化;下期若 component Go 代码恢复改动再转深度研判。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 仅构建版本号仓(仅锚点)</summary>

- npu-container-toolkit | 仅 ascend-docker-runtime.dockerfile 的 `ARG VERSION` 7.3.0→26.0.0(对齐 CANN 26.0.0),无逻辑改动
- npu-operator | 无新提交
- npu-driver-installer | 无新提交
- npu-node-provision | 无新提交
- npu-dra-plugin | 无新提交
- volcano-ext | 无新提交
- ub-network-device-plugin | 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=8c6371e325e92989eed27d87d26f212ff3751051 tag=v26.1.0.beta.2 scanned=2026-07-26 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-07-26 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-07-26 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-07-26 -->
<!-- ANCHOR repo=vNPU sha=79931f49395007d6ede88492ea3bbd48bedb6758 tag=v0.1.0 scanned=2026-07-26 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-26 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-26 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-26 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-26 -->

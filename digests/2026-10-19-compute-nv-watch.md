# NVIDIA 算力栈 diff 雷达 2026-10-19

## 摘要
- 本期唯一实质改动落在 **L4 调度 KAI-Scheduler**,且全是 **fix 类**:给 GPU-sharing ConfigMap 的写入补了 nil-map 初始化守卫(修 panic)、给 `kai-config-deployer` hook 补了 OpenShift SCC 授权、修 scale-test 环境里 binder/pod-grouper 的资源与限流参数。无 API/CRD、无弃用、无版本跨档。
- 其余 8 个源仓本期全无新提交(gpu-operator / nvidia-container-toolkit / gpu-driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted),锚点原样续链。
- 当日无重要改变信号命中(KAI 三条均为 bugfix,不触发弃用/API-CRD/架构/版本/新能力)。

## 当日重要改变
- 无命中弃用/API-CRD/架构方向/版本跨档/新能力信号。

## kai-scheduler/KAI-Scheduler: e496b753 -> e9b83d67
- 比较: e496b7539d40d3c8428ce56d967933de4a9a0a05 -> e9b83d67 | ahead=3 | files=6 | Release: v0.16.12

### AI 总结重点(源码 diff 为据)
- **GPU-sharing ConfigMap 写入补 nil-map 守卫(修潜在 panic)**:`pkg/binder/common/gpusharingconfigmap/config_map.go` 的 `patchConfigMap` 在把 `desiredConfigMap.Data` 的非空值逐条写回 `updatedConfigMap.Data` 前,新增 `if updatedConfigMap.Data == nil { updatedConfigMap.Data = map[string]string{} }`。此前若既有 ConfigMap 的 `Data` 字段为 nil(如从未设过数据),对 nil map 赋值会直接 panic。这是 GPU 分片(GPU sharing)配置下发链路的健壮性修复,不改配置语义——空值仍被 `len(v) != 0` 过滤掉,只保证目标 map 可写。配套测试 `config_map_test.go` 新增 `TestUpsertConfigMapSameOwner`,覆盖 nil data / 空值序列化省略 / 合并保留既有键 / nil desired 保留既有 等 case。
  <details><summary>代码依据 pkg/binder/common/gpusharingconfigmap/config_map.go</summary>

  ```diff
       updatedConfigMap := existingConfigMap.DeepCopy()
       for k, v := range desiredConfigMap.Data {
           if len(v) != 0 {
  +            if updatedConfigMap.Data == nil {
  +                updatedConfigMap.Data = map[string]string{}
  +            }
               updatedConfigMap.Data[k] = v
           }
       }
  ```
  </details>
- **`kai-config-deployer` hook 获得 OpenShift SCC 授权**:`deployments/kai-scheduler/templates/rbac/scc.yaml` 在 SCC 的 `users` 和 `subjects` 两处都把 `kai-config-deployer` ServiceAccount 加进来,使这个 config-deployer hook job 能在 OpenShift 的 SecurityContextConstraints 约束下运行。这是部署面对 OpenShift 的兼容性补齐(对标 OAI 场景下 KAI 的可落地性),不动调度逻辑。
  <details><summary>代码依据 deployments/kai-scheduler/templates/rbac/scc.yaml</summary>

  ```diff
   users:
   - system:serviceaccount:{{ .Release.Namespace }}:kai-topology-migration
  +- system:serviceaccount:{{ .Release.Namespace }}:kai-config-deployer
   ...
   subjects:
  +  - kind: ServiceAccount
  +    name: kai-config-deployer
  +    namespace: {{ .Release.Namespace }}
  ```
  </details>
- **scale-test 环境脚本修限流/内存参数**:`hack/setup-scale-test-env.sh` 把 binder 的 `qps`/`burst` 从顶层 `args` 挪进 `k8sClientConfig`(`{"k8sClientConfig":{"qps":500,"burst":2000}}`),并把 pod-grouper 的 memory requests/limits 从 2Gi 上调到 8Gi。这是测试基建修正,透露出 **binder 限流配置的权威入口已统一到 `k8sClientConfig`**(与 pod-grouper 一致),顶层 args 形态被废弃;仅影响 scale-test,不改线上默认值。
  <details><summary>代码依据 hack/setup-scale-test-env.sh</summary>

  ```diff
  -...{"binder":{...,"args":{"maxConcurrentReconciles": 100, "qps": 500, "burst": 2000}}}...
  +...{"binder":{"service":{...},"k8sClientConfig":{"qps":500,"burst":2000}}}...
  -...{"podGrouper":{"service":{"requests":{..."memory":"2Gi"},"limits":{..."memory":"2Gi"}}}...
  +...{"podGrouper":{"service":{"requests":{..."memory":"8Gi"},"limits":{..."memory":"8Gi"}}}...
  ```
  </details>
- 探测器确认本期「无 API/CRD 路径命中」,CRD/调度核心逻辑未动。

### 后续发展方向 [AI]
- 可读到的方向信号是 **KAI 的配置面在收敛客户端限流参数的位置**:binder 的 qps/burst 从散落的顶层 `args` 迁入结构化的 `k8sClientConfig`,与 pod-grouper 的既有形态对齐,暗示后续各组件(scheduler/queue-controller 等)的 k8s client 调参会统一走 `k8sClientConfig` 块。但证据**仅来自 scale-test 脚本**,未见 config CRD schema 或 binder 启动参数解析代码的对应改动,无法确认顶层 `args.qps/burst` 是否已在代码侧判废。另外两条(ConfigMap nil 守卫、OpenShift SCC)是健壮性/兼容性修复,不指示能力演进。GPU 分片(GPU-sharing ConfigMap)这条链路本期只加固不改语义,软切分/DRA 主线无进展。来源:https://github.com/kai-scheduler/KAI-Scheduler/pull/2408  https://github.com/kai-scheduler/KAI-Scheduler/pull/2441  https://github.com/kai-scheduler/KAI-Scheduler/pull/2424

## 本期无实质改动(折叠)
<details><summary>下列 repo 本期仅 bump/CI/merge 或无新提交,未单列正文</summary>

- NVIDIA/gpu-operator:无新提交。
- NVIDIA/nvidia-container-toolkit:无新提交。
- NVIDIA/gpu-driver-container:无新提交。
- NVIDIA/k8s-device-plugin:无新提交。
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交。
- NVIDIA/dcgm-exporter:无新提交。
- NVIDIA/DCGM:无新提交(master 分支)。
- NVIDIA/mig-parted:无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=dbb11e85129b601afe9fb502ac25b062ad094abd branch=main release=v26.7.2 scanned=2026-10-19 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3e112b4af299bf72a1b23193b4f5c3321475dd6d branch=main release=v1.20.1 scanned=2026-10-19 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d6d82abedb448b8f67992f1b59c86f163df24772 branch=main release=— scanned=2026-10-19 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1053da35d5a67fdbc3f0ea0877b7178026048769 branch=main release=v0.20.1 scanned=2026-10-19 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=63e98d305bb66cb9f2a07a0669661329d320ee3f branch=main release=v0.5.1 scanned=2026-10-19 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-19 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-19 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-19 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=e9b83d67c15b1d52c8e9a70d02d46aae9bdac709 branch=main release=v0.16.12 scanned=2026-10-19 -->

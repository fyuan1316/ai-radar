# NVIDIA 算力栈 diff 雷达 2026-10-01

## 摘要
- 仅 KAI-Scheduler 有实质改动,且集中在 podgrouper/Karta 分组路径:一是把 podgrouper 的启动参数从 Helm 硬编码单值改成可透传任意参数的 map,二是修 Karta 无 gang 指令时应回退到默认分组的 bug。
- L1 驱动容器化(gpu-operator/container-toolkit/driver-container)、L2 device-plugin/DRA、L3 监控/拓扑(dcgm/DCGM/mig-parted)本日全部无实质改动。
- 无 API/CRD 字段增删,无弃用/移除信号。

## 当日重要改变
- KAI-Scheduler [新能力] Helm chart 的 podgrouper args 从只支持写死 `genericKartaFallback` 一个值,改为透传整张 `podgrouper.args` map(可下发 `gangScheduleDeployment`/`gangScheduleKnative` 等),配置面收敛到统一入口 https://github.com/kai-scheduler/KAI-Scheduler/pull/2269

## kai-scheduler/KAI-Scheduler: 45cadab0 -> a6941e62
- 比较: 45cadab0443fe1a3ea9032968ca7208c36d97897 -> a6941e62 | ahead=2 | files=7 | Release: v0.18.1
- https://github.com/kai-scheduler/KAI-Scheduler/compare/45cadab0443fe1a3ea9032968ca7208c36d97897...a6941e624a0956117d89abe50880ad36f65b2f66

### AI 总结重点(源码 diff 为据)
- **podgrouper 参数透传:Helm 模板从"只渲染一个固定 key"改为"合并整张 args map + 兼容旧扁平字段"**。`_helpers.tpl` 原来只把 `genericKartaFallback` 一个值塞进容器 args;现在先把 `.Values.podgrouper.args` 整个 map 拷进 `$pgArgs`,再把旧的扁平 `podgrouper.genericKartaFallback`(若存在)覆盖进去,最后 `toYaml` 整体下发。效果是任意 podgrouper 参数(如下面测试里的 `gangScheduleDeployment`、`gangScheduleKnative`)都能经 values 透传,旧写法保持兼容。
  <details><summary>代码依据 deployments/kai-scheduler/templates/_helpers.tpl</summary>

  ```diff
  +    {{- $pgArgs := dict }}
  +    {{- range $k, $v := (.Values.podgrouper.args | default dict) }}
  +    {{- $_ := set $pgArgs $k $v }}
  +    {{- end }}
  +    {{- if hasKey .Values.podgrouper "genericKartaFallback" }}
  +    {{- $_ := set $pgArgs "genericKartaFallback" .Values.podgrouper.genericKartaFallback }}
  +    {{- end }}
  +    {{- if $pgArgs }}
       args:
  -      genericKartaFallback: {{ .Values.podgrouper.genericKartaFallback }}
  +      {{- toYaml $pgArgs | nindent 6 }}
  +    {{- end }}
  ```
  </details>
  <details><summary>代码依据 deployments/kai-scheduler/values.yaml</summary>

  ```diff
  -  genericKartaFallback: true
  +  # Flat podgrouper.genericKartaFallback overrides this map.
  +  args:
  +    genericKartaFallback: true
  ```
  </details>

- **Karta 分组回退修复:`GetPodGrouperPlugin` 在拿到 grouper 为 nil 时显式返回 nil(触发默认分组),而非把 nil 当成有效 grouper 往下传**。原代码 `err == nil` 就直接 `return kartaGrouper`,当 Karta 资源缺少 gang scheduling 指令、`getKartaGrouperForGvk` 返回 `(nil, nil)` 时会把 nil grouper 交出去;新增 `if kartaGrouper == nil { return nil }` 后,调用方据此落到默认 grouper。测试断言 NIMService(`apps.nvidia.com/v1alpha1`)在 `GangScheduling=nil` 时选中 "Default Grouper",有 gang 指令时才选 "Karta Grouper"。
  <details><summary>代码依据 pkg/podgrouper/podgrouper/plugins/karta/hub.go</summary>

  ```diff
   	kartaGrouper, err := g.getKartaGrouperForGvk(context.Background(), gvk)
   	if err == nil {
  +		if kartaGrouper == nil {
  +			return nil
  +		}
   		return kartaGrouper
   	}
  ```
  </details>
  <details><summary>代码依据 pkg/podgrouper/podgrouper/hub/hub_test.go</summary>

  ```diff
  +		DescribeTable("NIMService Karta grouper selection", func(withGangScheduling bool, expectedName string) {
  +			gvk := metav1.GroupVersionKind{Group: "apps.nvidia.com", Version: "v1alpha1", Kind: "NIMService"}
  +			...
  +			Entry("without gang scheduling", false, "Default Grouper"),
  +			Entry("with gang scheduling", true, "Karta Grouper"),
  ```
  </details>

### 后续发展方向 [AI]
- 两处改动都指向同一件事:KAI 把 NIM(`apps.nvidia.com` NIMService)这类 NVIDIA 自家工作负载的 gang 调度接入做得更稳——只有真正声明了 gang 指令的 Karta 才走 gang 分组,否则退回默认,避免误判成 gang 导致 pod 卡住。args 透传则为后续继续加 podgrouper 开关(如按工作负载类型细分 gang 策略)铺了配置通道。证据只覆盖 hub.go 的回退分支与 Helm 模板,未见 Karta 资源本身的定义与 gangScheduleDeployment/Knative 的具体消费逻辑。
- 均属稳定性/配置面打磨,非架构方向转向;本日无 DRA、time-slicing/MPS、driver 容器化相关代码变更。

## 本期无实质改动(折叠)
<details>
- NVIDIA/gpu-operator(ahead=8,仅 bump/CI/merge)
- NVIDIA/nvidia-container-toolkit(无新提交)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(ahead=2,仅 bump/CI/merge)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=75210df15b7322f999a43448221612a0b83f5f3b branch=main release=v26.7.1 scanned=2026-10-01 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=84e2c2c182bfa0b2edab4fdca27e5197faba0ca7 branch=main release=v1.20.1 scanned=2026-10-01 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=73b03d850b0d2468a75341e5054315aee49f966d branch=main release=— scanned=2026-10-01 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=a6ddd0252a5b84f24dbff8e2f3e253e5dfb67fc7 branch=main release=v0.20.1 scanned=2026-10-01 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=495bf4c59b9423080aa1fe2163955f44a495012c branch=main release=v0.5.0 scanned=2026-10-01 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-01 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-01 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=a668e5c92da14856769edcb0fec27946abf8920c branch=main release=v0.15.1 scanned=2026-10-01 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=a6941e624a0956117d89abe50880ad36f65b2f66 branch=main release=v0.18.1 scanned=2026-10-01 -->

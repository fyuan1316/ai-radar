# 昇腾算力栈 diff 雷达 2026-09-19

## 摘要
- 本期唯一实质代码改动落在 mind-cluster 的 **clusterd 故障域(faultdomain)**:`IsUnRecoverInPlaceFaultLevels` 在判断"是否属于原地不可恢复故障"时,把 `PreSeparateNPU`(预隔离态)也从待判集合里剔除——即预隔离不再触发原地不可恢复分支,归为"另有处理路径/可原地恢复"。属故障分级判定的正确性修正,非新功能。
- 其余 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期全部无新提交。

## 当日重要改变
- mind-cluster [调度正确性] clusterd `IsUnRecoverInPlaceFaultLevels` 判定集合新增剔除 `constant.PreSeparateNPU`,使仅含预隔离态的故障不再被判为"原地不可恢复"。https://gitcode.com/Ascend/mind-cluster/compare/a8e1df68db7c990575c805b7ff7084c4b4496a7c...17c2878e4b47efeb699e7066c2910ab22abe4bf5

## mind-cluster: a8e1df68 -> 17c2878e
- 比较: a8e1df68..17c2878e | tag: v26.1.1 | commits=14 | truncated=false
- 源: https://gitcode.com/Ascend/mind-cluster/compare/a8e1df68db7c990575c805b7ff7084c4b4496a7c...17c2878e4b47efeb699e7066c2910ab22abe4bf5

### AI 总结重点(源码 diff 为据)

- **clusterd 故障域:预隔离态 `PreSeparateNPU` 从"原地不可恢复"判定中排除。** `IsUnRecoverInPlaceFaultLevels(faultLevel, jobSubHealthStrategy)` 先克隆故障级别集合,再 `Delete` 掉一批"已处理/无需迁移"的级别,然后据剩余集合是否含 `SubHealthFault`(且策略非 ignore)或剩余非空来判定是否原地不可恢复。本期把 `constant.PreSeparateNPU` 追加进 `Delete` 列表——效果是:一个只含 `PreSeparateNPU`(叠加原有那几个可处理级别)的故障集合,现在返回 `false`(不再判为原地不可恢复),即预隔离态被视作"另有处理路径 / 可原地恢复",不再强制走重启/迁移分支。新增 `TestIsUnRecoverInPlaceFaultLevels` 表驱动用例锁定该语义(可恢复级别 + subhealth ignore → false;`SeparateNPU`(已隔离,非预隔离)→ true)。
  <details><summary>代码依据 component/clusterd/pkg/domain/faultdomain/fault_utils.go</summary>

  ```diff
   func IsUnRecoverInPlaceFaultLevels(faultLevel sets.String, jobSubHealthStrategy string) bool {
   	tmpSet := faultLevel.Clone()
  -	tmpSet.Delete(constant.NotHandleFault, constant.RestartRequest, constant.RestartBusiness)
  +	tmpSet.Delete(constant.NotHandleFault, constant.RestartRequest, constant.RestartBusiness, constant.PreSeparateNPU)
   	return (tmpSet.Has(constant.SubHealthFault) && jobSubHealthStrategy != constant.SubHealthyIngore) ||
   		(!tmpSet.Has(constant.SubHealthFault) && tmpSet.Len() > 0)
   }
  ```
  ```diff
  +func TestIsUnRecoverInPlaceFaultLevels(t *testing.T) {
  +	...
  +		{
  +			name: "recoverable fault levels and subhealth fault with ignore strategy should return false",
  +			faultLevels: []string{
  +				constant.NotHandleFault, constant.RestartRequest, constant.RestartBusiness, constant.PreSeparateNPU, constant.SubHealthFault,
  +			},
  +			jobSubHealthStrategy: constant.SubHealthyIngore,
  +			want:                 false,
  +		},
  +		{
  +			name:                 "unrecoverable fault other than subhealth should return true",
  +			faultLevels:          []string{constant.SeparateNPU},
  +			jobSubHealthStrategy: constant.SubHealthFaultStrategy,
  +			want:                 true,
  +		},
  ```
  </details>
  含义:预隔离(PreSeparateNPU,尚未真正隔离的预备态)与已隔离(SeparateNPU)在故障恢复策略上被拉开——前者不触发原地不可恢复(不强制作业重启/迁移),后者仍触发。对训练作业容错的意义是减少"预隔离"这种未定态导致的过度重启。证据只覆盖 `IsUnRecoverInPlaceFaultLevels` 一处判定的集合成员变化,未见 `PreSeparateNPU` 的产生点与消费该 bool 的上层容错编排代码。

- **附:本区间提交标题另含 clusterops 侧 "CM sharding of pathmap and relcache"(路径映射/关系缓存的配置分片)与故障诊断资料合入,但按 PATHPREFIX(component/*)过滤后信号文件仅命中 faultdomain 两文件**,说明这些提交改动的文件不在受跟踪的 component 子目录内(或为文档/生成物),故不展开研判。GitCode compare 的 commits 是整区间不按 path 细分,以信号文件/patch 为准。

### 后续发展方向 [AI]
- 故障分级持续细化:`PreSeparateNPU` 作为"预隔离"中间态被从原地不可恢复集合中拆出,方向是把 NPU 故障从"二元(健康/隔离)"细化为带预备态的多级恢复策略,降低误判导致的作业重启。下期可跟 `PreSeparateNPU` 的判级来源(哪个 fault level 探测器产生它)与它最终如何转成 `SeparateNPU`。证据只覆盖本次一处集合成员剔除,未见状态机全貌。

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:均无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=17c2878e4b47efeb699e7066c2910ab22abe4bf5 tag=v26.1.1 scanned=2026-09-19 -->
<!-- ANCHOR repo=npu-operator sha=802e269728d3528e7864b4d8c04a915c12d1169b tag=v26.6.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=npu-dra-plugin sha=5d7339c517d971eaeb0b915bd19ed3d90db3c44c tag=v26.6.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-19 -->

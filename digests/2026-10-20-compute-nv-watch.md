# NVIDIA 算力栈 diff 雷达 2026-10-20

## 摘要
- 仅 KAI-Scheduler 有实质改动,核心是一处 binder 行为修正:失败但仍有重试余额的 BindRequest 现在会**保住 GPU 预留**,避免分数/共享场景下重试时预留已被提前释放。
- 另一条是发版工程改造:Helm chart 把 `gpu-fractioning` 子 chart 从精确 pin 改成 `~0.1.0` 版本范围、构建时解析,Chart.lock 不再入库,改由 release 资产 `subcharts.yaml` 记录实际发布版本。**对我们这类 diff 雷达的影响**:今后 gpu-fractioning(GPU 软切分组件)的版本变化不会在 KAI 仓 commit 里体现,靠扫 commit 会漏。
- 其余 8 个 repo 本日无实质改动(仅保锚点)。

## 当日重要改变
- 无(本日改动未命中弃用/API-CRD/架构方向/版本跨档/新 package 信号)

## kai-scheduler/KAI-Scheduler: e9b83d67 -> 337b49e0
- 比较: ahead=3 | files=19 | Release: v0.16.12(未跨档)
- https://github.com/kai-scheduler/KAI-Scheduler/compare/e9b83d67c15b1d52c8e9a70d02d46aae9bdac709...337b49e0f60816b59d9014d99d71dc1f9e44020c

### AI 总结重点(源码 diff 为据)
- **binder 预留保活语义翻转**:`hasActiveBindRequestsForGpuGroup` 对处于 `BindRequestPhaseFailed` 的请求,判定分支的两条出口全部对调。旧逻辑是"退避额度已耗尽→`return false`(视为无活跃请求,预留可释放)/ 仍有重试余额→`continue`";新逻辑改成"退避额度耗尽→`continue`(继续看同组其它请求,不再立刻判无)/ 仍有重试余额→`return true`(判定该 GPU 组仍有活跃绑定,保住预留)"。效果:一个失败但可重试的 BindRequest 不再被当成"无活跃请求"而导致 GPU 预留被提前回收,下次重试仍能用到原先预留的卡;同时单个已耗尽的请求也不再直接短路掉对同组其它请求的检查。commit:fix(binder): preserve GPU reservations during binding retries (#2406)
  <details><summary>代码依据 pkg/binder/binding/resourcereservation/resource_reservation.go</summary>

  ```diff
  	if br.Status.Phase == schedulingv1alpha2.BindRequestPhaseFailed {
  +		var backoffLimit any
  +		if br.Spec.BackoffLimit != nil {
  +			backoffLimit = *br.Spec.BackoffLimit
  +		}
  +		logger := log.FromContext(ctx).WithValues(
  +			"namespace", br.Namespace, "name", br.Name, "gpuGroup", gpuGroup,
  +			"failedAttempts", br.Status.FailedAttempts, "backoffLimit", backoffLimit)
  		// If the binding backoff limit is not spent, the binder will keep retrying.
  		if br.Spec.BackoffLimit == nil || br.Status.FailedAttempts >= *br.Spec.BackoffLimit {
  -			return false, nil
  +			logger.Info("Failed BindRequest has no retries remaining, checking other requests for GPU group")
  +			continue
  		}
  -		continue
  +		logger.Info("Preserving GPU reservation for failed BindRequest with retries remaining")
  +		return true, nil
  	}
  ```
  </details>

- **gpu-fractioning 子 chart 改为范围解析,版本脱钩 git**:Helm chart 把 `gpu-fractioning` 从精确 pin(原 Chart.lock 锁 `v0.1.7`)改为 `~0.1.0` 范围、构建时 `helm dependency build` 现场解析;`deployments/kai-scheduler/Chart.lock` 从仓库移除(改为本地构建产物),新增 `hack/subchart-versions.sh` 在发版流程里比对并自动补 changelog 条目,push-artifacts 流水线生成并上传 `subcharts.yaml` 作为"实际发布了哪个子 chart 版本"的权威记录。含义:gpu-fractioning 的补丁无需在本仓提 PR 即被下次 chart 构建带入。commit:feat(chart): resolve gpu-fractioning by ~0.1.0 range at build time (#2411)
  <details><summary>代码依据 AGENTS.md / .github/workflows/push-artifacts.yaml</summary>

  ```diff
  +**Sub-chart versions:** the chart declares `gpu-fractioning` as a version range (`~0.1.0`) rather than an exact pin,
  + so a gpu-fractioning patch is picked up by the next chart build instead of needing a PR here.
  +`deployments/kai-scheduler/Chart.lock` is therefore **not tracked** — it is local build output.
  +- **Which version shipped is recorded on the release**, not in git: the `subcharts.yaml` asset on the GitHub Release.
  ...
  +      - name: Generate subcharts.yaml
  +        run: make subcharts-manifest
  -      - name: Attach Helm chart to the GitHub Release
  +      - name: Attach release assets to the GitHub Release
  -              gh release upload "$PACKAGE_VERSION" ./charts/kai-scheduler-$PACKAGE_VERSION.tgz --clobber
  +              gh release upload "$PACKAGE_VERSION" ./charts/kai-scheduler-$PACKAGE_VERSION.tgz subcharts.yaml --clobber
  ```
  </details>

- 第三条 `chore: move the third-party component inventory out of NOTICE (#2356)`(NOTICE→COPYRIGHT 拆分)为纯 license 清单归置,无功能含义,略。

### 后续发展方向 [AI]
- binder 修正指向 KAI 在 **GPU 分数/共享 (fractioning) 场景下预留生命周期的稳健性**仍在打磨——此前失败重试与预留回收存在竞态(重试时卡已被别人抢走)。证据只覆盖 `resource_reservation.go` 这一处 `Failed` 分支,未见对 `Succeeded`/`Pending` 分支或预留 TTL 的改动,不能断定预留模型整体重构。
- gpu-fractioning 走版本范围脱钩,说明该组件已拆成**独立发版节奏的子 chart**,KAI 主仓与软切分内核解耦。对本雷达是扫描盲区提示:gpu-fractioning 是独立仓(`ghcr.io/kai-scheduler/.../gpu-fractioning`),其能力演进不在本 task 当前数据源内,后续若要跟 KAI 软切分内核本身需单独加源。证据仅覆盖 chart 打包与 AGENTS.md 说明,未见 gpu-fractioning 自身代码。

## 本期无实质改动(折叠)
<details><summary>8 个 repo 本日仅保锚点,无新提交/实质改动</summary>

- NVIDIA/gpu-operator(无新提交)
- NVIDIA/nvidia-container-toolkit(无新提交)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=dbb11e85129b601afe9fb502ac25b062ad094abd branch=main release=v26.7.2 scanned=2026-10-20 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3e112b4af299bf72a1b23193b4f5c3321475dd6d branch=main release=v1.20.1 scanned=2026-10-20 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d6d82abedb448b8f67992f1b59c86f163df24772 branch=main release=— scanned=2026-10-20 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1053da35d5a67fdbc3f0ea0877b7178026048769 branch=main release=v0.20.1 scanned=2026-10-20 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=63e98d305bb66cb9f2a07a0669661329d320ee3f branch=main release=v0.5.1 scanned=2026-10-20 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-20 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-20 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-20 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=337b49e0f60816b59d9014d99d71dc1f9e44020c branch=main release=v0.16.12 scanned=2026-10-20 -->

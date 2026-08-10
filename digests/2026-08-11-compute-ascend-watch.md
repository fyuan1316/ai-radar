# 昇腾算力栈 diff 雷达 2026-08-11

## 摘要
- 仅 `npu-dra-plugin` 有实质提交(1 组:!36 修 DestroyVDevice 错误处理逻辑倒挂 + !35 chart 问题 + !34 静态 PIE 构建);其余 8 仓(mind-cluster / npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin)相对 08-10 锚点均无新提交。
- 核心改动是一个**真实 bug 修复**:昇腾 DRA 插件销毁 vNPU 子设备(VDevice)时判定条件写反,失败被当成功吞掉、成功反而打 warning,现已改正并在失败时向上返回 error。这直接关系软切分 vNPU 资源回收的可靠性。
- 发布镜像从 `scratch` 改为 `ubuntu:22.04`,并启用 static-pie;软切分挂载(softShareMounts)清单调整(去掉 libboundscheck.so、npu-monitor→enpu-monitor)。

## 当日重要改变
- npu-dra-plugin [新能力/可靠性] DestroyVDevice 失败判定倒挂修复——vNPU 子设备销毁失败此前被静默当成功、不回收,现返回 error。证据 `pkg/dcmi/dcmi.go` @!36。 https://gitcode.com/openFuyao/npu-dra-plugin/commit/fa979c80357c29e82e576eca1cadc699fadf49c3
- npu-dra-plugin [架构方向] 发布镜像由 scratch 换成 ubuntu:22.04 + static-pie 构建,软切分挂载清单收敛。证据 `build/Dockerfile_pipeline` / `charts/npu-dra-driver/values.yaml` @!34/!35。 https://gitcode.com/openFuyao/npu-dra-plugin/commit/d1d27a7e72

## npu-dra-plugin: c5cb370f -> fa979c80
- 比较: c5cb370f..fa979c80 | tag: v26.6.0 | commits=6 | truncated=false
- 源: https://gitcode.com/openFuyao/npu-dra-plugin/compare/c5cb370fbc8d4201e352cadacefc5a2f82d15f39...fa979c80357c29e82e576eca1cadc699fadf49c3

### AI 总结重点(源码 diff 为据)
- **`DCMIManager.DestroyVDevice` 的成功/失败分支彻底写反,现已修正**。旧代码在 `ret != successDCMIResult`(即 DCMI 返回销毁**失败**)时,打印 "destroy vdevice **success**" 且 `return nil`——失败被当成功吞掉、上层永远收不到错误;而真正成功的路径反而走到 `klog.Warningf("... warning ... ret=%d")`。新代码在失败分支改为 `klog.Warningf("destroy vdevice **failed** ...")` 并 `return fmt.Errorf(...)` 把错误向上抛,成功分支才打 Info。对软切分而言,这意味着 vNPU 子设备回收失败此前会被静默,残留 VDevice 占位、后续预约可能拿不到几何——这是回收可靠性的实质修复,而非日志措辞调整。
  <details><summary>代码依据 pkg/dcmi/dcmi.go</summary>

  ```diff
   	if ret != successDCMIResult {
  -		klog.Infof("destroy vdevice success: card=%d device=%d vdevid=%d", cardID, deviceID, vdevID)
  -		return nil
  +		klog.Warningf("destroy vdevice failed: card=%d device=%d vdevid=%d ret=%d", cardID, deviceID, vdevID, ret)
  +		return fmt.Errorf("destroy vdevice failed: card=%d device=%d vdevid=%d ret=%d", cardID, deviceID, vdevID, ret)
   	}
  -	klog.Warningf("destroy vdevice warning: card=%d device=%d vdevid=%d ret=%d", cardID, deviceID, vdevID, ret)
  +	klog.Infof("destroy vdevice success: card=%d device=%d vdevid=%d", cardID, deviceID, vdevID)
   	return nil
  ```
  </details>
- **发布镜像从 `scratch` 换为 `ubuntu:22.04`,构建产物路径与权限调整,并启用 static-pie**。release stage 的 `FROM scratch` 改为 `FROM ubuntu:22.04`,拷贝的二进制从 `/go/bin/npu-dra-plugin`(chmod 555)变为 `/go/bin/app`(chmod 550);builder 镜像路径加了一层 `builder/` 命名空间,新增 `ARG PKG=./cmd/ascend-npu-dra-kubeletplugin`。换 ubuntu 基底通常是为了 static-pie(!34)下需要 glibc/动态加载环境或调试便利,代价是镜像体积与攻击面比 scratch 大。
  <details><summary>代码依据 build/Dockerfile_pipeline</summary>

  ```diff
  -FROM scratch AS release
  +FROM ubuntu:22.04 AS release
   WORKDIR /
  -COPY --link --from=build --chmod=555 /go/bin/npu-dra-plugin /npu-dra-plugin
  +COPY --link --from=build --chmod=550 /go/bin/app /npu-dra-plugin
   ENTRYPOINT [ "/npu-dra-plugin" ]
  ```
  </details>
- **软切分挂载清单(softShareMounts)收敛**:values.yaml 里删掉了 `/opt/xpu/lib/libboundscheck.so → /lib/libboundscheck.so` 的只读挂载,并把监控工具从 `/opt/xpu/bin/npu-monitor` 改成 `/opt/xpu/bin/enpu-monitor`(挂到容器内 `/opt/enpu/vcann-rt/tools/enpu-monitor`)。示例 Pod 也把挂载点从子目录 `ascend-toolkit`(`/usr/local/Ascend/ascend-toolkit`)放宽到整个 `/usr/local/Ascend`。说明 vCANN-RT 软切分运行时的依赖注入面在调整——去掉自带边界检查库、统一用 enpu-monitor 采集。
  <details><summary>代码依据 charts/npu-dra-driver/values.yaml + manifests/examples/soft-vnpu-pod.yaml</summary>

  ```diff
  # values.yaml softShareMounts
  -  - hostPath: /opt/xpu/lib/libboundscheck.so
  -    containerPath: /lib/libboundscheck.so
  -    options: [ro, rbind]
  -  - hostPath: /opt/xpu/bin/npu-monitor
  +  - hostPath: /opt/xpu/bin/enpu-monitor
       containerPath: /opt/enpu/vcann-rt/tools/enpu-monitor

  # soft-vnpu-pod.yaml 示例挂载放宽
  -    - name: ascend-toolkit
  -      mountPath: /usr/local/Ascend/ascend-toolkit
  +    - name: ascend
  +      mountPath: /usr/local/Ascend
  ```
  </details>

### 后续发展方向 [AI]
- DestroyVDevice 修复标志昇腾 DRA 软切分正从"能切"进入"回收可靠"打磨期——错误现在会向上抛,上层(kubeletplugin)理应据此重试/告警。证据只覆盖 dcmi.go 单个函数的返回契约变化,**未见**调用方是否已消费这个新 error(需看 cmd/ascend-npu-dra-kubeletplugin 的处理,本区间未改动该路径)。
- 挂载清单从 scratch+精确子目录转向 ubuntu+整目录 `/usr/local/Ascend`,方向是降低"依赖路径踩坑"的运维摩擦,但放宽 hostPath 挂载面。证据仅覆盖示例 Pod 与 chart 默认值,**未见**是否有配套的只读/安全约束收紧。

## 本期无实质改动(折叠)
- mind-cluster / npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin —— 相对 08-10 锚点无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=1aa04bb11642a630a16ba9ac88f392e4b3982e96 tag=v26.1.0 scanned=2026-08-11 -->
<!-- ANCHOR repo=npu-operator sha=7cddacb58841f285c6f719e2d7a5cb235be32cdb tag=v26.6.0 scanned=2026-08-11 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-11 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-11 -->
<!-- ANCHOR repo=vNPU sha=f5869cd17c57b8392b97fc76a7879a1a9a1eb81f tag=v0.1.0 scanned=2026-08-11 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-11 -->
<!-- ANCHOR repo=npu-dra-plugin sha=fa979c80357c29e82e576eca1cadc699fadf49c3 tag=v26.6.0 scanned=2026-08-11 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-11 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-11 -->

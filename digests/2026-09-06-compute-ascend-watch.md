# 昇腾算力栈 diff 雷达 2026-09-06

## 摘要
- **本日昇腾 NPU 算力栈无实质代码改动**:8 个 openFuyao 仓全部无新提交;`mind-cluster` 有 1 条实质提交,但落在 `component/dpu-exporter/`(DPU 网卡指标),不在本 task 的 NPU 组件 PATHPREFIX 范围内 → 视为空日,仅归档保锚点、不推飞书。
- 唯一 diff(范围外,仅备忘):dpu-exporter carrier 指标在网卡 linkdown 时由"跳过不上报"改为"上报 -1(unknown)",并把 carrier 显式当布尔量 0/1 解析。属昨日 linkdown 系列修复的 DPU 侧延续,但设备类为 DPU 非昇腾 NPU,不做 NPU 栈研判。

## 当日重要改变(NPU 栈范围内)
- 无

## 范围外观察(不计入 NPU 栈研判,仅记录)
- mind-cluster [范围外/bugfix] `component/dpu-exporter` 修网卡端口 linkdown 后 carrier 指标异常:读 sysfs `carrier` 失败(linkdown)时不再 `continue` 跳过,而是把该指标置 -1(unknown)上报;并在 `parseSysfsValue` 中把 carrier 单独按布尔解析("1"→1、"0"→0、其他→-1),避免走通用 `ParseFloat` 对非数值原始值报错。设备类为 DPU,非昇腾 NPU,故不纳入 NPU 栈趋势。
  - 提交:【dpu-exporter】网卡端口linkdown之后carrier指标异常问题修复(!4590)
  - 源:https://gitcode.com/Ascend/mind-cluster
  <details><summary>代码依据 component/dpu-exporter/pkg/collector/metricscollector/sysfs_collector.go</summary>

  ```diff
       raw, err := dmgr.ReadSysfs(path)
       if err != nil {
  +        if fileName == "carrier" {
  +            metrics[fileName] = -1
  +        }
           continue
       }
  ...
  +    // carrier is boolean: report 0/1 as-is, anything else as -1 (unknown)
  +    if fileName == "carrier" {
  +        switch raw {
  +        case "1":
  +            return 1, nil
  +        case "0":
  +            return 0, nil
  +        default:
  +            return -1, nil
  +        }
  +    }
       return strconv.ParseFloat(raw, 64)
  ```
  </details>

## 本期无实质改动(折叠)
- mind-cluster:2 提交,仅 merge + 1 条 dpu-exporter(范围外),NPU 组件 PATHPREFIX 内无命中
- npu-operator:无新提交
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- vNPU:无新提交
- npu-node-provision:无新提交
- npu-dra-plugin:无新提交
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=9d6a0171cd3c973ba2db488dbb5bfa093d609412 tag=v26.2.0.beta.1 scanned=2026-09-06 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f3cfd270f0dda85b259f4041d6c99824920e17e5 tag=v26.6.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=ef44c337d16e208fc1557b8e56a77447f30bc2a7 tag=1.0.2 scanned=2026-09-06 -->

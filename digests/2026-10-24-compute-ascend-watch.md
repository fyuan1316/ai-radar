# 昇腾算力栈 diff 雷达 2026-10-24

## 摘要
- 本期唯一有新提交的仓是 `Ascend/mind-cluster`(2240d93d → eb251a57,6 次提交,truncated),但**改动全是文档 + 单元测试,无任何生产代码 hunk**:300 个变更文件里,`component/` 下的全部落在 `ascend-faultdiag/.../test/`(故障诊断工具 ascend-fd-tk 的 Python 单测),其余是 26.2.0 版本的集群调度 / 故障诊断**英文文档**合入。device-plugin / docker-runtime / for-volcano / operator / npu-exporter / noded / clusterd / infer-operator / DRA / common 这些核心算力组件的生产代码**本期零改动**。
- 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)相对上期(2026-10-23)锚点**全部无新提交**,HEAD SHA 逐一比对一致。
- 虽无生产代码 diff,但新单测的 fixture / 断言**间接暴露了故障诊断工具的生产 API 面与芯片代际支持**——其中出现 **A5 / Ascend950(下一代)** 代际,值得记一笔(见下,证据边界:只看到测试代码,未见生产实现 hunk)。

## 当日重要改变
- **[新能力-软信号] mind-cluster / ascend-faultdiag:故障诊断工具 `NpuType` 代际枚举 + `npu-smi info -m` 解析已覆盖 A2 / A3 / A5(Ascend950 下一代)**。证据来自新增单测(非生产实现):`test_diag_enum.py` 断言 `NpuType.A3`、`NpuType.A5` 为合法枚举、`A9` 为非法;`test_chip_generation.py` 的 fixture 同时含 `Ascend910`(A3)与 `Ascend950`(A5)回显,被 `parse_npu_mapping_and_generation` 解析成代际 + npu_mapping。说明昇腾在把故障诊断能力向下一代 A5/Ascend950 对齐。**生产实现的 diff 本期未见(此前提交已合,现在才补测),故列为软信号。**
  <details><summary>代码依据 component/ascend-faultdiag/.../test/core/common/test_diag_enum.py</summary>

  ```diff
  +from ascend_fd_tk.core.common.diag_enum import DeviceStatus, DeviceType, NpuType, get_enum
  +        self.assertIs(get_enum(NpuType, name="A3"), NpuType.A3)
  +        self.assertIs(get_enum(NpuType, value="A5"), NpuType.A5)
  +        self.assertIs(get_enum(NpuType, name="A2", value="A5"), NpuType.A2)
  +        self.assertIsNone(get_enum(NpuType, name="A9"))
  ```
  </details>
  <details><summary>代码依据 component/ascend-faultdiag/.../test/core/common/test_chip_generation.py</summary>

  ```diff
  +"""generation 单元测试:npu-smi info -m 回显解析出代际与 npu_mapping。"""
  +from ascend_fd_tk.core.common.generation import parse_npu_mapping_and_generation
  +A3_STDOUT = """... 0  0  0  0  Ascend910 ..."""
  +A5_STDOUT = """... 0  0  0  0  Ascend950 ..."""
  ```
  </details>

## mind-cluster: 2240d93d -> eb251a57
- 比较: 2240d93db1810b0230b453db14d925f4d517ba71..eb251a57 | tag: v26.2.0 | commits=6 | truncated=true
- 源链接:https://gitcode.com/Ascend/mind-cluster/compare/2240d93db1810b0230b453db14d925f4d517ba71...eb251a57b56bc12d38a729441295b697a944231d

### AI 总结重点(源码 diff 为据)
- **ascend-fd-tk 故障诊断工具补齐了成体系的单元测试(约 100+ 个 `test_*.py`),覆盖面映射出该工具的完整功能骨架**:`core/service/` 层(9 个)含 `auto_diag` / `auto_inspection` / `collect_services` / `root_cause_analysis` / `loopback_diag` / `generate_diag_report` / `load_cache` / `output_cache`——即"采集→解析→诊断→根因分析→出报告 + 缓存"的闭环;`core/collect/` 覆盖 host/bmc/switch 的 dump log 与 ssh 采集;`core/model/` 覆盖 hccs / optical_module(光模块)/ bmc / cluster_mapping 等诊断对象。是故障诊断组件走向**产品化/可测试化**的工程信号(此前多为功能堆叠,现在补测试网)。
  <details><summary>代码依据:新增测试模块分布(ascend-faultdiag/.../test/core/)</summary>

  ```
  10 test/core/model/      (hccs/optical_module/bmc/cluster_mapping/threshold/...)
   9 test/core/service/    (auto_diag/auto_inspection/collect_services/root_cause_analysis/loopback_diag/...)
   9 test/core/collect/    (host/bmc/switch dump log + ssh fetcher)
   5 test/core/config/     (conn/dump_log_dir/port_mapping/tool config)
   5 test/core/common/     (chip_generation/diag_enum/errors/json_obj)
   4 test/core/report/  3 test/core/cli_module/  2 test/core/root_cause/
  ```
  </details>
- **文档面:26.2.0 的集群调度 + 故障诊断英文资料整体合入,并删除了"OpenPGP 校验"相关描述**。英文文档从调度(亲和/full-npu/多级调度/重调度)、故障检测诊断、断点续训/续推、到 vLLM/SGLang/MindIE-Motor/infer-operator 最佳实践全覆盖——是该栈面向**海外/国际化 GA** 的信号。OpenPGP 校验描述被移除属文档调整,未见对应代码层签名校验逻辑的 diff。
  <details><summary>依据:提交标题 + 文档路径</summary>

  ```
  【docs】合入26.2.0版本故障诊断英文资料
  【docs】合入集群调度26.2.0英文资料,并删除OpenPGP校验描述
  [Feature][FD] component testcase for core and utils
  docs/en/scheduling/...  docs/en/faultdiag/...  (116 added / 175 modified / 9 removed)
  ```
  </details>

### 后续发展方向 [AI]
- 故障诊断(ascend-faultdiag / ascend-fd-tk)是本期唯一活跃方向,且补测 + 补英文文档同步进行,指向该组件近期要**对外发布/国际化**。证据只覆盖测试与文档,未见生产实现 hunk,因此"A5/Ascend950 支持已落地到什么程度"无法从本期 diff 判定——需下期关注 `component/ascend-faultdiag` 生产代码(`core/common/generation.py`、`core/common/diag_enum.py`)的增量。
- 对我们产品的启示:昇腾把"故障采集→根因→报告"做成有测试覆盖的独立诊断工具(可 SDK/CLI 调用),是企业级可运维性(Day-2)的补课动作;对标我们 OAI 方向的 NPU/GPU 故障自愈链路,值得跟踪其 `root_cause_analysis` / `loopback_diag`(环回诊断)的对外接口形态。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓均无新提交</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:compare base..HEAD 无新提交,HEAD SHA 与上期一致。
- mind-cluster 的 device-plugin / docker-runtime / for-volcano / operator / npu-exporter / noded / clusterd / infer-operator / DRA(参见 [[ascend-dra-pathprefix-gap]])/ common 本期生产代码零改动。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=eb251a57b56bc12d38a729441295b697a944231d tag=v26.2.0 scanned=2026-10-24 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-10-24 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-10-24 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-10-24 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v26.9.0 scanned=2026-10-24 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-24 -->
<!-- ANCHOR repo=npu-dra-plugin sha=031dc691f082fdb90610f77eab3bcf91ad8e9aa3 tag=v26.9.0 scanned=2026-10-24 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-24 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=v26.9.0 scanned=2026-10-24 -->

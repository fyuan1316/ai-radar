# HAMi diff 雷达 2026-06-26

## 摘要
- 本日无实质代码改动。5 仓中仅 `Project-HAMi/HAMi` 有 1 个提交,且为纯文档:README(中/英/日)新增"生态系统集成"章节,正式列出 vLLM / Volcano / Kueue / Prometheus / Grafana / NVIDIA GPU Operator 六个集成对象。
- HAMi-core、volcano-vgpu-device-plugin、ascend-device-plugin、HAMi-WebUI 均无新提交。
- 无 API/CRD/proposal 路径命中,无能力面/调度面变化。

## 当日重要改变
- 无(唯一提交为文档,未命中弃用/API-CRD/架构/版本跨档/新能力任一信号)

## Project-HAMi/HAMi: bf7faa2c -> 5f06e0ab
- 比较: https://github.com/Project-HAMi/HAMi/compare/bf7faa2c6b1c70a6f7d124ae2752b107ecdbcd15...5f06e0abbb5ab27ec86ac0fe144e8cab1125a477 | ahead=1 | 最新 Release v2.9.0

### AI 总结重点(源码 diff 为据)
- 唯一改动是 README.md / README_cn.md / README_ja.md 各 +11/-0,在 "HAMi WebUI" 截图之后、"路线图/治理" 之前插入一个 `## Ecosystem Integrations` 表格。**这是文档/定位变更,不是代码**,六行表格把 HAMi 与上游生态的分工边界写进了官方 README:
  - vLLM:以"GPU 显存上限"跑推理服务器,多模型共享单卡(即 HAMi 软切分对推理场景的卖点定型为"显存配额");
  - Volcano:为 GPU 工作负载提供 Gang 调度 + 队列批调度;
  - Kueue:通过 `ResourceTransformation` 把 HAMi 资源暴露给 Kueue 做批作业排队——这是六条里唯一带具体机制名的,点明 HAMi↔Kueue 走资源转换而非自定义对接;
  - Prometheus / Grafana:按容器粒度上报 GPU 显存用量与利用率,并提供预构建 dashboard;
  - NVIDIA GPU Operator:明确"HAMi 管调度、GPU Operator 管驱动"的共存分工。

  <details><summary>代码依据 README.md(三语同构,摘英文)</summary>

  ```diff
  @@ -165,6 +165,17 @@ HAMi also provides:
   ![HAMi WebUI](imgs/hami-webui-overview.png)
  +## Ecosystem Integrations
  +
  +| Project | What the integration enables |
  +| --- | --- |
  +| [vLLM](https://github.com/vllm-project/vllm) | Run inference servers with GPU memory caps, enabling multiple models to share one GPU |
  +| [Volcano](https://volcano.sh/) | Gang scheduling and queue-based batch scheduling for GPU workloads |
  +| [Kueue](https://kueue.sigs.k8s.io/) | HAMi resources exposed to Kueue via ResourceTransformation for batch job queueing |
  +| [Prometheus](https://prometheus.io/) | HAMi exposes per-container GPU metrics including memory usage and utilization |
  +| [Grafana](https://grafana.com/) | Pre-built dashboard available for visualizing HAMi GPU metrics |
  +| [NVIDIA GPU Operator](https://github.com/NVIDIA/gpu-operator) | Can coexist with GPU Operator when HAMi manages scheduling and the Operator manages drivers |
   ## Roadmap, Governance, And Contributing
  ```
  </details>

### 后续发展方向 [AI]
- 这是定位信号而非能力信号:HAMi 把"调度层归我、驱动层归 GPU Operator、批队列归 Volcano/Kueue、可观测归 Prometheus/Grafana"的协作边界固化进官方文档,等于对外承诺不与 GPU Operator 抢驱动管理、不自造队列。对我们产品的启示:若要对标,HAMi 的护城河被明确收敛到"软切分调度 + per-container GPU 指标"两点,而 Kueue 集成走 `ResourceTransformation` 是可直接复用的标准路径。
- 证据边界:仅看了 README diff,未见任何代码/CRD 改动佐证这些集成有新增实现;无法判断 Kueue `ResourceTransformation` 路径本期是否有代码侧变化(本期 HAMi 代码零改动)。提交:https://github.com/Project-HAMi/HAMi/pull/1970

## 本期无实质改动(折叠)
<details><summary>4 个仓 EMPTY(均无新提交);HAMi 仅文档改动</summary>

- Project-HAMi/HAMi-core: 0831874b -> 0831874b | 无新提交
- Project-HAMi/volcano-vgpu-device-plugin: 6561f1c1 -> 6561f1c1 | 无新提交
- Project-HAMi/ascend-device-plugin: 799eaa34 -> 799eaa34 | 无新提交
- Project-HAMi/HAMi-WebUI: 30c3ce14 -> 30c3ce14 | Release hami-webui-1.2.0 | 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=5f06e0abbb5ab27ec86ac0fe144e8cab1125a477 branch=master release=v2.9.0 scanned=2026-06-26 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=0831874bce5af56cefca7093dfb2f9f95d1970aa branch=main release=— scanned=2026-06-26 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-06-26 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-26 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-26 -->

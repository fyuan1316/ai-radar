# HAMi diff 雷达 2026-08-31

## 摘要
- **HAMi-WebUI 昨天还在 proposal 的"NestJS 双运行时 → Go 静态网关"迁移,今天已作为一整批 PR(#167~#226,ahead=51)落地为实现**:新增可复用 Go Web 入口、移除 Nest 运行时、砍掉 Vue CLI/Webpack 工具链、删除内置认证视图——方向从"提案"变"既成事实"。
- 同批还在做前端供应链瘦身(移除 body-parser/Socket.IO/Node polyfills 等未用依赖 + 一串 security baseline 升级)与算力/内存 metrics 口径继续纠偏,延续 8-30 那期确立的口径统一方向。
- HAMi、HAMi-core、volcano-vgpu-device-plugin、ascend-device-plugin 四仓本日均无新提交(EMPTY),仅保锚点。

## 当日重要改变
- Project-HAMi/HAMi-WebUI [架构方向] `docs/proposals` 路径命中 + 顶层 `refactor: remove retired Nest runtime` —— WebUI 前端运行时从 NestJS 双运行时正式切到 Go 统一 Web 入口,昨天定调的架构收敛这期成批落地。证据(概览): https://github.com/Project-HAMi/HAMi-WebUI/pull/172 与 https://github.com/Project-HAMi/HAMi-WebUI/pull/168
- Project-HAMi/HAMi-WebUI [弃用/移除] 一批 remove/drop:`remove legacy Vue CLI and Webpack toolchain`(#173)、`remove unreachable auth views`(#217)、`remove retired Nest runtime`(#172)——对应昨天 proposal 说的"废弃多集群回归单集群只读 + 认证外置"。 https://github.com/Project-HAMi/HAMi-WebUI/pull/217

## Project-HAMi/HAMi-WebUI: 566bb06f -> 01333fb2
- 比较: https://github.com/Project-HAMi/HAMi-WebUI/compare/566bb06fc5acf79d92b98034e3f5d13951ce14bb...01333fb2 | ahead=51 | files=300(已被 API 截断)| Release: v1.3.0(未跨档)
- **本节为大区间概览,未逐文件读代码 hunk**(files 触顶 300 触发 OVERVIEW 模式);结论从"实质提交"标题 + 改动热点目录聚类得出,符号级差异待后续深度扫描或直接看 PR。

### AI 总结重点(概览,基于提交标题+热点目录,非 hunk)
改动 300 个文件里 275 个落在 `packages/web`,压倒性是**前端运行时大重构**,可聚成 5 个方向:

- **运行时迁移落地(NestJS 双运行时 → Go 统一 Web 入口)**:`add reusable Go web entry`(#167)、`switch frontend runtime to Go Web entry`(#168)、`remove retired Nest runtime`(#172)、`add unified application entry`(#225)、`keep unified entry HTTP-only`(#226)。这正是 8-30 digest 里 status=proposed 的 Gateway 方案,今天成批实现。
  - https://github.com/Project-HAMi/HAMi-WebUI/pull/167 https://github.com/Project-HAMi/HAMi-WebUI/pull/225
- **构建/工具链去 Nest 化**:`remove legacy Vue CLI and Webpack toolchain`(#173)、`replace legacy SVG sprite chain`(#204)、`migrate chart runtime to Vue-ECharts 8`(#206)、`pin the complete proto toolchain`(#201)、`upgrade Vite security baseline`(#203)。
  - https://github.com/Project-HAMi/HAMi-WebUI/pull/173 https://github.com/Project-HAMi/HAMi-WebUI/pull/206
- **前端依赖瘦身 + 供应链安全基线**:移除未用依赖 `body-parser`(#196)、`Socket.IO client`(#197)、`Vue WebSocket plugin`(#198)、`Node polyfills`(#200)、`iframe helper`(#190)、`unused global components`(#224);安全基线升级 Go(#191)、Axios(#195)、js-cookie(#199)。
  - https://github.com/Project-HAMi/HAMi-WebUI/pull/196 https://github.com/Project-HAMi/HAMi-WebUI/pull/191
- **认证/多集群收敛**:`remove unreachable auth views`(#217)、`remove unreachable legacy files`(#215)——呼应"废弃内置认证、单集群只读"的定调,内置登录能力从代码里真删掉。
  - https://github.com/Project-HAMi/HAMi-WebUI/pull/217
- **算力/内存 metrics 口径继续纠偏**:`preserve missing device usage samples`(#178)、`align allocation capacity and coverage`(#183)、`restore physical device memory contract`(#185)、`remove localized driver placeholders`(#214)、`preserve Prometheus results with warnings`(#223)、`secure external Prometheus TLS`(#221)。延续 8-30 那期"算力利用率口径全面纠偏"的主线,这次补内存契约与缺失样本保留。
  - https://github.com/Project-HAMi/HAMi-WebUI/pull/185 https://github.com/Project-HAMi/HAMi-WebUI/pull/183
- 部署形态配套:`support URL prefixes and controlled embedding`(#169)、`add an internal backend Service`(#170,chart)、`render image pull secrets`(#180,chart)——支撑反向代理挂载 + 受控 iframe 嵌入,正是 Go 网关方案要的部署能力。
  - https://github.com/Project-HAMi/HAMi-WebUI/pull/169

改动热点目录:`packages/web`(275)、`charts/hami-webui`(10)、`.github/workflows`(3)、`docs/proposals`(1)。

### 后续发展方向 [AI]
- WebUI 已完成"去 NestJS、去 Vue CLI/Webpack、去内置认证"的运行时收敛,Go 统一入口 + 反向代理/URL 前缀/iframe 嵌入的部署形态基本成型。对我们产品的启示:HAMi 控制台已明确定位为"被上层平台嵌入的只读单集群视图",企业多集群纳管与认证鉴权要由外层平台(如我们自家控制台)承接,不能指望 WebUI 自带。证据边界:本期为概览模式、未读 hunk,Go 入口的具体路由/鉴权外置接口形态需看 #225/#226 源码确认。
- metrics 口径纠偏仍在收尾(内存契约、缺失样本、Prometheus warning 处理、外部 Prometheus TLS),说明 8-30 的算力口径改造是一轮系统性数据正确性整治的一部分,尚未完全收口。证据只到提交标题,各 PromQL/契约的前后差异未逐一验证。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- Project-HAMi/HAMi:无新提交(HEAD 仍 ebcd8ae0)
- Project-HAMi/HAMi-core:无新提交(HEAD 仍 de6ce39d)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HEAD 仍 32162c65)
- Project-HAMi/ascend-device-plugin:无新提交(HEAD 仍 4b977f92)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=ebcd8ae000d0ded373cad0ebfabb8289f2c5810a branch=master release=v2.10.0 scanned=2026-08-31 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=de6ce39dc36246d4161e931ae2fd93929e676e55 branch=main release=— scanned=2026-08-31 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=32162c65332b649084b07894fa2c6101469012f5 branch=main release=— scanned=2026-08-31 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-08-31 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=01333fb2c3a6a685165f7f3a4000fb8e0c78c948 branch=main release=v1.3.0 scanned=2026-08-31 -->
</content>
</invoke>

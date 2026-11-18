# HAMi diff 雷达 2026-11-19

## 摘要
- 当日没有 API/CRD、proposal 或版本跨档。HAMi v2.11.0、WebUI v1.3.0 均未发新 Release。唯一命中信号的是 HAMi 主仓「remove images」:删掉的只是 README 里没被引用的图片，对运行时没有影响。
- HAMi 主仓真正动到行为的是 Chart 的两个兜底修复:① 显式把 `scheduler.service.httpTargetPort` 置空/null 时,NetworkPolicy 原来放行的是 Service 端口 443,而不是容器端口 9443。② 组件镜像 tag 只填了空白字符时，原来会渲染出空 tag,现在改为回退到 `global.imageTag`。另外，项目依赖从已归档的 `gopkg.in/yaml` 整体迁到 `go.yaml.in/yaml`。
- HAMi-WebUI 的 Overview 新接入沐曦 MetaX C500 物理卡的利用率和显存读取(经 mxExporter 的 `mx_*` 指标，按单 die 契约取数),继续落实「多厂商物理卡统一看板」路线;同时去掉了 Issues 面板的 cordoned 节点项和 partial 覆盖度状态。

## 当日重要改变
- Project-HAMi/HAMi [弃用/移除] c9e266cc「chore: remove images that nothing references」删除 `HAMi.jpg`、`imgs/hard_limit.jpg`、`imgs/hami-webui-overview.png` 等未被引用的文档图片。只是文档资产清理，不涉及代码、flag 或 CRD 字段。 https://github.com/Project-HAMi/HAMi/commit/c9e266cca1b1ffbd758c306eaac61409fdda89c9

## Project-HAMi/HAMi: fc2bcd0d -> 297dfaed
- 比较: fc2bcd0d24da4e409a792de02deaf57a143565ac -> 297dfaed | ahead=9 | files=35 | Release: v2.11.0(未变)
- 比较链接: https://github.com/Project-HAMi/HAMi/compare/fc2bcd0d24da4e409a792de02deaf57a143565ac...297dfaedd9a00291b4ad3f40aa367eb9581aa3a4
- 说明:helper 的 patch 节选名额被新增 SVG 和 README 占满，下面 Chart、`cmd/scheduler`、`go.mod` 的 hunk 是用同一区间的 GitHub compare API 补拉的原始 patch。

### AI 总结重点(源码 diff 为据)
- **NetworkPolicy 端口兜底值从 443 改为 9443**(`charts/hami/templates/scheduler/networkpolicy.yaml`)。
  - 问题：模板中 `httpTargetPort` 的 `default` 写成了 443。443 是 Service 端口 `scheduler.service.httpPort`,而容器实际监听的是 `httpTargetPort`(values 默认 9443)。用户显式把 `httpTargetPort` 设成 `""` 或 `null` 时，策略放行的是 443,打到 9443 的流量全被拒绝。被拒的是 kube-apiserver → admission webhook 和 device-plugin → `/refit` 两条链路。
  - 后果：按 values 注释，在 `failurePolicy: Ignore` 下，这种情况会让 Pod 不经 HAMi 改写就被静默放行。
  - 新增 `charts/hami/tests/scheduler_networkpolicy_test.yaml`,覆盖空串和 null 两种情况都回落到 9443。
  - 只影响 `scheduler.networkPolicy.enabled=true` 且显式清空 `httpTargetPort` 的部署。
  - 提交: https://github.com/Project-HAMi/HAMi/commit/de5ffefe2dc10b6745dcc897b7461ccf07e5b3a5
  <details><summary>代码依据 charts/hami/templates/scheduler/networkpolicy.yaml</summary>

  ```diff
         ports:
           - protocol: TCP
  -          port: {{ .Values.scheduler.service.httpTargetPort | default 443 }}
  +          port: {{ .Values.scheduler.service.httpTargetPort | default 9443 }}
  ```
  </details>
- **`hami.imageTagOrGlobal` 改为先 trim 再回退**(`charts/hami/templates/_helpers.tpl`)。
  - 旧逻辑:`.imageRoot.tag | default global.imageTag | trim`。`"   "` 这类空白字符串不算空，不会触发 default,trim 后变成空 tag,渲染出 `projecthami/hami:` 这样的坏镜像引用。
  - 新逻辑：先把组件 tag trim 成 `$tag`,`$tag` 为空时才回退到 `global.imageTag`。非空 tag 两端的空白(含 `\t`、`\n`)也会被剥掉。
  - 新增 `image_tag_fallback_test.yaml`,覆盖 scheduler extender、device-plugin、monitor 三个镜像。
  - 提交: https://github.com/Project-HAMi/HAMi/commit/b47e94afee861362d792fcc5bdbd348d8e5230d8
  <details><summary>代码依据 charts/hami/templates/_helpers.tpl</summary>

  ```diff
   {{- define "hami.imageTagOrGlobal" -}}
  -{{- .imageRoot.tag | default (and .global .global.imageTag) | default "" | toString | trim -}}
  +{{- $tag := .imageRoot.tag | default "" | toString | trim -}}
  +{{- $tag | default (and .global .global.imageTag) | default "" | toString | trim -}}
   {{- end -}}
  ```
  </details>
- **`scheduler validate` 子命令在参数解析通过后设 `cmd.SilenceUsage = true`**(`cmd/scheduler/validate.go`,作用于 `newValidateCommand` 和 `newSchedulerConfigCommand` 的 `RunE`)。
  - 行为变化：配置内容校验失败(YAML 错误、资源名冲突等)时只打印错误，不再附带 cobra 的 Usage 文本。只有命令行本身写错(未知 flag、参数个数不对)时才打印 Usage。
  - 测试新增 `wantUsage` 断言来固化这一区分。
  - 提交: https://github.com/Project-HAMi/HAMi/commit/5cc634fa9436f156e98c5898a99f71e729307a53
  <details><summary>代码依据 cmd/scheduler/validate.go</summary>

  ```diff
   		RunE: func(cmd *cobra.Command, args []string) error {
  +			// The command line parsed, so an error from here on is about the
  +			// input. Print it without the usage text.
  +			cmd.SilenceUsage = true
   			path := args[0]
   			cfg, err := config.LoadConfig(path)
  ...
   		RunE: func(cmd *cobra.Command, _ []string) error {
  +			// As for device-config: past parsing, skip the usage text.
  +			cmd.SilenceUsage = true
   			if err := validateSchedulerOptions(); err != nil {
  ```
  </details>
- **YAML 库从已归档的 `gopkg.in/yaml.v2/v3` 迁到 `go.yaml.in/yaml/v2/v3`**,版本从 v2.4.0/v3.0.1 升到 v2.4.5/v3.0.6,原来的 indirect 依赖转为 direct 依赖。
  - 涉及文件:`pkg/scheduler/config/config.go`(调度器配置解析)、`hack/tools/rbaccheck`,以及 ascend 设备测试。
  - 只换了 import 路径，没有改调用代码。
  - 同区间还有两项依赖 bump:`NVIDIA/k8s-device-plugin` v0.20.1 → v0.20.2;`libvgpu` 子模块升到 `1fc9ea59`,即上期 HAMi-core 的 HEAD。
  - 提交: https://github.com/Project-HAMi/HAMi/commit/65847375e01a7f6af37ac9afa718ecbccd790cd8
  <details><summary>代码依据 go.mod / pkg/scheduler/config/config.go</summary>

  ```diff
  -	github.com/NVIDIA/k8s-device-plugin v0.20.1
  +	github.com/NVIDIA/k8s-device-plugin v0.20.2
  ...
  +	go.yaml.in/yaml/v2 v2.4.5
  +	go.yaml.in/yaml/v3 v3.0.6
  -	gopkg.in/yaml.v2 v2.4.0
  -	gopkg.in/yaml.v3 v3.0.1
  ```
  ```diff
  -	"gopkg.in/yaml.v2"
  +	"go.yaml.in/yaml/v2"
   	utilerrors "k8s.io/apimachinery/pkg/util/errors"
  ```
  </details>
- **benchmark 脚本的就绪判定更严格**(`benchmarks/ai-benchmark/run_bench.sh`)。
  - 原来 curl 能连上就算就绪，现在要求 `/v1/models` 返回 HTTP 200,并加了 2s 连接超时和 5s 请求超时。
  - 新增 `trap cleanup EXIT` 加 HUP/INT/TERM 信号处理，按 `container_id` 停容器，不再依赖流程末尾那一次 `docker stop`。
  - `MAX_RETRIES` 增加正整数校验。
  - 只影响测试工具，不影响产品行为。
  - 提交: https://github.com/Project-HAMi/HAMi/commit/297dfaedd9a00291b4ad3f40aa367eb9581aa3a4
  <details><summary>代码依据 benchmarks/ai-benchmark/run_bench.sh</summary>

  ```diff
  -  if curl -s "$VLLM_URL/v1/models" > /dev/null 2>&1; then
  +  if http_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  +    --connect-timeout 2 --max-time 5 "$VLLM_URL/v1/models") && [ "$http_status" = 200 ]; then
  ...
  +trap cleanup EXIT
  +trap 'exit 129' HUP
  ```
  </details>

### 后续发展方向 [AI]
- 两个 Chart 修复都附带了 helm-unittest 用例，延续了上期 v2.11.0 前后对 Chart 做「兜底值和用户输入健壮性」加固的节奏。NetworkPolicy 修复说明 HAMi 正在把调度器 webhook 链路的网络隔离当成正式支持的安全选项，而不只是示例模板。
- 证据只覆盖 Chart 模板和测试，没有看到 deployment 模板中容器端口的兜底是否同步，也没有逐 PR 展开讨论。
- 本期没有触及 `pkg/device`、`pkg/scheduler` 的调度和切分逻辑，软切分能力本身零变化。

## Project-HAMi/HAMi-core: 1fc9ea59 -> 9bc18ca8
- 比较: 1fc9ea59cf1f94e16a7ddf6f445e129d282e1d03 -> 9bc18ca8 | ahead=2 | files=4 | Release: —
- 比较链接: https://github.com/Project-HAMi/HAMi-core/compare/1fc9ea59cf1f94e16a7ddf6f445e129d282e1d03...9bc18ca8f31e7f4ad92b53deb0d3fa58e5c6009f

### AI 总结重点(源码 diff 为据)
- **`Makefile` 的 `CUDA_IMAGE` 不再硬编码 digest,改为从 `dockerfiles/Dockerfile` 第一行 `FROM` 用 awk 解析**。
  - 原来是手工固定的 `nvidia/cuda:13.3.0-cudnn-devel-ubi8@sha256:...`,现在以 Dockerfile 为唯一来源，消除两处需要同步的漂移点。
  - 新增 `docker-build` target(默认镜像 `DOCKER_IMAGE ?= hami-core:dev`),三语 README 的构建命令同步改为 `make docker-build`。
  - 纯构建工程改动，没有触及 hook 或显存记账代码。
  - 提交: https://github.com/Project-HAMi/HAMi-core/commit/9bc18ca8f31e7f4ad92b53deb0d3fa58e5c6009f
  <details><summary>代码依据 Makefile</summary>

  ```diff
  -# Keep in sync with dockerfiles/Dockerfile and Project-HAMi/HAMi's NVIDIA_IMAGE.
  -CUDA_IMAGE ?= nvidia/cuda:13.3.0-cudnn-devel-ubi8@sha256:e5b2b971730b6d0defd6d1bd7697630e0e599c359190cc4351e3032134e7b401
  +# Derived from dockerfiles/Dockerfile (kept in sync with Project-HAMi/HAMi's NVIDIA_IMAGE).
  +CUDA_IMAGE ?= $(shell awk '/^FROM / {print $$2; exit}' $(current_dir)dockerfiles/Dockerfile)
  +DOCKER_IMAGE ?= hami-core:dev
  ...
  +docker-build:
  +	docker build -f $(current_dir)dockerfiles/Dockerfile -t $(DOCKER_IMAGE) $(current_dir)
  ```
  </details>

### 后续发展方向 [AI]
- 只看到构建入口收敛，没有新的 CUDA hook 类型，也没有显存/算力记账变化。上期 147 commit 的 CUDA Graph/VMM 记账补齐之后，本期进入平稳期。证据只覆盖 Makefile 和 README。

## Project-HAMi/HAMi-WebUI: 01b0ba23 -> 19a0f955
- 比较: 01b0ba234db547f3bcc0b9f916ba8664f0716ea0 -> 19a0f955 | ahead=6 | files=21 | Release: v1.3.0(未变)
- 比较链接: https://github.com/Project-HAMi/HAMi-WebUI/compare/01b0ba234db547f3bcc0b9f916ba8664f0716ea0...19a0f955a652ba7f7e4af5a9315686829e884328

### AI 总结重点(源码 diff 为据)
- **新增 MetaX C500 物理卡遥测**(新文件 `server/internal/exporter/metax_observations.go`,在 `resource_telemetry.go` 中接入)。
  - 取数范围:`telemetryPlan` 的 provider 列表加入 `biz.MetaxGPUDevice`,按 `uuid` 分批拉 `mx_gpu_state`、`mx_gpu_usage`、`mx_memory_used`、`mx_memory_total` 四个指标，过滤条件为 `uuid=~...,type=~"|vram"`。
  - 显存单位：显存按 KiB 换算(`memoryScale = bytesPerKiB`),source 标为 `mx_exporter`。
  - 判卡规则:`metaxReadings` 只接受 `die_id="0"` 且型号为 C500/MXC500 的单 die 卡。`mx_gpu_state` 必须为 1。同一次采集里如果出现其他 die,判为 `errDCGMAmbiguous`,防止把单个 die 的读数当成整卡读数。
  - 型号缺失的处理:sGPU 插件注册时 model 字段可能填的是 `sgpu`/`native` 或为空，这时由 `metaxC500Candidate` 放行，再用 exporter 的 `mx_gpu_state.modelName` 确认是否为 C500。
  - 提交: https://github.com/Project-HAMi/HAMi-WebUI/commit/3343fd540d129869a3772730bac5445ac6971ae7
  <details><summary>代码依据 server/internal/exporter/metax_observations.go / resource_telemetry.go</summary>

  ```diff
  +const (
  +	metaxState       = "mx_gpu_state"
  +	metaxUtilization = "mx_gpu_usage"
  +	metaxUsed        = "mx_memory_used"
  +	metaxTotal       = "mx_memory_total"
  +)
  +func metaxChipMatches(d resourceview.Device, l map[string]string) bool {
  +	return l["die_id"] == "0" && metaxC500(l["modelName"]) && l["Hostname"] == d.Identity.Node && ...
  +}
  +// The sGPU plugin can put a sharing mode in the registration's model field.
  +func metaxC500Candidate(model string) bool {
  +	return metaxC500(model) || model == "" || model == "sgpu" || model == "native"
  +}
  ...
  +	if state.selection.Value != 1 {
  +		return failedReadings(errDCGMInvalid)
  +	}
  ```
  ```diff
  -	for _, provider := range []string{biz.NvidiaGPUDevice, biz.AscendGPUDevice, biz.HygonHCUDevice, biz.HygonGPUDevice} {
  +	for _, provider := range []string{biz.NvidiaGPUDevice, biz.AscendGPUDevice, biz.HygonHCUDevice, biz.HygonGPUDevice, biz.MetaxGPUDevice} {
  ...
  +			case biz.MetaxGPUDevice:
  +				families = []string{metaxState, metaxUtilization, metaxUsed, metaxTotal}
  +				filter = fmt.Sprintf("uuid=~%q,type=~%q", strings.Join(ids, "|"), "|vram")
  ...
  +				memoryScale = bytesPerKiB // mxExporter reports VRAM in KiB.
  ```
  </details>
- **`nodeMetricLabels` 的 `pci` 字段泛化为 `entity`,并抽出 `sameCollection`**(`node_observations.go`)。
  - 字段语义：海光用它承载 `pcieBus_number`,MetaX 用它承载 `die_id`,所以从「PCI 地址」泛化成「子实体标识」。
  - 节点匹配：对 MetaX 不再要求样本带 `node` 标签(mxExporter 用的是 `Hostname`),显存样本只取 `type="vram"`,排除 XTT 系统内存和 sGPU 配额。
  - 原来 `memoryPair` 里内联的一致性判断抽成 `sameCollection`,MetaX 的利用率读数也复用它，校验与 state 样本是否来自同一次采集。
  <details><summary>代码依据 server/internal/exporter/node_observations.go</summary>

  ```diff
  -type nodeMetricLabels struct{ deviceID, index, pci, model, utilization string }
  +type nodeMetricLabels struct{ deviceID, index, entity, model, utilization string }
  ...
  -		if labels["__name__"] != name || labels[schema.deviceID] != exportedID || labels["node"] != id.Node {
  +		if labels["__name__"] != name || labels[schema.deviceID] != exportedID {
  +			continue
  +		}
  +		if id.Provider == biz.MetaxGPUDevice {
  +			if (name == metaxUsed || name == metaxTotal) && labels["type"] != "vram" {
  +				continue
  +			}
  +		} else if labels["node"] != id.Node {
  ...
  +func (schema nodeMetricLabels) sameCollection(a, b dcgmSelection) bool {
  ```
  </details>
- **Overview Issues 指示器简化：去掉 `nodeCordoned` 和 partial 覆盖度状态**(`resource-summary.mjs`、`node-device-issues.mjs`)。
  - cordoned 节点：不再记为 issue,`summarizeNodeIssues` 只保留 `deviceUnhealthy` 和 `nodeNotReady` 两类，返回值从 `{incidents, cordonedNodes, count}` 收缩为 `{incidents}`。
  - 覆盖度：删除 `issueCoverageGap`,`issueStatus` 不再有 `'partial'`,只剩 `ready`/`empty`。用量侧的 `usageStatus` 仍然按 `deviceCoverage.complete` 判断。
  - 结果：上期引入的「不完整不报 0」覆盖度语义，只在利用率面板保留，Issues 面板不再提示「健康数据不全」。
  - 提交: https://github.com/Project-HAMi/HAMi-WebUI/commit/a4928c9ebfed51446a1ba3bf060544cea9074795
  <details><summary>代码依据 packages/web/projects/vgpu/views/monitor/overview/resource-summary.mjs / node-device-issues.mjs</summary>

  ```diff
  -  let issueCoverageGap = '';
  -  if (!nodeCoverage.complete) issueCoverageGap = deviceCoverage.complete ? 'nodeInventory' : 'inventory';
  -  else if (!deviceCoverage.complete) issueCoverageGap = 'deviceInventory';
  ...
  -    if (node.schedulable === false) issues.push({ ...identity, kind: 'nodeCordoned' });
  ...
  -    issueStatus: issueCoverageGap ? 'partial' : nodes.length || devices.length ? 'ready' : 'empty',
  -    issueCoverageGap,
  +    issueStatus: nodes.length || devices.length ? 'ready' : 'empty',
  ```
  ```diff
  -    if (!issue?.node || !['deviceUnhealthy', 'nodeNotReady', 'nodeCordoned'].includes(issue.kind)) continue;
  +    if (!issue?.node || !['deviceUnhealthy', 'nodeNotReady'].includes(issue.kind)) continue;
  ...
  -  return { incidents, cordonedNodes, count };
  +  return { incidents };
  ```
  </details>
- **其余**:`DeviceUsageDistribution.vue` 的 tooltip 和间距调整，以及新组件 `UsageMark.vue`,属于纯 UI 改动。只看了文件名和改动量，没有逐 hunk 读，不做结论。提交: https://github.com/Project-HAMi/HAMi-WebUI/commit/7a38fc8bc309a6d61b0fcdd659263390cb97727e

### 后续发展方向 [AI]
- **多厂商物理卡纳管继续扩面**。Overview 的物理遥测已覆盖 NVIDIA、昇腾、海光 HCU/DCU、MetaX 五类，每接一家都是同一套模式：新增 `<vendor>_observations.go`、扩 `nodeMetricLabels`、在 `telemetryPlan` 加一个 case。依据是 `telemetryPlan` 的 provider 列表和 `metaxReadings`。证据边界:MetaX 只支持单 die 的 C500;只发 `metax-tech.com/gpu` 计数的原生部署没有卡 UUID,看不到读数(见 `docs/installation/helm/index.md` 本期新增段落)。没有看到多 die 型号的整卡聚合逻辑。
- **Issues 面板从「宁可多报」转向「只报确定故障」**。cordon 被视为运维意图，不再算故障，覆盖度缺口也不再在 Issues 侧显示。证据只来自前端两个 mjs 文件，没有看到后端 API 是否同步删除 `schedulable` 字段(`summary.nodes.schedulable` 仍在)。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos</summary>

- `Project-HAMi/volcano-vgpu-device-plugin`:无新提交(仍 e5b0164c / volcano-vgpu-device-plugin-1.13.0)
- `Project-HAMi/ascend-device-plugin`:无新提交(仍 9325759b / ascend-device-plugin-0.2.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=297dfaedd9a00291b4ad3f40aa367eb9581aa3a4 branch=master release=v2.11.0 scanned=2026-11-19 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=9bc18ca8f31e7f4ad92b53deb0d3fa58e5c6009f branch=main release=— scanned=2026-11-19 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=e5b0164caef64359ea10a7430a15008fa6be2ecb branch=main release=volcano-vgpu-device-plugin-1.13.0 scanned=2026-11-19 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-19 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=19a0f955a652ba7f7e4af5a9315686829e884328 branch=main release=v1.3.0 scanned=2026-11-19 -->

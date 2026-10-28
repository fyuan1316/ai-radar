# HAMi diff 雷达 2026-10-29

## 摘要
- HAMi 主仓两处实质改动,均非 vGPU/vNPU 软切分内核本身:① 调度打分修一个厂商兼容 bug——燧原(Enflame)把负数模式码 `-1` 塞进"显存百分比"字段,旧判据 `!= 0` 会把它当成有效百分比算出**负显存**,收窄为 `> 0`;② 一个较大的 Helm chart 工程化 feat,引入 `global.imageSource=upstream|cn` 一键切国内镜像源,并顺带把默认镜像源从阿里云镜像翻回上游 `registry.k8s.io`、镜像按 digest 钉死、**删掉 K8s<1.22 的老 certgen 路径**。
- 软隔离内核(HAMi-core)、Volcano 集成、昇腾 vNPU device-plugin、WebUI 四仓本期无新提交,锚点保链。
- 当日无 API/CRD/架构/版本跨档信号;唯一需留意的是 chart 删除了 `scheduler.patch.image` 系列老值(K8s<1.22 certgen),属破坏性配置面移除。

## 当日重要改变
- Project-HAMi/HAMi [弃用/移除] Helm chart 删除 K8s<1.22 的 certgen 镜像配置面(`scheduler.patch.image.*` 及模板定义 `hami.scheduler.patch.image` / `hami.scheduler.patch.imagePullSecrets`),job-patch 模板不再按 KubeVersion.Minor 分叉,统一走 `imageNew`。pin 在旧值上的 <1.22 用户升级会受影响。注:chart 配置级移除,非 CRD/flag。证据 charts/hami/templates/_helpers.tpl、job-patch/*.yaml。https://github.com/Project-HAMi/HAMi/pull/3306

## Project-HAMi/HAMi: 061001d3 -> 07c89a3f
- 比较: https://github.com/Project-HAMi/HAMi/compare/061001d37b8de1d1610bd2b00a951078cfa020b4...07c89a3f8cbda064a0e7641c354ac0770ac2a431 | ahead=2 | files=14 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)
- **调度打分收窄"百分比显存"判据,堵住厂商负数模式码算出负显存(#3313)**:`DeviceListsScore.ComputeScore` 里,当容器按百分比(非绝对 MiB)请求显存时,旧条件 `MemPercentagereq != 0 && != 101` 会把燧原设备上报的负数模式码 `-1` 当成合法百分比,`(Totalmem * (-1)) / 100` 算出**负显存**污染打分。改为 `MemPercentagereq > 0`,只把正值当百分比。这是软切分调度链路里对**多厂商(hygon/iluvatar/metax/mthreads/enflame)异构显存口径**的鲁棒性修正,不改分配语义。
  <details><summary>代码依据 pkg/scheduler/policy/gpu_policy.go</summary>

  ```diff
  -		if container.Memreq == 0 && container.MemPercentagereq != 0 && container.MemPercentagereq != 101 {
  +		// Only a positive value is a percentage: Enflame sends a negative mode
  +		// code (-1) there, which must not be scaled into negative memory.
  +		if container.Memreq == 0 && container.MemPercentagereq > 0 && container.MemPercentagereq != 101 {
  			mem += (ds.Device.Totalmem * container.MemPercentagereq) / 100
  			continue
  		}
  ```
  </details>
- **新增 `global.imageSource` 镜像源开关,上游/国内一键切(#3306)**:chart 顶层加 `imageSource: upstream`(可选 `cn`),新增模板帮手 `common.images.source` 对已知上游镜像做引用改写——`cn` 且 `global.imageRegistry` 为空时,kube-scheduler 换阿里云 `google_containers` 镜像(保留集群版本 tag、不加 digest),certgen 整体换成阿里云 certgen(索引 digest 不同故整条替换),`projecthami/hami`、`mock-device-plugin`、`lupine-server/client` 四个仓加 `m.daocloud.io/` 前缀。非法值 `fail` 报错。
  <details><summary>代码依据 charts/hami/templates/_commons.tpl</summary>

  ```diff
  +{{- define "common.images.source" -}}
  +{{- $source := $global.imageSource | default "upstream" -}}
  +{{- if not (has $source (list "upstream" "cn")) -}}
  +{{- fail "global.imageSource must be upstream or cn" -}}
  +{{- end -}}
  +{{- if and (eq $source "cn") (not $global.imageRegistry) -}}
  +  {{- if eq $image "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9@sha256:01038e7d..." -}}
  +    {{- $image = "registry.cn-hangzhou.aliyuncs.com/google_containers/kube-webhook-certgen:v1.6.9@sha256:78bf4f77..." -}}
  +  {{- else if and (hasPrefix "registry.k8s.io/kube-scheduler:" $image) (not (contains "@" $image)) -}}
  +    {{- $image = replace "registry.k8s.io/kube-scheduler:" "registry.cn-hangzhou.aliyuncs.com/google_containers/kube-scheduler:" $image -}}
  +  {{- else -}}
  +    {{- range $repository := list "docker.io/projecthami/hami" ... "ghcr.io/lupinemachines/lupine-client" -}}
  +      {{- if or (hasPrefix ...) -}}{{- $image = printf "m.daocloud.io/%s" $image -}}{{- end -}}
  ```
  </details>
- **默认镜像源翻回上游并按 digest 钉死**:随 imageSource 落地,kube-scheduler 默认 registry 从 `registry.cn-hangzhou.aliyuncs.com`(阿里云镜像)翻回 `registry.k8s.io`;`global.imageTag` 从纯 `v2.10.0` 升级为 `v2.10.0@sha256:8c45cd84...`(digest 钉死);certgen 默认仓从 `docker.io/liangjw/kube-webhook-certgen:v1.1.1` 换成 `registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9@sha256:...`;lupine-client 默认也补了 digest。默认行为由"面向中国可达性"转为"面向上游+可复现",国内用户改用 `--set global.imageSource=cn`。
  <details><summary>代码依据 charts/hami/values.yaml</summary>

  ```diff
  -  imageTag: "v2.10.0"
  +  imageTag: "v2.10.0@sha256:8c45cd84d8df3e6a8fe8c95e0141684973b5015692a0ef87588da05284f34447"
  ...
  -      registry: "registry.cn-hangzhou.aliyuncs.com"
  -      repository: "google_containers/kube-scheduler"
  +      registry: "registry.k8s.io"
  +      repository: "kube-scheduler"
  ...
  -      repository: "liangjw/kube-webhook-certgen"
  -      tag: "v1.1.1@sha256:64d8c73d..."
  +      registry: "registry.k8s.io"
  +      repository: "ingress-nginx/kube-webhook-certgen"
  +      tag: "v1.6.9@sha256:01038e7d..."
  ```
  </details>
- **移除 K8s<1.22 的 certgen 双路径分叉**:job-patch 的 createSecret / patchWebhook 两模板删掉按 `KubeVersion.Minor >= 22` 的 if/else,统一只用 `imageNew`;`_helpers.tpl` 删除 `hami.scheduler.patch.image`、`hami.scheduler.patch.imagePullSecrets` 两个旧定义。chart 不再维护 <1.22 的 jettech certgen 兜底路径。
  <details><summary>代码依据 charts/hami/templates/scheduler/job-patch/job-createSecret.yaml</summary>

  ```diff
  -      {{- if ge (regexReplaceAll "[^0-9]" .Capabilities.KubeVersion.Minor "" | int) 22 }}
  -        {{- include "hami.scheduler.patch.new.imagePullSecrets" . | nindent 6 }}
  -      {{- else }}
  -        {{- include "hami.scheduler.patch.imagePullSecrets" . | nindent 6 }}
  -      {{- end }}
  +      {{- include "hami.scheduler.patch.new.imagePullSecrets" . | nindent 6 }}
         containers:
           - name: create
  -          {{- if ge (regexReplaceAll "[^0-9]" .Capabilities.KubeVersion.Minor "" | int) 22 }}
            image: {{ include "hami.scheduler.patch.new.image" . }}
  -          {{- else }}
  -          image: {{ include "hami.scheduler.patch.image" . }}
  -          {{- end }}
  ```
  </details>

### 后续发展方向 [AI]
- 调度打分正在逐厂商打补丁收敛显存口径(本次燧原负数模式码,注释里点名 hygon/iluvatar/metax/mthreads 同属"百分比显存"分支),说明多厂商异构显存的归一化仍在 case-by-case 阶段,尚未抽象出统一的厂商显存语义层。证据只覆盖 `ComputeScore` 这一处判据,未见上游统一 schema 校验。
- chart 工程化方向明确转向"上游默认 + digest 可复现 + 镜像源开关化",并主动裁掉 K8s<1.22 兼容路径,暗示支持基线上移。证据仅覆盖 charts/ 下模板与 values,未见 go 侧对 K8s 版本下限的硬改动,实际最低版本是否随之收紧需看后续 go.mod/CI matrix。

## 本期无实质改动(折叠)
<details><summary>4 仓无新提交(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=07c89a3f8cbda064a0e7641c354ac0770ac2a431 branch=master release=v2.10.0 scanned=2026-10-29 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=6736b0589049390ec945bd40dfb4769f9f043def branch=main release=— scanned=2026-10-29 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-29 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ab41bec367ca95ac52ed1bcb8667c33e689f8f37 branch=main release=ascend-device-plugin-0.2.0 scanned=2026-10-29 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-10-29 -->
</content>
</invoke>

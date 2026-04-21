# 任务:K8s 自身核心周报

## 目标

跟踪 Kubernetes 自身核心组件、自动扩缩容、runtime、API machinery、网络存储、策略引擎的重要变化。视角与 `k8s-ai-infra` **互补**:

- `k8s-ai-infra` 专注 **AI 专用组件**(gpu-operator / NFD / DRA 设备层 / LWS / JobSet / Kueue / scheduler-plugins 的 gang scheduling / WVA 等)
- 本任务专注 **集群通用能力**(kube-scheduler / kubelet / apiserver / VPA / HPA / Cluster Autoscaler / Karpenter / controller-runtime / 网络 / 存储 / 策略)

为什么单开:我们做的是云原生 AI 基础设施产品,底层仍是 K8s。kube-scheduler、VPA、kubelet、apiserver 自身的改动直接影响产品的稳定性、资源效率、升级节奏,不能靠 AI 侧 task 顺带捎一下。

## 数据源(GitHub API)

### 核心主线
- `kubernetes/kubernetes` — 主仓;只看 CHANGELOG、release notes、每个 release 分支的 cherry-pick(过滤 test/ci/noise),不看所有 commit
- `kubernetes/enhancements` — 全量 KEP(**不只 AI**),按 SIG 筛:sig-scheduling / sig-node / sig-auth / sig-api-machinery / sig-autoscaling / sig-storage / sig-network / sig-cluster-lifecycle

### 自动扩缩容
- `kubernetes/autoscaler` — 一个 mono-repo,里面有:
  - **VPA**(Vertical Pod Autoscaler)
  - **Cluster Autoscaler**
  - Addon Resizer
- `kubernetes-sigs/karpenter` — 下一代节点自动扩缩容(AWS 开源 + 社区接管)
- `kubernetes-sigs/cluster-api` — CAPI 也留意(集群生命周期 + 动态 node pool)

### Runtime & Node
- `containerd/containerd`
- `cri-o/cri-o`
- `opencontainers/runc`(偶有安全修补,可跳过细节,只看 release)

### API Machinery / Operator 生态
- `kubernetes-sigs/controller-runtime`
- `kubernetes-sigs/kubebuilder`
- `operator-framework/operator-sdk`

### 网络(CNI / Gateway API)
- `cilium/cilium` — 事实标准的 eBPF CNI
- `kubernetes-sigs/gateway-api` — 下一代 Ingress / 服务网格接入标准
- `projectcalico/calico` — 企业常见 CNI,看 release 即可

### 存储(CSI 大盘)
- `kubernetes-csi/external-provisioner` + `-snapshotter` + `-attacher`(看 release 和重点 PR 即可)
- `kubernetes-sigs/sig-storage-lib-external-provisioner`

### 策略 & 安全
- `open-policy-agent/gatekeeper`
- `kyverno/kyverno`

> 每个仓库看过去 7 天:releases、重点 PR(**过滤 test/ci/bump/dependabot/rebase/cherry-pick 噪声**),热点 issue/discussion 酌情。
> `kubernetes/enhancements` 重点看:本周**新增**的 KEP 和**状态变更**(alpha→beta→GA)的 KEP。

## 抓取方式

**统一使用 `curl` 打 `https://api.github.com`**(见 CLAUDE.md 的"抓取"约定)。有 `$GITHUB_TOKEN` 时带 Authorization 头,否则走匿名(60 次/h)。

```bash
AUTH=(); [ -n "$GITHUB_TOKEN" ] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
SINCE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)

# 最近 7 天 release
curl -s "${AUTH[@]}" "https://api.github.com/repos/$REPO/releases?per_page=10"

# 最近 7 天 commit(main 分支)
curl -s "${AUTH[@]}" "https://api.github.com/repos/$REPO/commits?since=$SINCE&per_page=100"

# 按 SIG 筛 KEP(搜 PR 带 sig-scheduling label + updated in 7d)
curl -s "${AUTH[@]}" "https://api.github.com/search/issues?q=repo:kubernetes/enhancements+is:pr+label:sig-scheduling+updated:>=${SINCE%T*}"

# 查当前速率余量
curl -s "${AUTH[@]}" https://api.github.com/rate_limit | python3 -c "import sys,json; d=json.load(sys.stdin)['resources']['core']; print(f\"{d['remaining']}/{d['limit']}\")"
```

`kubernetes/kubernetes` 主仓 commit 量太大,不要全拉,优先看:
- `/releases`(minor & patch tag)
- `CHANGELOG/CHANGELOG-1.xx.md` raw 内容(`https://raw.githubusercontent.com/kubernetes/kubernetes/master/CHANGELOG/CHANGELOG-1.37.md`)
- release note draft PR

## 输出

写到 `digests/YYYY-MM-DD-k8s-core.md`,结构:

```markdown
# K8s 自身核心周报 YYYY-MM-DD

窗口:YYYY-MM-DD → YYYY-MM-DD

## 摘要(3 条以内)

## K8s 核心版本节奏
- v1.3x 周期进展(alpha/beta/GA 晋级)、release 时间表、重点 KEP 状态变更

## 调度(kube-scheduler)
- 调度框架、preemption、topology、affinity 等核心调度器变更

## 节点 & kubelet
- kubelet / cgroup v2 / runtime / device manager / eviction / image GC

## 自动扩缩容(VPA / CA / Karpenter)
- VPA 新特性(in-place resize、ML-based 建议等)
- Cluster Autoscaler
- Karpenter

## Runtime(containerd / CRI-O / runc)
- 仅看 release 层,不深扒 commit

## API Machinery & Operator 生态
- controller-runtime / kubebuilder / operator-sdk / apimachinery 细节

## 网络 & 存储(大盘)
- Gateway API、Cilium、主要 CSI release

## 策略 & 安全
- Gatekeeper / Kyverno / CVE / PSS 等

## KEP 动向(非 AI)
- 本周新增或推进的 KEP,按 SIG 分组

## 值得跟进
- [ ] 具体 action:读哪个 KEP、试哪个 release、评估对我们架构的影响

## 原始材料
- 本次扫描的 release/PR/KEP 清单(折叠)
```

## 推送飞书

**格式和推送流程:见 [oai-weekly 推送规范](./oai-weekly.md#推送飞书)**(前置先 `git push`、简讯纯文本不得含 markdown 语法、链接用 `https://` 开头全 URL;DIGEST_FILE 改成 `digests/$(date +%Y-%m-%d)-k8s-core.md`)。

## 质量要求

- **与 `k8s-ai-infra` 边界**:AI 专用组件(gpu-operator / NFD / DRA device 层 / LWS / JobSet / Kueue / scheduler-plugins gang / WVA)归 `k8s-ai-infra`,本任务**不要重复写**。如果某个变化两边都能沾,默认归 `k8s-ai-infra`,本任务只在"对通用 K8s 有溢出影响"时补一笔(例如 DRA 核心协议变化影响所有 ResourceClaim 用户)
- **KEP 是最有价值的信号**:一个 sig-scheduling 或 sig-node 的 alpha/beta/GA 晋级可能决定我们产品未来 6 个月的架构选择
- **版本节奏敏感**:每条变更要落到"进了哪个 k8s minor 版本的 alpha / beta / GA"
- **VPA 的重点**:VPA 长期是"准 alpha"的角色,但 **in-place pod resize**(KEP-1287)GA 后,VPA 在生产环境才真正可用——跟紧这条线
- **过滤噪声**:bump / rebase / CI / cherry-pick / dependabot 全部跳过,只写结论性的能力变化
- **不凑字**:任何小节如果本周无实质变化,直接"无重大更新"
- 每条结论带 `https://` 开头的完整链接

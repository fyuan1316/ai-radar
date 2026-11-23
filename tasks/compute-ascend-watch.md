# 任务:昇腾(Ascend)算力栈 diff 雷达

## 目标
按 commit 区间跟踪昇腾 NPU 在 K8s 上的算力栈(驱动容器化/runtime → device-plugin/DRA → 监控 → 调度 → operator)的**代码级变化**,从 diff 判断功能趋势与重要改变。机制同 [hami-watch](./hami-watch.md)。

取数走 GitCode 的 **Gitee 风格 v5 API**(`https://api.gitcode.com/api/v5`),用 `hack/diff-scan-gitcode.sh`。**不需要 clone**:已实测 compare 端点 `repos/{owner}/{repo}/compare/{base}...{head}` 匿名可用、返回 `files[].patch`(真实 hunk)+ `truncated` 标志,与 GitHub compare 同构。(早期"必须 clone"的判断已作废——WebFetch 拿不到的是网页/raw 文件内容,不是 REST API。)若被限流,在 `.env` 配 `GITCODE_TOKEN`(走 `PRIVATE-TOKEN` 头)。

## 与其他 task 的边界(硬约束)
- 本 task 管 **昇腾供应商算力栈的代码实现**(diff 视角)。
- HAMi 对昇腾的 vNPU 虚拟化归 `hami-watch`(按项目);`openfuyao-weekly` 保留"扶摇社区路线对标 OAI/KServe"的**新闻视角**,本 task 与它重叠的 repo(npu-operator 等)只做代码 diff、不做社区对标。

## 数据源(GitCode v5 API,用 hack/diff-scan-gitcode.sh,参数是 owner/repo)
> 关键结构:昇腾 K8s 全栈组件**不是独立仓**,全在 `Ascend/mind-cluster` 的 `component/` 子目录里(已核实:ascend-device-plugin / ascend-docker-runtime / ascend-for-volcano / ascend-operator / npu-exporter / noded / clusterd / infer-operator …)。一个 repo 全覆盖,helper 用 PATHPREFIX 参数按 component/ 限定方向(client-side 过滤 files)。

| owner/repo | 优先级 | 覆盖 |
|---|---|---|
| `Ascend/mind-cluster` | P0 | 昇腾 device-plugin / docker-runtime / for-volcano 调度 / operator / npu-exporter / noded(driver runtime + 调度 + 监控全在此) |
| `openFuyao/npu-operator` | P0 | Operator Framework 管驱动/固件/device plugin,含 vNPU/断点续训 |
| `openFuyao/npu-container-toolkit` | P0 | 容器内 NPU 可见性,**对标 nvidia-container-toolkit** |
| `openFuyao/npu-driver-installer` | P0 | **NPU 驱动容器化安装**(用户底座核心,对标 gpu-driver-container) |
| `openFuyao/vNPU` | P0 | **NPU 虚拟化/切分**(对标 HAMi vGPU,vCANN) |
| `openFuyao/npu-node-provision` | P1 | NPU 节点准备/provision |
| `openFuyao/npu-dra-plugin` | P1 | 昇腾接 K8s DRA |
| `openFuyao/npu-feature-discovery` | P1 | **NPU 型号发现 + 节点打标**(对标 NFD),npu-operator→调度器的标签来源,新机型纳管最早信号 |
| `openFuyao/volcano-ext` | P2 | Volcano NPU 拓扑亲和扩展 |
| `openFuyao/ub-network-device-plugin` | P2 | UB 超低时延网络 device plugin(多机训练 fabric) |
| `openFuyao/ub-network-bandwidth-operator` | P2 | UB 带宽配置 operator(同 fabric 主线,configmap 下发带宽) |

> **定期核对组织清单**:每隔若干期跑 `curl -s "https://api.gitcode.com/api/v5/orgs/openFuyao/repos?per_page=100&page=N"`(N=1..3,`orgs` 端点比网页可靠)拉全量仓库名,把新出现的 NPU/算力相关仓补进表里。2026-11-23 据此补入 `npu-feature-discovery`(活跃却长期漏扫)与 `ub-network-bandwidth-operator`。
> **空壳仓待观察**(只有 Initial commit、无代码,暂不纳入扫描):`equivalent-compute-unit`(2026-11-18 建仓,"算力等效单元",异构算力折算/配额等效,与我们产品多厂商统一计量直接相关)、`compute-fusion`(2026-10-23 建仓)。出代码即纳管。
> **已知盲区**:GitCode compare 只跟默认分支,各仓在 feature 分支上的开发会被整体漏掉。

## 执行步骤
1. mind-cluster(用 PATHPREFIX 限定 component 子目录,避免文档/构建噪声):
   ```bash
   ./hack/diff-scan-gitcode.sh Ascend/mind-cluster compute-ascend-watch \
     component/ascend-device-plugin component/ascend-docker-runtime component/ascend-for-volcano \
     component/ascend-operator component/npu-exporter component/noded component/clusterd component/infer-operator \
     component/ascend-dynamic-resource-allocation component/ascend-common \
     component/ascend-clusterops-agent component/ascend-faultdiag component/ascend-faultdiag-online \
     component/container-manager
   ```
   > PATHPREFIX 漏项会**静默过滤**整条主线,踩过两次:`ascend-dynamic-resource-allocation`/`ascend-common`(DRA 主线)、`ascend-clusterops-agent`/`ascend-faultdiag`(运维 Agent + 故障诊断,2026-11-21 那期 145 个改动文件里有 128 个在这两个目录)。2026-11-24 第三次:`component/container-manager`(容器侧卡死/设备重置管理,与 device-plugin 卡死检测同一提交)不在清单;`ascend-faultdiag-online`(在线慢节点/网络故障算法)只是被 `ascend-faultdiag` 前缀碰巧匹配,一并显式补入。新增 component 时先跑一次不带 PATHPREFIX 的 compare 核对目录分布。
2. 其余 openFuyao 仓(全仓,不限 path):
   ```bash
   for r in npu-operator npu-container-toolkit npu-driver-installer vNPU \
            npu-node-provision npu-dra-plugin npu-feature-discovery \
            volcano-ext ub-network-device-plugin ub-network-bandwidth-operator; do
     ./hack/diff-scan-gitcode.sh "openFuyao/$r" compute-ascend-watch
   done
   ```
3. `__EMPTY__` 跳过正文保锚点;非空写研判。锚点 repo 名 = owner/repo 的 basename(mind-cluster / npu-operator / …)。
4. 注意:GitCode compare 的 commits 是整区间、**不按 path 细分**,故"实质提交"列表可能含其他 component 的提交;但"信号文件/patch 节选"已按 PATHPREFIX 限定,以后者为准写研判。`truncated=true` 时大区间可能漏文件,降低 base 跨度(提高频率)即可。

## 输出 / 重要改变信号 / 推送飞书 / 质量要求
沿用 [hami-watch](./hami-watch.md) 对应各节(含"AI 总结重点必须读 patch 写符号级、每条贴代码依据"的硬要求 —— GitCode compare 同样返回真实 patch,昇腾 commit 多为中文流水账,**更要靠代码 diff 而非 commit 标题**),task 名 `compute-ascend-watch`、DIGEST_FILE=`digests/$(date +%Y-%m-%d)-compute-ascend-watch.md`。**GitCode 唯一降级**:compare 给 files+patch 但**不给 PR label/milestone**,故"重要改变信号"里 `[架构方向]` 这类需结合改动文件路径 + 提交标题判断。空日全 EMPTY 只归档不推飞书。

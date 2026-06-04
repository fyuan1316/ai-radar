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
| `openFuyao/volcano-ext` | P2 | Volcano NPU 拓扑亲和扩展 |
| `openFuyao/ub-network-device-plugin` | P2 | UB 超低时延网络 device plugin(多机训练 fabric) |

> 建文件时若 openFuyao SIG-installation 下有 `npu-driver-installer`/`npu-node-provision` 等驱动容器化新仓,补进 P1(先 `WebFetch https://gitcode.com/openFuyao` 拿最新清单)。

## 执行步骤
1. mind-cluster(用 PATHPREFIX 限定 component 子目录,避免文档/构建噪声):
   ```bash
   ./hack/diff-scan-gitcode.sh Ascend/mind-cluster compute-ascend-watch \
     component/ascend-device-plugin component/ascend-docker-runtime component/ascend-for-volcano \
     component/ascend-operator component/npu-exporter component/noded component/clusterd component/infer-operator
   ```
2. 其余 openFuyao 仓(全仓,不限 path):
   ```bash
   for r in npu-operator npu-container-toolkit npu-driver-installer vNPU \
            npu-node-provision npu-dra-plugin volcano-ext ub-network-device-plugin; do
     ./hack/diff-scan-gitcode.sh "openFuyao/$r" compute-ascend-watch
   done
   ```
3. `__EMPTY__` 跳过正文保锚点;非空写研判。锚点 repo 名 = owner/repo 的 basename(mind-cluster / npu-operator / …)。
4. 注意:GitCode compare 的 commits 是整区间、**不按 path 细分**,故"实质提交"列表可能含其他 component 的提交;但"信号文件/patch 节选"已按 PATHPREFIX 限定,以后者为准写研判。`truncated=true` 时大区间可能漏文件,降低 base 跨度(提高频率)即可。

## 输出 / 重要改变信号 / 推送飞书 / 质量要求
沿用 [hami-watch](./hami-watch.md) 对应各节(含"AI 总结重点必须读 patch 写符号级、每条贴代码依据"的硬要求 —— GitCode compare 同样返回真实 patch,昇腾 commit 多为中文流水账,**更要靠代码 diff 而非 commit 标题**),task 名 `compute-ascend-watch`、DIGEST_FILE=`digests/$(date +%Y-%m-%d)-compute-ascend-watch.md`。**GitCode 唯一降级**:compare 给 files+patch 但**不给 PR label/milestone**,故"重要改变信号"里 `[架构方向]` 这类需结合改动文件路径 + 提交标题判断。空日全 EMPTY 只归档不推飞书。

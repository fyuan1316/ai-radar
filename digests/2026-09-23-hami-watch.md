# HAMi diff 雷达 2026-09-23

## 摘要
- **HAMi-core 补软隔离释放路径漏洞**:`remove_chunk` 对"本 allocator 链没跟踪到的指针"(如 stream-ordered 分配走到同步 free 路径)不再返回 `-1` 空转,而是转发给真实 driver `cuMemoryFree`,避免分配泄漏并把陌生 CUresult 甩给调用方。
- **volcano-vgpu 加固分配一致性**:`getOldestPod` 只挑 `Pending` Pod 参与冲突裁决;`PatchPodAnnotations` 从"一次尽力 patch"升级为 3 次重试 + 回读校验(`verifyPodAnnotations`),防注解写入丢失导致重复投放。
- HAMi 主仓本期仅 6 条 dependabot bump,ascend-device-plugin / HAMi-WebUI 无新提交。

## 当日重要改变(命中信号才列;无则写"无")
- 无(本期改动均为 bugfix / 健壮性,未命中 弃用·API/CRD·架构·版本跨档·新能力 信号)

## Project-HAMi/HAMi-core: a5231c7f -> 410dfbe9
- 比较: a5231c7f4524e5d98f5200fde47f97b06356fcbe -> 410dfbe9 | ahead=4 | files=3 | Release: —

### AI 总结重点(源码 diff 为据)
- **`remove_chunk()` 两条"未跟踪指针"分支从返回 `-1` 改为透传到真实 driver `cuMemoryFree(dptr)`**。前:链为空、或遍历完仍未命中该 `CUdeviceptr` 时直接 `return -1`,分配仍存活、调用方收到无法识别的错误码;后:两处都转发给底层 driver 真正释放。注释点名根因是 stream-ordered 分配(异步分配)走到同步 free 路径时不在本链登记,行为对齐 `remove_chunk_async` 的 not-found 分支。这是 HAMi-core 显存跟踪表与真实 driver 状态一致性的修复,属软隔离能力边界的正确性补强,不是新增 hook 类型。
  <details><summary>代码依据 src/allocator/allocator.c</summary>

  ```diff
      if (a_list->length == 0) {
  -       return -1;
  +       /* Nothing tracked here, so the pointer was not allocated through this
  +        * list. Forward the free to the real driver rather than returning -1 */
  +       return cuMemoryFree(dptr);
      }
      ...
      pthread_mutex_unlock(&mutex);
  -   return -1;
  +   /* Not tracked in this list (e.g. a stream-ordered allocation reaching the
  +    * synchronous free path): forward the free to the real driver instead of
  +    * returning -1 ... Mirrors the not-found path in remove_chunk_async. */
  +   return cuMemoryFree(dptr);
  ```
  </details>
  证据:https://github.com/Project-HAMi/HAMi-core/commit/6546ba9a
- **`security-insights.yml` 重构漏洞披露元数据**:`schema-version` 从 2.2.0 回退到 2.1.0(修可解析性),`policy` 键改名 `security-policy`,并把 `in-scope`/`out-of-scope` 结构化字段挪进自由文本 `comment`。内容上明确宣示 HAMi-core 的安全边界:租户越权拿到别人 GPU 内存/设备/命名空间属 in-scope;而"通过 unset LD_PRELOAD / 静态链接 CUDA runtime / 对自身进程 ptrace 越过自己配额"属 out-of-scope——即 HAMi-core 是**可信集群上的协作式配额机制,不是硬隔离边界**。这是文档/合规声明,非代码能力变化。
  <details><summary>代码依据 security-insights.yml</summary>

  ```diff
  -    policy: https://github.com/Project-HAMi/HAMi/security/policy
  -    in-scope:
  -      - A workload reaching another tenant's GPU memory, device or namespace
  -    out-of-scope:
  -      - A workload exceeding its own GPU quota by unsetting LD_PRELOAD
  +    security-policy: https://github.com/Project-HAMi/HAMi/security/policy
  +    comment: |
  +      In scope: a workload reaching another tenant's GPU memory ...
  +      Out of scope: a workload exceeding its own GPU quota by unsetting
  +      LD_PRELOAD, by linking the CUDA runtime statically, or by calling ptrace
  ```
  </details>
  证据:https://github.com/Project-HAMi/HAMi-core/commit/b6d21024

### 后续发展方向 [AI]
- allocator 这次把"未跟踪指针"统一透传 driver,说明 HAMi-core 正在把异步(stream-ordered)与同步分配的跟踪表做一致性收口;证据只覆盖 `remove_chunk` 同步路径与其对 `remove_chunk_async` 的对齐,未见异步侧是否也有对称改动或引入统一跟踪结构。
- security-insights 明确"软配额 ≠ 硬隔离"的对外定调,对我们产品的启示:若要对标硬多租隔离,HAMi-core 单靠 CUDA hook 不够,需叠加 MIG/内核态或可信执行边界;这是声明层证据,非代码层。

## Project-HAMi/volcano-vgpu-device-plugin: 806072e6 -> 6063efe9
- 比较: 806072e6eb8594f1989913085ad4b87bc5d61af5 -> 6063efe9 | ahead=2 | files=6 | Release: —

### AI 总结重点(源码 diff 为据)
- **`getOldestPod()` 新增 `Pending` 相位过滤**:遍历候选 Pod 时先跳过一切非 `v1.PodPending` 的 Pod。前:所有 Pod(含 Running/Failed 等)都可能被当作"最老待分配 Pod"参与设备冲突裁决,可能把已落位或已终态的 Pod 误判为待分配;后:只有真正 Pending 的才参与,收窄冲突解决的候选集。这是 commit "Resolve GPU allocation conflict" 的核心。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
   for _, pod := range pods {
  +    if pod.Status.Phase != v1.PodPending {
  +        klog.V(3).Infof("GetOldestPod -- Skip non-pending pod: %s, phase: %s", pod.Name, pod.Status.Phase)
  +        continue
  +    }
       if pod.Annotations[AssignedNodeAnnotations] == nodename {
  ```
  </details>
  证据:https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/6fb9a0b9
- **`PatchPodAnnotations()` 从单次 best-effort 升级为"重试 + 回读校验"**:新增 `maxRetries=3` / `retryInterval=500ms`,每次 patch 成功后调用新函数 `verifyPodAnnotations` 重新 `Get` Pod 并逐键比对注解是否真正落库,不一致或 patch 失败则重试,三次仍败返回 `lastErr`(前一版 patch 失败只打 log 后 `return err`,不校验落库)。目的:防注解写入丢失/被覆盖导致设备重复分配。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  -   _, err = client.GetClient().CoreV1().Pods(pod.Namespace).
  -       Patch(context.Background(), pod.Name, k8stypes.StrategicMergePatchType, bytes, metav1.PatchOptions{})
  -   if err != nil {
  -       klog.Infof("patch pod %v failed, %v", pod.Name, err)
  -   }
  -   return err
  +   var lastErr error
  +   for attempt := 1; attempt <= maxRetries; attempt++ {
  +       _, err = client.GetClient().CoreV1().Pods(pod.Namespace).Patch(...)
  +       if err != nil { lastErr = ...; time.Sleep(retryInterval); continue }
  +       // Patch succeeded, verify annotations consistency
  +       err = verifyPodAnnotations(pod, annotations)
  +       if err == nil { return nil }
  +       lastErr = ...; time.Sleep(retryInterval)
  +   }
  +   return lastErr
  ```
  </details>
  证据:https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/6fb9a0b9
- **klog 日志级别可经 `KLOG_LEVEL` 环境变量配置**:`cmd/vgpu` 与 `cmd/vgpu-monitor` 各新增 `init()`,用独立 `flag.NewFlagSet`(刻意不注册到 `flag.CommandLine`,避开 urfave/cli 的 `-v` version 冲突),读 `KLOG_LEVEL` 环境变量(默认 "2")设日志级别;Helm `values.yaml` 增 `logging.klogLevel`、daemonset 模板与 static yaml 注入该 env。运维可调日志噪声,不改逻辑。
  <details><summary>代码依据 cmd/vgpu/main.go + daemonset.yaml</summary>

  ```diff
  +func init() {
  +    klogFlags := flag.NewFlagSet("klog", flag.ContinueOnError)
  +    klog.InitFlags(klogFlags)
  +    level := os.Getenv("KLOG_LEVEL")
  +    if level == "" { level = "2" }
  +    _ = klogFlags.Set("v", level)
  +}
  ---
  +        - name: KLOG_LEVEL
  +          value: {{ .Values.logging.klogLevel | quote }}
  ```
  </details>
  证据:https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/6fb9a0b9

### 后续发展方向 [AI]
- 这批改动集中在 volcano 集成路径的**分配一致性/幂等**:Pending 过滤 + patch 回读校验,指向 HAMi×Volcano 在高并发调度下曾有注解丢失/误判导致重复投放的实战问题。证据只覆盖 `util.go` 的两处;未见调度器侧(volcano scheduler plugin)是否有配套改动。
- KLOG_LEVEL 可配是可运维性小步;对我们产品启示有限,记为集成成熟度信号。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅 bump/CI/merge 或无新提交)</summary>

- **Project-HAMi/HAMi**:ahead=6,全部 dependabot bump(gomega / nvidia-container-toolkit / grpc / codeql-action / codecov-action / ginkgo),无逻辑改。
- **Project-HAMi/ascend-device-plugin**:无新提交。
- **Project-HAMi/HAMi-WebUI**:无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=6531fdd97682642eccf10caefc13da418b3bba7e branch=master release=v2.10.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=410dfbe999f1fadca3039cd629823c4534fdd90a branch=main release=— scanned=2026-09-23 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-09-23 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=074d93a8e1ca4f357fb1f4946f0566ced93641a6 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=b2af8ecc94a2330a6f11ab189522f16f328495bd branch=main release=v1.3.0 scanned=2026-09-23 -->

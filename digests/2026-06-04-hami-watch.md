# HAMi diff 雷达 2026-06-04

## 摘要
- HAMi 主仓给 scheduler 的 chart RBAC 加了一整组 DRA(resource.k8s.io)资源读权限,面向 K8s 1.34+,是软切分调度器开始与原生 DRA 资源模型对接的信号。 https://github.com/Project-HAMi/HAMi/pull/1917
- ascend-device-plugin 重构 gRPC server 生命周期:把 `grpcServer` 创建从构造期移到 `Start()`,`Stop()` 改成幂等并加 `WaitGroup`,实现可重启不 panic + 优雅停机。 https://github.com/Project-HAMi/ascend-device-plugin/pull/84
- HAMi-core / volcano-vgpu-device-plugin / HAMi-WebUI 本期无实质改动(仅保锚点)。

## 当日重要改变
- Project-HAMi/HAMi [架构方向] scheduler clusterrole 新增 `resource.k8s.io` 下 deviceclasses/resourceclaims/resourceclaimtemplates/resourceslices 的 get/list/watch 权限,为 K8s 1.34+ DRA 路径铺路。证据:charts/hami/templates/scheduler/clusterrole.yaml。 https://github.com/Project-HAMi/HAMi/pull/1917

## Project-HAMi/HAMi: c005cbd1 -> 8f0664b0
- 比较: c005cbd15ca164d461aa50a50feb7c2f42af7910 -> 8f0664b0 | ahead=5 | files=8 | Release: v2.9.0
- 比较页:https://github.com/Project-HAMi/HAMi/compare/c005cbd15ca164d461aa50a50feb7c2f42af7910...8f0664b0fac7d9a356d808a67a4640002bd24f7b

### AI 总结重点(源码 diff 为据)
- scheduler 的 ClusterRole 新增一条 `resource.k8s.io` apiGroup 规则,授予 `deviceclasses`、`resourceclaims`、`resourceclaimtemplates`、`resourceslices` 四类 DRA 核心资源的 `get/list/watch`。改前 scheduler 只读 core/调度相关资源(pods、nodes、resourcequotas 等),改后它具备了观察 DRA 资源对象的权限——这是 HAMi 调度器准备在 K8s 1.34+ 上感知/协同原生 DRA 资源声明的前置条件(纯软切分调度无需这些权限)。
  <details><summary>代码依据 charts/hami/templates/scheduler/clusterrole.yaml</summary>

  ```diff
    - apiGroups: [""]
      resources: ["resourcequotas"]
      verbs: ["get", "list", "watch"]
  +  - apiGroups: ["resource.k8s.io"]
  +    resources: ["deviceclasses", "resourceclaims", "resourceclaimtemplates", "resourceslices"]
  +    verbs: ["get", "list", "watch"]
  ```
  </details>
- 构建系统从按架构传参改为按平台传参:`version.mk` 把 `TARGET_ARCH=amd64` 替换为 `TARGET_PLATFORMS=linux/amd64`,Makefile 的 `docker build` 相应用 `--platform ${TARGET_PLATFORMS}` 取代 `--build-arg TARGET_ARCH`。语义上从"传一个架构字符串进 Dockerfile"转为"用 buildx 的原生多平台参数",为后续多 arch(如 arm64)镜像构建做铺垫。
  <details><summary>代码依据 version.mk / Makefile</summary>

  ```diff
  - TARGET_ARCH=amd64
  + TARGET_PLATFORMS=linux/amd64
  ---
    docker build \
  + --platform ${TARGET_PLATFORMS} \
    --build-arg GOLANG_IMAGE=${GOLANG_IMAGE} \
  - --build-arg TARGET_ARCH=${TARGET_ARCH} \
  ```
  </details>
- 四个 Dockerfile(Dockerfile / .withlib / .hamimaster / .hamicore)运行时基础镜像统一从 `nvidia/cuda:13.2.1-base-ubuntu22.04` 升到 `13.3.0-base-ubuntu22.04`,只是 CUDA 基础镜像补丁位 bump,无功能含义。
  <details><summary>代码依据 docker/Dockerfile.hamicore(其余三个同样)</summary>

  ```diff
  - FROM nvidia/cuda:13.2.1-base-ubuntu22.04
  + FROM nvidia/cuda:13.3.0-base-ubuntu22.04
  ```
  </details>
- 其余两条为纯测试增量(`pkg/util/util_test.go` +44):给 `GetGPUSchedulerPolicyByPod`(从 pod 注解 `hami.io/...gpu-scheduler-policy` 取调度策略,缺省回落 defaultPolicy)和 `SchedulerPolicyName.String()`(binpack/spread/topology-aware 枚举映射)补单测,反映 binpack/spread/topology-aware 三档 GPU 调度策略仍是稳定 API,无行为变更。

### 后续发展方向 [AI]
- DRA 是明确方向:RBAC 已先行授予 DRA 资源读权限(配合上一篇区间里 kube-scheduler DRA 适配),但本期 diff 只看到 chart 层权限,**未见调度器 Go 代码里真正消费 resourceclaims 的逻辑**——证据只覆盖"权限就位",未覆盖"调度逻辑接入",需后续盯 pkg/scheduler 下是否出现 resource.k8s.io client。
- 构建链转向 `--platform`,是 HAMi 走多架构镜像(arm64,贴合昇腾/国产 CPU 场景)的早期信号,但当前 `TARGET_PLATFORMS` 仍只列 `linux/amd64`,尚未真正多平台。

## Project-HAMi/ascend-device-plugin: a27ce4a1 -> 799eaa34
- 比较: a27ce4a190a65c7bfbe9732de0b1ff65f1ce5a34 -> 799eaa34 | ahead=3 | files=3 | Release: —
- 比较页:https://github.com/Project-HAMi/ascend-device-plugin/compare/a27ce4a190a65c7bfbe9732de0b1ff65f1ce5a34...799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b

### AI 总结重点(源码 diff 为据)
- gRPC server 的生命周期从"构造即创建、停了不能再起"改为"每次 Start() 重建、可安全重启"。`NewPluginServer` 不再在构造时 `grpcServer: grpc.NewServer()`,改为在 `Start()` 里 `ps.grpcServer = grpc.NewServer()`。原因:`grpc.Server.Stop()` 后的实例不可复用,旧写法导致设备插件被 kubelet 触发重启时拿着已停的 server 而 panic;新写法每轮 Start 都拿全新 server。
  <details><summary>代码依据 internal/server/server.go</summary>

  ```diff
    server := &PluginServer{
  -   grpcServer:            grpc.NewServer(),
      mgr:                   mgr,
  ...
    func (ps *PluginServer) Start() error {
  -   if err := prepareHostResources(); err != nil {
  +   if err := ps.prepareHostResources(); err != nil {
        ...
      }
      ps.stopCh = make(chan interface{})
  +   ps.grpcServer = grpc.NewServer()
  ```
  </details>
- `Stop()` 从"无脑 close + Stop"改为幂等优雅停机:对 `stopCh` 用 `select` 探测避免重复 close 导致 panic、对 `grpcServer` 做 nil 判空、新增 `ps.wg.Wait()` 等待后台 goroutine 退出、并 `os.Remove(ps.socket)` 清理 unix socket 文件。配套给 `startPeriodicCheckIdleVNPUs`、`watchAndRegister`、`serve` 内的 goroutine 都加了 `wg.Add(1)/defer wg.Done()`,让停机真正等到 goroutine 收敛。
  <details><summary>代码依据 internal/server/server.go</summary>

  ```diff
    func (ps *PluginServer) Stop() error {
  -   close(ps.stopCh)
  -   ps.grpcServer.Stop()
  +   if ps.stopCh != nil {
  +     select {
  +     case <-ps.stopCh:  // already closed; no-op
  +     default:
  +       close(ps.stopCh)
  +     }
  +   }
  +   if ps.grpcServer != nil {
  +     ps.grpcServer.Stop()
  +   }
  +   ps.wg.Wait()
  +   _ = os.Remove(ps.socket)
      return nil
    }
  ```
  </details>
- 引入测试注入钩子(`dialFunc` / `registerKubeletFunc` / `prepareHostResourcesFunc`),让 `registerKubelet`、`dial`、`prepareHostResources` 在测试里可绕过真实 socket/kubelet 依赖;配套 server_test.go +182 行加了 `RestartDoesNotPanic` 类用例(含把 grpc Fatalf 转 panic 的 logger 以断言不触发 os.Exit)。属可测性改造,非运行时能力变更。

### 后续发展方向 [AI]
- 这是把 Ascend vNPU 设备插件做"生产健壮性"加固:可重启不 panic + 优雅停机 + socket 清理,意味着该插件正从能跑向"可被 kubelet 反复拉起/驱逐而不崩"演进。证据只覆盖 internal/server 的生命周期重构,**未见 vNPU 切分/算力隔离逻辑本身的改动**(idle vNPU 回收逻辑只是被加了 wg 计数,语义未变)。

## 本期无实质改动(折叠)
<details><summary>3 个仓本期仅保锚点,无实质提交</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=8f0664b0fac7d9a356d808a67a4640002bd24f7b branch=master release=v2.9.0 scanned=2026-06-04 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=4bbd97ad48a5ca82149fe89787d2df7ac855e465 branch=main release=— scanned=2026-06-04 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=7aba185031fd2f6169885b9c94cfbe1dfc5b788f branch=main release=— scanned=2026-06-04 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-04 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-04 -->

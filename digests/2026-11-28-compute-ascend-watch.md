# 昇腾算力栈 diff 雷达 2026-11-28

## 摘要

- **k8s-rdma-shared-dev-plugin 部署契约改了**:16 个预定义 NAD(`ens0f0`..`ens3f3`)从组件主部署 YAML `k8s-rdma-shared-dp.yaml` 里整块摘除,搬到新文件 `k8s-rdma-shared-dp-nad.yaml`,并在 helm chart 里新增按 Multus CRD 能力条件渲染的 `templates/nad.yaml`。动因是 NAD 属于 Multus 提供的 CRD,未装 Multus 时整个 `kubectl apply -f k8s-rdma-shared-dp.yaml` 会连带报错、回显不友好。既有用户升级后"一条 apply 同时拉起 DaemonSet + NAD"的行为不再成立。
- **ascend-docker-runtime 三引擎(docker/containerd/CRI-O)入口校验与 TOML 清理路径合并**:新增共享 `parseAndValidateCommand` / `deleteRuntimeAndEmptyParents` / `deleteConfigPath`。表面是"重复代码优化",实际 containerd 与 CRI-O 两条路径的**源文件缺失时的校验被收紧**(原来不校验,现在要求父目录通过 `RealDirChecker`),且 containerd 的空父节点删除错误从**静默丢弃**改为向上返回。三引擎各补两个回归用例锁定新行为。
- **ascend-faultdiag 时间基准解析从"首行即定生死"改为"跳过坏行取首个可用行"**:`_parse_time_reference` 遇到字段缺失/时间非法/日期为 `1970-01-01`(底板时钟未同步)的 `[ERROR] KERNEL` 参照行不再直接返回 `None`,改为 `continue`。这条直接决定 kernel.log 开机时长→实际时间的换算是否可用。
- 其余 10 个 openFuyao 仓(npu-operator / vNPU / npu-dra-plugin / npu-container-toolkit / npu-driver-installer / npu-node-provision / npu-feature-discovery / volcano-ext / ub-network-device-plugin / ub-network-bandwidth-operator)本期**零新提交**,HEAD 自 11-27 冻结。

## 当日重要改变

- **mind-cluster [弃用/移除]** `component/k8s-rdma-shared-dev-plugin/build/k8s-rdma-shared-dp.yaml` 第 219 行起的 263 行 NAD 定义块被删除(该文件只剩 DaemonSet/ConfigMap 等),16 个 NAD 迁至新增文件 `k8s-rdma-shared-dp-nad.yaml`;`build/build.sh` 的 `mv_file()` 同步把新文件拷进 `output/`,文档明确要求"部署 Multus CNI 后,于 YAML 所在路径 `kubectl apply -f k8s-rdma-shared-dp-nad.yaml`"。https://gitcode.com/Ascend/mind-cluster/commit/413d08ba993fa9325401272dc2ecef6631001ef3
- **mind-cluster [新能力]** helm 侧新增 `helm-deploy-tool/app/charts/k8s-rdma-shared-dev-plugin/templates/nad.yaml`:以 `.Capabilities.APIVersions.Has "k8s.cni.cncf.io/v1/NetworkAttachmentDefinition"` 为总开关,集群没装 Multus 就整块不渲染;内部 glob `yamls/nad/**.yaml` 并逐文件 `tpl` 渲染,**匹配不到文件直接 `fail`**。等于把"NAD 要不要装"从手工步骤变成 chart 自适应。https://gitcode.com/Ascend/mind-cluster/commit/413d08ba993fa9325401272dc2ecef6631001ef3
- 未命中信号:`[版本跨档]`(最新 tag 仍 `v26.3.0-beta.2`,与上期同,tag 列表按 semver 排序最大值未变)、`[API/CRD变更]`(无 `*_types.go` / `config/crd` / `apis/` 改动)、`[架构方向]`(无 `docs/proposals` / `/design/`,无新增或删除顶层 package)。

## mind-cluster: 629a0324 -> d67f247c

- 比较: 629a03245ffb8f2b8bda040305fbb6c74051556c..d67f247c | tag: v26.3.0-beta.2 | commits=10 | truncated=false
- 源链接: https://gitcode.com/Ascend/mind-cluster/compare/629a03245ffb8f2b8bda040305fbb6c74051556c...d67f247cf3deab021abf581867c66ad666eca961
- 本期实质提交 5 条(其余 5 条是 `!NNNN merge ... into master` 合入节点):
  - `413d08ba` [rdma-dp][Bug-fix] 未部署 multus-cni 时 NAD 实例化失败、回显不友好
  - `123e126f` [bugfix][ascend-docker-runtime] DockerProcess、ContainerdProcess、CriOProcess 三个入口函数重复代码优化
  - `735337ea` 解析基准时间时,以第一次非 1970-01-01 这种时间的行为准
  - `5fae4269` 资料修改-简介中支持产品形态和 OS 清单
  - `581dfaf9` [ci][ut] `ut_python_execute.sh` 的 pip 清单补顶层 langchain(被 helper 的 `[ci` 前缀过滤,全量标题核对后补回)

### AI 总结重点(源码 diff 为据)

**1. ascend-docker-runtime:三引擎入口校验收敛到 `parseAndValidateCommand`,containerd/CRI-O 的"源文件缺失"分支由不校验变为必须父目录安全**

旧代码里三个入口各写一份参数解析。docker 用的是 `os.IsNotExist(err)` → 缺失时校验父目录;containerd 与 CRI-O 用的是 `!os.IsNotExist(err)` → **只在文件存在时校验,缺失时直接放过**。新的共享函数采用了 docker 那一侧(更严)的语义,于是 containerd 与 CRI-O 新增了一条拒绝路径:源文件不存在且其父目录过不了 `RealDirChecker` 时,安装/卸载直接失败返回。

<details><summary>代码依据 component/ascend-docker-runtime/install/process/common.go(新增共享校验)</summary>

```diff
+func parseAndValidateCommand(command []string) (*commandArgs, string, error) {
+	if len(command) == 0 {
+		return nil, "", fmt.Errorf("error param, length of command is 0")
+	}
+	action := command[actionPosition]
+	correctParam, behavior := checkParamAndGetBehavior(action, command)
+	if !correctParam {
+		return nil, "", fmt.Errorf("error param")
+	}
+	arg := &commandArgs{
+		action:       action,
+		srcFilePath:  command[srcFilePosition],
+		destFilePath: command[destFilePosition],
+	}
+	if _, err := os.Stat(arg.srcFilePath); os.IsNotExist(err) {
+		if _, err := mindxcheckutils.RealDirChecker(filepath.Dir(arg.srcFilePath), true, false); err != nil {
+			return nil, behavior, err
+		}
+	} else {
+		if _, err := mindxcheckutils.RealFileChecker(arg.srcFilePath, true, false,
+			mindxcheckutils.DefaultSize); err != nil {
+			return nil, behavior, err
+		}
+	}
+	if _, err := mindxcheckutils.RealDirChecker(filepath.Dir(arg.destFilePath), true, false); err != nil {
+		return nil, behavior, err
+	}
+	if action == addCommand {
+		arg.runtimeFilePath = command[runtimeFilePosition]
+		...
+	}
+	return arg, behavior, nil
+}
```
</details>

<details><summary>代码依据 component/ascend-docker-runtime/install/process/containerd_process.go(旧的宽松分支被删)</summary>

```diff
 func ContainerdProcess(command []string) (string, error) {
-	if len(command) == 0 {
-		return "", fmt.Errorf("error param, length of command is 0")
-	}
-	action := command[actionPosition]
-	correctParam, behavior := checkParamAndGetBehavior(action, command)
-	if !correctParam {
-		return "", fmt.Errorf("error param")
-	}
-	srcFilePath := command[srcFilePosition]
-	if _, err := os.Stat(srcFilePath); !os.IsNotExist(err) {
-		if _, err := mindxcheckutils.RealFileChecker(srcFilePath, true, false, mindxcheckutils.DefaultSize); err != nil {
-			hwlog.RunLog.Errorf("check failed, error: %v", err)
-			return behavior, err
-		}
-	}
-	destFilePath := command[destFilePosition]
-	if _, err := mindxcheckutils.RealDirChecker(filepath.Dir(destFilePath), true, false); err != nil {
+	arg, behavior, err := parseAndValidateCommand(command)
+	if err != nil {
 		return behavior, err
 	}
```
</details>

<details><summary>代码依据 component/ascend-docker-runtime/install/process/crio_process_test.go + common_test.go(新行为被回归锁定,三引擎各两例)</summary>

```diff
+func TestCriORejectsUnsafeMissingSourceParent(t *testing.T) {
+	assertUnsafeMissingSourceParent(t, CriOProcess)
+func TestCriOMissingSourceUnsafeParentRealValidation(t *testing.T) {
+	assertUnsafeMissingSourceParentReal(t, "crio", CriOProcess)
```

common_test.go 里的断言体明确:`os.Stat` 被 patch 成 `os.ErrNotExist` 后,`RealDirChecker(filepath.Dir("src"), true, false)` 必须被调用且其错误必须原样冒泡,同时 `behavior` 仍为 `"install"`:

```diff
+	patches.ApplyFunc(os.Stat, func(string) (os.FileInfo, error) { return nil, os.ErrNotExist })
+	failure := errors.New("unsafe source parent")
+	patches.ApplyFunc(mindxcheckutils.RealDirChecker, func(path string, parent, link bool) (string, error) {
+		if path != filepath.Dir("src") || !parent || link {
+			t.Fatal("incorrect parent validation")
+		}
+		return "", failure
+	})
+	behavior, err := entry([]string{"add", "src", "dest", "runtime", "0", "0"})
+	if behavior != "install" || !errors.Is(err, failure) {
```
</details>

附带两处行为细节(同一提交):
- `runtimeFilePath` 的取值条件从 `len(command) == addCommandLength` 换成 `action == addCommand`。因为 `checkParamAndGetBehavior` 已保证 `addCommand` ↔ `addCommandLength` 配对,结果等价,但索引访问 `command[runtimeFilePosition]` 的前置条件从"长度"改成了"动作",后续若放宽参数长度校验这里会变成越界风险点。
- containerd/CRI-O 原先在源文件与 runtime 文件校验失败时各打一行 `hwlog.RunLog.Errorf("check failed, error: %v", err)`,合并后共享函数里**没有对应日志**,错误只向上返回。排障时这两条路径的现场日志变少了。

**2. TOML runtime 清理:错误容忍串提成常量、空父节点删除失败由静默吞掉改为上抛、显式不删根节点**

containerd 的旧 `removeRuntime` 只容忍 `"path not found"` 一种错误串,且清理空父目录的 `tree.DeletePath(parentPath)` **返回值被整个丢弃**;CRI-O 的旧 `removeCriORuntime` 容忍两种串但把同样的循环抄了一遍。现在两者都收敛到 `deleteRuntimeAndEmptyParents`,错误容忍统一为 `constant.go` 新增的两个常量,并且父节点删除失败会 `return err`。

<details><summary>代码依据 component/ascend-docker-runtime/install/process/constant.go</summary>

```diff
+// TOML deletion error fragments used to tolerate missing configuration paths.
+const (
+	tomlPathNotFoundMessage = "path not found"
+	tomlNoSuchKeyMessage    = "no such key to delete"
+)
```
</details>

<details><summary>代码依据 component/ascend-docker-runtime/install/process/common.go(新共享清理函数)</summary>

```diff
+// deleteRuntimeAndEmptyParents preserves sibling keys and never deletes the root.
+func deleteRuntimeAndEmptyParents(tree *toml.Tree, runtimePath []string) error {
+	if tree == nil || len(runtimePath) == 0 {
+		return nil
+	}
+	if err := deleteConfigPath(tree, runtimePath); err != nil {
+		return err
+	}
+	for length := len(runtimePath) - 1; length > 0; length-- {
+		parentPath := runtimePath[:length]
+		parentNode := getSubtreeByPath(parentPath, tree)
+		if parentNode == nil || len(parentNode.Keys()) != 0 {
+			break
+		}
+		if err := deleteConfigPath(tree, parentPath); err != nil {
+			return err
+		}
+	}
+	return nil
+}
+
+func deleteConfigPath(tree *toml.Tree, path []string) error {
+	if err := tree.DeletePath(path); err != nil {
+		if !strings.Contains(err.Error(), tomlPathNotFoundMessage) &&
+			!strings.Contains(err.Error(), tomlNoSuchKeyMessage) {
+			return err
+		}
+	}
+	return nil
+}
```
</details>

<details><summary>代码依据 component/ascend-docker-runtime/install/process/containerd_process.go(旧 containerd 版本:只容忍一种错误串 + 静默吞父节点删除错误)</summary>

```diff
-	runtimePath := []string{pluginsKey, criRuntimePluginName, containerdKey, runtimesKey, name}
-	err := tree.DeletePath(runtimePath)
-	if err != nil {
-		// If path doesn't exist, ignore error
-		if !strings.Contains(err.Error(), "path not found") {
-			hwlog.RunLog.Errorf("failed to remove runtime, error: %v", err)
-			return err
-		}
-	}
-	// Clean up empty parent directories
-	for i := 1; i < len(runtimePath); i++ {
-		parentPath := runtimePath[:len(runtimePath)-i]
-		parentNode := getSubtreeByPath(parentPath, tree)
-		if parentNode != nil && len(parentNode.Keys()) == 0 {
-			tree.DeletePath(parentPath)
-		} else {
-			break
-		}
-	}
-	return nil
+	return deleteRuntimeAndEmptyParents(tree, []string{pluginsKey, criRuntimePluginName, containerdKey, runtimesKey, name})
```
</details>

循环边界本身等价(旧 `runtimePath[:len-i]`,i∈[1,len-1];新 `runtimePath[:length]`,length∈[len-1,1]),差异在于新版 `length > 0` 把 `path[:0]`(整棵树的根)显式排除在删除范围之外,与注释 "never deletes the root" 对应;另外共享的 `getSubtreeByPath` / `copy` 从 containerd_process.go 移到 common.go 并补了 doc 注释,语义不变。

**3. k8s-rdma-shared-dev-plugin:NAD 从主部署 YAML 拆出,chart 侧改为按 Multus CRD 能力条件渲染**

主 YAML 删掉的那 263 行就是 16 个 `NetworkAttachmentDefinition`(`ens0f0`..`ens3f3`,对应 4 卡 × 4 口),每个 NAD 的 `spec.config` 是 `type: ub-host-device` + `ubMode: true` + `inheritHostIP: true` + `device: <网卡名>`;Pod 通过 `k8s.v1.cni.cncf.io/networks` 注解引用网卡名,CNI 把该网卡(含其 IP)搬进 Pod。新文件头部加了明确的前置依赖说明。

<details><summary>代码依据 component/k8s-rdma-shared-dev-plugin/build/k8s-rdma-shared-dp.yaml(主 YAML 删除 NAD 块)</summary>

```diff
@@ -219,263 +219,3 @@ spec:
         - name: hiai-driver
           hostPath:
             path: /usr/local/Ascend/driver
----
-# Predefined per-port NADs for UB (DPU) host-device mounting: one NAD per DPU
-# port, named after the host NIC (ens0f0..ens3f3). A pod attaches a specific
-# port by referencing the NIC name in its k8s.v1.cni.cncf.io/networks
-# annotation; the CNI moves that NIC (and its IPs, inheritHostIP) into the pod
-apiVersion: "k8s.cni.cncf.io/v1"
-kind: NetworkAttachmentDefinition
-metadata:
-  name: ens0f0
-  namespace: default
-spec:
-  config: |
-    {
-      "cniVersion": "0.3.1",
-      "name": "ens0f0",
-      "type": "ub-host-device",
-      "ubMode": true,
-      "inheritHostIP": true,
-      "device": "ens0f0"
-    }
```
</details>

<details><summary>代码依据 component/k8s-rdma-shared-dev-plugin/build/k8s-rdma-shared-dp-nad.yaml(新文件,显式声明 Multus 前置)</summary>

```diff
+# NOTE: NetworkAttachmentDefinition is a CRD provided by Multus CNI. Deploy
+# Multus CNI before applying this file, otherwise these resources cannot be
+# instantiated.
+apiVersion: "k8s.cni.cncf.io/v1"
+kind: NetworkAttachmentDefinition
+metadata:
+  name: ens0f0
```
</details>

<details><summary>代码依据 helm-deploy-tool/app/charts/k8s-rdma-shared-dev-plugin/templates/nad.yaml(chart 侧条件渲染)</summary>

```diff
+{{- if .Capabilities.APIVersions.Has "k8s.cni.cncf.io/v1/NetworkAttachmentDefinition" -}}
+{{- $filePath := "yamls/nad/**.yaml" -}}
+{{- $files := .Files.Glob $filePath -}}
+{{- if not $files -}}
+  {{- fail (printf "No files found matching pattern: %s" $filePath) -}}
+{{- end -}}
+{{- $currentScope := . }}
+{{- range $path, $_ := .Files.Glob $filePath }}
+  {{- with $currentScope }}
+    {{- $content := $.Files.Get $path -}}
+    {{- tpl $content $ }}
+---
+  {{- end }}
+{{- end }}
+{{- end -}}
```
</details>

配套改动:`build/build.sh` 的 `mv_file()` 新增 `cp "${TOP_DIR}"/build/k8s-rdma-shared-dp-nad.yaml "${TOP_DIR}"/output/...`(新文件进发布包);`.pre-commit-config.yaml` 的 `check-yaml` 排除清单从 `templates/(main|crds|validate-mutex)\.yaml` 扩到 `…|nad)\.yaml`(因为新模板里全是 Go template 控制流,不是合法 YAML)。文档 `05_1825_container_network.md` 把环境准备从 5 步扩到 6 步,新增第 6 步"实例化 NAD",并要求回显包含全部 16 个 NAD。

**4. ascend-faultdiag:时间参照行解析从"首行定生死"改为"跳过坏行"**

`NpuHistoryLogParser._parse_time_reference` 负责从 `device_os.log` 第一条 `[ERROR] KERNEL` 行取出 (W0 实际时间, T0 开机时长),用来把 kernel.log 里的开机时长换算成墙上时间。旧实现任一校验不过就 `return None`,整个时间换算失效;新实现 `continue` 往后找,并新增对底板时钟未同步(日期 `1970-01-01`)的识别。

<details><summary>代码依据 component/ascend-faultdiag/src/ascend_fd/pkg/parse/knowledge_graph/parser/npu_device_parse.py</summary>

```diff
+    _INVALID_DATE = "1970-01-01"
@@
-                    # 第一条 [ERROR] KERNEL 行解析 W0/T0,任一失败即视为参照不可用
+                    # 任一校验不通过即跳过本行,取后续首个可用的 [ERROR] KERNEL 行作参照
                     real_time_match = NpuHistoryLogParser._DEVICE_OS_REAL_TIME_PATTERN.search(line)
                     uptime_match = NpuHistoryLogParser._DEVICE_OS_UPTIME_PATTERN.search(line)
                     if not real_time_match or not uptime_match:
-                        return None
+                        continue
                     real_time = check_and_format_time_str(real_time_match.group(1))
-                    if not real_time:
-                        return None
+                    if not real_time or NpuHistoryLogParser._INVALID_DATE in line:
+                        continue
```
</details>

实现上有个值得记一笔的细节:`1970-01-01` 的判定是 `_INVALID_DATE in line`,匹配的是**整行原文**而不是已提取出的 `real_time`。也就是说行尾日志正文里若恰好出现 `1970-01-01` 字样,这条本来有效的参照行也会被跳过。按日志形态这概率低,但判定范围比意图宽。

同提交另有一处输出 schema 增量:`LostDeviceChecker` 吐出的故障记录新增 `"chains": {}` 字段,与 `code`/`entities_attribute`/`events_attribute` 并列 —— 下游消费方要准备接"故障链"结构。

<details><summary>代码依据 component/ascend-faultdiag/src/ascend_fd/pkg/parse/knowledge_graph/prechecker/lost_device_checker.py</summary>

```diff
                     "code": code,
                     "entities_attribute": entities_attribute,
                     "events_attribute": events_attribute,
+                    "chains": {},
```
</details>

新增 `TestNpuHistoryTimeReference` 三个用例锁定了语义边界:坏日期行跳过取后续有效行、字段缺失/时间非法行跳过、**全量都是 1970-01-01 时返回 `None`(与"无参照"同语义)**。

<details><summary>代码依据 component/ascend-faultdiag/test/dt/test_ub_precheck_parse.py</summary>

```diff
+    def test_all_invalid_date_lines_return_none(self):
+        # 全量为 1970-01-01 参照行时无有效基准,返回 None(与"无参照"同语义)
+        path = self._write_device_os([self._reference_line(datetime(1970, 1, 1))])
+        self.assertIsNone(self.parser._parse_time_reference(path))
```
</details>

**5. 其余(非 component/,靠全量 compare 才可见)**

- `docs/zh/scheduling/01_introduction/03_supported_product_models_and_os.md` 重排了章节:原"集群场景 / 单机场景 / 单机场景(训练)/ 单机场景(推理)"四段改为"管理节点 / 计算节点(表 1 训推通用、表 2 训练、表 3 推理)/ 存储节点",并新增两句部署约束 —— 管理节点"MindCluster 组件对于 OS 无强依赖,建议使用 K8s 支持的 OS 版本"、存储节点"无 mindcluster 组件部署"。**机型与 OS 条目本身没有新增**(diff 里 Atlas 900 A3 SuperPoD、A200T A3 Box8 等行只有空格与 kernel 版本号写法 `6.6.80.29` → `6.6.80-29` 的订正),所以这期不构成"新机型纳管"信号。https://gitcode.com/Ascend/mind-cluster/commit/5fae4269
- `.gitcode/workflows/scripts/ut_python_execute.sh` 给 `ascend-clusterops-agent` 的 UT pip 清单补了顶层 `langchain`(原先只装 `langgraph langchain-openai`)—— 该 Agent 开始直接依赖 langchain 顶层包,不只是 langgraph + OpenAI 适配。https://gitcode.com/Ascend/mind-cluster/commit/581dfaf9

### 后续发展方向 [AI]

- **UB/DPU fabric 的部署形态正在从"一包全给"转向"按集群能力分层装配"**。证据是 NAD 从主 YAML 剥离 + chart 侧用 `.Capabilities.APIVersions.Has "k8s.cni.cncf.io/v1/NetworkAttachmentDefinition"` 做总开关这一对改动:组件自身(DaemonSet)与它对 Multus 生态的依赖被拆成两个可独立决策的单元。对我们产品的启示是,接昇腾 UB 组网时不能假定"装了 rdma-dp 就有 NAD",需要显式把 Multus 与 NAD 实例化纳入前置检查项,否则容器拿不到网卡而现场只看到一条不友好的 apply 报错。证据只覆盖 rdma-dp 这一个 chart,未见 ub-host-device-cni / ub-network-device-plugin 侧是否也在做同样的拆分。
- **ascend-docker-runtime 的安装期校验正在向"最严引擎"对齐,升级会暴露此前被放过的不安全路径**。证据是 containerd/CRI-O 的 `!os.IsNotExist` 宽松分支被 docker 的严格分支替换,并被六个回归用例锁定。含义:原先在 containerd/CRI-O 上能装成功的环境(源配置文件不存在、父目录权限或软链接不合规),升级到本版后会直接安装失败。我们若在交付镜像/底座里托管 Ascend Docker Runtime 的安装步骤,要提前核对 `/etc/containerd`、CRI-O drop-in 目录的 owner 与权限。证据只覆盖 `install/process` 这一层,未见 `RealDirChecker` 自身判据(parent/link 两个布尔的具体含义)是否同期调整。
- **故障诊断正在从"单点规则"往"故障链"走**。证据是 `LostDeviceChecker` 输出里凭空多出的 `"chains": {}` 占位字段 —— 当前恒为空字典,但它与 `entities_attribute`/`events_attribute` 并列进同一条记录,说明消费侧 schema 已为链式归因预留。同时时间基准解析被改成"跳过坏行取首个可用行",正是链式归因对时间轴对齐的硬需求(底板时钟未同步的 1970 时间会把整条链的时序打乱)。证据只覆盖 lost_device_checker 一个 checker 与 `_parse_time_reference` 一个函数,未见 `chains` 的真实填充逻辑与数据结构定义。

### 本期扫描质量说明(盲区与核对)

- **`component/` 目录清单差集:本期无漏项**。`contents/component?ref=master` 返回 19 个目录,与任务里 19 个 PATHPREFIX 完全一致(连续四期的 PATHPREFIX 漏扫首次清零)。
- **新发现盲区:`helm-deploy-tool/` 在 `component/` 前缀之外**。本期 chart 侧的 `helm-deploy-tool/app/charts/k8s-rdma-shared-dev-plugin/templates/nad.yaml` 与根目录 `.pre-commit-config.yaml`、`.gitcode/workflows/` 的改动都被 PATHPREFIX 静默过滤,只有不带 prefix 的全量 compare 才看到。mind-cluster 顶层目录为 `build / component / docker / docs / helm-deploy-tool / pre-commit / tests`,其中 `helm-deploy-tool` 是组件部署形态的另一条主线(chart 与 component 下的裸 YAML 是同一能力的两种交付),建议下期把 `helm-deploy-tool/app/charts` 补进 PATHPREFIX。
- **commit 标题全量核对**:helper 的主题过滤器按 `^(Merge|!?[0-9]+ *merge|[Bb]ump|\[ci|chore|…)` 丢掉了 5 条,逐条核对后 4 条确为 `!NNNN merge … into master` 合入节点,1 条 `581dfaf9 [ci][ut] …` 是实质改动(被 `\[ci` 规则吞掉),已在正文补回。
- `truncated=false`,10 个 commit、22 个改动文件全部可见,无 patch 截断导致的结论缺口。

## 本期无实质改动(折叠)

<details><summary>10 个 openFuyao 仓本期零新提交(HEAD 与 11-27 锚点相同)</summary>

- npu-operator(HEAD `ddcf0eb7`,tag v26.9.0)
- npu-container-toolkit(HEAD `c720a3b8`,tag v26.9.0)
- npu-driver-installer(HEAD `bd1b2a9e`,tag v26.9.0)
- vNPU(HEAD `21a52631`,tag v26.9.0)
- npu-node-provision(HEAD `717ef777`,tag v26.6.0)
- npu-dra-plugin(HEAD `4f20ad9b`,tag v26.9.0)
- npu-feature-discovery(HEAD `4ba6e58e`,tag v26.9.0)
- volcano-ext(HEAD `0f265f98`,tag v1.9.0)
- ub-network-device-plugin(HEAD `9cc5dbdd`,tag v26.9.0)
- ub-network-bandwidth-operator(HEAD `d4ee1a47`,无 tag)

空壳仓待观察(仍只有 Initial commit,未纳入扫描):`equivalent-compute-unit`、`compute-fusion`。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)

<!-- ANCHOR repo=mind-cluster sha=d67f247cf3deab021abf581867c66ad666eca961 tag=v26.3.0-beta.2 scanned=2026-11-28 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=vNPU sha=21a52631996530ae84da9ca97eb469d9cab436f3 tag=v26.9.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=npu-dra-plugin sha=4f20ad9bd8a6d248315d32f42fbd706c6e241713 tag=v26.9.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=npu-feature-discovery sha=4ba6e58e3e132f61936ae2c619f91d9e75c5ec90 tag=v26.9.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=9cc5dbdd87c01f90aa7f9ea8038b7a1ed5b2bd2d tag=v26.9.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=ub-network-bandwidth-operator sha=d4ee1a478ec50c0c543b73f01a00944467e8018d tag=— scanned=2026-11-28 -->

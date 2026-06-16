# HAMi diff 雷达 2026-06-17

## 摘要
- HAMi 主仓删除调度器三个未使用的全局默认资源 flag(`--default-mem`/`--default-cores`/`--default-gpu`)及对应 config 变量,默认资源语义彻底从启动参数下沉,CLI 表面收窄([弃用/移除])。
- HAMi-core 一轮安全/构建硬化:CUDA hook 与显存限额里用 `snprintf` 全面替换 `strcpy`/`strcat`/`strcat` 拼接(防溢出);编译基镜像从 ubuntu 切到 RHEL 系 `ubi8` 且 CUDA 12.9.1→13.3.0;并删掉 array hook 里早已无用的字节计算——印证 CUDA array 分配本就不计入显存隔离账本。
- volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI 三仓本期无新提交。

## 当日重要改变
- Project-HAMi/HAMi [弃用/移除] 调度器移除 `DefaultMem`/`DefaultCores`/`DefaultResourceNum` 三个全局变量及 `--default-mem`/`--default-cores`/`--default-gpu` 三个启动 flag(#1953)。证据 pkg/scheduler/config/config.go、cmd/scheduler/main.go。https://github.com/Project-HAMi/HAMi/pull/1953
- Project-HAMi/HAMi-core [架构方向] 编译基镜像由 `nvidia/cuda:12.9.1-...-ubuntu20.04` 改为 `nvidia/cuda:13.3.0-cudnn-devel-ubi8`,构建从 apt 切 dnf。证据 dockerfiles/Dockerfile、Makefile。https://github.com/Project-HAMi/HAMi-core/commit/0831874bce5af56cefca7093dfb2f9f95d1970aa

## Project-HAMi/HAMi: df6ac09e -> 5bfaee19
- 比较: df6ac09e -> 5bfaee19 | ahead=2 | Release: v2.9.0
- 比较链接 https://github.com/Project-HAMi/HAMi/compare/df6ac09e0420fd337133eb673d7fe72269dd194e...5bfaee19fdcfae2f58bb35ebfd2f012d2615d667

### AI 总结重点(源码 diff 为据)
- 调度器配置删除三个全局默认资源变量 `DefaultMem`/`DefaultCores`/`DefaultResourceNum`。这三个变量原本承载"pod 未显式声明时给的兜底显存/算力/卡数",现整块移除,说明默认值不再由全局配置态变量持有。
  <details><summary>代码依据 pkg/scheduler/config/config.go</summary>

  ```diff
  	SchedulerName      string
  	MetricsBindAddress string
 
  -	DefaultMem         int32
  -	DefaultCores       int32
  -	DefaultResourceNum int32
  -
  	// NodeSchedulerPolicy is config this scheduler node to use `binpack` or `spread`. default value is binpack.
  	NodeSchedulerPolicy = util.NodeSchedulerPolicyBinpack.String()
  ```
  </details>
- 与之对应,scheduler 启动参数删除 `--default-mem`/`--default-cores`/`--default-gpu` 三个 flag(后者原默认值 1)。运维侧不再能用启动参数配集群级默认资源,CLI 表面收窄;默认分配逻辑须改由 device 层/请求解析时处理。
  <details><summary>代码依据 cmd/scheduler/main.go</summary>

  ```diff
  	rootCmd.Flags().StringVar(&config.SchedulerName, "scheduler-name", "", "...")
  -	rootCmd.Flags().Int32Var(&config.DefaultMem, "default-mem", 0, "default gpu device memory to allocate")
  -	rootCmd.Flags().Int32Var(&config.DefaultCores, "default-cores", 0, "default gpu core percentage to allocate")
  -	rootCmd.Flags().Int32Var(&config.DefaultResourceNum, "default-gpu", 1, "default gpu to allocate")
  	rootCmd.Flags().StringVar(&config.NodeSchedulerPolicy, "node-scheduler-policy", ...)
  ```
  </details>
- 配套:测试 `Test_DefaultResourceNum` 更名为 `TestResourceQuantityAsInt64`(测试主体未变,仅去掉与已删 flag 的命名绑定);SKILL.md 文档把 `defaultMem=0` 措辞改为 `defaultMemory=0`。属同一清理的收尾,无新逻辑。

### 后续发展方向 [AI]
- 证据(config.go + main.go 删除)指向"集群级默认资源配置入口"被收掉:HAMi 倾向于让显存/算力默认在请求解析或 device 注册时确定,而非一个可被运维覆盖的全局 flag。证据只覆盖 flag/变量的删除,未见替代默认逻辑落在哪个文件(本区间无新增默认实现的 hunk),需下期跟 device 层是否补默认值处理。

## Project-HAMi/HAMi-core: 02a9ac22 -> 0831874b
- 比较: 02a9ac22 -> 0831874b | ahead=8 | Release: —
- 比较链接 https://github.com/Project-HAMi/HAMi-core/compare/02a9ac22a438824b411e13ad4144fc152a1ec63b...0831874bce5af56cefca7093dfb2f9f95d1970aa

### AI 总结重点(源码 diff 为据)
- CUDA hook 与显存限额初始化里,固定长度缓冲的字符串拼接由 `strcpy`/`strcat` 改为 `snprintf(buf, sizeof(buf), ...)`,消除潜在缓冲区溢出。这是软隔离 hook 的安全硬化:符号回退查找(`find_symbols_in_table` 拼 `_v3`/`_v2`)与逐设备环境变量名(`CUDA_DEVICE_MEMORY_LIMIT_N`/`CUDA_DEVICE_SM_LIMIT_N`)的构造都改成有界写入。
  <details><summary>代码依据 src/cuda/hook.c</summary>

  ```diff
  -    strcpy(symbol_v,symbol);
  -    strcat(symbol_v,"_v3");
  -    pfn = __dlsym_hook_section(NULL,symbol_v);
  -    if (pfn!=NULL) {
  +    snprintf(symbol_v, sizeof(symbol_v), "%s_v3", symbol);
  +    if ((pfn = __dlsym_hook_section(NULL, symbol_v)) != NULL)
         return pfn;
  -    }
       symbol_v[strlen(symbol_v)-1]='2';
  ```
  </details>
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  -        char env_name[CUDA_DEVICE_MEMORY_LIMIT_KEY_LENGTH] = CUDA_DEVICE_MEMORY_LIMIT;
  -        char index_name[8];
  -        snprintf(index_name, 8, "_%d", i);
  -        strcat(env_name, index_name);
  +        char env_name[CUDA_DEVICE_MEMORY_LIMIT_KEY_LENGTH];
  +        snprintf(env_name, sizeof(env_name), "%s_%d", CUDA_DEVICE_MEMORY_LIMIT, i);
  ```
  </details>
- array hook 删除"算了字节但丢弃结果"的死代码:`cuArray3DCreate_v2`/`cuArrayCreate_v2`/`cuArrayDestroy` 原先调用 `compute_*_array_alloc_bytes()` 后把返回值注释成 `/*uint64_t bytes*/` 弃用,现直接透传到底层调用。即 **CUDA array 分配本来就没计入显存隔离账本,这次只是删掉无用计算坐实这一行为边界**——array 类显存不受软切分限额约束。
  <details><summary>代码依据 src/cuda/memory.c</summary>

  ```diff
   CUresult cuArrayDestroy(CUarray arr) {
  -    CUDA_ARRAY3D_DESCRIPTOR desc;
       LOG_DEBUG("cuArrayDestroy");
  -    CHECK_DRV_API(cuArray3DGetDescriptor(&desc, arr));
  -    /*uint64_t bytes*/
  -    compute_3d_array_alloc_bytes(&desc);
  -    CUresult res = CUDA_OVERRIDE_CALL(cuda_library_entry,cuArrayDestroy, arr);
  -    return res;
  +    return CUDA_OVERRIDE_CALL(cuda_library_entry, cuArrayDestroy, arr);
   }
  ```
  </details>
- 编译基镜像与工具链迁移:Dockerfile/Makefile 把 `nvidia/cuda:12.9.1-cudnn-devel-ubuntu20.04` 换成 `nvidia/cuda:13.3.0-cudnn-devel-ubi8`,包管理从 `apt-get` 改 `dnf`,并在 docker 构建里加 `rm -rf /libvgpu/build` 清理旧产物。基底转向 RHEL 系 UBI8 + CUDA 13.3,利于企业级合规分发与新驱动兼容。
  <details><summary>代码依据 dockerfiles/Dockerfile</summary>

  ```diff
  -FROM nvidia/cuda:12.9.1-cudnn-devel-ubuntu20.04
  -ENV DEBIAN_FRONTEND=noninteractive
  +FROM nvidia/cuda:13.3.0-cudnn-devel-ubi8
   WORKDIR /libvgpu
   COPY . /libvgpu
  -RUN apt-get update && apt-get install -y cmake git && rm -rf /var/lib/apt/lists/*
  +RUN dnf install -y cmake git && dnf clean all
   RUN bash ./build.sh
  ```
  </details>
- 零散修复:`utilization_watcher()` 在 `nvmlDeviceGetCount` 失败分支由 `return;` 改 `return NULL;`(函数返回 `void*`,原写法编译告警/UB);`shrreg_tool` 删掉重复的 `--print` 参数分支;`utils.c` 补 `#include <sys/file.h>`(flock 相关)。均为小修,无新能力。

### 后续发展方向 [AI]
- 证据(全仓 snprintf 化 + utilization_watcher 返回值修正)显示 HAMi-core 正做一轮系统性的内存安全与告警清零,软隔离 hook 的健壮性在补课,而非加新切分能力。UBI8 + CUDA 13.3 的基底迁移指向对接更新 NVIDIA 驱动栈与企业发行通道。证据只覆盖本区间 8 个文件的 hunk,未见 array 显存纳入隔离的补偿逻辑——array 不计账这一缺口本期未被填补,需持续观察是否后续补 hook。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=5bfaee19fdcfae2f58bb35ebfd2f012d2615d667 branch=master release=v2.9.0 scanned=2026-06-17 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=0831874bce5af56cefca7093dfb2f9f95d1970aa branch=main release=— scanned=2026-06-17 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-06-17 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-17 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-17 -->

# NVIDIA 算力栈 diff 雷达 2026-09-25

## 摘要
- **gpu-driver-container 把 NVLink5+ fabric manager 支持铺到全预编译矩阵**:新增 `_configure_fabric_manager()`,靠 `NVFM_CONFIG_*` 环境变量把 fabricmanager.cfg 字段动态注入(带 sed 转义防注入),并在 `FABRIC_MODE=1` 启动后 `nvidia-smi -r` 复位 GPU 清理陈旧 fabric 分区;rhel8 补齐 NVLink5 检测(`_assert_nvlink5_system`/`_ensure_nvlink5_prerequisites`),Dockerfile 改直装 `nvidia-imex`/`nvlsm`/`infiniband-diags`。这是 GB200 NVL72 级 NVSwitch 系统在驱动容器里的落地信号。
- **gpu-operator 修正 DRA driver 样例镜像引用**:GPUCluster 样例的 `draDriver` 从 `registry.k8s.io/dra-driver-nvidia:v0.4.0` 改为 `nvcr.io/nvidia/dra-driver-nvidia-gpu:v0.5.0`,CSV alm-example 里的 draDriver 只保留 `computeDomains.enabled`、不再硬钉 repository/version,配套 update-csv-images.py 删掉 draDriver 注入分支。纯样例/bundle 修正,ClusterPolicy CRD 无字段增删。
- 其余 7 仓无实质改动(container-toolkit/dcgm-exporter/DCGM/mig-parted/k8s-device-plugin/dra-driver/KAI-Scheduler 均无新提交)。

## 当日重要改变
- gpu-driver-container [新能力] 预编译驱动新增 `NVFM_CONFIG_*` 环境变量→fabricmanager.cfg 的动态配置注入,并对 NVLink5+/NVLink4 两条路径统一在启动 FM 前调用;`FABRIC_MODE=1` 后复位 GPU。证据 `rhel8/precompiled/nvidia-driver`、`ubuntu*/precompiled/nvidia-driver` https://github.com/NVIDIA/gpu-driver-container/pull/1026
- gpu-driver-container [矩阵] rhel8 预编译补齐 NVLink5 支持:Dockerfile 弃用旧 FABRIC_MANAGER_VERSION 版本推算逻辑,改直装 `nvidia-fabricmanager`/`libnvidia-nscq`/`nvidia-imex`/`infiniband-diags`/`nvlsm`(非 aarch64 另加 `libnvsdm`)。证据 `rhel8/precompiled/Dockerfile`、`rhel8/precompiled/nvidia-driver` https://github.com/NVIDIA/gpu-driver-container/commit/d0fb1c404b5270c807a65a108677277299509698
- gpu-operator [配置面] GPUCluster 样例 draDriver 镜像源与版本更正(registry.k8s.io→nvcr.io、v0.4.0→v0.5.0),CSV alm-example 去掉 draDriver 的 repository/image/version 硬编码。证据 `config/samples/nvidia_v1alpha1_gpucluster.yaml`、`.github/scripts/update-csv-images.py` https://github.com/NVIDIA/gpu-operator/pull/2960

## NVIDIA/gpu-driver-container: 575c9011 -> 39e0cfd3
- 比较: 575c9011 -> 39e0cfd3 | ahead=2 | files=13 | Release: —
### AI 总结重点(源码 diff 为据)
- 新增 `_configure_fabric_manager()`:扫描 `NVFM_CONFIG_<field>` 前缀的环境变量,把 `<field>=<value>` 写进 `/usr/share/nvidia/nvswitch/fabricmanager.cfg`——已有键用 `sed` 就地替换、无则追加。value 先经 `sed -e 's/[\\&|]/\\&/g'` 转义反斜杠/&/竖线,注释明确是防止 value 破坏 sed 替换或注入额外 sed 命令。该函数被塞进 NVLink5+ 与 NVLink4 两条 FM 启动分支的 daemon 拉起之前,全 OS 变体(ubuntu 22/24/26、rhel 8/9/10)同步落地。这是把 fabric manager 配置从"镜像内静态文件"变为"运行时按 env 可调"的能力面扩展。
  <details><summary>代码依据 ubuntu24.04/precompiled/nvidia-driver 等</summary>

  ```diff
  +_configure_fabric_manager() {
  +    local fm_config_file=/usr/share/nvidia/nvswitch/fabricmanager.cfg
  +    nvfm_env_vars=$(env | grep '^NVFM_CONFIG_' || true)
  +    [ -z "${nvfm_env_vars}" ] && return 0
  +    while IFS='=' read -r name value; do
  +        local field="${name#NVFM_CONFIG_}"
  +        ...
  +        if grep -q "^${field}=" "${fm_config_file}"; then
  +            sed_escaped_value=$(printf '%s' "${value}" | sed -e 's/[\\&|]/\\&/g')
  +            sed -i "s|^${field}=.*|${field}=${sed_escaped_value}|" "${fm_config_file}"
  +        else
  +            printf '\n%s=%s\n' "${field}" "${value}" >> "${fm_config_file}"
  ```
  </details>
- NVLink5+ 路径在 FM 启动成功后新增条件复位:当 `NVFM_CONFIG_FABRIC_MODE=1` 时执行 `nvidia-smi -r || return 1`,注释说明是"清除设置 FABRIC_MODE=1 后残留的陈旧 FM 分区状态"。此前非预编译的 ubuntu26.04/nvidia-driver 里同段复位是 `nvidia-smi -r`(无错误传播),本期一并改为 `|| return 1`,复位失败即让驱动容器启动失败而非静默继续。
  <details><summary>代码依据 rhel10/precompiled/nvidia-driver & ubuntu26.04/nvidia-driver</summary>

  ```diff
  +        if [ ! -z "${NVFM_CONFIG_FABRIC_MODE:-}" ] && [ "${NVFM_CONFIG_FABRIC_MODE}" == "1" ]; then
  +            echo "Resetting GPUs to clear stale fabric partition states..."
  +            nvidia-smi -r || return 1
  +        fi
  -            nvidia-smi -r
  +            nvidia-smi -r || return 1
  ```
  </details>
- rhel8 预编译从"只支持到 NVLink4"补齐到 NVLink5+:新增 `_assert_nvlink5_system()`(遍历 `/sys/class/infiniband/*/device/vpd`,命中 `SW_MNG` 即判定 NVLink5+ 系统)与 `_ensure_nvlink5_prerequisites()`(轮询等待 `mlx5_core` 与 `ib_umad` 内核模块加载),`_load_driver` 的判定从 `if _assert_nvswitch_system` 改为先试 `_assert_nvlink5_system` 再 fallback,与其他 OS 拉齐。
  <details><summary>代码依据 rhel8/precompiled/nvidia-driver</summary>

  ```diff
  +_assert_nvlink5_system() (
  +    for dir in /sys/class/infiniband/*/device; do
  +        if [ -f "$dir/vpd" ] && grep -q "SW_MNG" "$dir/vpd"; then
  +            echo "Detected NVLink5+ system"; return 0
  +        fi
  +    done
  +    return 1 )
  -    if _assert_nvswitch_system; then
  +    if _assert_nvlink5_system; then
  +        _ensure_nvlink5_prerequisites || return 1
  ```
  </details>
- rhel8/precompiled/Dockerfile 重构 fabric manager 依赖安装:删掉基于 `VERSION_ARRAY` 手算 `FABRIC_MANAGER_VERSION`/`NSCQ_VERSION` 的旧逻辑,改为直接 `dnf install nvidia-fabricmanager-${DRIVER_VERSION} libnvidia-nscq-${DRIVER_VERSION} nvidia-imex-${DRIVER_VERSION} infiniband-diags nvlsm`(非 aarch64 追加 `libnvsdm`)。包名从 `nvidia-fabric-manager` 改为 `nvidia-fabricmanager`,并新纳入 NVLink5 必需的 imex/nvlsm/infiniband 诊断组件。
  <details><summary>代码依据 rhel8/precompiled/Dockerfile</summary>

  ```diff
  -        VERSION_ARRAY=(${DRIVER_VERSION//./ }) \
  -        && if [ ${VERSION_ARRAY[0]} -ge 470 ] ... FABRIC_MANAGER_VERSION=...
  -            nvidia-fabric-manager-${FABRIC_MANAGER_VERSION} \
  -            libnvidia-nscq-${NSCQ_VERSION} \
  +        dnf install -y \
  +            nvidia-fabricmanager-${DRIVER_VERSION} \
  +            libnvidia-nscq-${DRIVER_VERSION} \
  +            nvidia-imex-${DRIVER_VERSION} \
  +            infiniband-diags \
  +            nvlsm \
  +        && if [ "$TARGETARCH" != "aarch64" ]; then dnf install -y libnvsdm-${DRIVER_VERSION}; fi \
  ```
  </details>
### 后续发展方向 [AI]
- 本期主线是 GB200/NVL72 级 NVLink5+ NVSwitch 系统在容器化驱动里的工程化:配置面从静态文件转为 `NVFM_CONFIG_*` 运行时注入(便于 gpu-operator 经 env 下发 fabric 拓扑/mode),部署面把 rhel8 拉到与 ubuntu/rhel9-10 同等的 NVLink5 支持。证据集中在各 OS 的 `nvidia-driver` 启动脚本与 rhel8 Dockerfile,未见 gpu-operator 侧对应的 `NVFM_CONFIG_*` 下发字段(operator 本期无 driver 容器编排改动),env 变量的消费端契约需后续在 gpu-operator/ClusterPolicy 侧确认。

## NVIDIA/gpu-operator: 42052c45 -> 60526e35
- 比较: 42052c45 -> 60526e35 | ahead=2 | files=3 | Release: v26.7.1
### AI 总结重点(源码 diff 为据)
- GPUCluster 样例 `draDriver` 镜像坐标更正:repository 从 `registry.k8s.io/dra-driver-nvidia` 改为 `nvcr.io/nvidia`、version 从 `v0.4.0` 抬到 `v0.5.0`(与 dra-driver-nvidia-gpu 当前 Release v0.5.0 对齐)。CSV bundle 的 alm-example 里 draDriver 块删去 repository/image/version/imagePullPolicy 四个硬编码字段,只留 `computeDomains.enabled: true`,交由 operator 默认值填充。
  <details><summary>代码依据 config/samples/nvidia_v1alpha1_gpucluster.yaml & bundle CSV</summary>

  ```diff
  -    repository: registry.k8s.io/dra-driver-nvidia
  +    repository: nvcr.io/nvidia
       image: dra-driver-nvidia-gpu
  -    version: v0.4.0
  +    version: v0.5.0
  -              "repository": "nvcr.io/nvidia",
  -              "image": "dra-driver-nvidia-gpu",
  -              "version": "v0.4.1",
  -              "imagePullPolicy": "IfNotPresent",
                 "computeDomains": { "enabled": true }
  ```
  </details>
- `update-csv-images.py` 的 `update_alm_examples` 删掉针对 `kind==GPUCluster` 注入 draDriver 镜像引用的分支,只保留 NVIDIADriver 分支——即 CSV 生成流程不再自动改写 GPUCluster 样例的 draDriver 镜像。
  <details><summary>代码依据 .github/scripts/update-csv-images.py</summary>

  ```diff
  -    dra_driver_ref = image_refs.get("draDriver")
  -    if not alm_examples or not (driver_ref or dra_driver_ref):
  +    if not alm_examples or not driver_ref:
  -        elif example.get("kind") == "GPUCluster" and dra_driver_ref:
  -            dra_driver = spec.setdefault("draDriver", {})
  -            update_image_reference_fields(dra_driver, dra_driver_ref)
  ```
  </details>
### 后续发展方向 [AI]
- 纯 bug fix:统一 DRA driver 镜像源到 nvcr.io 并对齐 v0.5.0,把样例从"CI 自动改写镜像"改为"手工维护 + 默认值"。ClusterPolicy/NVIDIADriver CRD 无字段变化(`clusterpolicy_types.go` 未命中),无功能面影响。证据仅覆盖样例与 CI 脚本。

## 本期无实质改动(折叠)
- NVIDIA/nvidia-container-toolkit — 无新提交(v1.20.1)
- NVIDIA/k8s-device-plugin — 无新提交(v0.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(v0.5.0)
- NVIDIA/dcgm-exporter — 无新提交(4.8.4)
- NVIDIA/DCGM — 无新提交(master)
- NVIDIA/mig-parted — 无新提交(v0.15.1)
- kai-scheduler/KAI-Scheduler — 无新提交(v0.18.0)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=60526e35efeeedef584d8f40db0bac8864f98f26 branch=main release=v26.7.1 scanned=2026-09-25 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=84e2c2c182bfa0b2edab4fdca27e5197faba0ca7 branch=main release=v1.20.1 scanned=2026-09-25 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=39e0cfd337a0cac8d272412b8fa16343c973afe9 branch=main release=— scanned=2026-09-25 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=86142cf1a93fb68a99c5927b9599e13392e27e15 branch=main release=v0.20.1 scanned=2026-09-25 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=495bf4c59b9423080aa1fe2163955f44a495012c branch=main release=v0.5.0 scanned=2026-09-25 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-09-25 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-25 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=626a3f6a2c8597705f42b4be27a822f561fef706 branch=main release=v0.15.1 scanned=2026-09-25 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=b44868939553e64c67b43467b8e0cc4939495d32 branch=main release=v0.18.0 scanned=2026-09-25 -->

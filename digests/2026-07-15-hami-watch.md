# HAMi diff 雷达 2026-07-15

## 摘要
- 仅 ascend-device-plugin 有实质改动:修复 device-plugin 找不到 `npu-smi` 的问题——daemonset 补挂宿主机 `/usr/local/sbin`(只读)。属部署侧运行时依赖修复,非能力变化。
- HAMi 主仓、HAMi-core、volcano-vgpu-device-plugin、HAMi-WebUI 本日均无新提交。
- 当日无"重要改变"信号命中(无弃用/API-CRD/架构/版本跨档/新能力)。

## 当日重要改变
- 无

## Project-HAMi/ascend-device-plugin: 678ae765 -> f8ae57c3
- 比较: 678ae765c803cc00ed7b893647ee775acfb174c7 -> f8ae57c3 | ahead=4 | files=3 | Release: —
- 比较页: https://github.com/Project-HAMi/ascend-device-plugin/compare/678ae765c803cc00ed7b893647ee775acfb174c7...f8ae57c30dd6e8311815bb3327a2991e34293b1d

### AI 总结重点(源码 diff 为据)
- **device-plugin 容器补挂宿主机 `/usr/local/sbin`(只读),以便运行时能定位 `npu-smi` 二进制。** daemonset 模板与整合版 `ascend-device-plugin.yaml` 同步新增一个 `host-sbin` volume(`hostPath: /usr/local/sbin`,`type: DirectoryOrCreate`)并挂进容器同名路径。昇腾 `npu-smi` 常安装在宿主 `/usr/local/sbin`,此前容器内 PATH 找不到该工具会导致 vNPU 查询/切分链路失败;这是一处部署侧运行时依赖修复,不改任何调度或虚拟化逻辑。
  <details><summary>代码依据 charts/ascend-device-plugin/templates/daemonset.yaml</summary>

  ```diff
             - name: hiai-driver
               mountPath: /usr/local/Ascend/driver
               readOnly: true
  +            - name: host-sbin
  +              mountPath: /usr/local/sbin
  +              readOnly: true
             - name: log-path
               mountPath: /var/log/mindx-dl/devicePlugin
  ...
         - name: hiai-driver
           hostPath:
             path: /usr/local/Ascend/driver
  +        - name: host-sbin
  +          hostPath:
  +            path: /usr/local/sbin
  +            type: DirectoryOrCreate
  ```
  </details>
- **CI 发布产物的镜像 tag 不再剥掉 `v` 前缀。** release workflow 的版本提取从 `${TAG_NAME#v}` 改为 `${TAG_NAME}`,即打 `v1.2.3` 标签时镜像 tag 保留为 `v1.2.3` 而非 `1.2.3`。纯发布流水线口径调整,不影响运行时。
  <details><summary>代码依据 .github/workflows/ci.yml</summary>

  ```diff
           if [[ "${{ github.ref }}" == refs/tags/* ]]; then
             TAG_NAME="${GITHUB_REF#refs/tags/}"
  -          echo "VERSION=${TAG_NAME#v}" >> $GITHUB_OUTPUT
  +          echo "VERSION=${TAG_NAME}" >> $GITHUB_OUTPUT
  ```
  </details>

### 后续发展方向 [AI]
- 本期 ascend 侧全是维护性修复(运行时依赖 + 发布 tag),无功能/架构演进信号。结合前一日刚落地的 vNPU 监控 chart,当前昇腾插件处于"配套打磨"阶段——把可观测性与部署可靠性补齐,而非扩虚拟化能力。证据仅覆盖 3 个改动文件(2 份 daemonset manifest + 1 份 CI),未见任何 Go 源码或 CRD 改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo(仅锚点,无正文)</summary>

- Project-HAMi/HAMi — 无新提交(Release 仍 v2.9.0)
- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=a1b418c7a439948e3e22192a397e1716ceecff34 branch=master release=v2.9.0 scanned=2026-07-15 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=06e698079335cffd0009f3c119bd95b012600ae5 branch=main release=— scanned=2026-07-15 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-15 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=f8ae57c30dd6e8311815bb3327a2991e34293b1d branch=main release=— scanned=2026-07-15 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-15 -->
</content>
</invoke>

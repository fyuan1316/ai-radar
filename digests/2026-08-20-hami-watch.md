# HAMi diff 雷达 2026-08-20

## 摘要
- 本日无实质改动。5 个仓库中 4 个无新提交;`Project-HAMi/HAMi` 仅有 2 条提交(golang.org/x/tools 依赖 bump + release workflow 权限收窄的 CI 改动),不触及 vGPU/vNPU 能力,归为 bump/CI 噪声。

## 当日重要改变
- 无

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- Project-HAMi/HAMi:仅 dep bump + CI。`build(deps): bump golang.org/x/tools from 0.48.0 to 0.49.0 (#2720)`(go.mod/go.sum +3/-3、+6/-0),`ci: move release workflow write permissions to job level (#2711)`。无信号文件、无源码 hunk。https://github.com/Project-HAMi/HAMi/compare/e803f7584137e08e134d00c8da9436f04b2bff17...949f78e634f67294e9c8f843c25b806837944532
- Project-HAMi/HAMi-core:无新提交
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=949f78e634f67294e9c8f843c25b806837944532 branch=master release=v2.9.0 scanned=2026-08-20 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-20 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=4fb76ba16a1744b161e9e2fbfc0b9ec3a546dd9b branch=main release=— scanned=2026-08-20 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=1cf92f2ff25cebfe6f6752c1d50bbb729fb0683e branch=main release=— scanned=2026-08-20 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-20 -->

# fy-runner 部署

## 文件命名约定

| 前缀 | 在哪跑 | 用什么 kubectl |
|---|---|---|
| `macos-*` | **macOS 本地** | 高权限 kubectl(集群管理员) |
| 其他 | **devpod 内 / 任何地方** | 默认 kubectl 即可(用 pod SA) |

## 首次部署(分两步)

### Step 1:macOS 本地一次性授权

```bash
# 在 macOS 上,确保 kubectl 是高权限那份
kubectl apply -f kbs/ai-radar/deploy/macos-rbac.yaml
```

授权之后,pod 内 `default` SA 拥有自己 ns 下管理 fy-runner 资源的全部权限。

### Step 2:在 devpod 里部署

```bash
cd /workspaces/yuanfang-base-ubuntu/kbs/ai-radar/deploy
./apply.sh
```

## 日常操作(全在 devpod 里)

```bash
./apply.sh              # 首次部署 / 更新 yaml
./apply.sh smoke        # 手动跑 oai-weekly 冒烟
./apply.sh smoke k8s-core   # 跑指定任务
./apply.sh logs         # 跟启动日志
./apply.sh restart      # .env 改了之后重新同步 Secret + 滚动
./apply.sh down         # 卸载 deployment + secret(RBAC 不动)
```

## 完全卸载(macOS)

```bash
# devpod 内先 down
./apply.sh down
# macOS 撤销 RBAC
kubectl delete -f kbs/ai-radar/deploy/macos-rbac.yaml
```

## 触发条件(原理速记)

- **Namespace 必须在 `MiHomoConfig.spec.targetNamespaces` 里** —— 否则不注入
- **Pod 必须带 label `devpod.sh/created: "true"`** —— webhook 第二层过滤
- 两者满足 → mihomo webhook 自动注入 `claude-config-watcher` sidecar + `/workspaces/.claude/` 凭证
- `fy-runner.yaml` 已经写好这个 label,别动

## Cron 调度(Asia/Shanghai)

| 时间 | 任务 | 选时理由 |
|---|---|---|
| 周一 09:00 | `arxiv-ai-systems` | 抓上周一~周五完整 arxiv,周末已沉淀 |
| 周一 17:00 | `openfuyao-weekly` | 国内项目,工作日午后扫描更全 |
| 周二 11:00 | `oai-weekly` | 上周完整 + 美国 patch tuesday 当天 |
| 周三 14:00 | `ai-infra-ecosystem` | 中期扫描(本周早期 vLLM/HF/SGLang release) |
| 周四 11:00 | `k8s-core` | 跟着美国周三 patch tuesday,SH 周四已可见 |
| 周四 13:00 | `k8s-ai-infra` | 跟 k8s-core 错峰 2h |
| 周五 14:00 | `ai-infra-ecosystem` | 总结扫描,覆盖中后段 release |

每周 7 条飞书消息,无空档日。改节奏直接编辑 `fy-runner.yaml` 里的 `cat > /work/crontab` 块,然后 `./apply.sh`。

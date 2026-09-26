# 昇腾算力栈 diff 雷达 2026-09-27

## 摘要
- 追踪的 9 个仓中,8 个 openFuyao 仓无新提交(EMPTY);mind-cluster 唯一新提交落在 `ascend-clusterops-agent`(cluster-ops 采集/快照 agent),**不在本 task 定义的 component 追踪清单内**(device-plugin / docker-runtime / for-volcano / operator / npu-exporter / noded / clusterd / infer-operator),故本日追踪范围内无实质代码变化。
- 附带记录:该 clusterops-agent 提交虽标题写"调整 plog collector 顺序",实际 diff 是把 relcache/pathmap 快照的 `SequentialShards` 分片路由从"追加式"改为"回填 + 主动 GC"策略(见下)。无 API/CRD 变更,不命中重要改变信号,tag 仍 v26.1.1 未跨档。

## 当日重要改变
无(本日无命中 [弃用/移除]/[API/CRD变更]/[架构方向]/[版本跨档]/[新能力] 的改动)。

## mind-cluster(范围外附注): e90da9d8 -> 90fb72cf
- 比较: e90da9d8..90fb72cf | tag: v26.1.1 | commits=2(1 merge + 1 实质)
- 提交标题:`[Fix][ClusterOPS] Adjust the order of plog collector`(标题误导,实为分片路由重写)
- 改动文件全在 `component/ascend-clusterops-agent/`,**未命中本 task 的 component PATHPREFIX**,以下研判仅作范围外记录,不代表追踪清单内组件有变化。

### AI 总结重点(源码 diff 为据)
- **新增 `DEFAULT_SHARD = 0` 常量并替换硬编码 0**:`shard_cm_name(base, shard)` 判断"shard 0 保留旧 CM 名(无数字后缀)"时改用 `DEFAULT_SHARD`,语义不变、仅去魔数,shard 0 始终保留。
  <details><summary>代码依据 agent-core/constants.py + agent-core/k8s.py</summary>

  ```diff
  +DEFAULT_SHARD = 0  # shard 0 keeps the legacy CM name (no numeric suffix) and is always kept
  ...
  -    return base_name if shard == 0 else f"{base_name}-{shard}"
  +    return base_name if shard == DEFAULT_SHARD else f"{base_name}-{shard}"
  ```
  </details>
- **分片填充策略从"追加式"改为"回填式"**:原 `_resume_fill_position` 快照恢复后把 active 跳到"最高非空分片"(`max(self._shard_bytes)`),新逻辑改为调用新增的 `_rewind_fill_position(size)`,每次路由新条目前先把 active **回退到最低的、仍有空间容纳该条目的分片**(default shard 优先,再 1、2…)。效果:低编号分片的空位被复用,而不是一路往高分片增长,ConfigMap 分片数收敛、抑制 shard CM 膨胀。
  <details><summary>代码依据 agent-core/k8s.py(SequentialShards)</summary>

  ```diff
  +        self._rewind_fill_position(size)
           while (
               self._shard_bytes.get(self._active, 0) and self._shard_bytes.get(self._active, 0) + size > self._fill_limit
           ):
  ...
  +    def _rewind_fill_position(self, size: int = 0) -> None:
  +        for shard in range(self._shards):
  +            used = self._shard_bytes.get(shard, 0)
  +            if used == 0 or used + size <= self._fill_limit:
  +                self._active = shard
  +                return
  +
       def _resume_fill_position(self) -> None:
  -        if self._shard_bytes:
  -            self._active = max(self._shard_bytes)
  +        self._rewind_fill_position()
  ```
  </details>
- **新增 `_has_deleted` 标志,路由新 pod 前主动 GC 过期条目**:任何缓存条目带 `deleted_at`(pod 被删)即置 `_has_deleted=True`;`upsert` 路由**新** pod(`old is None`)前若 `_has_deleted` 则先跑 `_gc()` 清理超 `POD_TTL` 的墓碑条目,避免 stale bytes 占住低分片挡住回填。`_gc` 结束按 `retained_deleted` 重算标志。原逻辑靠 `_gc` 内部 `changed` 触发 CM sync,不在写入路径前置清理。
  <details><summary>代码依据 agent-core/k8s.py(upsert / mark_deleted / _gc)</summary>

  ```diff
  +        if old is None and self._has_deleted:
  +            self._gc()
           target = self._active if old is not None else self._route_new_shard(serialized_bytes(entry))
  ...
  -                if e.get("deleted_at") and now - e["deleted_at"] > POD_TTL:
  -                    self._evict_pod(uid, e)
  -                    changed = True
  +                if e.get("deleted_at"):
  +                    if now - e["deleted_at"] > POD_TTL:
  +                        self._evict_pod(uid, e)
  +                        changed = True
  +                    else:
  +                        retained_deleted += 1
  +            self._has_deleted = retained_deleted > 0
  ```
  </details>

### 后续发展方向 [AI]
- 证据仅覆盖 `ascend-clusterops-agent` 的内存快照分片存储实现,方向是**把 pod/task 关系缓存持久化到分片 ConfigMap 的空间效率优化**(回填 + 前置 GC 抑制 CM 分片膨胀),属于 cluster-ops 侧运维数据面收敛,与 device-plugin/调度/驱动等追踪清单内组件无耦合。未见 API/CRD/调度语义变化。
- 对我们产品的启示:昇腾 cluster-ops agent 用"分片 ConfigMap 存 pod/task 关系快照"作为集群态持久化载体(而非 CRD/外部存储),分片满 1MB 切下一片、shard 0 兼容旧名——这是绕开单 ConfigMap 1MB 限制的典型做法,做同类集群态缓存时可参考,但要留意 GC/回填的一致性成本。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(保锚点)</summary>

- npu-operator:无新提交
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- vNPU:无新提交
- npu-node-provision:无新提交
- npu-dra-plugin:无新提交
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交
- mind-cluster(追踪清单内 component):无 diff(唯一提交在范围外的 clusterops-agent)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=90fb72cfef5c23e53cb19b517681eb53f3015bf0 tag=v26.1.1 scanned=2026-09-27 -->
<!-- ANCHOR repo=npu-operator sha=817e8a2372642f0e5b143a0faf1928d30cc12bdf tag=v26.6.0 scanned=2026-09-27 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-27 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-27 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-27 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-27 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-09-27 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-27 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-27 -->

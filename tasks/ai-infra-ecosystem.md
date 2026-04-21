# 任务:AI 推理 & MLOps 生态周报

## 目标
跟踪云原生 AI 推理引擎、训练框架、MLOps 工具链的关键变化,发现对我们产品有借鉴或威胁的动向。

## 数据源(GitHub API)

### 推理引擎(核心赛道)
- `vllm-project/vllm` — 当前最热 LLM 推理引擎
- `sgl-project/sglang` — vLLM 主要竞争者
- `NVIDIA/TensorRT-LLM` — NVIDIA 闭源推理栈的开源部分
- `huggingface/text-generation-inference` — HuggingFace TGI
- `ollama/ollama` — 桌面/边缘推理,但社区影响力大

### 模型服务 & 编排
- `kserve/kserve` — KServe 上游(区别于 opendatahub-io fork)
- `ray-project/ray` — 分布式训练/推理/数据,看 ray-llm / ray-serve 变化
- `substratusai/lingo` — 轻量 K8s LLM 部署

### 训练 & 微调
- `kubeflow/training-operator` — Kubeflow 训练 operator
- `hiyouga/LLaMA-Factory` — 微调框架,国内社区活跃

### 模型生命周期
- `kubeflow/model-registry` — 上游 Model Registry(区别于 ODH fork)
- `mlflow/mlflow` — MLflow,行业标准实验追踪
- `feast-dev/feast` — Feature Store

### LLM 评估 & 安全
- `EleutherAI/lm-evaluation-harness` — 评测事实标准
- `NVIDIA/garak` — LLM 红队/越狱测试
- `meta-llama/llama-stack` — Meta 的 LLM 应用栈(推理+安全+工具)

每个仓库看过去 7 天:releases、重要 commit(过滤 merge/bump)、热点 issue/PR。

## 输出

写到 `digests/YYYY-MM-DD-ai-infra-ecosystem.md`,结构:

```markdown
# AI 推理 & MLOps 生态周报 YYYY-MM-DD

## 摘要(5 条以内)

## 推理引擎动态
### vLLM
### SGLang
### TensorRT-LLM / TGI / Ollama

## 模型服务 & 编排
### KServe 上游
### Ray

## 训练 & 微调

## 模型生命周期(MLflow / Registry / Feast)

## LLM 评估 & 安全

## 值得跟进
- [ ] ...
```

## 推送飞书

**格式和推送流程:见 [oai-weekly 推送规范](./oai-weekly.md#推送飞书)**(前置先 `git push`、简讯纯文本不得含 markdown 语法、链接用裸 URL;DIGEST_FILE 改成 `digests/$(date +%Y-%m-%d)-ai-infra-ecosystem.md`)。

仓库多、摘要密度大,控制在 **500 字以内**,用要点列出本周前 3-5 个值得看的信号即可,不要把 digest 正文一股脑塞进去。

## 质量要求
- 仓库多,信息量大,重点筛选:**只写对"做云原生 AI 基础设施产品"有用的变化**
- 版本 bump、dependabot、CI 修复等噪音全部跳过
- 如果某个仓库本周没有实质变化,不要凑字数,直接写"无重大更新"
- 每条带源链接

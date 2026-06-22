Step 1
EKS

Step 2
GPU Node

Step 3
vLLM 0.5B

Step 4
curl 成功

Step 5
GitHub Action 自动验证

Step 6
Prometheus
  DEV_ENABLE_PROMETHEUS=1 → make install-prometheus TF_ENVIRONMENT=dev
  or GitHub dev env var DEV_ENABLE_PROMETHEUS=1 + Deploy

Step 7
KEDA

Step 8
ALB

Step 9
Qwen 7B/8B

Step 10
Production





对照 design.md 的 dev 路线图，当前状态如下（分 代码/配置已具备 和 dev 上真正跑通 两层）：

Step	内容	代码/CI	dev 实际验证
1
EKS
✅ terraform/environments/dev + Deploy workflow
✅ 曾跑起来（qwen-vllm-dev）；你最近在 destroy，且 destroy 失败（ECR/IGW 依赖），集群可能半残
2
GPU Node
✅ Karpenter NodePool g5.2xlarge
⚠️ 不稳定 — 有时能起 GPU 节点，常因 NodeClaim / disrupted taint Pending
3
vLLM 0.5B
✅ Qwen2.5-0.5B-Instruct + 保守 args
⚠️ pod 曾 Started（init 下完、vLLM 在 load），rollout 时 Evicted，未稳定 1/1 Running
4
curl 成功
✅ README + 本地 port-forward 说明
❌ 未稳定确认 — CI smoke test 曾因 model 名错失败（已改 /models/...），本地你 kubeconfig/Pending 也未完成一次 curl
5
GitHub Action 自动验证
✅ deploy.yml rollout 45m + dev smoke test
❌ 整条 CI 尚未稳定绿 — 到过 smoke test 但失败；fix 后是否再跑过不确定
6
Prometheus
❌ dev 故意跳过（install-addons.sh）
❌ 未做（符合 dev 最小路径）
7
KEDA
❌ dev 故意跳过（deploy-k8s.sh）
❌ 未做
8
ALB
❌ dev 故意跳过（install-controllers.sh）
❌ 未做
9
Qwen 7B/8B
❌ dev 默认仍是 0.5B
❌ 未做
10
Production
❌ 留给 main/prod
❌ 不是 dev 目标
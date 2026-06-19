using './main.bicep'

// =============================================================================
// デプロイ パラメーター（検証環境）
// タスク指定: Location = East US 2 / Resource Group = rg- プレフィックスで新規
// =============================================================================

param location = 'eastus2'
param namePrefix = 'agenteval'
param resourceGroupName = 'rg-agenteval-batcheval'

// ジャッジ（AI支援評価器）用 GPT デプロイ
param judgeModelName = 'gpt-4.1-mini'
param judgeModelVersion = '2025-04-14'
param judgeDeploymentName = 'gpt-4.1-mini'
param judgeModelSkuName = 'GlobalStandard'
param judgeModelCapacity = 50

param tags = {
  workload: 'agent-batch-eval'
  environment: 'poc'
  managedBy: 'bicep'
  task: 'Batch-eval'
}

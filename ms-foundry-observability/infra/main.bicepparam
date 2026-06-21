using './main.bicep'

// =============================================================================
// デプロイ パラメーター（検証環境 / 直接 az デプロイ用の参考値）
// 通常は deploy.settings + init-config からの値を使用します。このファイルは
// `az deployment sub create --parameters main.bicepparam` を直接使う場合の参考です。
// Location = East US 2 / Resource Group = rg- プレフィックスで新規
// =============================================================================

param location = 'eastus2'
param namePrefix = 'foundryobs'
param resourceGroupName = 'rg-foundryobs-eval'

// ジャッジ（AI支援評価器）用 GPT デプロイ
param judgeModelName = 'gpt-5.4'
param judgeModelVersion = '2026-03-05'
param judgeDeploymentName = 'gpt-5.4'
param judgeModelSkuName = 'GlobalStandard'
param judgeModelCapacity = 50

param tags = {
  workload: 'foundry-observability'
  environment: 'poc'
  managedBy: 'bicep'
}

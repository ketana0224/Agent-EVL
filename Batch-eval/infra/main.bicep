// =============================================================================
// Agent 評価基盤 (Batch Evaluation) - サブスクリプション スコープ メインテンプレート
// -----------------------------------------------------------------------------
// このテンプレートは Resource Group を新規作成し、その中に
//   - Log Analytics Workspace
//   - Application Insights (workspace-based)
//   - Microsoft Foundry アカウント + プロジェクト
//   - ジャッジ用 GPT モデルデプロイ
//   - プロジェクト → Application Insights 接続
// をデプロイします。
//
// 想定: Foundry のバッチ評価 (cloud evaluation) + App Insights トレース評価。
// 参照: _report/20260614-1600-batch-eval-foundry/final-report.md
// =============================================================================

targetScope = 'subscription'

// ----------------------------------------------------------------------------
// パラメーター
// ----------------------------------------------------------------------------

@description('全リソースのリージョン。タスク指定により既定は East US 2。')
param location string = 'eastus2'

@description('リソース名のベースとなるプレフィックス（標準プレフィックスで新規作成）。')
@minLength(3)
@maxLength(12)
param namePrefix string = 'agenteval'

@description('リソース名の一意サフィックス。既定はサブスクリプション+プレフィックスから生成。')
param nameSuffix string = substring(uniqueString(subscription().subscriptionId, namePrefix), 0, 5)

@description('作成する Resource Group 名（rg- プレフィックス）。')
param resourceGroupName string = 'rg-${namePrefix}-batcheval'

@description('ジャッジ（LLM評価器）用 GPT モデル名。')
param judgeModelName string = 'gpt-4.1-mini'

@description('ジャッジ用 GPT モデルのバージョン。')
param judgeModelVersion string = '2025-04-14'

@description('ジャッジ用モデルデプロイのデプロイ名（SDKから参照する名前）。')
param judgeDeploymentName string = 'gpt-4.1-mini'

@description('ジャッジ用モデルの SKU 種別。')
@allowed([
  'GlobalStandard'
  'Standard'
  'DataZoneStandard'
])
param judgeModelSkuName string = 'GlobalStandard'

@description('ジャッジ用モデルの容量（1000 TPM 単位）。')
param judgeModelCapacity int = 50

@description('共通タグ。')
param tags object = {
  workload: 'agent-batch-eval'
  environment: 'poc'
  managedBy: 'bicep'
}

// ----------------------------------------------------------------------------
// Resource Group
// ----------------------------------------------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ----------------------------------------------------------------------------
// リソース本体（RG スコープのモジュール）
// ----------------------------------------------------------------------------

module resources 'modules/resources.bicep' = {
  name: 'batch-eval-resources'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    nameSuffix: nameSuffix
    judgeModelName: judgeModelName
    judgeModelVersion: judgeModelVersion
    judgeDeploymentName: judgeDeploymentName
    judgeModelSkuName: judgeModelSkuName
    judgeModelCapacity: judgeModelCapacity
    tags: tags
  }
}

// ----------------------------------------------------------------------------
// 出力（deploy スクリプトが .env 生成に利用）
// ----------------------------------------------------------------------------

@description('作成された Resource Group 名。')
output resourceGroupName string = rg.name

@description('Foundry アカウント名。')
output foundryAccountName string = resources.outputs.foundryAccountName

@description('Foundry プロジェクト名。')
output foundryProjectName string = resources.outputs.foundryProjectName

@description('Foundry プロジェクト エンドポイント（SDK の PROJECT_ENDPOINT に使用）。')
output projectEndpoint string = resources.outputs.projectEndpoint

@description('Foundry プロジェクトのマネージドID プリンシパルID（RBAC付与に使用）。')
output projectPrincipalId string = resources.outputs.projectPrincipalId

@description('ジャッジ用モデルデプロイ名。')
output judgeDeploymentName string = resources.outputs.judgeDeploymentName

@description('Application Insights リソース名。')
output appInsightsName string = resources.outputs.appInsightsName

@description('Application Insights リソースID。')
output appInsightsId string = resources.outputs.appInsightsId

@description('Application Insights 接続文字列。')
output appInsightsConnectionString string = resources.outputs.appInsightsConnectionString

@description('Log Analytics Workspace リソースID。')
output logAnalyticsWorkspaceId string = resources.outputs.logAnalyticsWorkspaceId

// =============================================================================
// Agent 評価基盤 (Batch Evaluation) - Resource Group スコープ リソース
// =============================================================================

@description('リージョン。')
param location string

@description('リソース名プレフィックス。')
param namePrefix string

@description('一意サフィックス。')
param nameSuffix string

@description('ジャッジ用 GPT モデル名。')
param judgeModelName string

@description('ジャッジ用 GPT モデルのバージョン。')
param judgeModelVersion string

@description('ジャッジ用モデルデプロイ名。')
param judgeDeploymentName string

@description('ジャッジ用モデルの SKU 種別。')
param judgeModelSkuName string

@description('ジャッジ用モデルの容量（1000 TPM 単位）。')
param judgeModelCapacity int

@description('共通タグ。')
param tags object

// ----------------------------------------------------------------------------
// 命名
// ----------------------------------------------------------------------------

var logAnalyticsName = 'log-${namePrefix}-${nameSuffix}'
var appInsightsName = 'appi-${namePrefix}-${nameSuffix}'
var foundryAccountName = 'aif-${namePrefix}-${nameSuffix}'
var foundryProjectName = 'proj-${namePrefix}-${nameSuffix}'
var customSubDomain = toLower('${namePrefix}${nameSuffix}')

// ----------------------------------------------------------------------------
// 監視: Log Analytics Workspace + Application Insights (workspace-based)
// ----------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ----------------------------------------------------------------------------
// Microsoft Foundry アカウント (kind=AIServices, project management 有効)
// ----------------------------------------------------------------------------

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryAccountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: customSubDomain
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
  }
}

// ジャッジ（AI支援評価器）用 GPT モデルデプロイ
resource judgeDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundryAccount
  name: judgeDeploymentName
  sku: {
    name: judgeModelSkuName
    capacity: judgeModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: judgeModelName
      version: judgeModelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

// ----------------------------------------------------------------------------
// Foundry プロジェクト
// ----------------------------------------------------------------------------

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundryAccount
  name: foundryProjectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Agent Batch Evaluation Project'
    description: 'バッチ評価 + App Insights トレース評価の検証用プロジェクト'
  }
  dependsOn: [
    judgeDeployment
  ]
}

// プロジェクト → Application Insights 接続（トレース評価・結果ルーティング用）
resource appInsightsConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: foundryProject
  name: 'appinsights-connection'
  properties: {
    category: 'AppInsights'
    target: appInsights.id
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: {
      key: appInsights.properties.ConnectionString
    }
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsights.id
    }
  }
}

// ----------------------------------------------------------------------------
// 出力
// ----------------------------------------------------------------------------

output foundryAccountName string = foundryAccount.name
output foundryProjectName string = foundryProject.name
output projectEndpoint string = 'https://${customSubDomain}.services.ai.azure.com/api/projects/${foundryProject.name}'
output projectPrincipalId string = foundryProject.identity.principalId
output judgeDeploymentName string = judgeDeployment.name
output appInsightsName string = appInsights.name
output appInsightsId string = appInsights.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output logAnalyticsWorkspaceId string = logAnalytics.id

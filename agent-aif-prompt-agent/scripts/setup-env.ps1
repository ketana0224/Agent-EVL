#requires -Version 7.0
<#
.SYNOPSIS
    プロンプトエージェント実行用の .env を生成します（インフラのデプロイは不要）。

.DESCRIPTION
    プロンプトエージェントは既存の Foundry プロジェクトをそのまま使うため、
    追加リソース（Cosmos/Storage/Search）や Capability Host のデプロイは不要です。
    本スクリプトは ../ms-foundry-observability/.env から接続情報を引き継ぎ、
    このフォルダ直下の .env を生成します（create_agent.py が参照）。

    既存 .env の CONTOSO_MCP_URL / CONTOSO_MCP_KEY は維持されます。

.NOTES
    生成後: python -m pip install -r requirements.txt; python create_agent.py
#>
[CmdletBinding()]
param(
    [string]$ObservabilityEnv,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$envFile  = Join-Path $repoRoot '.env'

Write-Host '== プロンプトエージェント用 .env 生成 ==' -ForegroundColor Cyan

if ((Test-Path $envFile) -and -not $Force) {
    Write-Host "$envFile は既に存在します。CONTOSO_MCP_* は維持しつつ更新します。" -ForegroundColor Yellow
}

# --- ms-foundry-observability/.env から接続情報を取得 -------------------------
if (-not $ObservabilityEnv) {
    $ObservabilityEnv = Join-Path (Split-Path -Parent $repoRoot) 'ms-foundry-observability\.env'
}
$obs = @{}
if (Test-Path $ObservabilityEnv) {
    foreach ($line in Get-Content $ObservabilityEnv) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#') -and $t.Contains('=')) {
            $k, $v = $t -split '=', 2
            $obs[$k.Trim()] = $v.Trim()
        }
    }
    Write-Host "ms-foundry-observability/.env を検出: $ObservabilityEnv" -ForegroundColor Green
}
else {
    throw "ms-foundry-observability/.env が見つかりません: $ObservabilityEnv`n先に ../ms-foundry-observability をデプロイするか、-ObservabilityEnv で明示指定してください。"
}

$tenantId        = $obs['AZURE_TENANT_ID']
$subscriptionId  = $obs['AZURE_SUBSCRIPTION_ID']
$resourceGroup   = $obs['AZURE_RESOURCE_GROUP']
$projectEndpoint = $obs['PROJECT_ENDPOINT']
$modelDeployment = $obs['MODEL_DEPLOYMENT_NAME']
$appInsightsConn = $obs['APPLICATIONINSIGHTS_CONNECTION_STRING']
$appInsightsName = $obs['APPLICATIONINSIGHTS_NAME']

if (-not $projectEndpoint) {
    throw "PROJECT_ENDPOINT を観測基盤 .env から取得できませんでした: $ObservabilityEnv"
}

# --- 既存 .env から MCP 設定を維持 --------------------------------------------
$existingMcpUrl = ''
$existingMcpKey = ''
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^CONTOSO_MCP_URL=(.*)$') { $existingMcpUrl = $Matches[1] }
        if ($line -match '^CONTOSO_MCP_KEY=(.*)$') { $existingMcpKey = $Matches[1] }
    }
}

$envContent = @"
# 自動生成 (agent-aif-prompt-agent/scripts/setup-env.ps1) - $(Get-Date -Format o)
AZURE_TENANT_ID=$tenantId
AZURE_SUBSCRIPTION_ID=$subscriptionId
AZURE_RESOURCE_GROUP=$resourceGroup
PROJECT_ENDPOINT=$projectEndpoint
MODEL_DEPLOYMENT_NAME=$modelDeployment
AGENT_MODEL_DEPLOYMENT_NAME=
APPLICATIONINSIGHTS_CONNECTION_STRING=$appInsightsConn
APPLICATIONINSIGHTS_NAME=$appInsightsName
CONTOSO_MCP_URL=$existingMcpUrl
CONTOSO_MCP_KEY=$existingMcpKey
"@
Set-Content -Path $envFile -Value $envContent -Encoding utf8

Write-Host ''
Write-Host "環境変数を書き出しました: $envFile" -ForegroundColor Green
Write-Host "  PROJECT_ENDPOINT       = $projectEndpoint"
Write-Host "  MODEL_DEPLOYMENT_NAME  = $modelDeployment"
Write-Host ''
Write-Host '次の手順:' -ForegroundColor Yellow
Write-Host '  python -m pip install -r requirements.txt'
Write-Host '  python create_agent.py                 # サンプル質問でトレース生成'
Write-Host '  python create_agent.py --interactive   # 対話モード（マルチターン）'

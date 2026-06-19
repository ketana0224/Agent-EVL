#requires -Version 7.0
<#
.SYNOPSIS
    Agent 評価基盤（バッチ評価）の Azure リソースをデプロイします。

.DESCRIPTION
    1. Azure CLI でログイン状態とサブスクリプションを確認
    2. infra/main.bicep をサブスクリプション スコープでデプロイ（RG 新規作成）
    3. RBAC を付与
        - 実行ユーザー        -> Foundry アカウントに「Foundry User」
        - プロジェクト MI     -> Application Insights に「Monitoring Reader」「Log Analytics Reader」
    4. eval/.env を生成（SDK が参照する環境変数）

.NOTES
    既定値は環境変数 AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID から取得します。
    未設定の場合は現在の az ログイン コンテキスト（az account show）を使用します。
    パラメーターで明示指定も可能です（-TenantId / -SubscriptionId）。
      Location : eastus2 (East US 2)
#>

[CmdletBinding()]
param(
    [string]$TenantId       = $env:AZURE_TENANT_ID,
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$Location       = ($env:AZURE_LOCATION ?? 'eastus2'),
    [string]$DeploymentName = "$($env:DEPLOYMENT_NAME_PREFIX ?? 'batch-eval')-$(Get-Date -Format 'yyyyMMddHHmmss')",
    [switch]$SkipRbac
)

$ErrorActionPreference = 'Stop'
$repoRoot   = Split-Path -Parent $PSScriptRoot
$bicepParam = Join-Path $repoRoot 'infra\main.bicepparam'
$envFile    = Join-Path $repoRoot 'eval\.env'

Write-Host '== Agent 評価基盤 (バッチ評価) デプロイ ==' -ForegroundColor Cyan

# --- 0. Azure CLI 確認 ---------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) が見つかりません。https://aka.ms/installazurecli からインストールしてください。'
}

# --- 1. ログイン / サブスクリプション設定 --------------------------------------
# TenantId 未指定時は、テナント指定なしでログイン（既存コンテキストを利用）。
$account = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host 'Azure へログインします...' -ForegroundColor Yellow
    if ($TenantId) { az login --tenant $TenantId --only-show-errors | Out-Null }
    else { az login --only-show-errors | Out-Null }
    $account = az account show --only-show-errors 2>$null | ConvertFrom-Json
}
elseif ($TenantId -and $account.tenantId -ne $TenantId) {
    Write-Host "テナント $TenantId にログインします..." -ForegroundColor Yellow
    az login --tenant $TenantId --only-show-errors | Out-Null
    $account = az account show --only-show-errors 2>$null | ConvertFrom-Json
}

# 未指定の値は現在のコンテキストから補完
if (-not $SubscriptionId) { $SubscriptionId = $account.id }
if (-not $TenantId)       { $TenantId       = $account.tenantId }

az account set --subscription $SubscriptionId
Write-Host "サブスクリプション設定: $SubscriptionId" -ForegroundColor Green

$deployerObjectId = az ad signed-in-user show --query id -o tsv

# --- 2. デプロイ ---------------------------------------------------------------
Write-Host "Bicep をデプロイします (deployment: $DeploymentName)..." -ForegroundColor Yellow
az deployment sub create `
    --name $DeploymentName `
    --location $Location `
    --parameters $bicepParam `
    --only-show-errors `
    -o none
if ($LASTEXITCODE -ne 0) { throw 'デプロイに失敗しました。' }

# 出力は show で取得（create の stdout には Bicep CLI メッセージが混ざるため）
$o = az deployment sub show --name $DeploymentName --query properties.outputs -o json |
    ConvertFrom-Json
if (-not $o) { throw 'デプロイ出力の取得に失敗しました。' }
$resourceGroupName    = $o.resourceGroupName.value
$foundryAccountName   = $o.foundryAccountName.value
$projectEndpoint      = $o.projectEndpoint.value
$projectPrincipalId   = $o.projectPrincipalId.value
$judgeDeploymentName  = $o.judgeDeploymentName.value
$appInsightsName      = $o.appInsightsName.value
$appInsightsId        = $o.appInsightsId.value
$appInsightsConnStr   = $o.appInsightsConnectionString.value
$logAnalyticsId       = $o.logAnalyticsWorkspaceId.value

Write-Host 'デプロイ完了。' -ForegroundColor Green

# --- 3. RBAC -------------------------------------------------------------------
if (-not $SkipRbac) {
    Write-Host 'RBAC を付与します...' -ForegroundColor Yellow
    $foundryAccountId = az cognitiveservices account show `
        --name $foundryAccountName --resource-group $resourceGroupName `
        --query id -o tsv

    # 実行ユーザー -> Foundry アカウントに Foundry User
    az role assignment create `
        --assignee-object-id $deployerObjectId `
        --assignee-principal-type User `
        --role 'Foundry User' `
        --scope $foundryAccountId --only-show-errors | Out-Null

    # プロジェクト MI -> App Insights / LA にトレース読み取り権限
    foreach ($scope in @($appInsightsId, $logAnalyticsId)) {
        foreach ($role in @('Monitoring Reader', 'Log Analytics Reader')) {
            az role assignment create `
                --assignee-object-id $projectPrincipalId `
                --assignee-principal-type ServicePrincipal `
                --role $role `
                --scope $scope --only-show-errors | Out-Null
        }
    }
    Write-Host 'RBAC 付与完了。' -ForegroundColor Green
}

# --- 4. .env 生成 --------------------------------------------------------------
$envContent = @"
# 自動生成 (scripts/deploy.ps1) - $(Get-Date -Format o)
AZURE_TENANT_ID=$TenantId
AZURE_SUBSCRIPTION_ID=$SubscriptionId
AZURE_RESOURCE_GROUP=$resourceGroupName
PROJECT_ENDPOINT=$projectEndpoint
MODEL_DEPLOYMENT_NAME=$judgeDeploymentName
JUDGE_MODEL_DEPLOYMENT_NAME=$judgeDeploymentName
APPLICATIONINSIGHTS_CONNECTION_STRING=$appInsightsConnStr
APPLICATIONINSIGHTS_NAME=$appInsightsName
"@
Set-Content -Path $envFile -Value $envContent -Encoding utf8
Write-Host "環境変数を書き出しました: $envFile" -ForegroundColor Green

Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host "Resource Group : $resourceGroupName"
Write-Host "Project        : $projectEndpoint"
Write-Host "Judge model    : $judgeDeploymentName"
Write-Host "App Insights   : $appInsightsName"
Write-Host ''
Write-Host '次の手順:' -ForegroundColor Yellow
Write-Host '  1) cd eval; python -m venv .venv; .\.venv\Scripts\Activate.ps1; pip install -r requirements.txt'
Write-Host '  2) python ..\agent\create_agent.py        # 検証用エージェント作成'
Write-Host '  3) python run_batch_eval.py               # データセット バッチ評価'
Write-Host '  4) python run_trace_eval.py               # App Insights トレース評価 (preview)'

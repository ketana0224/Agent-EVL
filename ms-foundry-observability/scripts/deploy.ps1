#requires -Version 7.0
<#
.SYNOPSIS
    Microsoft Foundry 可観測性 環境の Azure リソースをデプロイします。

.DESCRIPTION
    0. deploy.settings（init-config.ps1 で生成）を読み込み、リソース名等を決定
    1. Azure CLI でログイン状態とサブスクリプションを確認
    2. infra/main.bicep をサブスクリプション スコープでデプロイ（RG 新規作成）
    3. RBAC を付与
        - 実行ユーザー        -> Foundry アカウントに「Foundry User」
        - プロジェクト MI     -> Application Insights に「Monitoring Reader」「Log Analytics Reader」
    4. .env を生成（リポジトリ ルート。評価コード・各エージェントの setup-env が参照する接続情報）

.NOTES
    リソース名・リージョン・モデル設定は deploy.settings で管理します。
    先に ./init-config.ps1 を実行して deploy.settings を生成・編集してください。
    テナント / サブスクリプションは環境変数 AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID、
    または現在の az ログイン コンテキストから取得します。
#>

[CmdletBinding()]
param(
    [string]$TenantId       = $env:AZURE_TENANT_ID,
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$SettingsFile,
    [switch]$PurgeSoftDeleted,
    [switch]$SkipRbac
)

$ErrorActionPreference = 'Stop'
$repoRoot     = Split-Path -Parent $PSScriptRoot
$gitRoot      = Split-Path -Parent $repoRoot
$templateFile = Join-Path $repoRoot 'infra\main.bicep'
$envFile      = Join-Path $gitRoot '.env'
if (-not $SettingsFile) { $SettingsFile = Join-Path $repoRoot 'deploy.settings' }

Write-Host '== Microsoft Foundry 可観測性 環境構築 デプロイ ==' -ForegroundColor Cyan

# --- 0a. 設定ファイル読み込み -------------------------------------------------
if (-not (Test-Path $SettingsFile)) {
    throw "設定ファイルが見つかりません: $SettingsFile`n先に ./init-config.ps1 を実行して設定ファイルを生成してください。"
}
$settings = @{}
foreach ($line in Get-Content $SettingsFile) {
    $t = $line.Trim()
    if ($t -and -not $t.StartsWith('#') -and $t.Contains('=')) {
        $k, $v = $t -split '=', 2
        $settings[$k.Trim()] = $v.Trim()
    }
}
$Location            = $settings['LOCATION']
$NamePrefix          = $settings['NAME_PREFIX']
$ResourceGroupName   = $settings['RESOURCE_GROUP_NAME']
$JudgeModelName      = $settings['JUDGE_MODEL_NAME']
$JudgeModelVersion   = $settings['JUDGE_MODEL_VERSION']
$JudgeDeploymentName = $settings['JUDGE_DEPLOYMENT_NAME']
$JudgeModelSkuName   = $settings['JUDGE_MODEL_SKU_NAME']
$JudgeModelCapacity  = $settings['JUDGE_MODEL_CAPACITY']
foreach ($req in 'LOCATION', 'NAME_PREFIX', 'RESOURCE_GROUP_NAME') {
    if (-not $settings[$req]) { throw "設定ファイルに $req がありません: $SettingsFile" }
}
$DeploymentName = "foundry-observability-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "設定: prefix=$NamePrefix / RG=$ResourceGroupName / location=$Location" -ForegroundColor Green

# --- 0b. Azure CLI 確認 --------------------------------------------------------
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

# --- 2a. ソフトデリート済み Foundry アカウントの衰突確認 ----------------------
# Foundry/Cognitive Services はソフトデリート対象。同名が残っていると
# 再デプロイが FlagMustBeSetForRestore で失敗するため事前に検出する。
$softDeleted = az cognitiveservices account list-deleted --only-show-errors -o json | ConvertFrom-Json
$collisions  = @($softDeleted | Where-Object { $_.name -like "aif-$NamePrefix-*" })
if ($collisions) {
    # ソフトデリート済みの同名アカウントは衝突要因。無視して進めるため自動 purge する。
    foreach ($c in $collisions) {
        # 削除済みアカウントの id は
        # .../resourceGroups/<rg>/deletedAccounts/<name> 形式。RG を正しく抽出する。
        if ($c.id -match '/resourceGroups/([^/]+)/') { $deletedRg = $Matches[1] }
        else { throw "リソースグループを id から抽出できませんでした: $($c.id)" }
        Write-Host "  purge (soft-deleted): $($c.name) [rg=$deletedRg]" -ForegroundColor Yellow
        az cognitiveservices account purge `
            --location $c.location `
            --resource-group $deletedRg `
            --name $c.name --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "purge に失敗しました: $($c.name)" }
    }

    # purge は非同期。soft-deleted リストから消えるまで待ってからデプロイする
    # （未完了のままだと FlagMustBeSetForRestore で失敗するため）。
    $targets = @($collisions | ForEach-Object { $_.name })
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 10
        $still = az cognitiveservices account list-deleted --only-show-errors -o json | ConvertFrom-Json
        $remaining = @($still | Where-Object { $targets -contains $_.name })
        if (-not $remaining) { break }
        Write-Host "  purge 完了待ち... ($($remaining.Count) 件残り)" -ForegroundColor DarkYellow
    }
    if ($remaining) { throw "purge の完了待ちがタイムアウトしました: $($remaining.name -join ', ')" }
    Write-Host '  purge 完了。' -ForegroundColor Green
}

# --- 2b. デプロイ --------------------------------------------------------------
Write-Host "Bicep をデプロイします (deployment: $DeploymentName)..." -ForegroundColor Yellow
az deployment sub create `
    --name $DeploymentName `
    --location $Location `
    --template-file $templateFile `
    --parameters `
        location=$Location `
        namePrefix=$NamePrefix `
        resourceGroupName=$ResourceGroupName `
        judgeModelName=$JudgeModelName `
        judgeModelVersion=$JudgeModelVersion `
        judgeDeploymentName=$JudgeDeploymentName `
        judgeModelSkuName=$JudgeModelSkuName `
        judgeModelCapacity=$JudgeModelCapacity `
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
# 自動生成 (ms-foundry-observability/scripts/deploy.ps1) - $(Get-Date -Format o)
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

# 同一セッションへもエクスポート（後続手順がファイル読み込みなしで即利用できる）。
# ※ このセッション限り有効。別ターミナル / Python からは上記 .env ファイルが担保します。
$env:AZURE_TENANT_ID                        = $TenantId
$env:AZURE_SUBSCRIPTION_ID                  = $SubscriptionId
$env:AZURE_RESOURCE_GROUP                   = $resourceGroupName
$env:PROJECT_ENDPOINT                       = $projectEndpoint
$env:MODEL_DEPLOYMENT_NAME                  = $judgeDeploymentName
$env:JUDGE_MODEL_DEPLOYMENT_NAME            = $judgeDeploymentName
$env:APPLICATIONINSIGHTS_CONNECTION_STRING  = $appInsightsConnStr
$env:APPLICATIONINSIGHTS_NAME               = $appInsightsName
Write-Host '現在のセッションに環境変数をエクスポートしました（後続手順でそのまま利用可）。' -ForegroundColor Green

Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host "Resource Group : $resourceGroupName"
Write-Host "Project        : $projectEndpoint"
Write-Host "Judge model    : $judgeDeploymentName"
Write-Host "App Insights   : $appInsightsName"
Write-Host "Env file       : $envFile"
Write-Host ''
Write-Host '次の手順:' -ForegroundColor Yellow
Write-Host "  - 生成された .env ($envFile) を評価コード・各エージェントの setup-env が参照します。"
Write-Host '  - 同じターミナルなら接続情報は環境変数としても利用できます（PROJECT_ENDPOINT など）。'

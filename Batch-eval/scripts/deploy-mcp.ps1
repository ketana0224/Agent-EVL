#requires -Version 7.0
<#
.SYNOPSIS
    Contoso ポリシー MCP サーバーを Azure Container Apps にデプロイします。

.DESCRIPTION
    1. Azure CLI / containerapp 拡張 / リソースプロバイダーを確認・登録
    2. `az containerapp up --source` でクラウドビルド（ローカル Docker 不要）し、
       ACR + Container Apps 環境 + Container App（外部 HTTPS Ingress, port 8000）を作成
    3. API キー（x-contoso-key）を生成し env var として設定
    4. 公開 URL とキーを eval/.env に追記（CONTOSO_MCP_URL / CONTOSO_MCP_KEY）

.NOTES
    既存のバッチ評価リソース（rg-agenteval-batcheval）と同じ RG / リージョンに配置します。
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId   = $env:AZURE_SUBSCRIPTION_ID,
    [string]$ResourceGroup    = ($env:AZURE_RESOURCE_GROUP    ?? 'rg-agenteval-batcheval'),
    [string]$Location         = ($env:AZURE_LOCATION          ?? 'eastus2'),
    [string]$AppName          = ($env:CONTOSO_MCP_APP_NAME    ?? 'contoso-policy-mcp'),
    [string]$EnvName          = ($env:CONTOSO_MCP_ENV_NAME    ?? 'aca-agenteval'),
    [string]$ApiKey           = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$mcpDir   = Join-Path $repoRoot 'mcp'
$envFile  = Join-Path $repoRoot 'eval\.env'

Write-Host '== Contoso MCP サーバー デプロイ (Azure Container Apps) ==' -ForegroundColor Cyan

# --- 0. 前提確認 ---------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) が見つかりません。'
}
# SubscriptionId 未指定時は現在の az コンテキストを使用
if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv 2>$null }
if (-not $SubscriptionId) { throw 'サブスクリプションが特定できません。az login を実行するか -SubscriptionId を指定してください。' }
az account set --subscription $SubscriptionId | Out-Null

Write-Host '[0/4] containerapp 拡張 / プロバイダーを確認...' -ForegroundColor Yellow
az extension add --name containerapp --upgrade --only-show-errors 2>$null | Out-Null
az provider register --namespace Microsoft.App --wait 2>$null | Out-Null
az provider register --namespace Microsoft.OperationalInsights --wait 2>$null | Out-Null
az provider register --namespace Microsoft.ContainerRegistry --wait 2>$null | Out-Null

# --- 1. API キー生成 -----------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey = [Convert]::ToHexString((1..16 | ForEach-Object { Get-Random -Max 256 } | ForEach-Object { [byte]$_ })).ToLower()
}
Write-Host "[1/4] API キーを生成しました（x-contoso-key）。" -ForegroundColor Yellow

# --- 2. RG 確認 ----------------------------------------------------------------
az group create -n $ResourceGroup -l $Location --only-show-errors | Out-Null

# --- 3. containerapp up（ソースからクラウドビルド） -----------------------------
Write-Host "[2/4] イメージをビルドして Container App をデプロイ（数分かかります）..." -ForegroundColor Yellow
Push-Location $mcpDir
try {
    az containerapp up `
        --name $AppName `
        --resource-group $ResourceGroup `
        --location $Location `
        --environment $EnvName `
        --source . `
        --ingress external `
        --target-port 8000 `
        --env-vars "CONTOSO_MCP_KEY=$ApiKey" "PORT=8000"
}
finally {
    Pop-Location
}

# --- 4. 公開 URL 取得 + .env 追記 ----------------------------------------------
$fqdn = az containerapp show -n $AppName -g $ResourceGroup --query properties.configuration.ingress.fqdn -o tsv
if ([string]::IsNullOrWhiteSpace($fqdn)) {
    throw 'Container App の FQDN を取得できませんでした。'
}
$mcpUrl = "https://$fqdn/mcp"

Write-Host "[3/4] 公開 URL: $mcpUrl" -ForegroundColor Yellow

# .env から既存の CONTOSO_MCP_* 行を除去して追記
if (Test-Path $envFile) {
    $lines = Get-Content $envFile | Where-Object { $_ -notmatch '^(CONTOSO_MCP_URL|CONTOSO_MCP_KEY)=' }
    Set-Content -Path $envFile -Value $lines -Encoding utf8
}
Add-Content -Path $envFile -Value "CONTOSO_MCP_URL=$mcpUrl" -Encoding utf8
Add-Content -Path $envFile -Value "CONTOSO_MCP_KEY=$ApiKey" -Encoding utf8

Write-Host '[4/4] eval/.env に CONTOSO_MCP_URL / CONTOSO_MCP_KEY を追記しました。' -ForegroundColor Yellow

Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host "MCP URL : $mcpUrl"
Write-Host "API Key : $ApiKey"
Write-Host ''
Write-Host '次の手順:' -ForegroundColor Cyan
Write-Host "  1) スモークテスト: cd ..\mcp; .\.venv\Scripts\python.exe smoke_test.py $mcpUrl $ApiKey"
Write-Host '  2) エージェントへ接続: cd ..\eval; .\.venv\Scripts\python.exe ..\agent\create_agent.py'

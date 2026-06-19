#requires -Version 7.0
<#
.SYNOPSIS
    Agent 評価基盤（バッチ評価）のリソースを削除します（Resource Group ごと削除）。
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId    = $env:AZURE_SUBSCRIPTION_ID,
    [string]$ResourceGroupName = ($env:AZURE_RESOURCE_GROUP ?? 'rg-agenteval-batcheval'),
    [string]$FoundryAccountPrefix = ($env:FOUNDRY_ACCOUNT_PREFIX ?? 'aif-'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# SubscriptionId 未指定時は現在の az コンテキストを使用
if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv 2>$null }
if (-not $SubscriptionId) { throw 'サブスクリプションが特定できません。az login を実行するか -SubscriptionId を指定してください。' }
az account set --subscription $SubscriptionId

if (-not $Force) {
    $confirm = Read-Host "Resource Group '$ResourceGroupName' を削除します。よろしいですか? (yes/no)"
    if ($confirm -ne 'yes') { Write-Host '中止しました。'; return }
}

Write-Host "Resource Group '$ResourceGroupName' を削除中..." -ForegroundColor Yellow
# 注: MCP 用の Azure Container Apps 環境 / コンテナーアプリ (contoso-policy-mcp) /
#     ACR / Log Analytics も同一 Resource Group 内のため、ここで一括削除されます。
az group delete --name $ResourceGroupName --yes --only-show-errors

# Foundry/Cognitive Services はソフトデリート対象。完全削除（purge）を試行。
Write-Host 'ソフトデリートされた Foundry アカウントを purge します...' -ForegroundColor Yellow
$deleted = az cognitiveservices account list-deleted --only-show-errors -o json | ConvertFrom-Json
foreach ($acc in $deleted) {
    if ($acc.name -like "$FoundryAccountPrefix*") {
        Write-Host "  purge: $($acc.name)"
        az cognitiveservices account purge `
            --location $acc.location `
            --resource-group ($acc.id -split '/')[4] `
            --name $acc.name --only-show-errors 2>$null
    }
}

Write-Host '削除完了。' -ForegroundColor Green

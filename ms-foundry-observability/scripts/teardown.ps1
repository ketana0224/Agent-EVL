#requires -Version 7.0
<#
.SYNOPSIS
    Microsoft Foundry 可観測性 環境のリソースを削除します（Resource Group ごと削除）。

.DESCRIPTION
    Resource Group 名・名前プレフィックスは deploy.settings から取得します
    （-ResourceGroupName / -NamePrefix で明示指定も可能）。
    ソフトデリート対象の Foundry アカウントは NAME_PREFIX に一致するものだけ purge します。
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId    = $env:AZURE_SUBSCRIPTION_ID,
    [string]$ResourceGroupName,
    [string]$NamePrefix,
    [string]$SettingsFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $SettingsFile) { $SettingsFile = Join-Path $repoRoot 'deploy.settings' }

# 設定ファイルから RG 名 / プレフィックスを補完
if (Test-Path $SettingsFile) {
    $settings = @{}
    foreach ($line in Get-Content $SettingsFile) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#') -and $t.Contains('=')) {
            $k, $v = $t -split '=', 2
            $settings[$k.Trim()] = $v.Trim()
        }
    }
    if (-not $ResourceGroupName) { $ResourceGroupName = $settings['RESOURCE_GROUP_NAME'] }
    if (-not $NamePrefix)        { $NamePrefix        = $settings['NAME_PREFIX'] }
}
if (-not $ResourceGroupName) { throw 'Resource Group 名が特定できません。-ResourceGroupName を指定するか deploy.settings を用意してください。' }
if (-not $NamePrefix)        { throw '名前プレフィックスが特定できません。-NamePrefix を指定するか deploy.settings を用意してください。' }

# SubscriptionId 未指定時は現在の az コンテキストを使用
if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv 2>$null }
if (-not $SubscriptionId) { throw 'サブスクリプションが特定できません。az login を実行するか -SubscriptionId を指定してください。' }
az account set --subscription $SubscriptionId

if (-not $Force) {
    $confirm = Read-Host "Resource Group '$ResourceGroupName' を削除します。よろしいですか? (yes/no)"
    if ($confirm -ne 'yes') { Write-Host '中止しました。'; return }
}

Write-Host "Resource Group '$ResourceGroupName' を削除中..." -ForegroundColor Yellow
az group delete --name $ResourceGroupName --yes --only-show-errors

# Foundry/Cognitive Services はソフトデリート対象。NAME_PREFIX 一致分のみ purge。
Write-Host "ソフトデリートされた Foundry アカウント (aif-$NamePrefix-*) を purge します..." -ForegroundColor Yellow
$deleted = az cognitiveservices account list-deleted --only-show-errors -o json | ConvertFrom-Json
foreach ($acc in $deleted) {
    if ($acc.name -like "aif-$NamePrefix-*") {
        Write-Host "  purge: $($acc.name)"
        az cognitiveservices account purge `
            --location $acc.location `
            --resource-group (($acc.id -split '/')[4]) `
            --name $acc.name --only-show-errors
        if ($LASTEXITCODE -ne 0) { Write-Warning "purge に失敗しました: $($acc.name)" }
    }
}

Write-Host '削除完了。' -ForegroundColor Green

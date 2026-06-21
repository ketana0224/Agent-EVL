#requires -Version 7.0
<#
.SYNOPSIS
    Microsoft Foundry 可観測性 環境構築の設定ファイル (deploy.settings) を生成します。

.DESCRIPTION
    deploy.ps1 / deploy.sh はこのファイルを読み込み、各値を Bicep パラメーターとして
    渡します。生成後、必要に応じて値を編集してから deploy を実行してください。

.EXAMPLE
    ./init-config.ps1
    ./init-config.ps1 -NamePrefix myfoundry -ResourceGroupName rg-myfoundry-obs -Force
#>
[CmdletBinding()]
param(
    [string]$Location            = 'eastus2',
    [ValidateLength(3, 12)]
    [string]$NamePrefix          = 'foundryobs',
    [string]$ResourceGroupName   = 'rg-foundryobs-eval',
    [string]$JudgeModelName      = 'gpt-5.4',
    [string]$JudgeModelVersion   = '2026-03-05',
    [string]$JudgeDeploymentName = 'gpt-5.4',
    [ValidateSet('GlobalStandard', 'Standard', 'DataZoneStandard')]
    [string]$JudgeModelSkuName   = 'GlobalStandard',
    [int]$JudgeModelCapacity     = 50,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot     = Split-Path -Parent $PSScriptRoot
$settingsFile = Join-Path $repoRoot 'deploy.settings'

if ((Test-Path $settingsFile) -and -not $Force) {
    Write-Host "設定ファイルは既に存在します: $settingsFile" -ForegroundColor Yellow
    Write-Host '上書きする場合は -Force を付けて再実行してください。'
    return
}

$content = @"
# =============================================================================
# Microsoft Foundry 可観測性 環境構築 設定ファイル
# init-config.ps1 / init-config.sh が生成。deploy.ps1 / deploy.sh が読み込みます。
# 値を編集してから deploy を実行してください（KEY=VALUE 形式 / # はコメント）。
# =============================================================================
LOCATION=$Location
NAME_PREFIX=$NamePrefix
RESOURCE_GROUP_NAME=$ResourceGroupName

# ジャッジ（AI支援評価器）用 GPT デプロイ
JUDGE_MODEL_NAME=$JudgeModelName
JUDGE_MODEL_VERSION=$JudgeModelVersion
JUDGE_DEPLOYMENT_NAME=$JudgeDeploymentName
JUDGE_MODEL_SKU_NAME=$JudgeModelSkuName
JUDGE_MODEL_CAPACITY=$JudgeModelCapacity
"@

Set-Content -Path $settingsFile -Value $content -Encoding utf8
Write-Host "設定ファイルを生成しました: $settingsFile" -ForegroundColor Green
Write-Host '必要に応じて値を編集し、./deploy.ps1 を実行してください。'

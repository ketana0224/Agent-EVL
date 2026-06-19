#!/usr/bin/env bash
# =============================================================================
# Agent 評価基盤（バッチ評価）デプロイ - Bash / Azure CLI 版
# TenantID / SubscriptionID は環境変数 AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID、
# または TENANT_ID / SUBSCRIPTION_ID から取得します。未設定時は現在の az ログイン
# コンテキスト（az account show）を使用します。
#   Location : eastus2
# =============================================================================
set -euo pipefail

TENANT_ID="${TENANT_ID:-${AZURE_TENANT_ID:-}}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-${AZURE_SUBSCRIPTION_ID:-}}"
LOCATION="${LOCATION:-${AZURE_LOCATION:-eastus2}}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-${DEPLOYMENT_NAME_PREFIX:-batch-eval}-$(date +%Y%m%d%H%M%S)}"
SKIP_RBAC="${SKIP_RBAC:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BICEP_PARAM="$REPO_ROOT/infra/main.bicepparam"
ENV_FILE="$REPO_ROOT/eval/.env"

echo "== Agent 評価基盤 (バッチ評価) デプロイ =="

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) が必要です。"; exit 1; }

# ログイン確認（未ログイン時のみログイン）
CURRENT_TENANT="$(az account show --query tenantId -o tsv 2>/dev/null || true)"
if [[ -z "$CURRENT_TENANT" ]]; then
  echo "Azure へログインします..."
  if [[ -n "$TENANT_ID" ]]; then
    az login --tenant "$TENANT_ID" --only-show-errors >/dev/null
  else
    az login --only-show-errors >/dev/null
  fi
elif [[ -n "$TENANT_ID" && "$CURRENT_TENANT" != "$TENANT_ID" ]]; then
  echo "テナント $TENANT_ID にログインします..."
  az login --tenant "$TENANT_ID" --only-show-errors >/dev/null
fi

# 未指定の値は現在のコンテキストから補完
[[ -z "$SUBSCRIPTION_ID" ]] && SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
[[ -z "$TENANT_ID" ]] && TENANT_ID="$(az account show --query tenantId -o tsv)"

az account set --subscription "$SUBSCRIPTION_ID"
echo "サブスクリプション設定: $SUBSCRIPTION_ID"

DEPLOYER_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"

# デプロイ
echo "Bicep をデプロイします (deployment: $DEPLOYMENT_NAME)..."
az deployment sub create \
  --name "$DEPLOYMENT_NAME" \
  --location "$LOCATION" \
  --parameters "$BICEP_PARAM" \
  --only-show-errors \
  -o none

# 出力は show で取得（create の stdout に Bicep CLI メッセージが混ざるため）
OUTPUTS="$(az deployment sub show \
  --name "$DEPLOYMENT_NAME" \
  --query properties.outputs -o json)"

get() { echo "$OUTPUTS" | python3 -c "import sys,json;print(json.load(sys.stdin)['$1']['value'])"; }

RESOURCE_GROUP_NAME="$(get resourceGroupName)"
FOUNDRY_ACCOUNT_NAME="$(get foundryAccountName)"
PROJECT_ENDPOINT="$(get projectEndpoint)"
PROJECT_PRINCIPAL_ID="$(get projectPrincipalId)"
JUDGE_DEPLOYMENT_NAME="$(get judgeDeploymentName)"
APPINSIGHTS_NAME="$(get appInsightsName)"
APPINSIGHTS_ID="$(get appInsightsId)"
APPINSIGHTS_CONNSTR="$(get appInsightsConnectionString)"
LOG_ANALYTICS_ID="$(get logAnalyticsWorkspaceId)"

echo "デプロイ完了。"

# RBAC
if [[ "$SKIP_RBAC" != "true" ]]; then
  echo "RBAC を付与します..."
  FOUNDRY_ACCOUNT_ID="$(az cognitiveservices account show \
    --name "$FOUNDRY_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv)"

  az role assignment create \
    --assignee-object-id "$DEPLOYER_OBJECT_ID" --assignee-principal-type User \
    --role "Foundry User" --scope "$FOUNDRY_ACCOUNT_ID" --only-show-errors >/dev/null

  for SCOPE in "$APPINSIGHTS_ID" "$LOG_ANALYTICS_ID"; do
    for ROLE in "Monitoring Reader" "Log Analytics Reader"; do
      az role assignment create \
        --assignee-object-id "$PROJECT_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
        --role "$ROLE" --scope "$SCOPE" --only-show-errors >/dev/null
    done
  done
  echo "RBAC 付与完了。"
fi

# .env 生成
cat > "$ENV_FILE" <<EOF
# 自動生成 (scripts/deploy.sh) - $(date -u +%Y-%m-%dT%H:%M:%SZ)
AZURE_TENANT_ID=$TENANT_ID
AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID
AZURE_RESOURCE_GROUP=$RESOURCE_GROUP_NAME
PROJECT_ENDPOINT=$PROJECT_ENDPOINT
MODEL_DEPLOYMENT_NAME=$JUDGE_DEPLOYMENT_NAME
JUDGE_MODEL_DEPLOYMENT_NAME=$JUDGE_DEPLOYMENT_NAME
APPLICATIONINSIGHTS_CONNECTION_STRING=$APPINSIGHTS_CONNSTR
APPLICATIONINSIGHTS_NAME=$APPINSIGHTS_NAME
EOF

echo ""
echo "== 完了 =="
echo "Resource Group : $RESOURCE_GROUP_NAME"
echo "Project        : $PROJECT_ENDPOINT"
echo "Judge model    : $JUDGE_DEPLOYMENT_NAME"
echo "App Insights   : $APPINSIGHTS_NAME"

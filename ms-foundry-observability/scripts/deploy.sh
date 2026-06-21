#!/usr/bin/env bash
# =============================================================================
# Microsoft Foundry 可観測性 環境構築 デプロイ - Bash / Azure CLI 版
# リソース名・リージョン・モデル設定は deploy.settings（init-config.sh で生成）から
# 読み込みます。先に ./init-config.sh を実行して設定ファイルを生成・編集してください。
# TenantID / SubscriptionID は環境変数 AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID、
# または現在の az ログイン コンテキストから取得します。
# =============================================================================
set -euo pipefail

TENANT_ID="${TENANT_ID:-${AZURE_TENANT_ID:-}}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-${AZURE_SUBSCRIPTION_ID:-}}"
SKIP_RBAC="${SKIP_RBAC:-false}"
PURGE_SOFT_DELETED="${PURGE_SOFT_DELETED:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GIT_ROOT="$(dirname "$REPO_ROOT")"
TEMPLATE_FILE="$REPO_ROOT/infra/main.bicep"
ENV_FILE="$GIT_ROOT/.env"
SETTINGS_FILE="${SETTINGS_FILE:-$REPO_ROOT/deploy.settings}"

echo "== Microsoft Foundry 可観測性 環境構築 デプロイ =="

# 設定ファイル読み込み
if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "設定ファイルが見つかりません: $SETTINGS_FILE" >&2
  echo "先に ./init-config.sh を実行して設定ファイルを生成してください。" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$SETTINGS_FILE"
set +a
: "${LOCATION:?deploy.settings に LOCATION がありません}"
: "${NAME_PREFIX:?deploy.settings に NAME_PREFIX がありません}"
: "${RESOURCE_GROUP_NAME:?deploy.settings に RESOURCE_GROUP_NAME がありません}"
DEPLOYMENT_NAME="foundry-observability-$(date +%Y%m%d%H%M%S)"
echo "設定: prefix=$NAME_PREFIX / RG=$RESOURCE_GROUP_NAME / location=$LOCATION"

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

# ソフトデリート済み Foundry アカウントの衰突確認
COLLISIONS="$(az cognitiveservices account list-deleted --only-show-errors -o json \
  | python3 -c "import sys,json;print('\n'.join(a['name']+'|'+a['location']+'|'+a['id'].split('/')[4] for a in json.load(sys.stdin) if a['name'].startswith('aif-${NAME_PREFIX}-')))")"
if [[ -n "$COLLISIONS" ]]; then
  if [[ "$PURGE_SOFT_DELETED" == "true" ]]; then
    while IFS='|' read -r CNAME CLOC CRG; do
      [[ -z "$CNAME" ]] && continue
      echo "  purge (soft-deleted): $CNAME"
      az cognitiveservices account purge --location "$CLOC" --resource-group "$CRG" --name "$CNAME" --only-show-errors
    done <<< "$COLLISIONS"
  else
    echo "ソフトデリート済みの Foundry アカウントが存在します:" >&2
    echo "$COLLISIONS" | cut -d'|' -f1 >&2
    echo "PURGE_SOFT_DELETED=true を付けて再実行するか、手動で purge してください。" >&2
    exit 1
  fi
fi

# デプロイ
echo "Bicep をデプロイします (deployment: $DEPLOYMENT_NAME)..."
az deployment sub create \
  --name "$DEPLOYMENT_NAME" \
  --location "$LOCATION" \
  --template-file "$TEMPLATE_FILE" \
  --parameters \
    location="$LOCATION" \
    namePrefix="$NAME_PREFIX" \
    resourceGroupName="$RESOURCE_GROUP_NAME" \
    judgeModelName="$JUDGE_MODEL_NAME" \
    judgeModelVersion="$JUDGE_MODEL_VERSION" \
    judgeDeploymentName="$JUDGE_DEPLOYMENT_NAME" \
    judgeModelSkuName="$JUDGE_MODEL_SKU_NAME" \
    judgeModelCapacity="$JUDGE_MODEL_CAPACITY" \
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
# 自動生成 (ms-foundry-observability/scripts/deploy.sh) - $(date -u +%Y-%m-%dT%H:%M:%SZ)
AZURE_TENANT_ID=$TENANT_ID
AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID
AZURE_RESOURCE_GROUP=$RESOURCE_GROUP_NAME
PROJECT_ENDPOINT=$PROJECT_ENDPOINT
MODEL_DEPLOYMENT_NAME=$JUDGE_DEPLOYMENT_NAME
JUDGE_MODEL_DEPLOYMENT_NAME=$JUDGE_DEPLOYMENT_NAME
APPLICATIONINSIGHTS_CONNECTION_STRING=$APPINSIGHTS_CONNSTR
APPLICATIONINSIGHTS_NAME=$APPINSIGHTS_NAME
EOF

# 同一セッションへもエクスポート（source した場合に後続手順が即利用できる）。
# ※ このセッション限り有効。別ターミナル / Python からは上記 .env ファイルが担保します。
export AZURE_TENANT_ID="$TENANT_ID"
export AZURE_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export AZURE_RESOURCE_GROUP="$RESOURCE_GROUP_NAME"
export PROJECT_ENDPOINT="$PROJECT_ENDPOINT"
export MODEL_DEPLOYMENT_NAME="$JUDGE_DEPLOYMENT_NAME"
export JUDGE_MODEL_DEPLOYMENT_NAME="$JUDGE_DEPLOYMENT_NAME"
export APPLICATIONINSIGHTS_CONNECTION_STRING="$APPINSIGHTS_CONNSTR"
export APPLICATIONINSIGHTS_NAME="$APPINSIGHTS_NAME"

echo ""
echo "== 完了 =="
echo "Resource Group : $RESOURCE_GROUP_NAME"
echo "Project        : $PROJECT_ENDPOINT"
echo "Judge model    : $JUDGE_DEPLOYMENT_NAME"
echo "App Insights   : $APPINSIGHTS_NAME"
echo "Env file       : $ENV_FILE"
echo ""
echo "次の手順:"
echo "  - 生成された .env ($ENV_FILE) を評価コード・各エージェントの setup-env が参照します。"
echo "  - このスクリプトを 'source ./deploy.sh' で実行した場合、接続情報は同セッションの環境変数としても利用できます。"

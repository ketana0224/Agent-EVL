#!/usr/bin/env bash
# プロンプトエージェント実行用の .env を生成（インフラのデプロイは不要）。
# プロンプトエージェントは既存の Foundry プロジェクトをそのまま使うため、
# 追加リソースや Capability Host のデプロイは不要。
# ルートの .env から接続情報を引き継ぎ、このフォルダ直下の .env を生成する。
# 既存 .env の CONTOSO_MCP_URL / CONTOSO_MCP_KEY は維持する。
#
# 環境変数:
#   OBSERVABILITY_ENV   接続情報元 .env のパス（既定: リポジトリ ルートの .env）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_ROOT/.env"

echo "== プロンプトエージェント用 .env 生成 =="

OBSERVABILITY_ENV="${OBSERVABILITY_ENV:-$(dirname "$REPO_ROOT")/.env}"
if [[ ! -f "$OBSERVABILITY_ENV" ]]; then
  echo "ERROR: ルートの .env が見つかりません: $OBSERVABILITY_ENV" >&2
  echo "       先に ../ms-foundry-observability をデプロイするか、OBSERVABILITY_ENV を指定してください。" >&2
  exit 1
fi
echo "観測基盤 .env を検出: $OBSERVABILITY_ENV"

get_val() { grep -E "^$1=" "$OBSERVABILITY_ENV" | head -n1 | cut -d= -f2- || true; }

TENANT_ID="$(get_val AZURE_TENANT_ID)"
SUBSCRIPTION_ID="$(get_val AZURE_SUBSCRIPTION_ID)"
RESOURCE_GROUP="$(get_val AZURE_RESOURCE_GROUP)"
PROJECT_ENDPOINT="$(get_val PROJECT_ENDPOINT)"
MODEL_DEPLOYMENT="$(get_val MODEL_DEPLOYMENT_NAME)"
APPINSIGHTS_CONN="$(get_val APPLICATIONINSIGHTS_CONNECTION_STRING)"
APPINSIGHTS_NAME="$(get_val APPLICATIONINSIGHTS_NAME)"

if [[ -z "$PROJECT_ENDPOINT" ]]; then
  echo "ERROR: PROJECT_ENDPOINT を観測基盤 .env から取得できませんでした。" >&2
  exit 1
fi

# 既存 .env から MCP 設定を維持
EXISTING_MCP_URL=""
EXISTING_MCP_KEY=""
if [[ -f "$ENV_FILE" ]]; then
  EXISTING_MCP_URL="$(grep -E '^CONTOSO_MCP_URL=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  EXISTING_MCP_KEY="$(grep -E '^CONTOSO_MCP_KEY=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
fi

# フォルダの .env に無ければルートの .env（mcp デプロイが書き込む）から引き継ぐ
[[ -z "$EXISTING_MCP_URL" ]] && EXISTING_MCP_URL="$(get_val CONTOSO_MCP_URL)"
[[ -z "$EXISTING_MCP_KEY" ]] && EXISTING_MCP_KEY="$(get_val CONTOSO_MCP_KEY)"

cat > "$ENV_FILE" <<EOF
# 自動生成 (agent-aif-prompt-agent/scripts/setup-env.sh) - $(date -u +%Y-%m-%dT%H:%M:%SZ)
AZURE_TENANT_ID=$TENANT_ID
AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID
AZURE_RESOURCE_GROUP=$RESOURCE_GROUP
PROJECT_ENDPOINT=$PROJECT_ENDPOINT
MODEL_DEPLOYMENT_NAME=$MODEL_DEPLOYMENT
AGENT_MODEL_DEPLOYMENT_NAME=
APPLICATIONINSIGHTS_CONNECTION_STRING=$APPINSIGHTS_CONN
APPLICATIONINSIGHTS_NAME=$APPINSIGHTS_NAME
CONTOSO_MCP_URL=$EXISTING_MCP_URL
CONTOSO_MCP_KEY=$EXISTING_MCP_KEY
EOF

echo ""
echo "環境変数を書き出しました: $ENV_FILE"
echo "  PROJECT_ENDPOINT      = $PROJECT_ENDPOINT"
echo "  MODEL_DEPLOYMENT_NAME = $MODEL_DEPLOYMENT"
echo ""
echo "次の手順:"
echo "  python -m pip install -r requirements.txt"
echo "  python create_agent.py                 # サンプル質問でトレース生成"
echo "  python create_agent.py --interactive   # 対話モード（マルチターン）"

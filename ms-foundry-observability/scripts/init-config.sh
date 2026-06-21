#!/usr/bin/env bash
# =============================================================================
# Microsoft Foundry 可観測性 環境構築の設定ファイル (deploy.settings) を生成します。
# deploy.sh / deploy.ps1 がこのファイルを読み込みます。
# 値は環境変数で上書き可能 (例: NAME_PREFIX=myfoundry ./init-config.sh)。
# 既存ファイルを上書きするには FORCE=true を指定します。
# =============================================================================
set -euo pipefail

LOCATION="${LOCATION:-eastus2}"
NAME_PREFIX="${NAME_PREFIX:-foundryobs}"
RESOURCE_GROUP_NAME="${RESOURCE_GROUP_NAME:-rg-foundryobs-eval}"
JUDGE_MODEL_NAME="${JUDGE_MODEL_NAME:-gpt-5.4}"
JUDGE_MODEL_VERSION="${JUDGE_MODEL_VERSION:-2026-03-05}"
JUDGE_DEPLOYMENT_NAME="${JUDGE_DEPLOYMENT_NAME:-gpt-4.1-mini}"
JUDGE_MODEL_SKU_NAME="${JUDGE_MODEL_SKU_NAME:-GlobalStandard}"
JUDGE_MODEL_CAPACITY="${JUDGE_MODEL_CAPACITY:-50}"
FORCE="${FORCE:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SETTINGS_FILE="$REPO_ROOT/deploy.settings"

if [[ -f "$SETTINGS_FILE" && "$FORCE" != "true" ]]; then
  echo "設定ファイルは既に存在します: $SETTINGS_FILE"
  echo "上書きする場合は FORCE=true ./init-config.sh を実行してください。"
  exit 0
fi

cat > "$SETTINGS_FILE" <<EOF
# =============================================================================
# Microsoft Foundry 可観測性 環境構築 設定ファイル
# init-config.ps1 / init-config.sh が生成。deploy.ps1 / deploy.sh が読み込みます。
# 値を編集してから deploy を実行してください（KEY=VALUE 形式 / # はコメント）。
# =============================================================================
LOCATION=$LOCATION
NAME_PREFIX=$NAME_PREFIX
RESOURCE_GROUP_NAME=$RESOURCE_GROUP_NAME

# ジャッジ（AI支援評価器）用 GPT デプロイ
JUDGE_MODEL_NAME=$JUDGE_MODEL_NAME
JUDGE_MODEL_VERSION=$JUDGE_MODEL_VERSION
JUDGE_DEPLOYMENT_NAME=$JUDGE_DEPLOYMENT_NAME
JUDGE_MODEL_SKU_NAME=$JUDGE_MODEL_SKU_NAME
JUDGE_MODEL_CAPACITY=$JUDGE_MODEL_CAPACITY
EOF

echo "設定ファイルを生成しました: $SETTINGS_FILE"
echo "必要に応じて値を編集し、./deploy.sh を実行してください。"

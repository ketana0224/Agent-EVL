"""
設定ユーティリティ: .env 読み込み・環境変数アクセス。
=====================================================================
このフォルダ（agent-custom-MAF-ACA）直下の .env を読み込む。ローカル実行では
scripts/setup-env が生成した .env を使い、ACA 上では Container App の環境変数
（deploy-aca.ps1 が設定）から同じキーを読み取る。自己完結のため外部フォルダへの
依存（sys.path 操作）は行わない。

プロンプトエージェント（agent-aif-prompt-agent）と同じ接続情報・MCP 設定・モデルを
使用する。違いは「フルマネージド」ではなく「自前コンテナ（MAF）」で実行する点のみ。
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

# agent-custom-MAF-ACA/.env を読み込む（無ければ環境変数のみ使用）
_ENV_PATH = Path(__file__).resolve().parent.parent / ".env"
load_dotenv(dotenv_path=_ENV_PATH)


def require(name: str) -> str:
    """必須環境変数を取得（無ければ明確なエラー）。"""
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"環境変数 {name} が未設定です。ローカルでは scripts/setup-env.ps1 "
            f"(または setup-env.sh) を実行して {_ENV_PATH} を生成するか、ACA では "
            f"deploy-aca.ps1 が Container App に設定します。"
        )
    return value


def project_endpoint() -> str:
    """Foundry プロジェクト エンドポイント（FoundryChatClient が参照）。"""
    return require("PROJECT_ENDPOINT")


def model_deployment_name() -> str:
    """エージェントが使用するモデルデプロイ名。"""
    return os.environ.get("AGENT_MODEL_DEPLOYMENT_NAME") or require("MODEL_DEPLOYMENT_NAME")


def mcp_config() -> tuple[str | None, str | None]:
    """Contoso ポリシー MCP の (URL, APIキー) を返す。未設定なら (None, None)。"""
    return os.environ.get("CONTOSO_MCP_URL"), os.environ.get("CONTOSO_MCP_KEY")


def appinsights_connection_string() -> str | None:
    """Application Insights 接続文字列（OTel トレース送信先, 任意）。"""
    return os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")

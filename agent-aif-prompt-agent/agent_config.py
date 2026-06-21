"""
共通ユーティリティ: .env 読み込み・Foundry / OpenAI クライアント取得。
=====================================================================
このフォルダ（agent-aif-prompt-agent）直下の .env を読み込み、Foundry プロジェクト
クライアントと OpenAI 互換クライアントを返す。自己完結のため外部フォルダへの
依存（sys.path 操作）は行わない。

依存: azure-ai-projects>=2.2.0, azure-identity, openai, python-dotenv
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

# agent-aif-prompt-agent/.env を読み込む（scripts/setup-env が自動生成）
_ENV_PATH = Path(__file__).resolve().parent / ".env"
load_dotenv(dotenv_path=_ENV_PATH)


def require(name: str) -> str:
    """必須環境変数を取得（無ければ明確なエラー）。"""
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"環境変数 {name} が未設定です。先に scripts/setup-env.ps1 (または setup-env.sh) を "
            f"実行して {_ENV_PATH} を生成するか、手動で設定してください。"
        )
    return value


def _get_credential():
    """az CLI 優先（長タイムアウト）、失敗時は DefaultAzureCredential。

    この環境では az CLI の応答が遅く DefaultAzureCredential の既定 10s タイムアウトを
    超えるため、AzureCliCredential を長めの process_timeout で優先使用する。
    """
    try:
        from azure.identity import AzureCliCredential

        cred = AzureCliCredential(process_timeout=90)
        # 早期検証: トークン取得できなければ例外 -> フォールバック
        cred.get_token("https://management.azure.com/.default")
        return cred
    except Exception:  # noqa: BLE001
        from azure.identity import DefaultAzureCredential

        return DefaultAzureCredential()


def get_project_client():
    """Foundry プロジェクト クライアント（AAD 認証）。"""
    from azure.ai.projects import AIProjectClient

    endpoint = require("PROJECT_ENDPOINT")
    return AIProjectClient(
        endpoint=endpoint,
        credential=_get_credential(),
    )


def get_openai_client(project_client=None):
    """エージェント呼び出し用の OpenAI 互換クライアント。"""
    project_client = project_client or get_project_client()
    return project_client.get_openai_client()


def model_deployment_name() -> str:
    """エージェントが使用するモデルデプロイ名。"""
    return os.environ.get("AGENT_MODEL_DEPLOYMENT_NAME") or require("MODEL_DEPLOYMENT_NAME")


def mcp_config() -> tuple[str | None, str | None]:
    """Contoso ポリシー MCP の (URL, APIキー) を返す。未設定なら (None, None)。"""
    return os.environ.get("CONTOSO_MCP_URL"), os.environ.get("CONTOSO_MCP_KEY")

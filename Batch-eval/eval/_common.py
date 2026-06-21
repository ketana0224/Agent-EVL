"""
共通ユーティリティ: .env 読み込み・Foundry / OpenAI クライアント取得。

依存: azure-ai-projects>=2.2.0, azure-identity, openai, python-dotenv
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

# .env を読み込む。deploy スクリプト (ms-foundry-observability/scripts/deploy.ps1) が
# リポジトリ ルートに .env を生成するため、それを優先して参照する。
# 無ければ従来どおり eval/.env（隣接）にフォールバックする。
_REPO_ROOT = Path(__file__).resolve().parents[2]
_ENV_CANDIDATES = (
    _REPO_ROOT / ".env",
    Path(__file__).resolve().parent / ".env",
)
_ENV_PATH = next((p for p in _ENV_CANDIDATES if p.exists()), _ENV_CANDIDATES[0])
load_dotenv(dotenv_path=_ENV_PATH)


def require(name: str) -> str:
    """必須環境変数を取得（無ければ明確なエラー）。"""
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"環境変数 {name} が未設定です。先に scripts/deploy.ps1 を実行して "
            f"{_ENV_PATH} を生成するか、手動で設定してください。"
        )
    return value


def get_project_client():
    """Foundry プロジェクト クライアント（AAD 認証）。

    この環境では az CLI の応答が遅く DefaultAzureCredential の既定 10s タイムアウトを
    超えるため、AzureCliCredential を長めの process_timeout で優先使用する。
    """
    from azure.ai.projects import AIProjectClient

    endpoint = require("PROJECT_ENDPOINT")
    return AIProjectClient(
        endpoint=endpoint,
        credential=_get_credential(),
    )


def _get_credential():
    """az CLI 優先（長タイムアウト）、失敗時は DefaultAzureCredential。"""
    try:
        from azure.identity import AzureCliCredential

        cred = AzureCliCredential(process_timeout=90)
        # 早期検証: トークン取得できなければ例外 -> フォールバック
        cred.get_token("https://management.azure.com/.default")
        return cred
    except Exception:  # noqa: BLE001
        from azure.identity import DefaultAzureCredential

        return DefaultAzureCredential()


def get_openai_client(project_client=None):
    """評価 (evals) API を呼ぶための OpenAI 互換クライアント。"""
    project_client = project_client or get_project_client()
    return project_client.get_openai_client()


def model_deployment_name() -> str:
    return os.environ.get("JUDGE_MODEL_DEPLOYMENT_NAME") or require("MODEL_DEPLOYMENT_NAME")


def mcp_config() -> tuple[str | None, str | None]:
    """Contoso ポリシー MCP の (URL, APIキー) を返す。未設定なら (None, None)。"""
    return os.environ.get("CONTOSO_MCP_URL"), os.environ.get("CONTOSO_MCP_KEY")


"""
プロンプトエージェントの作成
=========================================================
既存の Foundry プロジェクト上にプロンプトエージェント（指示・モデル・ツール構成だけで
定義されるフルマネージドエージェント）を作成（create_version）する。

このスクリプトは「作成のみ」を行います。質問の実行・対話・トレース生成は含みません。
作成したエージェントへの問い合わせ（評価対象トレースの生成）は別途行ってください。

プロンプトエージェントはコード・コンテナ・BYO リソース不要で、Foundry がフルマネージド
ランタイムで実行します（Capability Host ・ Standard 化は不要）。

前提:
  - ms-foundry-observability で Foundry プロジェクトをデプロイ済み
  - 本フォルダで scripts/setup-env.ps1（または setup-env.sh）を実行し .env 生成済み
  - .env（PROJECT_ENDPOINT / MODEL_DEPLOYMENT_NAME など）が設定済み

注意: Foundry Agent SDK は更新が速いため、メソッド名が SDK バージョンで異なる場合が
      あります。エラー時は `pip install -U azure-ai-projects` と公式サンプルを参照。
"""
from __future__ import annotations

import argparse
import sys
import time

from agent_config import (
    get_project_client,
    model_deployment_name,
    mcp_config,
)

AGENT_NAME = "contoso-support-agent"
MCP_SERVER_LABEL = "contoso-policy"
MCP_ALLOWED_TOOLS = [
    "get_return_policy",
    "get_shipping_policy",
    "get_payment_policy",
    "get_loyalty_points",
]
INSTRUCTIONS = (
    "あなたは Contoso のカスタマーサポート担当です。"
    "返品・配送・支払い・ポイントに関する質問に、ポリシーに沿って簡潔・正確に回答してください。"
    "不明な点は推測せず、確認が必要と伝えてください。"
    "ポリシーや顧客情報を答える際は、必ず contoso-policy ツール"
    "（get_return_policy / get_shipping_policy / get_payment_policy / get_loyalty_points）"
    "を呼び出し、その結果に基づいて回答してください。推測で答えてはいけません。"
    "同じツールを同じ引数で複数回呼び出さないでください。必要な情報は一度のツール呼び出しで取得し、"
    "重複した呼び出しを避けてください。"
)

_RETRYABLE = ("Throttl", "429", "timeout", "Timeout", "ServiceUnavailable", "503", "500")


def _is_retryable(ex: Exception) -> bool:
    msg = str(ex)
    return any(token in msg for token in _RETRYABLE)


def _with_retry(fn, *, attempts: int = 3, base_delay: float = 2.0, label: str = "操作"):
    """一時的エラーに対する簡易リトライ（指数バックオフ）。"""
    last: Exception | None = None
    for i in range(1, attempts + 1):
        try:
            return fn()
        except Exception as ex:  # noqa: BLE001
            last = ex
            if i < attempts and _is_retryable(ex):
                delay = base_delay * (2 ** (i - 1))
                print(f"[retry] {label} が一時的に失敗（{i}/{attempts}）。{delay:.0f}s 後に再試行: {ex}")
                time.sleep(delay)
                continue
            raise
    assert last is not None
    raise last


def build_mcp_tool():
    """CONTOSO_MCP_URL/KEY が設定されていれば MCPTool を構築。なければ None。"""
    url, key = mcp_config()
    if not url:
        print("[warn] CONTOSO_MCP_URL 未設定。MCP ツールなしでエージェントを作成します。")
        return None
    from azure.ai.projects.models import MCPTool

    headers = {"x-contoso-key": key} if key else None
    tool = MCPTool(
        server_label=MCP_SERVER_LABEL,
        server_url=url,
        allowed_tools=MCP_ALLOWED_TOOLS,
        require_approval="never",
    )
    if headers is not None:
        tool.headers = headers
    print(f"[ok] MCP ツールを構築: {MCP_SERVER_LABEL} -> {url}")
    return tool


def create_or_update_agent(project_client, agent_name: str):
    """バージョン付きエージェントを作成（create_version）し、(agent, version) を返す。"""
    from azure.ai.projects.models import PromptAgentDefinition

    agents = getattr(project_client, "agents", None)
    if agents is None:
        raise RuntimeError(
            "project_client.agents が見つかりません。`pip install -U azure-ai-projects` を実行してください。"
        )

    model = model_deployment_name()
    mcp_tool = build_mcp_tool()
    tools = [mcp_tool] if mcp_tool is not None else None

    if tools is not None:
        definition = PromptAgentDefinition(model=model, instructions=INSTRUCTIONS, tools=tools)
    else:
        definition = PromptAgentDefinition(model=model, instructions=INSTRUCTIONS)

    print(f"エージェントを作成: {agent_name} (model={model})")
    agent = _with_retry(
        lambda: agents.create_version(
            agent_name=agent_name,
            definition=definition,
            description="Contoso カスタマーサポート プロンプトエージェント",
        ),
        label="create_version",
    )
    version = getattr(agent, "version", "1")
    agent_id = getattr(agent, "id", None) or getattr(agent, "name", agent_name)
    print(f"      agent.id = {agent_id}  name = {agent.name}  version = {version}")
    return agent, version


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="プロンプトエージェントの作成")
    p.add_argument("--name", default=AGENT_NAME, help=f"エージェント名（既定: {AGENT_NAME}）")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    project_client = get_project_client()
    agent, version = create_or_update_agent(project_client, args.name)

    trace_agent_id = f"{agent.name}:{version}"
    print(f"\n作成完了。AGENT_ID={trace_agent_id}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

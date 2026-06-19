"""
検証用エージェントの作成 + トレース生成
=======================================
Foundry プロジェクト上に検証用エージェントを作成し、サンプル質問を投げて
App Insights に OpenTelemetry トレース（invoke_agent スパン）を出力します。

これにより:
  - run_trace_eval.py が採点するトレースが生成される
  - run_batch_eval.py のエージェントターゲット評価の対象にもなる

前提: eval/.env（PROJECT_ENDPOINT / MODEL_DEPLOYMENT_NAME /
       APPLICATIONINSIGHTS_CONNECTION_STRING）が設定済み。

注意: Foundry Agent SDK は更新が速いため、メソッド名が SDK バージョンで
      異なる場合があります。エラー時は `pip install -U azure-ai-projects` と
      公式サンプルを参照してください。
"""
from __future__ import annotations

import os
import sys

# eval/ をモジュール検索パスへ追加して _common を再利用
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "eval"))

from _common import (  # noqa: E402
    get_project_client,
    get_openai_client,
    model_deployment_name,
    mcp_config,
)
from azure.ai.projects.models import PromptAgentDefinition  # noqa: E402

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
)
SAMPLE_QUERIES = [
    "返品はいつまで可能ですか？",
    "送料が無料になる条件を教えてください。",
    "海外への配送はできますか？",
]


def enable_tracing() -> None:
    """App Insights への OpenTelemetry トレース送信を有効化。"""
    conn = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
    if not conn:
        print("[warn] APPLICATIONINSIGHTS_CONNECTION_STRING 未設定。トレースは送信されません。")
        return
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor

        configure_azure_monitor(connection_string=conn)
        os.environ.setdefault("AZURE_TRACING_GEN_AI_CONTENT_RECORDING_ENABLED", "true")
        print("[ok] App Insights トレースを有効化しました。")
    except Exception as ex:  # noqa: BLE001
        print(f"[warn] トレース有効化に失敗: {ex}")


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


def main() -> None:
    enable_tracing()
    project_client = get_project_client()
    openai_client = get_openai_client()
    model = model_deployment_name()

    print(f"[1/3] エージェントを作成: {AGENT_NAME} (model={model})")
    # azure-ai-projects 2.x: バージョン付きエージェント (create_version)
    agents = getattr(project_client, "agents", None)
    if agents is None:
        raise RuntimeError(
            "project_client.agents が見つかりません。`pip install -U azure-ai-projects` を実行してください。"
        )

    mcp_tool = build_mcp_tool()
    tools = [mcp_tool] if mcp_tool is not None else None

    definition = PromptAgentDefinition(
        model=model,
        instructions=INSTRUCTIONS,
        tools=tools,
    ) if tools is not None else PromptAgentDefinition(
        model=model,
        instructions=INSTRUCTIONS,
    )

    agent = agents.create_version(
        agent_name=AGENT_NAME,
        definition=definition,
        description="Contoso カスタマーサポート検証用エージェント",
    )
    agent_id = getattr(agent, "id", None) or getattr(agent, "name", AGENT_NAME)
    agent_version = getattr(agent, "version", "1")
    print(f"      agent.id = {agent_id}  name = {agent.name}  version = {agent_version}")

    print("[2/3] サンプル質問を実行（トレース生成）")
    for q in SAMPLE_QUERIES:
        try:
            resp = openai_client.responses.create(
                input=q,
                extra_body={
                    "agent_reference": {"name": agent.name, "type": "agent_reference"}
                },
            )
            text = getattr(resp, "output_text", None) or getattr(resp, "status", "?")
            preview = (text or "")[:40].replace("\n", " ")
            print(f"      Q: {q}  -> {preview}")
        except Exception as ex:  # noqa: BLE001
            print(f"      Q: {q}  -> 実行スキップ ({ex})")

    print("[3/3] 完了。トレース評価には次の AGENT_ID を使用してください:")
    trace_agent_id = f"{agent.name}:{agent_version}"
    print(f"\n    AGENT_ID={trace_agent_id}   # eval/.env に追記\n")
    print("数分の ingestion 遅延後に run_trace_eval.py を実行してください。")


if __name__ == "__main__":
    main()

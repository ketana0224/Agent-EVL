"""
MAF エージェント定義（ホスト型 / カスタム）
=========================================================
Microsoft Agent Framework (MAF) の `FoundryChatClient` を使い、既存の Foundry
プロジェクト上のモデルでカスタムエージェントを構築する。プロンプトエージェント
（agent-aif-prompt-agent）と同一の指示文・MCP ツール・モデルを使用する。

プロンプトエージェントとの違い:
  - プロンプトエージェント: Foundry のフルマネージドランタイムが実行（コード無し）
  - 本エージェント（MAF/ACA）: 自前のコンテナコードがエージェントループを実行

認証:
  - ローカル: az CLI ログイン（DefaultAzureCredential が AzureCliCredential を利用）
  - ACA: システム割り当てマネージド ID（deploy-aca.ps1 が Foundry に RBAC 付与）

MCP ツール（任意）:
  - CONTOSO_MCP_URL / CONTOSO_MCP_KEY 設定時、MCPStreamableHTTPTool として
    Contoso ポリシー MCP（get_return_policy / get_shipping_policy /
    get_payment_policy / get_loyalty_points）を構成する。

MCP 接続方式（重要）:
      MAF の `MCPStreamableHTTPTool` は MCP 接続を別タスク（lifecycle owner）で
      管理し anyio のキャンセルスコープを AsyncExitStack で跨いで保持するため、
      本環境（Windows + asyncio）では initialize がキャンセルされて失敗する。
      そこで本実装では素の `mcp` ライブラリ（streamablehttp_client + ClientSession）で
      各ツール呼び出しごとに短命セッションを張り、MAF の `@tool` 関数として公開する。
      セッションの確立〜呼び出し〜クローズが単一タスク・単一 async with 内で完結するため
      構造化並行性のルールに従い安定動作する（MCP サーバーは決定的なので低コスト）。
"""
from __future__ import annotations

import json
from contextlib import AsyncExitStack
from typing import Annotated, Any, Optional

from agent_framework import tool

from . import config

AGENT_NAME = "contoso-support-agent"
MCP_SERVER_LABEL = "contoso-policy"
# MCP サーバー側が公開するツール（本実装では同名の @tool 関数として再公開する）
MCP_TOOLS = [
    "get_return_policy",
    "get_shipping_policy",
    "get_payment_policy",
    "get_loyalty_points",
]

# プロンプトエージェントと同一の指示文（システムプロンプト）
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


def build_mcp_tool():
    """後方互換のためのプレースホルダ。本実装は MCP を `@tool` 関数として公開する。

    CONTOSO_MCP_URL が未設定なら警告を出して None を返す（=ツールなし）。
    """
    url, _ = config.mcp_config()
    if not url:
        print("[warn] CONTOSO_MCP_URL 未設定。MCP ツールなしでエージェントを構築します。")
        return None
    return True


async def _call_mcp_tool(tool_name: str, arguments: dict[str, Any]) -> str:
    """素の mcp ライブラリで MCP サーバーのツールを 1 回呼び出し、結果を文字列で返す。

    streamablehttp_client + ClientSession の確立〜呼び出し〜クローズを単一タスク・
    単一 async with 内で完結させることで、anyio の構造化並行性を満たし安定動作する。
    None 値の引数は送信しない（サーバー側の既定値を使わせる）。
    """
    url, key = config.mcp_config()
    if not url:
        raise RuntimeError("CONTOSO_MCP_URL が未設定です。")

    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    headers = {"x-contoso-key": key} if key else {}
    payload = {k: v for k, v in arguments.items() if v is not None}

    async with streamablehttp_client(url, headers=headers) as (read, write, _get_sid):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool_name, payload)
    return _extract_tool_result(result)


def _extract_tool_result(result: Any) -> str:
    """CallToolResult から決定的な文字列（JSON 優先）を取り出す。"""
    structured = getattr(result, "structuredContent", None)
    if structured is not None:
        return json.dumps(structured, ensure_ascii=False)
    parts: list[str] = []
    for content in getattr(result, "content", None) or []:
        text = getattr(content, "text", None)
        if text:
            parts.append(text)
    if parts:
        return "\n".join(parts)
    return json.dumps({"result": str(result)}, ensure_ascii=False)


# ---------------------------------------------------------------------------
# MCP の 4 ツールを MAF の関数ツールとして公開（サーバーと同じシグネチャ）
# ---------------------------------------------------------------------------
@tool(name="get_return_policy", description="Contoso の返品ポリシー（返品可否・期間・返金種別）を返す。")
async def get_return_policy(
    category: Annotated[str, "商品カテゴリ: general / digital / perishable / clearance"] = "general",
    purchased_days_ago: Annotated[Optional[int], "購入からの経過日数（任意）。返金種別の判定に使用。"] = None,
) -> str:
    return await _call_mcp_tool(
        "get_return_policy",
        {"category": category, "purchased_days_ago": purchased_days_ago},
    )


@tool(name="get_shipping_policy", description="Contoso の配送ポリシー（配送可否・送料・目安日数）を返す。")
async def get_shipping_policy(
    destination: Annotated[str, "配送先: 'domestic'（国内）または 'international'（海外）"] = "domestic",
    order_amount: Annotated[Optional[int], "注文金額（円・任意）。送料無料判定に使用。"] = None,
) -> str:
    return await _call_mcp_tool(
        "get_shipping_policy",
        {"destination": destination, "order_amount": order_amount},
    )


@tool(name="get_payment_policy", description="Contoso の支払いポリシー（利用可能な支払い方法・分割可否・返金処理日数）を返す。")
async def get_payment_policy(
    method: Annotated[Optional[str], "支払い方法（任意）。例: クレジットカード, credit_card, コンビニ支払い。"] = None,
) -> str:
    return await _call_mcp_tool("get_payment_policy", {"method": method})


@tool(name="get_loyalty_points", description="Contoso ポイントの付与率・換算・有効期限を返す。customer_id 指定で残高を返す。")
async def get_loyalty_points(
    customer_id: Annotated[Optional[str], "顧客ID（任意, 例 'C-1001'）。指定すると保有残高を返す。"] = None,
) -> str:
    return await _call_mcp_tool("get_loyalty_points", {"customer_id": customer_id})


_MCP_FUNCTION_TOOLS = [
    get_return_policy,
    get_shipping_policy,
    get_payment_policy,
    get_loyalty_points,
]


async def build_agent(stack: AsyncExitStack):
    """FoundryChatClient ベースの MAF エージェントを構築して返す。

    `stack` に資格情報のライフサイクルを登録するため、呼び出し側で
    `async with AsyncExitStack() as stack:` または lifespan 終了時に `aclose()` する。
    """
    from azure.identity.aio import DefaultAzureCredential
    from agent_framework.foundry import FoundryChatClient

    # ローカルは az CLI、ACA はマネージド ID（いずれも DefaultAzureCredential が解決）
    credential = await stack.enter_async_context(DefaultAzureCredential())

    client = FoundryChatClient(
        credential=credential,
        project_endpoint=config.project_endpoint(),
        model=config.model_deployment_name(),
    )

    # MCP が設定されていれば 4 つの関数ツールを公開（素の mcp 経由で安定動作）
    tools: list[Any] = []
    if build_mcp_tool() is not None:
        tools.extend(_MCP_FUNCTION_TOOLS)
        print(
            f"[ok] MCP ツールを公開: {MCP_SERVER_LABEL} "
            f"({', '.join(MCP_TOOLS)}) -> {config.mcp_config()[0]}"
        )

    agent = client.as_agent(
        name=AGENT_NAME,
        instructions=INSTRUCTIONS,
        tools=tools or None,
    )
    print(
        f"[ok] エージェント構築完了: {AGENT_NAME} "
        f"(model={config.model_deployment_name()}, tools={len(tools)})"
    )
    return agent

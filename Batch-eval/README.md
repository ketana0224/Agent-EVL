# Batch-eval — バッチ評価 / トレース評価 基盤

Microsoft Foundry の **バッチ評価（cloud evaluation）** と **App Insights トレース評価（preview）** を
検証するための Azure 構築スクリプトと評価コード一式です。

> 📖 **手順・前提条件・パラメーター・参考質問・補足/注意・参照元は、リポジトリ ルートの
> [`../README.md`](../README.md) に統合しました。** まずはそちらを参照してください。

## このフォルダの中身

| パス | 説明 |
|---|---|
| `infra/` | APIM ポリシー（`apim-aif-policy.xml`）のみ |
| `eval/` | バッチ評価・トレース評価の実行コード |
| [`../agent-aif-prompt-agent/`](../agent-aif-prompt-agent/) | 検証用 **プロンプトエージェント**（MCP ツール付き / トレース生成）。リポジトリ ルート直下に移動・昇格 |
| [`../ms-foundry-observability/`](../ms-foundry-observability/) | Foundry 可観測性 環境構築（Bicep + デプロイ/後片付けスクリプト）。リポジトリ ルート直下に移動 |
| [`../mcp/`](../mcp/) | Contoso ポリシー MCP サーバー（FastMCP / ACA ホスト）+ `deploy-mcp.ps1`（リポジトリ ルート直下に移動） |

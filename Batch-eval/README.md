# Batch-eval — バッチ評価 / トレース評価 基盤

Microsoft Foundry の **バッチ評価（cloud evaluation）** と **App Insights トレース評価（preview）** を
検証するための Azure 構築スクリプトと評価コード一式です。

> 📖 **手順・前提条件・パラメーター・参考質問・補足/注意・参照元は、リポジトリ ルートの
> [`../README.md`](../README.md) に統合しました。** まずはそちらを参照してください。

## このフォルダの中身

| パス | 説明 |
|---|---|
| `infra/` | Bicep（Foundry・モデル・App Insights・Log Analytics） |
| `scripts/` | デプロイ / MCP デプロイ / 後片付けスクリプト |
| `agent/` | 検証用エージェント作成（MCP ツール付き / トレース生成） |
| `mcp/` | Contoso ポリシー MCP サーバー（FastMCP / ACA ホスト） |
| `eval/` | バッチ評価・トレース評価の実行コード |

# Contoso ポリシー MCP サーバー

返品 / 配送 / 支払い / ポイント のポリシー応答を提供する **リモート MCP サーバー**です。
Microsoft Foundry エージェントの `mcp` ツールから呼び出される構成（Streamable-HTTP, パス `/mcp`）で、
**このフォルダ単独で Azure Container Apps へデプロイ**できます。

---

## 📦 フォルダ構成

```
mcp/
├── server.py            # FastMCP サーバー（streamable-http, 4ツール + APIキー認証 + ヘルスチェック）
├── requirements.txt     # 依存パッケージ（mcp / uvicorn / starlette）
├── Dockerfile           # ACA 用コンテナー定義（python:3.11-slim, port 8000）
├── .dockerignore        # ビルド除外（.venv / __pycache__ / smoke_test.py 等）
├── deploy-mcp.ps1       # Azure Container Apps へのデプロイスクリプト
├── smoke_test.py        # MCP クライアント疎通テスト
└── data/
    └── policies.json    # ポリシーデータ（決定的応答の元）
```

---

## 🧰 提供ツール

| ツール | 説明 | 主な引数 |
|---|---|---|
| `get_return_policy` | 返品ポリシー（カテゴリ・経過日数で返金種別を判定） | `category`, `purchased_days_ago` |
| `get_shipping_policy` | 配送可否・送料・目安日数（国内/海外・注文金額で送料無料判定） | `destination`, `order_amount` |
| `get_payment_policy` | 支払い方法・分割可否・返金処理日数 | `method` |
| `get_loyalty_points` | ポイント付与率・換算・有効期限（顧客ID指定で残高） | `customer_id` |

- **トランスポート**: streamable-http（FastMCP）
- **認証**: カスタムヘッダー `x-contoso-key`。環境変数 `CONTOSO_MCP_KEY` が設定されている場合のみ `/mcp` で検証
- **ヘルスチェック**: `GET /` および `GET /healthz`（認証不要）
- **データ**: `data/policies.json` から決定的に返却（評価の安定化・groundedness 向上のため）

---

## ✅ 前提条件

- **Azure CLI** (`az`) — [インストール](https://aka.ms/installazurecli)
- **PowerShell 7+**（`deploy-mcp.ps1` 用）
- **Python 3.10+**（ローカル実行 / スモークテスト用。クラウドデプロイには不要）
- ローカル Docker は **不要**（`az containerapp up --source` がクラウドビルドします）

---

## 🚀 Azure Container Apps へデプロイ

このフォルダで以下を実行します。

```powershell
cd mcp
./deploy-mcp.ps1
```

スクリプトの動作:

1. Azure CLI / `containerapp` 拡張 / リソースプロバイダーを確認・登録
2. API キー（`x-contoso-key`）を自動生成
3. `az containerapp up --source .` でクラウドビルド ＆ デプロイ
   （ACR + Container Apps 環境 + Container App、外部 HTTPS Ingress, port 8000）
4. 公開 URL と API キーをコンソールに出力

### パラメーター

すべて省略可能（環境変数または既定値を使用）。

| パラメーター | 環境変数 | 説明 | 例 |
|---|---|---|---|
| `-SubscriptionId` | `AZURE_SUBSCRIPTION_ID` | デプロイ先サブスクリプション。未指定なら現在の `az` コンテキストを使用 | `00000000-0000-0000-0000-000000000000` |
| `-ResourceGroup` | `AZURE_RESOURCE_GROUP` | リソースを配置する RG。無ければ自動作成 | `rg-contoso-mcp` |
| `-Location` | `AZURE_LOCATION` | デプロイ先リージョン | `japaneast` |
| `-AppName` | `CONTOSO_MCP_APP_NAME` | Container App の名前 | `contoso-policy-mcp` |
| `-EnvName` | `CONTOSO_MCP_ENV_NAME` | Container Apps 環境の名前 | `aca-contoso-mcp` |
| `-ApiKey` | — | 認証ヘッダー `x-contoso-key` の値。未指定ならランダム生成 | `<32桁の任意文字列>` |

```powershell
# 例: 独立した RG / リージョンへデプロイ
./deploy-mcp.ps1 -ResourceGroup rg-contoso-mcp -Location japaneast -AppName contoso-policy-mcp
```

---

## 🔎 後から URL / API キーを確認する

デプロイ時の出力を控え忘れても、`az` で後から取得できます。
RG 名はデプロイ先によって異なるため、アプリ名（既定 `contoso-policy-mcp`）から自動検索します。

```powershell
# アプリ名から RG を自動特定
$app  = az containerapp list --query "[?name=='contoso-policy-mcp'] | [0]" -o json | ConvertFrom-Json
$rg   = $app.resourceGroup
$fqdn = $app.properties.configuration.ingress.fqdn
$key  = az containerapp show -n contoso-policy-mcp -g $rg `
  --query "properties.template.containers[0].env[?name=='CONTOSO_MCP_KEY'].value | [0]" -o tsv
Write-Host "CONTOSO_MCP_URL=https://$fqdn/mcp"
Write-Host "CONTOSO_MCP_KEY=$key"
```

> アプリ名を変更してデプロイした場合は、上記の `contoso-policy-mcp` をその値に合わせてください。
> 一覧で名前が分からない場合は `az containerapp list -o table` で確認できます。

---

## 🧪 スモークテスト（疎通確認）

デプロイ後、出力された URL と API キーで全ツールを呼び出して確認します。

```powershell
# 依存をインストール（初回のみ）
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

# リモート（デプロイ済み）に対して
python smoke_test.py https://<fqdn>/mcp <api-key>
```

`list_tools` と 4 ツールの代表的な呼び出し結果が出力されれば成功です。

---

## 💻 ローカル実行

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

# 認証なしで起動（CONTOSO_MCP_KEY 未設定なら /mcp は無認証）
python server.py            # http://localhost:8000/mcp

# 別ターミナルで疎通確認
python smoke_test.py        # 既定: http://localhost:8000/mcp / localtestkey
```

認証を有効にするには起動前に環境変数を設定します。

```powershell
$env:CONTOSO_MCP_KEY = "localtestkey"
python server.py
python smoke_test.py http://localhost:8000/mcp localtestkey
```

---

## 🐳 コンテナーをローカルでビルド（任意）

```powershell
docker build -t contoso-policy-mcp .
docker run -p 8000:8000 -e CONTOSO_MCP_KEY=localtestkey contoso-policy-mcp
python smoke_test.py http://localhost:8000/mcp localtestkey
```

---

## 🔗 Foundry エージェントへの接続

デプロイで得た公開 URL（`https://<fqdn>/mcp`）と API キーを使って、エージェントに `mcp` ツールを付与します。
- `server_label`: 任意（例: `contoso-policy`）
- `server_url`: 公開 URL
- 認証ヘッダー: `x-contoso-key: <API キー>`

---

## 🧹 後片付け

作成した Container App / 環境 / ACR を削除します（パラメーターで名前を変えた場合はそれに合わせてください）。

```powershell
az containerapp delete -n contoso-policy-mcp -g rg-contoso-mcp --yes
az containerapp env delete -n aca-contoso-mcp -g rg-contoso-mcp --yes
# RG ごと削除する場合
az group delete -n rg-contoso-mcp --yes
```

# ms-foundry-observability — Microsoft Foundry 可観測性 環境構築

Microsoft Foundry のエージェント評価・トレース可観測性に必要な **Azure リソース群** を
Bicep で一括構築し、RBAC を付与し、評価コード・各エージェントが参照するルートの `.env` を生成する **独立した環境構築フォルダ**です。

このフォルダ単体でデプロイ／後片付けが完結します（他フォルダへの依存はありません）。

---

## 📦 構成

```
ms-foundry-observability/
├── README.md
├── infra/
│   ├── main.bicep            # サブスクリプション スコープ（Resource Group 新規作成）
│   ├── main.bicepparam       # 直接 az デプロイ用の参考パラメーター
│   └── modules/
│       └── resources.bicep   # RG スコープ リソース本体
└── scripts/
    ├── init-config.ps1       # 設定ファイル deploy.settings を生成（PowerShell）
    ├── init-config.sh        # 設定ファイル deploy.settings を生成（Bash）
    ├── deploy.ps1            # PowerShell デプロイ（Windows 既定）
    ├── deploy.sh             # Bash デプロイ
    └── teardown.ps1          # 削除（RG 削除 + Foundry purge）
```

> リソース名・リージョン・モデル設定は **`deploy.settings`**（`init-config` で生成）で管理します。
> `deploy.settings` とデプロイ後に生成される `.env` は Git 管理外です。

---

## 🏗️ 構築される Azure リソース

| リソース | 役割 |
|---|---|
| Log Analytics Workspace | ログ／トレースの保管先（PerGB2018, 30日保持） |
| Application Insights | workspace-based。エージェントの OTel トレース収集 |
| Microsoft Foundry アカウント | `kind=AIServices` / `S0` / SystemAssigned MI |
| ジャッジ用 GPT デプロイ | LLM 評価器（既定 `gpt-5.4` / GlobalStandard / 容量 50） |
| Foundry プロジェクト | 評価実行のプロジェクト |
| プロジェクト → App Insights 接続 | トレース可観測性のための接続（category=AppInsights） |

---

## ✅ 前提条件

- **Azure CLI** (`az`) — [インストール](https://aka.ms/installazurecli)
- **PowerShell 7+**（`deploy.ps1` 用）または Bash（`deploy.sh` 用）
- リージョンは **East US 2**、Resource Group は `rg-` プレフィックスで新規作成
- 対象サブスクリプションに対する **共同作成者 + ユーザーアクセス管理者**（または Owner）相当の権限（RBAC 付与を伴うため）

> テナント / サブスクリプションは次の優先順位で取得します（スクリプトにハードコードしていません）。
> 1. **推奨**: 利用する Azure 環境へ `az login` でログインし、その `az` ログイン コンテキストから取得
> 2. 環境変数 `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` で明示的に設定することも可能

> **リソース名のサフィックスについて**
> 各リソース名は `aif-<namePrefix>-<nameSuffix>`（例: `aif-foundryobs-jyenh`）の形式です。
> `nameSuffix` は Bicep の `uniqueString(サブスクリプションID, namePrefix)` の先頭5文字で**決定的**に生成されます。
> - 同じサブスクリプション＋同じ `namePrefix` なら**常に同じ値**になります（purge → 再デプロイしても同名で再作成されます）。
> - **別名で作りたい / soft-delete 衝突を完全に避けたい**場合は `deploy.settings` の `NAME_PREFIX` を変更してください（例: `foundryobs2`）。サフィックスごと別の値になります。

---

## 🚀 使い方

### 1. 設定ファイルの生成（初回のみ）

リソース名・リージョン・モデル設定を含む `deploy.settings` を生成します。

PowerShell:

```powershell
cd ms-foundry-observability\scripts
./init-config.ps1
```

Bash:

```bash
cd ms-foundry-observability/scripts
chmod +x init-config.sh && ./init-config.sh
```

生成された `ms-foundry-observability/deploy.settings` を開き、`NAME_PREFIX` /
`RESOURCE_GROUP_NAME` / `LOCATION` / ジャッジモデルなどを必要に応じて編集します。

> パラメーターで初期値を指定も可能: `./init-config.ps1 -NamePrefix myfoundry -ResourceGroupName rg-myfoundry-obs`
> （上書きは `-Force` / Bash は `FORCE=true`）

### 2. デプロイ

PowerShell（Windows 既定）:

```powershell
./deploy.ps1
```

Bash:

```bash
chmod +x deploy.sh && ./deploy.sh
```

`deploy.ps1` / `deploy.sh` は次を自動実行します:
0. `deploy.settings` の読み込み（未生成ならエラー）
1. テナント / サブスクリプションへのログイン・設定
2. ソフトデリート済み Foundry アカウント（`aif-<NAME_PREFIX>-*`）の衰突確認
3. `infra/main.bicep` のデプロイ（`deploy.settings` の値をパラメーターとして渡す）
4. RBAC 付与（実行ユーザー → `Foundry User`、プロジェクト MI → `Monitoring Reader` / `Log Analytics Reader`）
5. `.env` の生成（**リポジトリ ルート**。評価コード・各エージェントの setup-env が参照して利用）

> ソフトデリート済みアカウントが同名で残っている場合はエラーになります。
> 自動で purge して進むには `./deploy.ps1 -PurgeSoftDeleted`（Bash は `PURGE_SOFT_DELETED=true ./deploy.sh`）。
> RBAC をスキップする場合は `./deploy.ps1 -SkipRbac`（または `SKIP_RBAC=true ./deploy.sh`）。

### 後片付け

```powershell
cd ms-foundry-observability\scripts
./teardown.ps1
```

Resource Group ごと削除し、ソフトデリートされた Foundry アカウントを purge します。

---

## 🔧 設定（`deploy.settings`）

`init-config` が生成し `deploy.ps1` / `deploy.sh` が読み込みます。デプロイ前に編集できます。

| キー | 既定値 | 説明 |
|---|---|---|
| `LOCATION` | `eastus2` | 全リソースのリージョン |
| `NAME_PREFIX` | `foundryobs` | リソース名のベースプレフィックス（3〜12文字） |
| `RESOURCE_GROUP_NAME` | `rg-foundryobs-eval` | 新規作成する Resource Group 名 |
| `JUDGE_MODEL_NAME` | `gpt-5.4` | ジャッジ用 GPT モデル名 |
| `JUDGE_MODEL_VERSION` | `2026-03-05` | ジャッジ用モデルのバージョン |
| `JUDGE_DEPLOYMENT_NAME` | `gpt-5.4` | デプロイ名（SDK から参照） |
| `JUDGE_MODEL_SKU_NAME` | `GlobalStandard` | モデル SKU 種別 |
| `JUDGE_MODEL_CAPACITY` | `50` | 容量（1000 TPM 単位） |

> リソースの一意サフィックスは `uniqueString(subscription, NAME_PREFIX)` から決定されます。
> `NAME_PREFIX` を変えると別名のリソース一式が新規作成され、ソフトデリート衝突を回避できます。

---

## 📤 生成される `.env`

デプロイ後、リポジトリ ルートに `.env` が生成されます（評価コード・各エージェントが参照する接続情報）:

```
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
AZURE_RESOURCE_GROUP
PROJECT_ENDPOINT
MODEL_DEPLOYMENT_NAME
JUDGE_MODEL_DEPLOYMENT_NAME
APPLICATIONINSIGHTS_CONNECTION_STRING
APPLICATIONINSIGHTS_NAME
```

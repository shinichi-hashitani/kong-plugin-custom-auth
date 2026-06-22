# kong-plugin-custom-auth

Redis をバックエンドに用いた Kong Gateway 向けのカスタム認証プラグイン群。
Kong Gateway は **Kong Konnect をコントロールプレーン**とし、ローカルの
Gateway は **データプレーン**として動作します。

## プラグイン

| プラグイン | 役割 |
| --- | --- |
| `custom-auth-token` | トークンを生成し Redis に登録する |
| `custom-auth-authenticator` | リクエストのトークンを Redis で検索し、取得した ID / scope をヘッダに設定する |

> プラグイン本体は後続フェーズで 1 つずつ設計・実装します。本フェーズでは
> 全体構成と Konnect 接続の稼働確認までを行います。

## フォルダ構成

```
kong-plugin-custom-auth/
├── .env.example              # Konnect / Redis 接続設定のテンプレート
├── .gitignore
├── .dockerignore
├── Dockerfile                # プラグインを同梱したカスタム Kong イメージ
├── docker-compose.yml        # Kong Gateway (data plane) + Redis
├── certs/                    # Konnect 発行のデータプレーン証明書 (gitignore)
│   └── .gitkeep
└── plugins/
    ├── custom-auth-token/
    │   └── kong/plugins/custom-auth-token/      # handler.lua / schema.lua
    └── custom-auth-authenticator/
        └── kong/plugins/custom-auth-authenticator/  # handler.lua / schema.lua
```

## カスタムイメージのビルド

データプレーンは、プラグインを同梱した **カスタム Kong イメージ**（[Dockerfile](Dockerfile)）を
使います。プラグインの Lua ファイルを Kong 既定の Lua パス
（`/usr/local/share/lua/5.1/kong/plugins/<name>`）へ COPY し、`KONG_PLUGINS` で有効化します。

```bash
docker compose build                  # .env の KONG_IMAGE をベースにビルド
# または単体で
docker build --build-arg KONG_IMAGE=kong/kong-gateway:3.14 -t kong-custom-auth:local .
```

> ベースイメージ（`KONG_IMAGE`）はローカルに存在するか pull 可能なタグを指定してください。
> ビルド後 `docker compose up -d` で起動します（初回や変更時は `--build` 推奨）。

## フェーズ1: Konnect との接続稼働確認

### 1. Konnect でデータプレーンノードを登録

Konnect 管理画面で以下を行います。

1. **Gateway Manager** → 対象の Control Plane を選択
2. **Data Plane Nodes** → **New Data Plane Node** → **Docker** を選択
3. 表示された内容から次を控える / 保存する:
   - Control Plane エンドポイント（`*.cp.konghq.com`）
   - Telemetry エンドポイント（`*.tp.konghq.com`）
   - 証明書（certificate）と秘密鍵（private key）

   生成される `docker run` コマンドの環境変数は本リポジトリの
   `docker-compose.yml` に反映済みです（`KONG_KONNECT_MODE=on`,
   `KONG_TLS_CERTIFICATE_VERIFY=off`, `KONG_ROUTER_FLAVOR=expressions` を含む）。
   `KONG_CLUSTER_CERT` / `KONG_CLUSTER_CERT_KEY` は証明書ファイルを `certs/` に
   マウントする方式に置き換えています。

### 2. 証明書を配置

Konnect が発行した証明書・鍵を `certs/` に保存します（gitignore 済み）。

```bash
# 例: クリップボードや Konnect の表示内容を貼り付け
$EDITOR certs/tls.crt   # -----BEGIN CERTIFICATE-----
$EDITOR certs/tls.key   # -----BEGIN PRIVATE KEY-----
```

### 3. `.env` を作成

```bash
cp .env.example .env
$EDITOR .env   # KONNECT_CP_ENDPOINT / KONNECT_TP_ENDPOINT を設定
```

`KONNECT_CP_ENDPOINT` / `KONNECT_TP_ENDPOINT` はホスト名のみ（スキーム・ポート不要）。

### 4. 起動

```bash
docker compose up -d --build   # カスタムイメージをビルドして起動
docker compose ps
docker compose logs -f kong
```

### 5. 稼働確認

ローカルのデータプレーンのヘルスチェック:

```bash
curl -s http://localhost:8100/status | jq .
```

Konnect 管理画面の **Data Plane Nodes** に当該ノードが **Connected** として
表示されれば接続成功です。

### 停止 / クリーンアップ

```bash
docker compose down            # 停止
docker compose down -v         # Redis データも削除
```

## 接続トラブルシュート

- `KONG_CLUSTER_CONTROL_PLANE`/`SERVER_NAME` のホスト名が一致しているか
- `certs/tls.crt` / `certs/tls.key` が Konnect 発行のものか（期限切れでないか）
- Konnect CP のバージョンと `KONG_IMAGE` のバージョンが整合しているか
- `docker compose logs kong` に TLS / handshake エラーが出ていないか

---

## フェーズ2: custom-auth-token プラグイン

ダミー Route にアタッチし、トークンを発行/管理する小さな CRUD API。
プラグインがリクエストを終端し**直接レスポンス**します（upstream へはプロキシしない）。
発行されたトークンは後続の `custom-auth-authenticator` でヘッダ認証に使います。

ソース: [plugins/custom-auth-token/kong/plugins/custom-auth-token/](plugins/custom-auth-token/kong/plugins/custom-auth-token/)
（`handler.lua` / `schema.lua`）

### API

ルート例 `/tokens` にアタッチした場合（パス末尾セグメントを `<token>` として解釈）:

| Method | パス | 動作 | 成功時 |
| --- | --- | --- | --- |
| GET | `/tokens` | 全件の `{ token, user_name }` 一覧 | 200 |
| GET | `/tokens/<token>` | 該当レコードの詳細 | 200 / 無は 404 |
| POST | `/tokens` | 新規作成（`token` を UUID 生成） | 201 |
| PUT | `/tokens` | 更新（`token` は body 指定、未存在は 404） | 200 |
| DELETE | `/tokens/<token>` | 削除 | 204 |

その他: 不正 JSON / バリデーション違反 = 400、未対応メソッド = 405、Redis 接続不可 = 502。

### レコード属性

| 属性 | 規則 | 例 |
| --- | --- | --- |
| `token` | UUID（POST 時に自動採番） | `71b5e5f5-…` |
| `user_name` | スペース禁止（重複登録は許可） | `tyamada` |
| `name` | スペース可 | `Taroh Yamada` |
| `department` | スペース禁止 | `sales-tokyo` |
| `scope` | 半角スペース区切りの権限 | `inquiry application cancel order` |

### リクエスト例

```bash
# 作成（token は返り値で初めてクライアントに渡る）
curl -s -X POST http://localhost:8000/tokens \
  -H 'Content-Type: application/json' \
  -d '{"user_name":"tyamada","name":"Taroh Yamada","department":"sales-tokyo","scope":"inquiry application cancel order"}'
# -> 201 {"token":"71b5e5f5-...","user_name":"tyamada","name":"Taroh Yamada","department":"sales-tokyo","scope":"inquiry application cancel order"}

curl -s http://localhost:8000/tokens                       # 一覧
curl -s http://localhost:8000/tokens/<token>               # 詳細
curl -s -X PUT http://localhost:8000/tokens -d '{"token":"<token>", ...}'   # 更新
curl -s -X DELETE http://localhost:8000/tokens/<token>     # 削除
```

### Redis データ構造

| キー | 型 | 内容 |
| --- | --- | --- |
| `<key_prefix>:token:<token>` | Hash | `user_name` / `name` / `department` / `scope` |
| `<key_prefix>:index` | Hash | field=`token`, value=`user_name`（一覧用インデックス） |

`key_prefix` は既定 `custom-auth`（plugin config で変更可）。一覧は `index` の `HGETALL` 1 回で取得します。

### プラグイン設定（schema）

| フィールド | 既定 | 説明 |
| --- | --- | --- |
| `redis_host` | `redis` | Redis ホスト（compose のサービス名） |
| `redis_port` | `6379` | |
| `redis_password` | （なし） | `{vault://...}` 参照可 |
| `redis_database` | `0` | |
| `redis_timeout` | `2000` | connect/send/read のタイムアウト(ms) |
| `key_prefix` | `custom-auth` | Redis キーの接頭辞 |

### Konnect での有効化手順

1. **カスタムプラグインを Konnect CP に登録**
   Gateway Manager → 対象 CP → **Plugins** → **Custom Plugins** → `handler.lua` と
   `schema.lua` をアップロード（名前 `custom-auth-token`）。
2. **ダミー Service / Route を作成**（例: Route パス `/tokens`、`protocols` に `http,https`）。
3. 作成した Route（または Service）に **custom-auth-token プラグインをアタッチ**し、
   `redis_host` などを設定。
4. データプレーンには本リポジトリの `docker-compose.yml` で既にコードがマウントされ、
   `KONG_PLUGINS=bundled,custom-auth-token` で読み込み有効化済み。

### ローカル単体テスト（Konnect 不要・任意）

Konnect を介さずロジックだけ確認したい場合は、ビルド済みの `kong-custom-auth:local`
イメージを **DB-less モード**で起動し、宣言設定（`_format_version: "3.0"` の `kong.yml`
に Service / Route / plugin を定義）を読ませてプロキシ経由で叩けます。
プラグインはイメージに同梱済みなので `KONG_DATABASE=off` と `KONG_DECLARATIVE_CONFIG`
の指定だけで動きます（`KONG_PLUGINS` はイメージに焼き込み済み）。
本プラグインはこの方法で CRUD 全パスおよび認証/401/ヘッダ付与/スプーフィング防止を検証済みです。

---

## フェーズ3: custom-auth-authenticator プラグイン

保護対象の Route にアタッチし、リクエストの **Bearer トークン**を Redis で照合する
認証プラグイン。`custom-auth-token` が作成したレコードを参照します。

ソース: [plugins/custom-auth-authenticator/kong/plugins/custom-auth-authenticator/](plugins/custom-auth-authenticator/kong/plugins/custom-auth-authenticator/)

### 動作

1. `Authorization: Bearer <token>` を取得（無い／`Bearer` 形式でない → **401**）。
2. `<key_prefix>:token:<token>` を Redis で照会（レコード無し → **401**）。
3. 成功時、レコードの各値を upstream ヘッダに設定し、リクエストをプロキシ。
4. `hide_credentials`（既定 true）が有効なら `Authorization` ヘッダを削除して転送。

401 応答には `WWW-Authenticate: Bearer realm="kong"` を付与。Redis 接続不可は 502。

### 付与するヘッダ（既定）

| レコード属性 | ヘッダ（config で変更可） |
| --- | --- |
| `user_name` | `X-Consumer-Username`（`header_username`） |
| `name` | `X-Consumer-Name`（`header_name`） |
| `department` | `X-Consumer-Department`（`header_department`） |
| `scope` | `X-Consumer-Scope`（`header_scope`） |

クライアントが同名ヘッダを送っても、認証成功時に**必ず上書き**するためスプーフィング不可。

### プラグイン設定（schema）

Redis 接続フィールド（`redis_host` / `redis_port` / `redis_password` / `redis_database` /
`redis_timeout` / `key_prefix`）は `custom-auth-token` と同一。**`key_prefix` は両プラグインで
揃える**こと。加えて:

| フィールド | 既定 | 説明 |
| --- | --- | --- |
| `header_username` | `X-Consumer-Username` | user_name を載せるヘッダ |
| `header_name` | `X-Consumer-Name` | name を載せるヘッダ |
| `header_department` | `X-Consumer-Department` | department を載せるヘッダ |
| `header_scope` | `X-Consumer-Scope` | scope を載せるヘッダ |
| `hide_credentials` | `true` | 成功時に `Authorization` を upstream へ転送しない |

### リクエスト例

```bash
# custom-auth-token で発行した token を使う
curl -s http://localhost:8000/api/... -H "Authorization: Bearer <token>"
# 成功: upstream は X-Consumer-Username/Name/Department/Scope を受け取る
# 失敗: 401 {"message":"invalid token"}
```

### Konnect での有効化手順

1. `custom-auth-token` と同様に **カスタムプラグインを CP に登録**（名前
   `custom-auth-authenticator`）。
2. 保護したい **Service / Route に custom-auth-authenticator をアタッチ**し、
   `key_prefix` を `custom-auth-token` 側と揃える。
3. データプレーンは `docker-compose.yml` で
   `KONG_PLUGINS=bundled,custom-auth-token,custom-auth-authenticator` として読込済み。

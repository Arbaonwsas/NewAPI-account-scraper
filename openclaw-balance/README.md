# OpenClaw 余额查询脚本

这套脚本基于仓库里现有的 HyperAPI 查询逻辑整理，适合给 OpenClaw 或其他自动化工具调用。

特点：

- 纯 `bash + curl + jq`，不依赖 macOS Keychain。
- 默认输出 JSON，便于 OpenClaw 解析。
- 支持 access token、Authorization header、Cookie、账号密码四种方式。
- 查询账户余额、历史消耗、请求次数、订阅套餐剩余额度和到期时间。

## 文件

- `check-balance.sh`：主查询脚本。
- `init-env-from-keychain.sh`：从现有 Keychain token 生成 OpenClaw 用 `.env`。
- `.env.example`：配置模板，复制成 `.env` 后填写。
- `README.md`：当前说明。

## 依赖

本机需要安装：

```bash
curl --version
jq --version
```

如果缺少 `jq`：

```bash
brew install jq
```

## 推荐配置方式：access token

先在项目根目录用原有脚本生成一次系统 access token：

```bash
./scripts/setup-hyperapi-token.sh
```

这个脚本会把 `HYPERAPI_USER_ID` 写入根目录 `.env`，并把 access token 存入 macOS Keychain。

然后可以直接生成 OpenClaw 用的配置：

```bash
./openclaw-balance/init-env-from-keychain.sh
```

如果你想手动配置，也可以复制模板：

```bash
cd openclaw-balance
cp .env.example .env
```

编辑 `.env`：

```bash
HYPERAPI_BASE_URL=https://hyperapi.cc
HYPERAPI_USER_ID=123
HYPERAPI_ACCESS_TOKEN=your_access_token
```

如果你不想从 Keychain 复制 token，也可以直接用浏览器里抓到的 `authorization` 或 `cookie`：

```bash
HYPERAPI_AUTHORIZATION=your_authorization_header_value
# 或
HYPERAPI_COOKIE=your_browser_cookie
```

## 账号密码方式

也可以不填 token，每次运行时登录：

```bash
HYPERAPI_BASE_URL=https://hyperapi.cc
HYPERAPI_USERNAME=your_username_or_email
HYPERAPI_PASSWORD=your_password
```

如果账号开启 2FA：

```bash
HYPERAPI_2FA_CODE=123456
```

如果站点登录启用了 Cloudflare Turnstile，纯命令行登录可能失败。这种情况下建议使用 access token、Authorization header 或 Cookie。

## 运行

在 `openclaw-balance` 目录运行：

```bash
./check-balance.sh
```

默认输出完整 JSON。常用输出格式：

```bash
./check-balance.sh --format json
./check-balance.sh --format compact
./check-balance.sh --format text
```

OpenClaw 推荐使用：

```bash
/Users/qinzhiyong/Desktop/newapi-account-scraper/openclaw-balance/check-balance.sh --format compact
```

也可以指定外部配置文件：

```bash
ENV_FILE=/path/to/openclaw.env ./check-balance.sh --format compact
```

## 输出字段

`--format compact` 示例结构：

```json
{
  "ok": true,
  "fetchedAt": "2026-06-07 12:00:00 CST",
  "currentBalance": "$1.23",
  "historicalUsage": "$45.67",
  "requestCount": 1234,
  "subscriptions": [
    {
      "id": 128,
      "title": "套餐名称",
      "status": "active",
      "remaining": "$10.00",
      "remainingPercent": 80,
      "endTime": "2026-07-01 00:00:00"
    }
  ]
}
```

完整 JSON 会额外包含原始额度、订阅统计、已用百分比、下一次重置时间等字段。

## 可选参数

在 `.env` 里可以调整：

```bash
HYPERAPI_INCLUDE_ALL_SUBSCRIPTIONS=true
HYPERAPI_HIDE_EXHAUSTED=false
HYPERAPI_TIMEZONE=Asia/Shanghai
```

- `HYPERAPI_INCLUDE_ALL_SUBSCRIPTIONS=true`：展示接口返回的全部订阅。
- `HYPERAPI_HIDE_EXHAUSTED=true`：隐藏剩余额度小于等于 0 的订阅。
- `HYPERAPI_TIMEZONE`：控制输出时间的时区。

## 常见问题

如果提示缺少 `jq`，先安装 `jq`。

如果提示 `HYPERAPI_USER_ID is required`，说明正在使用 token/header/cookie 模式，需要同时提供用户 ID。

如果登录失败，检查站点地址、账号、密码、2FA 和 Turnstile 设置。

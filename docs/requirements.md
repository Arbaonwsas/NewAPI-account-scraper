# NewAPI 余额与订阅监控需求文档

## 1. 背景与目标

当前用户使用基于 NewAPI 搭建的中转站，希望在本地稳定查看自己的 AI 使用余量。NewAPI 站点本身面向用户的页面通常能展示订阅套餐、充值余额、使用量等信息，但不同部署版本可能没有统一暴露完整接口，因此本项目需要先建立可复用的数据抓取能力，再逐步封装为 macOS 风格的常驻监控组件。

产品目标：

- 抓取用户自己的账号充值余额。
- 抓取所有未过期订阅套餐的额度信息。
- 以进度条形式展示每个套餐的已用量、剩余额度和总额度。
- 允许用户隐藏已经用完的套餐。
- 支持用户选择刷新频率，长期监控 AI 余量变化。

本项目只用于用户抓取、展示自己合法拥有的 NewAPI 账号信息，不用于绕过鉴权、批量采集第三方账号或攻击站点。

## 2. 产品范围

### 2.1 v1：本地命令行抓取

v1 先实现 TypeScript CLI，目标是验证 NewAPI 余额和订阅数据能被稳定抓取，并沉淀统一数据模型。

CLI 需要支持：

- 配置 NewAPI 站点地址。
- 配置用户鉴权信息。
- 手动触发一次抓取。
- 输出账号充值余额。
- 输出订阅套餐余量。
- 输出抓取时间。
- 输出数据来源和错误状态。
- 当首选接口不可用时，进入页面或浏览器登录态兜底路径，并给出可读错误。

### 2.2 v2：macOS 菜单栏组件

v2 基于 v1 的数据层开发 macOS 风格桌面组件，推荐技术栈为 TypeScript + Tauri。

桌面组件需要支持：

- 菜单栏常驻显示核心余额状态。
- 点击菜单栏图标后展开详情面板。
- 详情面板展示账号充值余额。
- 详情面板展示所有未过期订阅套餐。
- 每个套餐用进度条展示已用量和剩余额度。
- 用户可选择隐藏已经用完的套餐。
- 用户可选择自动刷新频率。
- 网络失败时保留最近一次成功数据，并显示错误状态。

低余额提醒属于后续规划，不进入 v1 或 v2 的第一版验收范围。

## 3. 用户与使用场景

目标用户是 NewAPI 中转站的普通用户，而不是站点管理员。用户已经能通过网页登录 NewAPI，并能在网页或账号设置中看到自己的套餐、充值余额或 API Key。

核心使用场景：

- 用户在本地命令行确认当前账号剩余额度。
- 用户希望长期在 macOS 菜单栏查看 AI 额度余量。
- 用户希望按 10 秒、30 秒、1 分钟或 5 分钟刷新余额。
- 用户希望用进度条快速判断某个订阅套餐还剩多少。
- 用户不希望已用完套餐长期占据展示空间。

## 4. 技术路线

默认技术栈：

- 语言：TypeScript。
- v1 运行形态：Node.js CLI。
- v2 桌面形态：Tauri macOS 菜单栏应用。
- 安全存储：macOS Keychain。

设计原则：

- 数据层与展示层分离，CLI 和桌面组件复用同一套抓取逻辑。
- 接口优先，页面抓取兜底。
- 所有抓取结果统一归一化为快照模型。
- 任何敏感信息不得写入日志。
- 失败时尽量保留最近一次成功数据，避免菜单栏展示空白。

## 5. 鉴权与敏感信息

首选鉴权方式：

- 用户手动粘贴 User Token 或 API Key。
- 工具将敏感凭据保存到 macOS Keychain。
- CLI 初期可以提供交互式配置命令，但不得默认把 Token 明文写入仓库文件。
- 对 hyperapi.cc 实测路径，CLI 支持账号密码登录一次，生成系统 access token 后保存到 macOS Keychain；后续刷新优先使用 Keychain token，不再每次登录。

兜底鉴权方式：

- 支持浏览器登录态导入规划。
- 可从 Cookie 或 localStorage 读取 NewAPI 登录态。
- 浏览器登录态导入必须由用户显式触发。
- 导入前需要提示用户将读取对应站点的登录态。

需要保护的敏感信息包括：

- User Token。
- API Key。
- Cookie。
- localStorage 中的登录态字段。
- NewAPI 用户 ID。

## 6. 数据来源与抓取顺序

抓取策略为接口优先、页面兜底。

### 6.1 账号计费接口

优先探测以下接口：

- `GET /dashboard/billing/subscription`
- `GET /dashboard/billing/usage`

如果站点启用了 OpenAI SDK 兼容路径，再探测：

- `GET /v1/dashboard/billing/subscription`
- `GET /v1/dashboard/billing/usage`

请求头应支持：

- `Authorization: Bearer <user_token>`
- `New-Api-User: <user_id>`，当站点版本需要时使用。

这些接口用于获取账号订阅额度、硬限制、有效期和使用量。实现时不能假设所有 NewAPI 部署都支持这些接口，需要做能力探测和错误归一化。

### 6.2 Token 用量接口

可选支持：

- `GET /api/usage/token`

该接口用于监控单个 API Key 或 Bearer Token 的授予额度、已用额度和剩余额度。它不是第一优先级，账号余额和订阅套餐余量才是本项目主目标。

### 6.3 页面抓取兜底

当接口不可用、鉴权失败或站点版本不兼容时，进入页面抓取兜底路径。

页面抓取可以使用：

- 用户提供的 Cookie。
- 用户导入的浏览器登录态。
- 后续可选的无头浏览器抓取。

页面抓取目标字段：

- 账号充值余额。
- 订阅套餐名称。
- 套餐总额度。
- 套餐已用量。
- 套餐剩余额度。
- 套餐过期时间。
- 套餐状态。

页面抓取实现必须把选择器和字段映射集中管理，避免散落在业务逻辑中。

### 6.4 HAR 实测接口：hyperapi.cc

用户已通过浏览器 DevTools 导出 `captures/hyperapi.cc.har`。该 HAR 属于敏感本地文件，可能包含用户 ID、站点响应和登录态相关信息，不应提交到版本控制系统。

本次 HAR 中筛选到的目标接口如下：

- `GET /api/user/self`：返回当前用户信息，包含 `id`、`quota`、`used_quota`、`request_count`、`group`、`status` 等字段。
- `POST /api/user/amount`：请求体为 `{ "amount": number }`，返回格式化后的额度/金额字符串，可用于把 `quota`、`used_quota` 或套餐额度转换为前端同口径展示文本。
- `GET /api/subscription/self`：返回订阅信息，包含 `subscriptions`、`all_subscriptions`、`billing_preference`。
- `GET /api/subscription/plans`：返回套餐计划列表，可用 `plan.id` 关联订阅里的 `subscription.plan_id`，获取套餐标题、币种、总额度、周期等展示信息。

实测请求特征：

- 上述接口均带有 `new-api-user` 请求头。
- HAR 中 `new-api-user` 为数字形态，更像用户 ID，不像 Bearer Token。
- HAR 中未看到 `Authorization` 请求头。
- HAR 中当前订阅列表为 `subscriptions`，历史/全量列表为 `all_subscriptions`。
- 订阅时间戳字段看起来是秒级时间戳。
- 当前订阅中的 `plan_id` 均能在 `/api/subscription/plans` 中找到对应计划。
- 额度字段使用站点内部单位，实测美元金额换算为 `amount / 500000`。

基于该 HAR，v1 针对 hyperapi.cc 的优先抓取路径应调整为：

1. 读取 `baseUrl` 与 `new-api-user`。
2. 请求 `GET /api/user/self` 获取账号 `quota`、`used_quota` 和用户状态。
3. 请求 `POST /api/user/amount` 将额度数字转换为站点同款展示文本。
4. 请求 `GET /api/subscription/self` 获取当前订阅和历史订阅。
5. 请求 `GET /api/subscription/plans` 获取套餐名称与计划元数据。
6. 用 `subscription.plan_id` 关联 `plan.id`，生成订阅展示项。
7. 默认展示 `subscriptions` 中未过期、未隐藏的套餐；`all_subscriptions` 仅用于历史或排查。

token 化刷新流程：

1. 用户在 `.env` 中配置 `HYPERAPI_BASE_URL`、`HYPERAPI_USERNAME`、`HYPERAPI_PASSWORD`。
2. 首次运行 setup 脚本，通过 `POST /api/user/login` 建立临时 session。
3. setup 脚本使用登录 session 和 `new-api-user` 调用 `GET /api/user/token` 生成系统 access token。
4. access token 保存到 macOS Keychain，不写入 `.env`。
5. setup 脚本将 `HYPERAPI_USER_ID` 写入本地 `.env`。
6. 后续抓取脚本从 Keychain 读取 access token，并用 `Authorization: <access_token>` 与 `New-Api-User: <user_id>` 请求数据。
7. 如果用户主动重新运行 setup，会生成新的系统 access token，可能使旧 access token 失效。

实测字段映射：

- 当前余额：`user.self.data.quota / 500000`。
- 历史消耗：`user.self.data.used_quota / 500000`。
- 请求次数：`user.self.data.request_count`。
- 套餐总额度：`subscription.amount_total / 500000`。
- 套餐已用额度：`subscription.amount_used / 500000`。
- 套餐剩余额度：`(subscription.amount_total - subscription.amount_used) / 500000`。
- 套餐已用百分比：`amount_used / amount_total * 100`。
- 套餐名称：优先使用 `plans[].plan.title`，通过 `subscription.plan_id` 关联 `plan.id`；找不到计划时显示 `订阅 #<id>`。
- 过期时间：`subscription.end_time`，按 Asia/Shanghai 本地时间格式化。
- 下一次重置时间：`subscription.next_reset_time`，当值大于 0 时展示。
- 状态文案：`active` 展示剩余天数与截止时间，`expired` 展示过期时间，`cancelled` 展示作废时间。

实测展示口径：

- 金额保留两位小数并加 `$` 前缀。
- 剩余额度为正但四舍五入后小于 `$0.01` 时，页面展示为 `$0.01`。
- 剩余天数按截止时间与当前时间差向上取整。
- `subscriptions` 对应页面中“我的订阅”里的当前有效订阅；`all_subscriptions` 包含已过期和已作废订阅。

## 7. 统一快照模型

所有数据来源最终归一化为同一个快照模型。字段名为需求约定，实际代码可在保持含义一致的前提下使用 TypeScript 类型定义。

```ts
type DataSource = 'api' | 'page' | 'browser-session';

interface AccountSnapshot {
  baseUrl: string;
  fetchedAt: string;
  rechargeBalance: MoneyAmount | null;
  subscriptions: SubscriptionSnapshot[];
  usage: UsageSnapshot | null;
  errors: ScraperError[];
  source: DataSource;
}

interface MoneyAmount {
  value: number;
  unit: string;
  displayText: string;
}

interface SubscriptionSnapshot {
  id?: string;
  name: string;
  totalQuota: number | null;
  usedQuota: number | null;
  remainingQuota: number | null;
  progressPercent: number | null;
  expiresAt: string | null;
  isExpired: boolean;
  isExhausted: boolean;
  displayText: string;
}

interface UsageSnapshot {
  totalUsage: number | null;
  periodStart?: string | null;
  periodEnd?: string | null;
  displayText: string;
}

interface ScraperError {
  code: string;
  message: string;
  source: DataSource;
  retryable: boolean;
}
```

展示规则：

- 默认只展示 `isExpired === false` 的订阅套餐。
- 如果用户关闭已用完套餐，则隐藏 `isExhausted === true` 的套餐。
- `progressPercent` 表示已用比例，范围为 0 到 100。
- 当额度单位无法确认时，保留原始展示文本到 `displayText`。

## 8. 刷新与状态

支持刷新方式：

- 手动刷新。
- 自动刷新。

自动刷新档位：

- 10 秒。
- 30 秒。
- 1 分钟。
- 5 分钟。

刷新状态：

- `idle`：空闲。
- `loading`：正在抓取。
- `success`：抓取成功。
- `partial-success`：部分数据成功，部分数据失败。
- `error`：抓取失败。

桌面版在刷新失败时：

- 保留最近一次成功快照。
- 在详情面板显示错误信息。
- 菜单栏不应只显示空状态。

## 9. CLI 需求

CLI 推荐命令：

```bash
newapi-monitor config
newapi-monitor fetch
newapi-monitor watch --interval 30s
```

`config` 用于配置：

- NewAPI Base URL。
- User Token 或 API Key。
- 用户 ID，如果站点要求 `New-Api-User`。
- 是否启用页面抓取兜底。

`fetch` 用于：

- 执行一次抓取。
- 在终端输出人类可读结果。
- 支持 JSON 输出，便于后续桌面组件或自动化脚本复用。

`watch` 用于：

- 按指定间隔循环刷新。
- 间隔仅允许使用需求约定档位，或在实现中显式校验。

## 10. macOS 菜单栏组件需求

菜单栏主显示：

- 优先显示账号剩余充值额度。
- 当充值余额不可用时，显示总剩余订阅额度。
- 当数据过期或刷新失败时，显示可识别的异常状态。

点击展开详情：

- 顶部显示账号充值余额。
- 显示最近刷新时间。
- 显示刷新状态。
- 列出所有未过期订阅套餐。
- 每个套餐显示名称、过期时间、剩余额度和进度条。
- 提供隐藏已用完套餐开关。
- 提供刷新频率选择：10 秒、30 秒、1 分钟、5 分钟。
- 提供手动刷新按钮。

设置项：

- NewAPI Base URL。
- 凭据管理入口。
- 用户 ID，可选。
- 刷新频率。
- 是否隐藏已用完套餐。
- 是否启用页面抓取兜底。

## 11. 错误处理

需要覆盖的错误类型：

- Base URL 无效。
- 网络连接失败。
- TLS 或证书错误。
- 鉴权失败。
- Token 过期。
- 用户 ID 缺失。
- 接口不存在。
- 接口返回字段缺失。
- 页面结构变化导致字段无法解析。
- 服务端限流。

错误展示原则：

- CLI 输出清晰错误码和中文说明。
- 桌面组件展示简短错误状态，详情面板显示完整错误说明。
- 日志不得包含完整 Token、Cookie 或 API Key。

## 12. 验收标准

### 12.1 CLI 验收标准

- 用户能配置 NewAPI 地址和凭据。
- 用户能执行一次抓取并看到账号充值余额。
- 用户能看到所有未过期订阅套餐。
- 每个套餐能计算或展示剩余额度和进度。
- 接口不可用时能进入页面抓取兜底路径，或给出明确的不可用原因。
- 输出包含 `baseUrl`、`fetchedAt`、`rechargeBalance`、`subscriptions`、`usage`、`errors`、`source`。

### 12.2 桌面版验收标准

- 应用以 macOS 菜单栏组件形式运行。
- 点击菜单栏后能展示充值余额和订阅套餐列表。
- 订阅套餐使用进度条展示。
- 用户能隐藏已用完套餐。
- 用户能选择 10 秒、30 秒、1 分钟、5 分钟刷新频率。
- 凭据存入 macOS Keychain。
- 网络失败时保留最近一次成功数据，并展示错误状态。

## 13. 后续规划

后续可以扩展：

- 低余额阈值提醒。
- macOS 通知中心提醒。
- 多个 NewAPI 站点同时监控。
- 多个 API Key 分别监控。
- 历史用量趋势图。
- 导出 CSV 或 JSON。
- 更完整的浏览器登录态导入向导。

## 14. 参考资料

- NewAPI 计费面板接口文档：https://doc.newapi.pro/api/fei-account-billing-panel/
- NewAPI Token 用量接口文档：https://doc.newapi.pro/api/token-usage/

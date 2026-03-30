# PRD: New Channel Integrations

**Status**: Draft
**Author**: Agent
**Date**: 2026-03-30

## Goal

Expand Pincer's channel surface to cover the messaging platforms most likely to grow its user base, prioritized by implementation cost vs. reach. Each channel must be a real implementation -- polling or webhook-based, with full send/receive, streaming support, and session lifecycle -- not a stub.

## Evaluation Criteria

Every candidate platform was scored on:

| Criterion | Weight | Description |
|---|---|---|
| **API Quality** | 3 | REST/webhook-based? Clean JSON? Well-documented? No proprietary SDK required? |
| **Impl Cost** | 3 | Can we implement with Req + Finch (already in deps)? Or do we need native WebSocket/gRPC/SDK? How many endpoints to cover? |
| **User Reach** | 2 | MAU in markets where Pincer is likely to be adopted |
| **Streaming** | 1 | Does the API support edit/update for streaming agent responses? |
| **Session Model** | 1 | DM + group support? Per-user session mapping feasible? |

Scale: 1 (hard/limited) to 5 (easy/rich). Final score = weighted sum, max 50.

## Candidate Analysis

### Western Platforms

#### Microsoft Teams

| Criterion | Score | Notes |
|---|---|---|
| API Quality | 2 | Requires Azure Bot Framework registration. Bot Builder SDK is the canonical path; raw REST is possible but poorly documented for conversational bots |
| Impl Cost | 1 | Must implement Bot Framework Connector protocol (OAuth token exchange, conversation state, activity types). Heavy ceremony for what amounts to "receive message, send reply" |
| User Reach | 5 | 320M+ MAU, dominant in enterprise |
| Streaming | 1 | No message edit API for bots. Cannot update a sent message. Streaming requires chunked new messages or SSE via Teams app (not bot) |
| Session Model | 3 | DM + channels + group chats. Thread-aware |

**Score: 21/50**. Enterprise reach is massive but the API is the heaviest of any platform here. The Bot Framework Connector is a framework, not an API -- it owns your routing. Streaming is blocked. Not worth it unless enterprise demand materializes.

#### LINE

| Criterion | Score | Notes |
|---|---|---|
| API Quality | 5 | Clean REST + webhook. Send reply (within 30s), send push (anytime). JSON payloads. Excellent English documentation |
| Impl Cost | 4 | One webhook endpoint to receive, two POST endpoints to send (reply + push). Channel access token via OAuth. ~5 API calls to cover |
| User Reach | 3 | ~200M MAU, dominant in Japan/Thailand/Taiwan/Indonesia |
| Streaming | 2 | No message edit. Must send multiple messages for streaming. 30s reply window; push messages bypass this |
| Session Model | 4 | DM + group + multi-person chat. Rich menu support. User profile API |

**Score: 37/50**. Clean API, modest effort, strong in East/Southeast Asia. Streaming is the main gap -- agents would need to send chunked messages rather than update-in-place.

#### Matrix (via Application Service)

| Criterion | Score | Notes |
|---|---|---|
| API Quality | 3 | Application Service API is well-specified but complex. Elixir libraries exist (`matrix_sdk`, `matrix_app_service`) but are 0.x, not battle-tested |
| Impl Cost | 2 | Must run a homeserver or register as an AS against one. Long-lived transactions via HTTP. ETS-level complexity for sync state |
| User Reach | 2 | ~100M users across instances. Dominant in privacy-conscious/FOSS communities, German public sector |
| Streaming | 3 | Message edit API exists (`m.replace`). Can update messages in-place |
| Session Model | 3 | Rooms (DMs are 1:1 rooms). Federation-aware |

**Score: 25/50**. Streaming works, Elixir libs exist, but the user base is niche and the AS protocol adds operational complexity. Deferred.

### Chinese Platforms

#### Feishu / Lark

| Criterion | Score | Notes |
|---|---|---|
| API Quality | 5 | Full REST API with English docs (Lark) and Chinese docs (Feishu). Send message, reply, receive via webhook event subscription. Supports text, rich text, images, cards (interactive), files. `tenant_access_token` via OAuth2 client credentials |
| Impl Cost | 4 | ~6 endpoints: get token, send message, reply message, receive event (webhook), get user info, upload file. All JSON over HTTPS. Feishu Cards support interactive buttons for approval flows |
| User Reach | 4 | 12M+ organizations. Lark = international version, same API. Strong in tech companies, startups, and SEA enterprises |
| Streaming | 4 | **Supports streaming messages** (card content update). Can edit/update card messages for progressive agent output |
| Session Model | 5 | DM with bot, group chats, bot can initiate DM. Per-user `open_id` for session mapping. Rich bot menu support |

**Score: 46/50**. Best candidate overall. Clean REST API, streaming support via card updates, both Chinese (Feishu) and international (Lark) reach, and the API surface is small enough to implement in one sprint.

#### DingTalk

| Criterion | Score | Notes |
|---|---|---|
| API Quality | 4 | REST API with webhook. Custom bot = one webhook URL to push to groups. Enterprise bot = full API access (send DM, receive events, interactive cards). English docs exist but are thinner than Feishu's |
| Impl Cost | 3 | Two tiers: custom bot (trivial, webhook only, outbound-only) vs. enterprise bot (full API, requires app registration + admin approval). For real two-way, need enterprise tier which means OAuth + event subscription |
| User Reach | 4 | 700M+ users, 25M+ organizations. Dominant in Chinese SMB/enterprise |
| Streaming | 3 | Supports updating sent messages (interactive cards can be updated). Not as clean as Feishu's streaming API but workable |
| Session Model | 4 | DM + group. Enterprise bot can send DMs. `userid` for session mapping |

**Score: 36/50**. Second-best Chinese platform. The custom bot tier is trivially easy but outbound-only; the enterprise tier is needed for real integration. Larger user base than Feishu but slightly more complex API.

#### WeChat Official Account

| Criterion | Score | Notes |
|---|---|---|
| API Quality | 2 | XML-based message format (legacy) or JSON (newer). Requires a verified server in China or Hong Kong to receive webhooks. Signature verification with SHA1. Docs are primarily Chinese |
| Impl Cost | 1 | 48-hour messaging window (can only reply within 48h of last user message). Must handle XML. Server must respond within 5s or WeChat retries 3x. No native streaming. Template messages require pre-approval |
| User Reach | 5 | 1.3B+ MAU. The dominant messaging platform in China |
| Streaming | 1 | No message edit. Cannot update sent messages. 48h window severely limits long-running agent sessions |
| Session Model | 2 | DM only (no group bot). `openid` per user. Strict rate limits |

**Score: 17/50**. Massive reach but hostile API. The 48-hour window alone makes it unsuitable for autonomous agents that may run for hours. XML legacy format. Deferred indefinitely.

#### WeCom (Enterprise WeChat)

| Criterion | Score | Notes |
|---|---|---|
| API Quality | 3 | REST JSON API, better than WeChat OA. Webhook for group bots. Full API for enterprise apps. English docs available |
| Impl Cost | 2 | Requires enterprise registration. Bot can only interact within the enterprise -- no external users without extra approval. More ceremony than Feishu |
| User Reach | 3 | ~10M+ enterprise users. China-focused |
| Streaming | 2 | Can update messages via card update API. Not as clean as Feishu |
| Session Model | 3 | DM + group within enterprise. `userid` mapping |

**Score: 22/50**. Better than WeChat OA but still enterprise-walled. Feishu covers the same market with a more open API.

#### QQ (Guild/Channel Bot)

| Criterion | Score | Notes |
|---|---|---|
| API Quality | 2 | QQ Bot API v2 uses WebSocket for events + REST for sending. Docs are Chinese-only. API is in active development with frequent breaking changes |
| Impl Cost | 2 | Requires WebSocket client (not currently in deps). Guild/channel model is different from DM-centric platforms. Limited to guilds (not personal QQ chats for most bots) |
| User Reach | 3 | QQ has 500M+ MAU but bot API is guild-channel only, limiting actual reach |
| Streaming | 1 | No message edit API for bots. Must send new messages |
| Session Model | 2 | Guild channels only. No personal DM bot capability for most developers |

**Score: 14/50**. Large user base but the bot API is restricted to guilds, requires WebSocket, has no streaming, and docs are Chinese-only. Not worth the cost.

## Priority Ranking

| Rank | Channel | Score | Effort (days) | Rationale |
|---|---|---|---|---|
| 1 | **Feishu / Lark** | 46/50 | 5-7 | Best API, streaming support, dual-market (CN + international), small API surface |
| 2 | **LINE** | 37/50 | 4-5 | Cleanest API of all candidates, strong East/SEA reach, streaming gap is acceptable |
| 3 | **DingTalk** | 36/50 | 6-8 | Large CN enterprise base, but enterprise bot tier adds ceremony. Can reuse Feishu patterns |
| 4 | Matrix | 25/50 | 8-10 | Niche audience, Elixir libs immature. Deferred |
| 5 | Microsoft Teams | 21/50 | 10-14 | Heavy Bot Framework, no streaming. Only if enterprise demand appears |
| 6 | WeCom | 22/50 | 6-8 | Enterprise-walled, Feishu covers same market better |
| 7 | WeChat OA | 17/50 | 8-10 | 48h window kills agent use case. Hostile API |
| 8 | QQ | 14/50 | 6-8 | Guild-only, WebSocket required, no streaming, Chinese-only docs |

## Implementation Plan

### Phase 1: Feishu / Lark

One adapter module serving both Feishu (CN) and Lark (international) -- the API is identical, only the base URL differs (`open.feishu.cn` vs `open.larksuite.com`).

**User Stories**:

1. **US-1: Receive messages** -- Feishu sends `im.message.receive_v1` events via webhook. Pincer validates the signature, extracts text/image/file content, and routes to the session server.
   - Acceptance: Send a DM to the Feishu bot, agent responds.
2. **US-2: Send messages** -- Agent responses are sent via `POST /im/v1/messages` using `tenant_access_token`. Support text and rich text (markdown-converted).
   - Acceptance: Agent response appears in the Feishu chat.
3. **US-3: Streaming via card updates** -- During agent streaming, create a Feishu Card, then update its content via `PATCH /interactive/v1/card/update` as tokens arrive.
   - Acceptance: Watch agent response stream progressively in the Feishu chat.
4. **US-4: Session mapping** -- Map Feishu `open_id` to Pincer session IDs. Support DM and group chat scopes.
   - Acceptance: Two different users get independent sessions.
5. **US-5: Configuration** -- Add `feishu`/`lark` section to `config.yaml` with `app_id`, `app_secret` env vars, and base URL selection.
   - Acceptance: Toggle between Feishu and Lark by changing config.

**Key API Endpoints**:

```
POST /auth/v3/tenant_access_token/internal   -- get access token
POST /im/v1/messages                         -- send message
POST /im/v1/messages/{message_id}/reply      -- reply to specific message
PATCH /interactive/v1/card/update            -- update card content (streaming)
GET  /im/v1/messages/{message_id}            -- get message content (media)
POST /im/v1/images                           -- upload image
```

**Events** (via webhook):
- `im.message.receive_v1` -- new message received
- `im.message.message_read_v1` -- read receipt (optional)

**Files to create/modify**:
- `lib/pincer/channels/feishu.ex` -- Supervisor + Channel behaviour
- `lib/pincer/channels/feishu/api.ex` -- HTTP client for Feishu REST API
- `lib/pincer/channels/feishu/session.ex` -- Session callbacks (on_agent_response, on_agent_partial, etc.)
- `lib/pincer/channels/feishu/cards.ex` -- Card builder for streaming
- `config.yaml` -- feishu/lark section
- `test/pincer/channels/feishu_test.exs`
- `test/pincer/channels/feishu_session_test.exs`

### Phase 2: LINE

**User Stories**:

1. **US-6: Receive messages** -- LINE sends webhook events to Pincer's endpoint. Validate signature via HMAC-SHA256, extract text, route to session.
   - Acceptance: Send a message to the LINE Official Account, agent responds.
2. **US-7: Send messages** -- Use reply API (within 30s) for immediate responses, push API for async. Support text and flex messages.
   - Acceptance: Agent response appears in LINE chat.
3. **US-8: Chunked streaming** -- Since LINE has no message edit API, send initial response, then follow-up messages as the agent streams.
   - Acceptance: Agent response arrives in 2-3 messages during streaming.
4. **US-9: Session mapping** -- Map LINE `userId` to Pincer session IDs.
   - Acceptance: Different LINE users get independent sessions.
5. **US-10: Configuration** -- Add `line` section to `config.yaml` with `channel_access_token` and `channel_secret` env vars.
   - Acceptance: Enable/disable LINE via config.

**Key API Endpoints**:

```
POST /v2/bot/message/reply      -- reply (within 30s of webhook)
POST /v2/bot/message/push       -- send message anytime
POST /v2/bot/message/multicast  -- send to multiple users
GET  /v2/bot/profile/{userId}   -- get user profile
GET  /v2/bot/message/delivery/reply  -- delivery stats (optional)
```

**Files to create/modify**:
- `lib/pincer/channels/line.ex` -- Supervisor + Channel behaviour
- `lib/pincer/channels/line/api.ex` -- HTTP client for LINE Messaging API
- `lib/pincer/channels/line/session.ex` -- Session callbacks
- `config.yaml` -- line section
- `test/pincer/channels/line_test.exs`
- `test/pincer/channels/line_session_test.exs`

### Phase 3: DingTalk (Enterprise Bot)

Depends on patterns established in Phase 1 (Feishu). Can reuse much of the webhook handling and token management logic.

**User Stories**:

6. **US-11: Receive messages** -- DingTalk sends robot messages via event subscription (after 2.0 robot upgrade). Validate signature, extract text, route to session.
   - Acceptance: @mention the bot in a DingTalk group, agent responds.
7. **US-12: Send messages** -- Use robot send API (`POST /v1.0/robot/oToMessages/batchSend`) for DMs, group robot webhook for group messages. Support text and markdown.
   - Acceptance: Agent response appears in DingTalk chat.
8. **US-13: Streaming via card updates** -- DingTalk interactive cards support content updates, similar to Feishu.
   - Acceptance: Agent response streams progressively.
9. **US-14: Configuration** -- Add `dingtalk` section to `config.yaml` with `client_id`, `client_secret` env vars.
   - Acceptance: Enable/disable DingTalk via config.

**Key API Endpoints**:

```
POST /v1.0/oauth2/accessToken                 -- get access token
POST /v1.0/robot/oToMessages/batchSend        -- send DM via robot
POST /v1.0/robot/groupMessages/send           -- send to group via robot
POST /v1.0/card/instances                     -- create interactive card
PUT  /v1.0/card/instances/{cardInstanceId}    -- update card (streaming)
```

**Files to create/modify**:
- `lib/pincer/channels/dingtalk.ex`
- `lib/pincer/channels/dingtalk/api.ex`
- `lib/pincer/channels/dingtalk/session.ex`
- `config.yaml` -- dingtalk section
- `test/pincer/channels/dingtalk_test.exs`
- `test/pincer/channels/dingtalk_session_test.exs`

## Scope Decisions

**In scope**: Feishu/Lark (Phase 1), LINE (Phase 2), DingTalk (Phase 3). Three new channel adapters with full send/receive/streaming support.

**Explicitly out of scope**:
- WeChat Official Account -- 48-hour window makes it incompatible with long-running agent sessions
- WeCom -- enterprise-walled, Feishu covers the same market with a better API
- QQ -- guild-only, WebSocket required, immature API with frequent breaking changes
- Microsoft Teams -- Bot Framework overhead too heavy, no streaming
- Matrix -- niche audience, immature Elixir libraries
- KakaoTalk -- requires Korean business registration, no international API access
- Viber -- REST API exists but limited bot capabilities, small developer ecosystem

## Shared Infrastructure

All three channels share a pattern that should be extracted:

1. **Token management** -- OAuth2 client credentials flow (Feishu, DingTalk) and static token (LINE) should use a shared `TokenCache` GenServer that refreshes tokens before expiry.
2. **Webhook signature verification** -- Each platform uses different signing (Feishu: `X-Lark-Signature` with SHA256, LINE: `X-Line-Signature` with HMAC-SHA256, DingTalk: signature in URL params). Extract a `WebhookVerifier` utility.
3. **Streaming adapter** -- Feishu and DingTalk support in-place card updates; LINE needs chunked messages. The `Pincer.Ports.Channel` callback should express this capability so the session layer adapts automatically.

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Feishu API changes | Low | Medium | Pin API versions, monitor changelog |
| LINE 30s reply window | Known | Low | Use push API for responses > 30s |
| DingTalk enterprise approval | High | Medium | Document setup guide clearly; custom bot as fallback (outbound only) |
| Rate limits on all platforms | Known | Low | Implement backoff in API client |
| Chinese platform access from non-CN servers | Medium | High | Document that Feishu/Lark API works globally; DingTalk may need CN proxy |

## Success Metrics

- Each channel passes the same contract tests as Telegram/Discord (`test/pincer/contracts/channel_adapter_contract_test.exs`)
- `mix qa` passes with all three channels enabled
- Each channel has dedicated tests covering: send, receive, streaming, error recovery, token refresh
- README updated with configuration examples for each new channel

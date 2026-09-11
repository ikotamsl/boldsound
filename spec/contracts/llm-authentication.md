# LLM authentication

Status: ACTIVE. Owners: `LLMProviderConfig`, `LLMConfigStore`,
`LLMSettingsDraft`, `RoutingLLMClient`, `SubscriptionLLMClient`.

## Configuration and compatibility

`LLMProviderConfig.authenticationMode` is `apiKey` or `subscription`.
Missing values in older stored configurations decode as `apiKey`.
Unknown values fail decoding. Provider IDs remain unchanged.
API keys are excluded from Codable. Subscription configurations contain no
API key and loading them does not read Keychain. Saving a subscription choice
preserves the provider's previously saved API key. Updating the model preserves
the authentication mode. Switching back to API in Settings restores that key.

## Settings

AI → AI Setup → Current choice displays an API key / Subscription picker for
OpenAI and Google Gemini. Every other provider displays an explicit explanation:
Anthropic and OpenRouter do not support subscription access in this integration;
custom endpoints have no standard subscription authentication; local inference
needs no subscription; custom Local CLI manages its own billing/authentication.

Subscription uses saved sign-in in the official CLI, not a web-session token
or an API-key replacement. OpenAI requires Codex with ChatGPT sign-in. Gemini
requires Google sign-in in Gemini CLI; eligible account allowances may be free
or subscription based. The app verifies usable model access, not a receipt or
the existence of a paid plan. API model suggestions are not an entitlement list.

Before saving subscription mode, Test Connection must succeed for the current
draft. It sends only a synthetic request using the selected model. Any draft
change invalidates success; stale results cannot validate a newer draft, even
if it was changed back. Missing login, denied model access, quota exhaustion,
missing/old CLI, malformed output and timeout produce visible errors. Changes
in account entitlement after saving are handled by errors during actual use.

## Execution and privacy

Routing selects the subscription client for all operations before considering
provider ID. Unsupported subscription providers fail closed. Direct HTTP client
calls reject subscription configurations. No API or alternate-payment fallback.
Prompts travel on stdin, model IDs as individual argv entries, with no shell.
Only runtime environment essentials are inherited; API keys and custom auth,
Node startup injection, and endpoint overrides are not inherited.

Codex runs with ChatGPT-only login, ignored user config/rules, ephemeral sessions,
read-only sandbox, and disabled tools/integrations. Versions without required
flags fail and require an update. Gemini receives app-owned enforced Google-auth
settings, disabled tools/MCP/hooks/extensions and telemetry. Empty app-owned
`.env` and `.gemini/.env` files stop upward environment discovery before
global credentials or endpoint/telemetry overrides can be loaded. Gemini JSON must
report the requested exact model in `stats.models`; missing evidence or another
model fails rather than silently accepting fallback. Each invocation uses a
fresh temporary working directory, removed on completion. Cancellation and
timeouts use the existing process-group lifecycle.

Credentials stay with the official tools; the app never extracts OAuth tokens.
CLI stderr is classified into fixed messages and never shown or logged verbatim.
Gemini CLI may save local chat history under `~/.gemini`; Settings explicitly
states this and delegates retention to Gemini CLI. These files are user data
and are not deleted by BoldSound. Cloud text processing and provider privacy
terms still apply; audio capture/transcription behavior is unchanged.

Custom Local CLI uses `AppPaths.appSupportDir/LocalCLI` (normally
`~/Library/Application Support/BoldSound/LocalCLI`), honoring the app's debug
state override. The older MacParakeet working directory is not deleted or
migrated automatically. Existing Keychain service and saved preference keys
remain compatible; product naming changes do not reset credentials.

## Verification

Focused suites: `SubscriptionLLMClientTests`, `LLMSettingsDraftTests`,
`LLMSettingsViewModelTests`, `LLMConfigStoreTests`, `RoutingLLMClientTests`,
`LocalCLIExecutorTests`. Real account access must be checked with Test Connection
on the user's machine; automated tests use synthetic data and injected clients.

## Official references (checked 2026-09-11)

- [Codex authentication](https://developers.openai.com/codex/auth/)
- [Codex automation](https://developers.openai.com/codex/noninteractive/)
- [Gemini authentication](https://geminicli.com/docs/get-started/authentication/)
- [Gemini configuration](https://geminicli.com/docs/reference/configuration/)
- [Gemini session retention](https://geminicli.com/docs/cli/session-management/)
- [Anthropic integration restrictions](https://code.claude.com/docs/en/legal-and-compliance)
- [OpenRouter authentication/billing](https://openrouter.ai/docs/faq)

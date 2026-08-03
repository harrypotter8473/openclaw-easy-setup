# Changelog

## Unreleased

### Added

- Initial Windows PowerShell setup engine
- Read-only environment diagnosis and install planning
- Release-, commit-, and SHA-256-pinned installer download with size and syntax validation
- Sanitized installer dry-run before any package installation
- Exact WinGet package provisioning for the recommended Node.js 26 prerequisite
- Exact WinGet provisioning and Authenticode validation for Git for Windows
- Isolated installer PATH that blocks the upstream unpinned portable-Git fallback
- Explicit confirmation boundary for installation and onboarding
- OpenClaw doctor, security audit, and Gateway verification flow
- Dependency-free PowerShell 5.1/7 tests and GitHub Actions CI
- Stable user-facing error codes with actionable Korean failure guidance
- Sanitized structured logs under the local OpenClaw Easy Setup state directory
- Step checkpoints and `-Resume` support for interrupted installations
- Configurable state storage through `-StateDirectory`
- Existing-installation keep, update, and downgrade-block decisions
- Package-tree and command-shim provenance receipts before later OpenClaw execution
- Script-disabled repair reinstall for exact-version packages without a valid receipt
- Offline diagnostic ZIP creation with `Bundle` and `-DiagnosticOutputPath`
- Explicit assurance that logs and diagnostic bundles are never uploaded automatically
- Korean Windows WPF GUI with a double-click launcher and six beginner-oriented actions
- Eight-stage checkpoint progress, interrupted-install detection, and one-click resume
- Default-deny plan approval bound to a SHA-256 plan fingerprint
- Cooperative cancellation at safe stage boundaries with stable `OCES-CANCELLED-001` reporting
- Separate non-elevated worker processes and a visible console only for official interactive onboarding
- System-color, keyboard, DPI, and screen-reader accessibility metadata
- Dependency-free GUI tests for PowerShell 5.1 and PowerShell 7
- Korean safe-setup wizard for OpenAI, Anthropic, and Google provider/model selection
- Slack-first optional channel setup with two Slack Socket Mode `PasswordBox` secrets, followed by Telegram and Discord
- Exact official `@openclaw/slack@2026.7.1` plugin install with npm integrity and shasum provenance verification before any runtime load
- Windows Credential Manager storage using run-scoped credential IDs and a native OpenClaw exec SecretRef resolver
- Live OpenClaw `config schema`, existing-config validation, and `config patch --stdin --dry-run --json` checks
- SHA-256 schema/config freshness checks and an approved-plan fingerprint before configuration writes
- Redacted merge-patch preview with a separate, default-off user approval boundary
- Local loopback Gateway with a generated 256-bit token, Tailscale and terminal disabled
- Messaging tool profile with explicit runtime, filesystem, automation, UI, node, plugin, MCP-bundle, and elevated-tool denial
- Safe Slack/Telegram/Discord defaults: DM pairing, groups disabled, and channel configuration writes disabled; Slack also disables group DMs, native/slash commands, name matching, and bot messages
- Post-apply configuration, SecretRef, security, model, channel, Gateway service, and RPC checks
- Crash-safe `Preparing` → `AppliedPendingChecks` → terminal recovery receipts with exact credential IDs, configuration hashes, atomic updates, and sanitized failed-check details
- Startup recovery guards plus same-ID model/channel credential replacement, stable Gateway tokens, Gateway restart, and semantic re-verification
- Fingerprint-bound exact replacement of the resolver, Gateway auth, default model, selected provider, and selected channel objects so stale endpoints, headers, or resolver environment cannot inherit new credentials
- Value-free SecretRef binding through successful official patch provenance and configuration byte-hash continuity, with explicitly approved patch replay after drift
- Fail-closed Gateway mutation gates plus recovery-time OpenClaw version, schema, and active-config compatibility checks
- Durable all-secret replacement intent so an interrupted same-ID update requires the complete receipt-bound credential set again
- Safe-settings plan and recovery receipt schema v2, with validated terminal v1 compatibility and fail-closed guidance for unfinished v1 work
- Provenance receipt schema v2 with a retained full-content digest, fast metadata-tree verification, always-hashed critical files, and full-digest fallback
- Windows PowerShell 5.1-compatible UTF-8 stdin for official OpenClaw JSON patch commands
- Disposable Windows Sandbox GUI and token-free install-smoke modes with a read-only source mapping and sanitized result receipt

### Security

- API keys and tokens are not written as plaintext by the 0.4 easy-setup path; only SecretRefs are added to OpenClaw configuration.
- Secrets are never passed through process arguments, environment variables, temporary files, previews, or logs by the easy-setup path.
- Credential Manager storage is scoped to the current Windows user and is documented as reducing plaintext-at-rest exposure, not isolating secrets from other processes running as that user.

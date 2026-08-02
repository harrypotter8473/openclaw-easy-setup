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

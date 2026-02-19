# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - 2026-02-12

### Changed

- Replace OS-level sleep with fiber-aware sleep via `Time_compat` module.

## [0.2.0] - 2026-02-12

### Added

- SSE support for MCP streamable-http protocol.
- SSE shutdown notification broadcast on server stop.
- MCP `resources/list` and `resources/read` handlers.
- MCP resource templates and version metadata.
- Resilience module (circuit breaker, retry, backoff) adopted from mcp-protocol-ocaml for driver integration.
- `/health` endpoint with circuit breaker status API.

### Changed

- Replace hardcoded version string with dune-build-info.

### Fixed

- MCP notification processing (malformed JSON-RPC dispatch).
- Resilience reset logic and associated test corrections.

### Security

- Remove shell-based process execution; use direct `execvp` instead.
- Avoid shell invocation in `pgrep` calls.

## [0.1.0] - 2026-01-18

### Added

- Initial release: DAW MCP Server in OCaml.
- MCP tools for DAW (Digital Audio Workstation) control.
- JSON-RPC response handler with correct request ID propagation.
- CI/CD workflows (GitHub Actions) with manual dispatch trigger.

### Changed

- Default HTTP port set to 8950.

[0.2.1]: https://github.com/jeong-sik/daw-mcp/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/jeong-sik/daw-mcp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jeong-sik/daw-mcp/releases/tag/v0.1.0

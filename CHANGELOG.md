# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.7] - 2026-09-04

### Added

- `Git.repository_fetch/4` — optional fourth argument `runner_pid :: pid() | nil` wires a `git_credential_acquire_cb` into the fetch, mirroring the existing pattern on `repository_clone/5`. When the server returns 401, the C callback sends `{:credential_request, res_term, url}` to the runner and blocks the dirty scheduler thread until `Git.credential_deliver/2` is called. The 3-arg form delegates to 4-arg with `nil` — existing callers are unchanged.

### Fixed

- `git_engine_credential_acquire_cb` now checks `allowed_types` before contacting the runner. If the server does not advertise `GIT_CREDENTIAL_USERPASS_PLAINTEXT` (e.g. Negotiate-only servers), the callback returns `GIT_PASSTHROUGH` immediately without sending a message to the runner or blocking the dirty scheduler thread.

## [0.9.6] - 2026-08-31

### Added

- `Git.repository_fetch/3` — NIF wrapping `git_remote_create_anonymous` + `git_remote_fetch`, registered as `ERL_NIF_DIRTY_JOB_IO_BOUND`. Fetches from a remote URL or local filesystem path into an existing bare repository using caller-supplied refspecs. Primary use case: syncing a fork with its upstream (`+refs/heads/*:refs/heads/*`).

## [0.9.5] - 2026-08-22

### Added

- `Git.repository_clone/5` — fifth argument `runner_pid :: pid() | nil` wires a `git_credential_acquire_cb` into the clone. When the server returns 401, the C callback sends `{:credential_request, res_term, url}` to the runner process and blocks the dirty scheduler thread via `enif_cond_wait`. The runner calls `Git.credential_deliver/2` with `{:ok, {username, password}}` or `:error` to unblock and provide credentials.
- `Git.credential_deliver/2` — NIF called by the runner to deliver credentials back to a blocked `repository_clone` dirty thread.
- `Git.repository_clone/4` and below remain unchanged (call through to `/5` with `nil` runner — no credential callback).

## [0.9.4] - 2026-08-20

### Added

- `Git.repository_clone/4` — fourth argument `headers :: [String.t()]` injects custom HTTP headers into the clone fetch via `git_fetch_options.custom_headers`, enabling authenticated clones (e.g. HTTP Signature headers for cross-forge federation).

### Changed

- `WireProtocol.sideband_wrap/2` moved from `WireProtocol.ReceivePack` to `WireProtocol`; `ReceivePack` delegates to it. Eliminates a circular compile-time dependency (`WireProtocol` aliasing `ReceivePack` while `ReceivePack` declared `@behaviour WireProtocol`). Existing callers of `ReceivePack.sideband_wrap/2` are unaffected.

## [0.9.3] - 2026-08-14

### Added

- `GitAgent.commit_raw/2` — returns the signed data for a commit (commit content with the `gpgsig` header stripped), backed by a new `git_engine_commit_raw` NIF wrapping `git_commit_extract_signature`. Pair with `commit_gpg_signature/2` to verify SSH or GPG commit signatures.

## [0.9.2] - 2026-08-14

### Added

- `push_cmds/3` public function on `ReceivePack` — runs `GitRepo.pre_push/2` inside a `GitAgent.transaction/2`, serializing the protection check with the ref update through the GenServer. Eliminates a race where two concurrent pushes both pass `pre_push` before either commits.
- Protocol consolidation disabled in `:test` env (`consolidate_protocols: Mix.env() != :test`) so `defimpl` blocks in test files take effect at runtime.
- `push_cmds/3` unit tests covering: pre_push error stops push before ref update, pre_push ok commits the ref, pre_push error takes priority over stale-ref.

### Fixed

- `repository_is_empty` NIF: replaced `git_repository_is_empty` with `git_repository_head_unborn`. libgit2 1.9 changed `git_repository_is_empty` to return an error for non-bare repos, which the NIF misread as `false`. `git_repository_head_unborn` is the precise check for "no commits yet" and is stable since libgit2 0.18.

## [0.9.1] - 2026-08-08

### Fixed

- NIF compilation on GCC 14 / libgit2 1.9:
  - `odb.c`: call `writepack->free()` instead of `git_odb_free()` on `git_odb_writepack*` — the latter is the wrong free function for a writepack handle.
  - `signature.c`: use `ErlNifSInt64` / `enif_get_int64` for `git_time_t` (which is `int64_t` on Linux); the previous `int` cast silently truncated timestamps.
- Dialyzer PLT: added `logger`, `telemetry`, and `stream_split` to `plt_add_apps` to eliminate false positives.

## [0.9.0] - 2026-08-07

First release as a standalone Hex package, extracted and modernised from [git.limo](https://github.com/redrabbit/git.limo).

### Added

- `GitRepo.pre_push/2` callback — called inside receive-pack before refs are updated, allowing applications to validate or reject pushes.
- `validate_cmd/2` — stale-ref check for `:update` and `:delete` commands; non-fast-forward is accepted at protocol level (enforcement belongs in `pre_push`).
- `Git.repository_clone/3` NIF wrapping `git_clone` with bare-mode support.
- `Git.blame/2` and `Git.blame/3` — line-by-line blame via libgit2.
- `Git.diff_*` family — diff retrieval between commits, trees, and working directory.
- Wire protocol: `side-band` and `side-band-64k` capability support for multiplexed sideband output during fetch.
- Wire protocol: `ofs-delta` capability for pack negotiation.
- Wire protocol: `no-done` fix for HTTP upload-pack.
- Wire protocol: advisory / sideband message support (channel 2 output during push).
- Wire protocol: `report-status` delete operation fix.
- `vibe_kit` dependency.
- Credo static analysis configuration.
- Basic `GitAgent` unit tests.
- PKT-LINE packet size validation — rejects packets ≤ 4 bytes to prevent negative-size crashes.
- PACK object size limit — configurable via `config :ex_git_engine, max_object_size` (default 100 MB); raises on oversized objects to prevent memory exhaustion.
- MIT LICENSE with attribution to original gitrekt authors.
- Hex package metadata (`licenses`, `links`, `files`) in `mix.exs`.
- `ex_doc` dev dependency for Hex documentation publishing.
- README with description, usage examples, and author attribution.

### Changed

- Renamed library from `gitrekt` / `GitRekt` to `ex_git_engine` / `ExGitEngine` throughout all modules, configs, and tests.
- Elixir requirement raised to `~> 1.15`.
- Elixir 1.20 deprecation cleanup (pattern matching, unused variables).

### Fixed

- `GitRef` type resolution for multi-level / symbolic refs; completed `GitRef.type` typespec.
- Slash support in branch names (e.g. `feature/foo`).
- Tag peeling and `GitAgent` tag-related functions.
- `references_target` resolution for symbolic refs.

[0.9.6]: https://github.com/full-stack-biz/ex_git_engine/compare/v0.9.5...v0.9.6
[0.9.5]: https://github.com/full-stack-biz/ex_git_engine/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/full-stack-biz/ex_git_engine/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/full-stack-biz/ex_git_engine/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/full-stack-biz/ex_git_engine/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/full-stack-biz/ex_git_engine/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/full-stack-biz/ex_git_engine/releases/tag/v0.9.0

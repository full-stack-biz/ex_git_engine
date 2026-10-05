# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.12.0] - 2026-10-05

### Added

- Paged access to large diffs, following libgit2's model (files by index, text diffs computed per file, hunks by index):
  - `GitAgent.diff_files/3`: a page of a diff's files (`offset:`, `limit:`, default 1000, at most 5000) with `:index`, `:from`, `:to`, `:status`, plus the `:total`. Reads no file contents. Pages are bounded because the VM collects a larger NIF result on a dirty scheduler, where it waits behind long jobs.
  - `GitAgent.diff_patch/4`: one file's computed diff: `:binary`, `:additions`, `:deletions`, `:hunks` with line ranges and `:origins` (one byte per line, enough to size its rendering without the text), and `:patch`, a `%GitPatch{}`.
  - `GitAgent.diff_patch_text/3`: text of a `%GitPatch{}`, optionally only a range of its hunks (`hunks: 10..19`), each page with the file header so it parses on its own. Reads only the requested hunks; the file is not diffed again. The NIF yields (`enif_schedule_nif`) and counts its reductions, so long files neither block a scheduler nor take a dirty one.
  - Diffs and patches are only used by the agent that created them: libgit2 objects other than the object database are not safe to use from two processes at once.
- `ExGitEngine.JobLimiter`, started by the new `ExGitEngine.Application`: long agent operations that use nothing of the agent's repository handle (`pack_create`, `blame`, `graph_ahead_behind` on their own handle; `odb_writepack_commit` on its push's writepack) run outside the agent, at most `max_jobs` at a time (default: dirty CPU schedulers minus one; `config :ex_git_engine, max_jobs: n`), so they cannot take every dirty scheduler. Queued jobs whose caller has exited are dropped. Like a busy port, once `high_water` jobs are queued (default `10 * max_jobs`) it answers `{:error, :busy}` at once until the queue drains to `low_water` (default half).
- `GitAgent.diff_file/5`: the patch text of one file between two revisions or trees, by path, for callers that hold no diff. The path is matched exactly.
- `diff/4` option `exact_paths: true`: `:pathspec` entries are exact paths, not globs (`GIT_DIFF_DISABLE_PATHSPEC_MATCH`).

### Fixed

- `diff/4` options `context_lines` and `interhunk_lines` now take effect. The NIF stored the raw Erlang term instead of the integer.

- `diff_format` and `diff_deltas` no longer fail with `illegal byte sequence` when a file under a diff driver (`diff=cpp`, `diff=perl`, …) contains non-UTF-8 bytes. libgit2 runs the driver's funcname regex on context lines for hunk headers, and the system regex rejects invalid UTF-8 under a UTF-8 locale. Both NIFs now run with the "C" locale on their own thread (`uselocale`), leaving the rest of the VM untouched. Diffs of git.git between v2.0.0 and v2.54.0 failed entirely before.

- `GitAgent.pack_create/3` no longer holds up every other call to the same agent while a pack is built. It now runs in a separate process on its own repository handle and replies when done. Previously a clone or fetch of a large repository queued all other requests for that repository (web pages included) for the whole pack build, e.g. a `revision` call waited ~650ms during a 6.5k-object clone and ~2s during a large pack in tests.
- `GitAgent.blame/3` runs the same way, outside the agent on its own repository handle. Blame time grows with history depth: on git.git (80k commits) blaming a 23-commit `README.md` took 3.6s and blocked the agent for all of it; files with long histories took minutes.
- `GitAgent.graph_ahead_behind/3` and `GitAgent.odb_writepack_commit/3` run the same way. Counting ahead/behind across 44k commits of git.git blocked the agent for 680ms; indexing a pushed 53MB pack in `odb_writepack_commit` blocked it for 6s.

## [0.11.0] - 2026-10-05

### Changed

- Long-running NIFs now run on dirty schedulers so they no longer block normal schedulers (and every process queued on them) for their whole duration: `diff_tree`, `diff_format`, `diff_stats`, `diff_deltas`, `pack_insert_commit`, `pack_insert_walk`, `pack_data`, `revwalk_pack`, `merge_base`, `merge_commits`, `graph_ahead_behind` and `pathspec_match_tree` (CPU-bound); `odb_write_pack`, `odb_writepack_append` and `odb_writepack_commit` (IO-bound). Previously a 680-file `diff_format` stalled its scheduler for ~270ms and a large `pack_create` for over 2s.

## [0.10.2] - 2026-09-23

### Fixed

- SSH `git push` no longer crashes with `MatchError` when the ref update commands and their terminating flush-pkt arrive in separate SSH DATA messages. `git send-pack` writes them with separate `write()` calls (`send-pack.c`), so this split is common. `ReceivePack` now buffers commands in `pending_cmds` until the flush arrives.
- SSH `git fetch`/`clone` no longer crashes with `MatchError` when `want` lines and their flush-pkt arrive in separate SSH DATA messages. `UploadPack` buffers them in `pending_wants`.
- `WireProtocol.next/2` no longer crashes when an SSH DATA message ends partway through a pkt-line (including inside the 4-byte length header), e.g. when pushing many refs. The incomplete tail is held in `pkt_rest` and prepended to the next message.
- `atomic` pushes are now all-or-nothing. Every command is validated before any ref is updated; on the first failure nothing is applied, the failing ref reports its own reason and every other ref reports `atomic push failure` (git `execute_commands_atomic`).
- Push results are reported per ref, as git's `receive-pack` does: `unpack ok` followed by `ok <ref>` or `ng <ref> <reason>` for each ref. Previously one rejected ref marked every ref `ng` (including refs already updated) and sent the rejection reason as the unpack status. A `pre_push` rejection now reports `ng` for every ref with `unpack ok`.
- Creating a ref that already exists (e.g. two concurrent pushes of the same new branch) is rejected with `ng <ref> reference already exists` instead of raising inside the `GitAgent` transaction, which killed the repository's `GitAgent` GenServer.

### Changed

- `ReceivePack.push_cmds/3` returns `{:ok, cmd_errors}` (a map of rejected refname to reason; empty when every ref was applied) instead of `:ok`. `{:error, reason}` is still returned when `GitRepo.pre_push/2` declines the push. New optional fourth argument `atomic?` (default `false`).
- `GitRepo.push/2` receives only the commands that were applied, and is not called when every command was rejected.

## [0.10.1] - 2026-09-22

### Added

- `Git.repository_fetch/4` — the fourth argument now also accepts a `binary()` SSH private key PEM for in-memory SSH key auth, mirroring `repository_clone/5`. Accepted values are `nil` (no auth / system SSH agent), `pid()` (HTTP credential runner) or `binary()` (SSH key PEM). The NIF uses `git_credential_ssh_key_memory_new`; no key file is written to disk.

### Security

- As with `repository_clone/5` in 0.10.0, the SSH host key is not verified when a PEM is given (`git_engine_ssh_cert_check_cb` accepts any host key).

## [0.10.0] - 2026-09-22

### Added

- `Git.repository_clone/5` — the fifth argument now also accepts a `binary()` SSH private key PEM for in-memory SSH key auth. Accepted values are `nil` (no auth / system SSH agent), `pid()` (HTTP credential runner) or `binary()` (SSH key PEM). The NIF uses `git_credential_ssh_key_memory_new`; no key file is written to disk.

### Security

- When a PEM is given, the SSH host key is not verified: `git_engine_ssh_cert_check_cb` accepts any host key, so a man-in-the-middle is not detected.

## [0.9.9] - 2026-09-14

### Fixed

- `GitAgent.references/2` with an explicit `target:` option (e.g. `target: :commit`) no longer crashes when the repository contains symbolic refs. `fetch_reference_target/3` had no clause for `nil` when target was not `:undefined`; symbolic refs resolved to `nil` and then crashed the GenServer. Added `fetch_reference_target(nil, _target, _handle) -> {:ok, nil}` so they are short-circuited and subsequently filtered by the stream.

## [0.9.8] - 2026-09-14

### Fixed

- `GitAgent.references/2` no longer crashes when the repository contains symbolic refs (e.g. `refs/remotes/origin/HEAD`). `resolve_reference/1` previously had no clause for `:symbolic` tuples, raising `FunctionClauseError` and killing the GitAgent GenServer during SSH `git-upload-pack` reference discovery. Symbolic refs are now skipped (they carry no OID and should not be advertised to clients).

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

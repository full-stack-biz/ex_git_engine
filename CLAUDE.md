# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ExGitEngine** is an Elixir library that wraps libgit2 to provide Git repository access. It was extracted from [git.limo](https://github.com/redrabbit/git.limo) and updated for modern macOS and Linux.

The library is designed to be used as a dependency in other projects (not run standalone) and is published on Hex. It provides three layers of abstraction over Git operations:
- **Low-level (`ExGitEngine.Git`)**: Direct Erlang NIF bindings to libgit2
- **Mid-level (`ExGitEngine.GitAgent`)**: GenServer-based API with caching and transaction support
- **High-level (`ExGitEngine.GitRepo`)**: Protocol for extensible repository implementations with push/pull hooks

## Build & Development

### Setup
Requires libgit2 installed:
```bash
brew install libgit2              # macOS
sudo apt-get install libgit2-dev  # Ubuntu/Linux
```

### Common Commands
```bash
mix deps.get        # Install dependencies
mix compile         # Compile project (includes C code via Makefile)
mix test            # Run tests (currently minimal test suite)
mix clean           # Clean build artifacts (both Erlang and C code)
```

The Makefile handles C compilation of the libgit2 wrapper NIF. The `elixir_make` compiler is configured in `mix.exs` and automatically invokes make during the build process.

## Architecture

### Core Modules

**`ExGitEngine.Git`** - Low-level NIF wrapper to libgit2
- Direct bindings to C functions; compiled as a shared library (`priv/ex_git_engine_nif.so`)
- Functions for repository operations, object lookups, ref management, walking commit history
- Returns tuples indicating types (`:commit`, `:blob`, `:tree`, etc.)
- Example: `Git.repository_open/1`, `Git.revwalk_new/1`, `Git.commit_message/1`

**`ExGitEngine.GitAgent`** - Mid-level GenServer API
- Serializes Git commands via message passing, allowing safe concurrent access to a repository
- Implements caching for immutable Git objects
- Supports transactions to batch multiple commands into single requests
- Example: `GitAgent.start_link/1`, `GitAgent.branch/2`, `GitAgent.commit_author/2`
- Wrapper functions typically mirror their `Git.` counterparts but return different tuple structures

**`ExGitEngine.GitRepo`** - Protocol for repository implementations
- Defines extensible interface: `get_agent/1`, `pre_push/2`, `push/2`
- `pre_push/2` is a validation hook called before refs are updated (post-dispatch hook)
- `push/2` is called after refs have been updated with the actual commands that were applied
- Implementations can use any type; protocol falls back to default behavior via `Any` impl

### Wire Protocol

**`ExGitEngine.WireProtocol`** - Git transport protocol v2 implementation
- Implements both client and server sides of the protocol
- Acts as a finite-state machine: processes incoming requests, dispatches to services, returns encoded responses
- Two main services: `ReceivePack` (git push) and `UploadPack` (git fetch/pull)
- PKT-LINE encoding/decoding for protocol messages
- All protocol responses are unified as tuples: `{:unpack, status}`, `{:ok, refname}`, `{:ng, refname, reason}`, `{:sideband, channel, text}`, `{:flush}`
- These tuples flow through `encode/1` exactly once at the end of the pipeline

**`ExGitEngine.WireProtocol.ReceivePack`** - Handles `git push` requests
- Receives refs to update and objects from client
- Unpacks objects into ODB, validates refs, updates refs, notifies hooks
- Calls `GitRepo.pre_push/2` before updating refs, then `GitRepo.push/2` after
- Supports `report-status` capability for push response status messages
- Supports `side-band-64k` capability for multiplexed responses (status on channel 1, hook output on channel 2)
- Response builders:
  - `push_success_output/1` - Builds status tuples, optionally wraps with sideband if advertised
  - `build_push_response/2` - Combines status and hook messages with final flush
  - `sideband_wrap/2` - Wraps text with PKT-LINE sideband framing (4-byte hex size + channel byte + data + newline)

**`ExGitEngine.WireProtocol.UploadPack`** - Handles `git fetch`/`git pull` requests
- Advertises refs and capabilities to client
- Negotiates which objects are needed and sends them in packfile format

### Data Structures

All defined in `ExGitEngine` module as structs with inspect impls:
- `GitCommit`, `GitRef`, `GitTag`, `GitBlob`, `GitTree`, `GitTreeEntry`
- `GitIndex`, `GitIndexEntry` - Working directory index
- `GitDiff`, `GitOdb`, `GitWritePack` - Lower-level objects
- `GitError` - Exception type

### Utilities

**`ExGitEngine.Packfile`** - Utilities for Git packfile format (binary object format)

**`ExGitEngine.GitStream`** - Stream wrappers for lazy evaluation of Git objects

**`ExGitEngine.Cache`** - Simple caching layer used by GitAgent

## Key Design Patterns

- **NIF Safety**: The `Git` module is implemented as Erlang NIFs. Crashes in C code bring down the entire VM. Keep error handling at boundaries and avoid risky operations in hot paths.
- **Immutability**: Git objects are immutable once stored, enabling aggressive caching in `GitAgent`
- **Protocol Extensibility**: `GitRepo` protocol allows custom implementations (e.g., custom push validation or post-push hooks)
- **Message Passing**: `GitAgent` uses GenServer to serialize concurrent access to a single repository
- **Lazy Evaluation**: Many operations return streams rather than materializing full results
- **Single Encoding Point**: Wire protocol responses use unified tuple format that flows through `WireProtocol.encode/1` exactly once. Avoid pre-encoding, decoding, or re-encoding. Build the response structure as tuples, let encode handle all PKT-LINE framing.

## Common Workflows

### Extending Repository Behavior
Implement the `ExGitEngine.GitRepo` protocol for your repo type:
```elixir
defimpl ExGitEngine.GitRepo, for: MyRepoType do
  def get_agent(repo), do: {:ok, repo.agent_pid}
  
  def pre_push(repo, cmds) do
    # Validate ref updates before they're applied
    :ok
  end
  
  def push(repo, cmds) do
    # React to refs after they've been updated
    {:ok, repo}
  end
end
```

### Accessing Commits
```elixir
{:ok, agent} = ExGitEngine.GitAgent.start_link(repo_path)
{:ok, ref} = ExGitEngine.GitAgent.reference_lookup(agent, "refs/heads/main")
{:ok, commit} = ExGitEngine.GitAgent.peel(agent, ref)
{:ok, message} = ExGitEngine.GitAgent.commit_message(agent, commit)
```

### Testing Wire Protocol Features

Wire protocol logic is best tested with TDD using pattern matching on exact tuple structures:

```elixir
# Build response with unified tuple format
response = ReceivePack.push_success_output(handle)

# Assert exact structure, not just presence
assert [{:unpack, "ok"}, {:ok, "refs/heads/main"}] = response

# For sideband-wrapped responses
response_with_sideband = ReceivePack.push_success_output(%{handle | advertised_caps: ["side-band-64k", "report-status"]})

# Verify channel 1 wrapping for status messages
assert [
  {:sideband, 1, "unpack ok"},
  {:sideband, 1, "ok refs/heads/main"}
] = response_with_sideband
```

**Key patterns:**
- `report_status/1` returns status tuples without sideband wrapping
- `push_success_output/1` optionally wraps tuples with sideband if `"side-band-64k"` is in `advertised_caps` (not `caps`)
- `build_push_response/2` combines status (channel 1) and hook messages (channel 2) with final `{:flush}`
- All response tuples flow through `WireProtocol.encode/1` exactly once for PKT-LINE framing
- Use exact pattern matching in tests, not `Enum.any?` or loose assertions

## WireProtocol ReceivePack State Machine

### States

`:disco` → `:update_req` → `:pack` → `:buffer` → `:done`

The `:buffer` state exists to handle **pack fragmentation**: libgit2's `odb_writepack_append` may report `received_objects == total_objects` (pack appears complete) before the 20-byte SHA1 trailer has arrived in a separate transport message. Committing the writepack at that point causes a "missing trailer at the end of the pack" error. The fix: always transition `:pack` → `:buffer` after `odb_writepack_append`, and defer `odb_writepack_commit` to EOF.

### Two Execution Paths Through `:buffer`

The WireProtocol has two distinct callers that reach `:buffer` differently:

**SSH path** — `WireProtocol.next(service, binary_data)` called per DATA message:
1. First DATA message: `:pack` state → `odb_writepack_append` → `:buffer`
2. Additional DATA messages (fragmented pack): `:buffer` + non-empty binary → `next(:buffer, binary)` → wraps as `{:pack, binary}` → recurses to `:pack` → append → back to `:buffer`
3. EOF (`WireProtocol.next(service, :discovery)` from SSH EOF handler): `:buffer` + `[]` → `next(:buffer, [])` → `handle_push_cmds` → `odb_writepack_commit` → push

**HTTP path** — `WireProtocol.run(service, body)` which calls `exec_all`:
1. `exec_all` processes complete decoded body in one pass: `:disco` → `:update_req` → `:pack` → `odb_writepack_append` → `:buffer`
2. `exec_all` recurses with `[]`: `:buffer` + `[]` → `next(:buffer, [])` → `handle_push_cmds`
3. After the chunked HTTP body is consumed, `SmartHTTPBackend` reads the remainder, gets `""` (empty binary), and calls `WireProtocol.next(service_buffer, "")` — this **must** be treated as EOF, not as pack data

### Critical: Empty Binary `""` Means EOF in `:buffer` State

In `WireProtocol.next/2`, when `service.state == :buffer`:
- `data == ""` → convert to `[]` before calling `exec_next` → triggers `next(:buffer, [])` → `handle_push_cmds`
- `data` is non-empty binary → pass directly to `exec_next` → `next(:buffer, data)` handles SSH fragment

**Do not** pass `""` directly to `exec_next` — it will fall through to `next(:buffer, pack_data)` and attempt `odb_writepack_append(agent, writepack, "")`, which fails.

### Debug Logging Safety

`Logger.debug` in `exec_next_state` calls `length(lines)`. If `lines` is a binary (can happen in `:buffer` + SSH fragment path), `length/1` raises `ArgumentError`. Always use a lambda form and guard on type:

```elixir
Logger.debug(fn ->
  lines_info = if is_list(lines), do: length(lines), else: "binary(#{byte_size(lines)})"
  "... lines_count=#{lines_info} ..."
end)
```

### `exec_all` vs `exec_next` / `exec_after`

- `exec_all` (used by `run`): recursively processes all states until `:done`; used by HTTP
- `exec_next` + `exec_after` (used by `next/2`): processes one step, returns `:cont` or `:halt`; used by SSH per-message
- `exec_after` checks `service.state == :done` and calls `exec_next(service, [])` once more to flush any pending output

## Git Protocol Debugging

When implementing Git wire protocol features, validating capability negotiation, or debugging push/fetch protocol issues, use `/git-spec-explorer`.



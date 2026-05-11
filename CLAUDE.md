# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**GitRekt** is an Elixir library that wraps libgit2 to provide Git repository access. It was extracted from [git.limo](https://github.com/redrabbit/git.limo) and updated for modern macOS and Linux.

The library is designed to be used as a dependency in other projects (not run standalone) and is published on Hex. It provides three layers of abstraction over Git operations:
- **Low-level (`GitRekt.Git`)**: Direct Erlang NIF bindings to libgit2
- **Mid-level (`GitRekt.GitAgent`)**: GenServer-based API with caching and transaction support
- **High-level (`GitRekt.GitRepo`)**: Protocol for extensible repository implementations with push/pull hooks

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

**`GitRekt.Git`** - Low-level NIF wrapper to libgit2
- Direct bindings to C functions; compiled as a shared library (`priv/geef_nif.so`)
- Functions for repository operations, object lookups, ref management, walking commit history
- Returns tuples indicating types (`:commit`, `:blob`, `:tree`, etc.)
- Example: `Git.repository_open/1`, `Git.revwalk_new/1`, `Git.commit_message/1`

**`GitRekt.GitAgent`** - Mid-level GenServer API
- Serializes Git commands via message passing, allowing safe concurrent access to a repository
- Implements caching for immutable Git objects
- Supports transactions to batch multiple commands into single requests
- Example: `GitAgent.start_link/1`, `GitAgent.branch/2`, `GitAgent.commit_author/2`
- Wrapper functions typically mirror their `Git.` counterparts but return different tuple structures

**`GitRekt.GitRepo`** - Protocol for repository implementations
- Defines extensible interface: `get_agent/1`, `pre_push/2`, `push/2`
- `pre_push/2` is a validation hook called before refs are updated (post-dispatch hook)
- `push/2` is called after refs have been updated with the actual commands that were applied
- Implementations can use any type; protocol falls back to default behavior via `Any` impl

### Wire Protocol

**`GitRekt.WireProtocol`** - Git transport protocol v2 implementation
- Implements both client and server sides of the protocol
- Acts as a finite-state machine: processes incoming requests, dispatches to services, returns encoded responses
- Two main services: `ReceivePack` (git push) and `UploadPack` (git fetch/pull)
- PKT-LINE encoding/decoding for protocol messages

**`GitRekt.WireProtocol.ReceivePack`** - Handles `git push` requests
- Receives refs to update and objects from client
- Unpacks objects into ODB, validates refs, updates refs, notifies hooks
- Calls `GitRepo.pre_push/2` before updating refs, then `GitRepo.push/2` after

**`GitRekt.WireProtocol.UploadPack`** - Handles `git fetch`/`git pull` requests
- Advertises refs and capabilities to client
- Negotiates which objects are needed and sends them in packfile format

### Data Structures

All defined in `GitRekt` module as structs with inspect impls:
- `GitCommit`, `GitRef`, `GitTag`, `GitBlob`, `GitTree`, `GitTreeEntry`
- `GitIndex`, `GitIndexEntry` - Working directory index
- `GitDiff`, `GitOdb`, `GitWritePack` - Lower-level objects
- `GitError` - Exception type

### Utilities

**`GitRekt.Packfile`** - Utilities for Git packfile format (binary object format)

**`GitRekt.GitStream`** - Stream wrappers for lazy evaluation of Git objects

**`GitRekt.Cache`** - Simple caching layer used by GitAgent

## Key Design Patterns

- **NIF Safety**: The `Git` module is implemented as Erlang NIFs. Crashes in C code bring down the entire VM. Keep error handling at boundaries and avoid risky operations in hot paths.
- **Immutability**: Git objects are immutable once stored, enabling aggressive caching in `GitAgent`
- **Protocol Extensibility**: `GitRepo` protocol allows custom implementations (e.g., custom push validation or post-push hooks)
- **Message Passing**: `GitAgent` uses GenServer to serialize concurrent access to a single repository
- **Lazy Evaluation**: Many operations return streams rather than materializing full results

## Common Workflows

### Extending Repository Behavior
Implement the `GitRekt.GitRepo` protocol for your repo type:
```elixir
defimpl GitRekt.GitRepo, for: MyRepoType do
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
{:ok, agent} = GitRekt.GitAgent.start_link(repo_path)
{:ok, ref} = GitRekt.GitAgent.reference_lookup(agent, "refs/heads/main")
{:ok, commit} = GitRekt.GitAgent.peel(agent, ref)
{:ok, message} = GitRekt.GitAgent.commit_message(agent, commit)
```

## Git Protocol Debugging

When implementing Git wire protocol features, validating capability negotiation, or debugging push/fetch protocol issues, use `/git-spec-explorer`.



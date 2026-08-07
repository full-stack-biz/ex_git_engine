---
name: git-spec-explorer
description: >-
  Explore and collect details from Git specifications to ensure protocol conformity.
  Use when implementing Git wire protocol features, validating capability negotiation,
  or debugging push/fetch protocol issues. Extracts authoritative specs from Git man pages
  (man gitprotocol-v2, man gitprotocol-pack, etc.), updates protocol reference files,
  and references ex_git_engine's protocol knowledge base.
allowed-tools:
  - Bash
  - Skill
  - Read
  - Edit
---

# Git Spec Explorer

**Purpose:** Systematically explore Git specifications and collect implementation details to ensure protocol conformity in ex_git_engine.

**Core Principle:** ExGitEngine is a thin Elixir wrapper around libgit2. Maximize use of libgit2's C API via NIFs; only build Elixir code when libgit2 doesn't provide the functionality.

## Quick Start

```
/git-spec-explorer [search term or protocol aspect]

Examples:
- /git-spec-explorer report-status capability format
- /git-spec-explorer pkt-line encoding wire protocol
- /git-spec-explorer push protocol receive-pack flow
```

This collects protocol details from Git's official man pages (`man gitprotocol-v2`, `man gitprotocol-pack`, etc.), references ex_git_engine's protocol knowledge base, and updates documentation with findings. Returns authoritative specifications with implementation guidance.

## NIF-First Design Principle

**ExGitEngine Architecture:** libgit2 (C) → NIF bindings (`Git` module) → Elixir wrappers (`GitAgent`, `GitRepo`)

**When implementing features:**
1. **Check libgit2 first** — Does libgit2 already provide this? Use it via NIF.
2. **Build NIF wrapper if needed** — If libgit2 has the function, wrap it in C via NIF bindings.
3. **Add Elixir code only when necessary** — For state management, serialization, protocol handling, or business logic that libgit2 doesn't cover.

**Why this matters:**
- Performance: C code is faster than Elixir
- Safety: Concentrated memory management in one layer
- Correctness: Libgit2 handles Git complexity; reuse it
- Simplicity: Less Elixir code to maintain

**Example Decision Tree:**
- "I need to list commits" → libgit2 has `git_revwalk_*` → Add NIF wrapper
- "I need to send commits over wire protocol" → libgit2 doesn't handle protocol → Write Elixir code
- "I need to validate ref updates before push" → libgit2 doesn't validate business rules → Write Elixir hook
- "I need to cache commits" → libgit2 doesn't cache → Write Elixir caching in GitAgent

## Workflows

### Determine Implementation Layer (NIF vs Elixir)

**Goal:** Decide whether to use libgit2 via NIF or implement in Elixir.

**Process:**
1. **Define the feature** — What capability is needed?
2. **Search libgit2 API** → Check `references/libgit2_api.md` for matching functions
3. **If libgit2 has it**:
   - ✓ Use it via NIF (add C wrapper if needed, expose via `Git` module)
   - Check: Does libgit2 function handle edge cases? Memory management? Error conditions?
4. **If libgit2 doesn't have it**:
   - Check: Is it a protocol concern? (→ Elixir code in `WireProtocol`)
   - Check: Is it state management? (→ Elixir code in `GitAgent`)
   - Check: Is it business logic? (→ Elixir code in `GitRepo` hooks)

**Example:** Adding fetch support
- Feature: "Fetch refs from remote"
- libgit2 check: Yes, has `git_remote_*` and `git_fetch_*`
- Decision: Add NIF wrapper for remote operations, expose in `Git` module
- Elixir layer: `GitAgent` serializes concurrent access, `GitRepo` handles post-fetch hooks

**Example:** Adding push validation
- Feature: "Validate commits before push"
- libgit2 check: No, libgit2 doesn't validate business rules
- Decision: Implement in Elixir as `pre_push` hook in `GitRepo`
- Uses: NIF for commit lookup, Elixir for validation logic

### Search for Protocol Details

**Goal:** Find specific information from Git specs to answer implementation questions.

**Process:**
1. **Fetch from man pages (PRIMARY)** → `man gitprotocol-v2`, `man gitprotocol-pack`, `man gitprotocol-capabilities`, `man gitprotocol-http`
   - Extract clean text: `man <page> 2>/dev/null | col -b > /tmp/<page>.txt`
   - Man pages are authoritative, always available locally, need no network
2. **Cross-reference local** → Reference local protocol documentation for implementation details
3. **Update skill references** → When man page reveals new or corrected details, update corresponding .md file
4. **Organize findings** → Group by: spec source, protocol phase, implementation requirement

**Example queries:**
- "capability negotiation receive-pack" → finds how client/server negotiate capabilities
- "report-status format pkt-line" → finds exact message format and encoding
- "push protocol sequence" → finds full flow of reference discovery → commands → response

### Collect Implementation Requirements

**Goal:** Extract actionable implementation details from specs.

**Process:**
1. **Identify protocol phase** → Which part of push/fetch/upload flow?
2. **Find spec section** → Search official docs for that phase
3. **Extract rules** → Client MUST/MUST NOT, Server MUST/MUST NOT from RFC language
4. **Validate against ex_git_engine** → Check if `references/git_protocol.md` has this detail
5. **Document gaps** → Note any specs ex_git_engine hasn't documented yet

**Template for findings:**
```
Protocol Aspect: [capability | response format | command validation | etc]
Spec Reference: https://git-scm.com/docs/gitprotocol-[pack|http|capabilities]
Rule: [exact requirement from spec]
Current Implementation: [ex_git_engine file/function handling this]
Gaps: [anything missing or unclear]
```

## Key Specs to Know

**Primary Sources (Man Pages - Always Available Locally):**
- `man gitprotocol-v2` — Git Wire Protocol Version 2 (comprehensive, latest standard)
- `man gitprotocol-pack` — Wire protocol v1 and negotiation details
- `man gitprotocol-capabilities` — Capability advertising and negotiation
- `man gitprotocol-http` — HTTP smart protocol specifics
- `man gitprotocol-common` — Common protocol details shared across versions

**Alternative Sources (if man pages unavailable):**
- https://git-scm.com/docs/gitprotocol-v2 — Web version of v2 spec
- https://git-scm.com/docs/gitprotocol-pack — Web version of pack protocol
- https://git-scm.com/docs/gitprotocol-capabilities — Web version of capabilities
- https://git-scm.com/docs/gitprotocol-http — Web version of HTTP protocol
- RFC 4254 — SSH Connection Protocol (for SSH transport details)

**Gitrekt Reference Documents:**
- `references/git_protocol_wire.md` — Core wire protocol (universal): pkt-line format, capability negotiation, push/fetch phases, report-status, command structures
- `references/git_protocol_http.md` — HTTP smart protocol: GET /info/refs, POST /git-receive-pack, headers, authentication, redirects, Content-Type negotiation
- `references/git_protocol_ssh.md` — SSH transport: command execution, channel setup, authentication, environment, wire protocol delivery over stdin/stdout
- `references/git_client_behavior.md` — Git client parsing (transport-agnostic): how send-pack parses report-status, success/failure determination, stdin/stdout flow (sourced from git v2.54.0 source code)
- `references/libgit2_api.md` — libgit2 C library: API reference, repository/object/ref operations, memory management, NIF wrapper implications, common patterns

## Reference Document Structure

The references are organized by layer to eliminate duplication:

**Wire Protocol Layer** (transport-agnostic):
- **git_protocol_wire.md** — Shared by both HTTP and SSH
  - Pkt-line format, capabilities, phases (discovery, commands, response)
  - Push/fetch flows, packfile handling
  - ExGitEngine implementation specifics (`caps` vs `advertised_caps`)

**Transport Layers**:
- **git_protocol_http.md** — HTTP smart protocol only
  - GET /info/refs request/response
  - POST /git-receive-pack request/response
  - Headers (Content-Type, Cache-Control, Expires)
  - HTTP authentication, redirects
  - How HTTP wraps the wire protocol

- **git_protocol_ssh.md** — SSH transport only
  - SSH connection phases, authentication
  - Command execution (git-receive-pack, git-upload-pack)
  - Channel stdin/stdout delivery
  - Environment variables
  - How SSH delivers the wire protocol

**Git Library Layer**:
- **libgit2_api.md** — C library that implements Git
  - libgit2 API: repositories, objects, references, trees, commits, blobs
  - Memory management and object lifecycle
  - Thread safety and serialization requirements
  - NIF wrapper implications for ExGitEngine
  - Common patterns and pitfalls

**Research Strategy** (NIF-First):
1. **Start with libgit2** — Check `libgit2_api.md` for available functions
2. **Verify capability exists** — Can libgit2 do what you need? What are the constraints?
3. **Use protocol specs** — If NIF alone isn't enough, reference `git_protocol_wire.md` for protocol rules
4. **Reference transports** — For HTTP/SSH specifics, check `git_protocol_http.md` or `git_protocol_ssh.md`
5. **Identify gaps** — Only then implement in Elixir to fill what libgit2 doesn't provide

## Validation Checklist

When implementing features, verify:

**NIF-First Principle:**
- [ ] Checked libgit2 API — Does libgit2 already provide this functionality?
- [ ] If yes: Using NIF wrapper? (not reimplementing in Elixir)
- [ ] If no: Is Elixir implementation necessary? (not forced into C unnecessarily)
- [ ] Justified: Why is this layer the right place for this code?

**Spec Alignment:**
- [ ] Source is official spec (git-scm.com or Git source repo)
- [ ] Rule is exact quote or direct paraphrase from spec
- [ ] Implementation location identified in ex_git_engine code
- [ ] Protocol phase clearly identified (discovery, command, response, etc)
- [ ] Identified as universal (wire) or transport-specific (HTTP/SSH)

**Completeness:**
- [ ] Any gaps documented for future work
- [ ] Error cases handled (libgit2 error codes, edge cases)
- [ ] Memory management correct (if NIF code added)

## Getting Protocol Details

**To extract clean text from man pages:**
```bash
man gitprotocol-v2 2>/dev/null | col -b > /tmp/gitprotocol-v2.txt
# Use col -b to remove formatting artifacts (backspaces, bold/underline codes)
```

**Man page sources (always available on system with git):**
- `gitprotocol-v2(5)` — Latest protocol version, preferred for implementation
- `gitprotocol-pack(5)` — Core wire protocol, shared by v1 and v2
- `gitprotocol-capabilities(5)` — Capability definitions (all versions)
- `gitprotocol-http(5)` — HTTP transport specifics
- `gitprotocol-common(5)` — Common elements across protocol versions

## Error Handling

**If protocol detail needs verification:**
1. **Check man pages first** — Always available, authoritative, no network required
   - `man gitprotocol-<type> | col -b` to get clean text
   - Man pages are source-of-truth
2. **Update skill references** — When man page reveals detail not in references, update .md file
3. **Fall back to web docs** — Only if system man pages unavailable (use git-scm.com)
4. **Document source** — Always note which man page (with version if visible) provided the detail

**For libgit2 questions:**
1. Check `references/libgit2_api.md` first (comprehensive API reference)
2. Reference official https://libgit2.github.io/libgit2/ for detailed signatures
3. Check GitHub source code: https://github.com/libgit2/libgit2/tree/main/include

**For protocol questions:**
1. **Check man pages** — `man gitprotocol-v2 | col -b` for authoritative details
2. Start with `references/git_protocol_v2.md` for previously collected details
3. Reference `references/git_protocol_wire.md` for universal rules
4. Update reference files with any new findings from man pages

## When to Use NIF (libgit2)

These should **always** be done via NIF/libgit2, not reimplemented in Elixir:

| Task | libgit2 Function | Why NIF | Don't Implement in Elixir |
|------|------------------|---------|--------------------------|
| Open repository | `git_repository_open` | Core operation, handles .git discovery | Parsing .git structure is complex |
| Look up commit | `git_object_lookup` + `git_commit_*` | Standard Git object handling | OID resolution, caching, error handling |
| Walk commits | `git_revwalk_*` | Efficient graph traversal | Requires understanding Git DAG, loose/pack objects |
| Get tree entries | `git_tree_entry_*` | Standard tree iteration | Tree parsing from binary format |
| Get blob contents | `git_blob_rawcontent` | Handles loose/pack object decompression | Zlib decompression, packfile delta resolution |
| Update references | `git_reference_set_target` | Atomic ref updates, handles symbolic refs | Race conditions, atomic semantics |
| Calculate packfile | `git_diff_*`, `git_packfile_*` | Complex binary format, deltas | Delta compression algorithm |
| Index operations | `git_index_*` | Standard staging area logic | Binary index format, conflict resolution |
| Resolve HEAD | `git_repository_head` | Handles symbolic ref chains | Ref dereferencing logic |

## When to Use Elixir (Don't Use NIF)

These should **only** be done in Elixir, not in C:

| Task | Why Elixir | Don't Use NIF |
|------|-----------|--------------|
| Protocol framing (pkt-line) | Format encoding, not Git operation | libgit2 doesn't do protocol, just objects |
| Capability negotiation | Business logic specific to ExGitEngine | libgit2 doesn't negotiate capabilities |
| Push/fetch hooks | Repository-specific validation | Custom application logic, not Git core |
| Concurrent access serialization | Erlang GenServer patterns | libgit2 isn't thread-safe; GitAgent serializes |
| Caching strategy | Application-level caching decisions | libgit2 has internal cache; GitAgent adds Elixir caching |
| Error translation | Elixir error tuples | libgit2 return codes → `{:ok, result}` or `{:error, reason}` |
| Configuration | User-provided options, hooks | Application setup, not Git core operations |

## Common Searches

**Universal Wire Protocol** (same for HTTP and SSH):
- `pkt-line format` → Reference: git_protocol_wire.md — 4-byte hex size encoding, flush-pkt
- `report-status capability` → Reference: git_protocol_wire.md — When/how server sends push results
- `capability negotiation` → Reference: git_protocol_wire.md — Client requests, server validation, NUL-separated format
- `receive-pack phases` → Reference: git_protocol_wire.md — Discovery → commands → response
- `upload-pack negotiation` → Reference: git_protocol_wire.md — Want/have phases, object request
- `command format` → Reference: git_protocol_wire.md — Create/delete/update structure with NUL-capabilities

**HTTP-Specific Transport**:
- `http smart protocol` → Reference: git_protocol_http.md — GET /info/refs, POST /git-receive-pack
- `content-type headers` → Reference: git_protocol_http.md — application/x-git-receive-pack-*
- `cache-control headers` → Reference: git_protocol_http.md — Preventing discovery caching
- `http redirects` → Reference: git_protocol_http.md — 301/302 handling
- `http authentication` → Reference: git_protocol_http.md — Basic auth, tokens, TLS certs
- `protocol version http` → Reference: git_protocol_http.md — Git-Protocol header negotiation

**SSH-Specific Transport**:
- `ssh command execution` → Reference: git_protocol_ssh.md — git-receive-pack/git-upload-pack invocation
- `ssh authentication` → Reference: git_protocol_ssh.md — Key auth, password auth, agent forwarding
- `ssh channel` → Reference: git_protocol_ssh.md — stdin/stdout delivery, EOF detection
- `ssh environment variables` → Reference: git_protocol_ssh.md — GIT_PROTOCOL, GIT_USER_AGENT
- `ssh debugging` → Reference: git_protocol_ssh.md — -v logging, xxd capture, comparison with HTTP

**libgit2 C API**:
- `libgit2 repository operations` → Reference: libgit2_api.md — Opening, creating, configuration
- `libgit2 object lookup` → Reference: libgit2_api.md — By OID, by reference, revision walking
- `libgit2 commits` → Reference: libgit2_api.md — Accessing/creating commits, metadata, trees, parents
- `libgit2 trees and blobs` → Reference: libgit2_api.md — Tree entries, blob contents, recursive walking
- `libgit2 references` → Reference: libgit2_api.md — Looking up, creating, updating, deleting, iteration
- `libgit2 index` → Reference: libgit2_api.md — Staging area operations, adding/removing files
- `libgit2 memory management` → Reference: libgit2_api.md — Object lifecycle, freeing, leak prevention
- `libgit2 thread safety` → Reference: libgit2_api.md — Repository serialization, NIF implications
- `libgit2 error handling` → Reference: libgit2_api.md — Return codes, error details, common pitfalls

**Implementation**:
- `ex_git_engine capability validation` → Reference: git_protocol_wire.md — caps vs advertised_caps, validation rules
- `ex_git_engine report-status decision` → Reference: git_protocol_wire.md — Check caps field, not advertised_caps
- `ex_git_engine http transport` → Reference: git_protocol_http.md — Request/response body handling
- `ex_git_engine ssh transport` → Reference: git_protocol_ssh.md — Channel stdin/stdout handling
- `ex_git_engine nif wrapper` → Reference: libgit2_api.md — Memory management in NIFs, serialization, safety rules
- `ex_git_engine git module` → Reference: libgit2_api.md — Elixir bindings to libgit2 C functions

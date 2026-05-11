---
name: git-spec-explorer
description: >-
  Explore and collect details from Git specifications to ensure protocol conformity.
  Use when implementing Git wire protocol features, validating capability negotiation,
  or debugging push/fetch protocol issues. Searches official Git specs, fetches protocol
  documentation, and references gitrekt's collected protocol knowledge.
allowed-tools:
  - WebSearch
  - mcp__mcp-server-fetch__fetch
  - Read
---

# Git Spec Explorer

**Purpose:** Systematically explore Git specifications and collect implementation details to ensure protocol conformity in gitrekt.

**Core Principle:** GitRekt is a thin Elixir wrapper around libgit2. Maximize use of libgit2's C API via NIFs; only build Elixir code when libgit2 doesn't provide the functionality.

## Quick Start

```
/git-spec-explorer [search term or protocol aspect]

Examples:
- /git-spec-explorer report-status capability format
- /git-spec-explorer pkt-line encoding wire protocol
- /git-spec-explorer push protocol receive-pack flow
```

This searches official Git specs, fetches detailed documentation, and references gitrekt's protocol knowledge base. Returns findings organized by specification source and relevance to implementation.

## NIF-First Design Principle

**GitRekt Architecture:** libgit2 (C) → NIF bindings (`Git` module) → Elixir wrappers (`GitAgent`, `GitRepo`)

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
1. **Search official specs** → WebSearch across git-scm.com documentation and technical specs
2. **Fetch detailed sections** → WebFetch specific protocol docs for full context
3. **Cross-reference local** → Reference local protocol documentation for implementation details
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
4. **Validate against gitrekt** → Check if `references/git_protocol.md` has this detail
5. **Document gaps** → Note any specs gitrekt hasn't documented yet

**Template for findings:**
```
Protocol Aspect: [capability | response format | command validation | etc]
Spec Reference: https://git-scm.com/docs/gitprotocol-[pack|http|capabilities]
Rule: [exact requirement from spec]
Current Implementation: [gitrekt file/function handling this]
Gaps: [anything missing or unclear]
```

## Key Specs to Know

**Primary Sources:**
- https://git-scm.com/docs/gitprotocol-pack — Wire protocol (capabilities, pkt-line, push/fetch sequences)
- https://git-scm.com/docs/gitprotocol-capabilities — Capability negotiation and advertising
- https://git-scm.com/docs/gitprotocol-http — HTTP smart protocol specifics
- https://git-scm.com/book/en/v2/Git-Internals-Transfer-Protocols — Protocol overview (covers both HTTP and SSH)
- RFC 4254 — SSH Connection Protocol (for SSH transport details)

**Gitrekt Reference Documents:**
- `references/git_protocol_wire.md` — Core wire protocol (universal): pkt-line format, capability negotiation, push/fetch phases, report-status, command structures
- `references/git_protocol_http.md` — HTTP smart protocol: GET /info/refs, POST /git-receive-pack, headers, authentication, redirects, Content-Type negotiation
- `references/git_protocol_ssh.md` — SSH transport: command execution, channel setup, authentication, environment, wire protocol delivery over stdin/stdout
- `references/libgit2_api.md` — libgit2 C library: API reference, repository/object/ref operations, memory management, NIF wrapper implications, common patterns

## Reference Document Structure

The references are organized by layer to eliminate duplication:

**Wire Protocol Layer** (transport-agnostic):
- **git_protocol_wire.md** — Shared by both HTTP and SSH
  - Pkt-line format, capabilities, phases (discovery, commands, response)
  - Push/fetch flows, packfile handling
  - GitRekt implementation specifics (`caps` vs `advertised_caps`)

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
  - NIF wrapper implications for GitRekt
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
- [ ] Implementation location identified in gitrekt code
- [ ] Protocol phase clearly identified (discovery, command, response, etc)
- [ ] Identified as universal (wire) or transport-specific (HTTP/SSH)

**Completeness:**
- [ ] Any gaps documented for future work
- [ ] Error cases handled (libgit2 error codes, edge cases)
- [ ] Memory management correct (if NIF code added)

## Error Handling

**If git-scm.com is unreachable:**
1. Fall back to local references for cached knowledge
2. Reference RFC 9000 series for Git protocol specifications (alternative authoritative source)
3. Check libgit2 documentation (https://libgit2.github.io/libgit2/) for C library details

**If local documentation is missing:**
1. Query WebSearch for the specific Git protocol or libgit2 aspect
2. Document findings in appropriate reference file for future reference
3. Note in implementation whether spec details are confirmed or inferred

**For libgit2 questions:**
1. Check `references/libgit2_api.md` first (comprehensive API reference)
2. Reference official https://libgit2.github.io/libgit2/ for detailed signatures
3. Check GitHub source code: https://github.com/libgit2/libgit2/tree/main/include

**For protocol questions:**
1. Start with `references/git_protocol_wire.md` (universal rules)
2. Reference HTTP/SSH files for transport-specific details
3. Cross-check against official https://git-scm.com/docs/gitprotocol-pack

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
| Capability negotiation | Business logic specific to GitRekt | libgit2 doesn't negotiate capabilities |
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
- `gitrekt capability validation` → Reference: git_protocol_wire.md — caps vs advertised_caps, validation rules
- `gitrekt report-status decision` → Reference: git_protocol_wire.md — Check caps field, not advertised_caps
- `gitrekt http transport` → Reference: git_protocol_http.md — Request/response body handling
- `gitrekt ssh transport` → Reference: git_protocol_ssh.md — Channel stdin/stdout handling
- `gitrekt nif wrapper` → Reference: libgit2_api.md — Memory management in NIFs, serialization, safety rules
- `gitrekt git module` → Reference: libgit2_api.md — Elixir bindings to libgit2 C functions

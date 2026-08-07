# Git Wire Protocol (Universal)

Core wire protocol specification shared by both HTTP smart protocol and SSH transport.

Sources:
- https://git-scm.com/docs/gitprotocol-pack
- https://git-scm.com/docs/gitprotocol-capabilities

## Table of Contents

- [pkt-line Format](#pkt-line-format)
- [Reference Discovery Phase (receive-pack)](#reference-discovery-phase-receive-pack)
- [Push Commands Phase (receive-pack)](#push-commands-phase-receive-pack)
- [Report-Status Response Phase (receive-pack)](#report-status-response-phase-receive-pack)
- [Post-Receive Hook Output Phase (receive-pack)](#post-receive-hook-output-phase-receive-pack)
- [Reference Discovery Phase (upload-pack)](#reference-discovery-phase-upload-pack)
- [Fetch Negotiation Phase (upload-pack)](#fetch-negotiation-phase-upload-pack)
- [Common Protocol Rules (All Operations)](#common-protocol-rules-all-operations)
- [Full Push Example (Wire Protocol Only)](#full-push-example-wire-protocol-only)
- [ExGitEngine Implementation Notes](#ex_git_engine-implementation-notes)

---

## pkt-line Format

Every message is framed in pkt-line format (used by both HTTP and SSH):

- 4 ASCII hex digits = total size of the line INCLUDING the 4-digit prefix
- Payload bytes follow immediately
- Sender SHOULD append LF; receiver MUST NOT complain if absent
- `0000` = flush-pkt (no payload, signals phase end)

Example: `000eunpack ok\n`
- `000e` = 14 decimal = 4 (prefix) + 9 (payload "unpack ok") + 1 (LF) = 14 ✓

Error packet: `PKT-LINE("ERR" SP explanation-text)` — terminates the session immediately.

---

## Reference Discovery Phase (receive-pack)

Server advertises all refs and capabilities (called after startup, transport-independent).

Format:
```
S: PKT-LINE(obj-id SP refname NUL capability-list)
S: PKT-LINE(obj-id SP refname)
...
S: flush-pkt
```

If repository is empty (no refs):
```
S: PKT-LINE(zero-id SP "capabilities^{}" NUL capability-list)
S: flush-pkt
```

**Critical**: Capabilities appear ONLY on the FIRST ref line, NUL-separated. All subsequent ref lines have NO capabilities.

### Sideband-64k in Receive-Pack Context

**Official spec**: "If *side-band* or *side-band-64k* capabilities have been specified by the client, the server will send the packfile data multiplexed."

**In receive-pack (push):**
- Client SENDS packfile to server
- Server RECEIVES packfile
- Server does NOT send packfile, so sideband is not used for packfile transmission
- **BUT:** Server CAN send hook output via sideband channel 2 AFTER report-status

**Advertising side-band-64k in receive-pack:**
- Is technically valid per spec (both services can have it)
- But has NO effect on push responses (report-status is plain pkt-line)
- Only affects if server sends sideband channel 2 messages (post-receive hook output)

### Valid receive-pack Capabilities

Per gitprotocol-capabilities spec: "The *atomic*, *report-status*, *report-status-v2*, *delete-refs*, *quiet*, and *push-cert* capabilities are sent and recognized by the receive-pack (push to server) process. The *ofs-delta* and *side-band-64k* capabilities are sent and recognized by both upload-pack and receive-pack protocols."

- `report-status` — server can send push result report
- `report-status-v2` — extended report-status with proc-receive hook support
- `delete-refs` — server accepts zero-id as target (ref deletion)
- `ofs-delta` — server understands OBJ_OFS_DELTA pack format (BOTH services)
- `side-band-64k` — server can multiplex packfile data during upload (BOTH services, client can use this when sending packfile)
- `atomic` — server can apply all ref updates atomically or none
- `push-options` — server accepts push options
- `push-cert=<nonce>` — server accepts signed push certificates
- `quiet` — server can suppress progress output if client requests it
- `agent=X` — informational server version string
- `session-id=<id>` — session identifier for tracking (BOTH services)

**Server MUST NOT advertise capabilities it does not support.**

**CRITICAL DISTINCTION: Sideband in receive-pack**
- `side-band-64k` capability in receive-pack applies ONLY to how the CLIENT sends the packfile data
- It does NOT apply to the SERVER's report-status response
- The server sends report-status as plain pkt-line format, never multiplexed

---

## Push Commands Phase (receive-pack)

Client sends ref update commands and packfile.

Format:
```
command-list = PKT-LINE(command NUL capability-list)
               *PKT-LINE(command)
               flush-pkt
packfile     = "PACK" 28*(OCTET)
```

Command structures:
- `create = zero-id SP new-id SP refname`
- `delete = old-id SP zero-id SP refname`
- `update = old-id SP new-id SP refname`

### Capability Negotiation Rules

**Critical**: Capabilities appear ONLY on FIRST command line, NUL-separated.
- First command: `old-id SP new-id SP refname NUL cap1 cap2 cap3`
- Subsequent commands: `old-id SP new-id SP refname` (no NUL, no capabilities)
- If client sends no capabilities, NUL byte may be absent

**Validation**:
- Client MUST NOT request capabilities server did not advertise
- Server MUST NOT send report-status unless client requested it
- Server MUST diagnose and abort if unknown capabilities received

### Packfile Rules

- Packfile MUST be sent if any create or update command is used (send empty pack if objects already exist)
- Packfile MUST NOT be sent if only command is delete
- If push-options were negotiated, client sends them between command flush-pkt and packfile start

### Packfile Data Transfer (receive-pack)

If client advertised `side-band-64k` capability, the client SENDS the packfile multiplexed (not the server).

Per gitprotocol-pack spec:
> "Each packet starting with the packet-line length of the amount of data that follows, followed by a single byte specifying the sideband the following data is coming in on... The sideband byte will be a *1*, *2* or a *3*. Sideband *1* will contain packfile data, sideband *2* will be used for progress information that the client will generally print to stderr and sideband *3* is used for error information."

**This is for CLIENT→SERVER packfile transmission, not server responses.**

Format when sideband is negotiated:
```
[4-byte pkt-line length] [1-byte stream code] [payload data]
  - stream code 1: packfile data
  - stream code 2: progress (client progress only, not server)
  - stream code 3: error
```

---

## Report-Status Response Phase (receive-pack)

**The server sends a report IF AND ONLY IF the client included `report-status` in the capability-list of its first command line.**

From gitprotocol-capabilities spec:
> "The receive-pack process can receive a report-status capability, which tells it that the client wants a report of what happened after a packfile upload and reference update. **If the pushing client requests this capability**, after unpacking and updating references the server will respond..."

**CRITICAL: Report-status is ALWAYS plain pkt-line, NEVER sideband-wrapped.** (Even if side-band-64k capability was negotiated.)

From official spec: "If *side-band* or *side-band-64k* capabilities have been specified by the client, **the server will send the packfile data multiplexed**." (Emphasis: packfile data only, not responses.)

Report format (plain pkt-line):
```
report-status = unpack-status
                1*(command-status)
                flush-pkt

unpack-status  = PKT-LINE("unpack" SP unpack-result)
unpack-result  = "ok" / error-msg

command-status = command-ok / command-fail
command-ok     = PKT-LINE("ok" SP refname)
command-fail   = PKT-LINE("ng" SP refname SP error-msg)

error-msg      = 1*(OCTET)   ; anything that is not "ok"
```

Example successful report:
```
S: 000eunpack ok\n
S: 0018ok refs/heads/debug\n
S: 0000
```

Example with one rejection:
```
S: 000eunpack ok\n
S: 0018ok refs/heads/debug\n
S: 002ang refs/heads/master non-fast-forward\n
S: 0000
```

**If the client did NOT request report-status, the server sends nothing and closes the connection.**

---

## Post-Receive Hook Output Phase (receive-pack)

**After report-status completes, the server runs the `post-receive` hook and sends its output via sideband channel 2.**

This is NOT part of the official protocol spec, but is standard Git server behavior (documented in Git source: builtin/receive-pack.c line 2718-2719).

Hook output handling from Git source code:
- Server runs `post-receive` hook with sideband enabled
- Hook's stdout/stderr is captured via `copy_to_sideband()` function
- Output is sent via `send_sideband(1, 2, ...)` — **channel 2** (informational messages)
- Client receives and displays as `remote: [message]`

**Protocol sequence:**
```
S: 000eunpack ok\n                    (report-status: unpack result)
S: 0018ok refs/heads/master\n         (report-status: ref result)
S: 0000                                (report-status: flush)
S: [sideband channel 2 hook output]    (post-receive hook output)
S: 0000                                (final flush)
```

**Client behavior:**
- Reads report-status pkt-lines (unpack ok, ref ok/ng) — **processes internally for success/failure determination**
- Receives sideband channel 2 data — **displays to user as `remote: ...`**

**Real example (Bitbucket):**
```
Server sends:
  000eunpack ok\n
  0018ok refs/heads/feature/cyclone\n
  0000
  [sideband ch2] View pull request for feature/cyclone => release/cyclone:\n
  [sideband ch2]   https://bitbucket.org/.../pull-requests/191\n
  0000

Client displays to user:
  remote:
  remote: View pull request for feature/cyclone => release/cyclone:
  remote:   https://bitbucket.org/.../pull-requests/191
  
  feature/cyclone -> feature/cyclone
```

**Key point:** Report-status lines are NOT displayed to user. Only hook output (sideband ch2) is shown as `remote: ...`

---

## Reference Discovery Phase (upload-pack)

Server advertises all refs and capabilities for fetch/pull operations.

Same format as receive-pack:
```
S: PKT-LINE(obj-id SP refname NUL capability-list)
S: PKT-LINE(obj-id SP refname)
...
S: flush-pkt
```

### Valid upload-pack Capabilities

- `agent=X` — informational server version
- `fetch-pack` — server supports protocol version
- `ls-refs` — server supports ls-refs command (protocol v2)
- `fetch` — server supports fetch command (protocol v2)
- `server-option` — server accepts server options
- `object-format=<algorithm>` — object format (sha1, sha256)
- `symref=HEAD:refs/heads/main` — symbolic ref advertisement
- `thin-pack` — server understands thin pack format
- `ofs-delta` — server understands OBJ_OFS_DELTA format
- `side-band` / `side-band-64k` — server can multiplex progress/error on side channel
- `allow-tip-sha1-in-want` — server allows requesting arbitrary SHAs
- `allow-reachable-sha1-in-want` — server allows requesting reachable SHAs

---

## Fetch Negotiation Phase (upload-pack)

Client sends want/have lines to negotiate which objects are needed.

Format:
```
C: PKT-LINE("want" SP obj-id SP capability-list)
C: PKT-LINE("want" SP obj-id)
...
C: PKT-LINE("have" SP obj-id)
...
C: flush-pkt
```

First "want" line has NUL-separated capabilities; subsequent lines don't.

Server responds:
```
S: PKT-LINE("ACK" / "NAK" ...)
S: [PACKDATA if objects needed]
```

---

## Common Protocol Rules (All Operations)

1. **Capability negotiation is transport-agnostic** — same rules for HTTP and SSH
2. **Pkt-line framing is universal** — both transports use identical pkt-line format
3. **Phase structure is universal** — discovery → commands → response, regardless of transport
4. **EOF handling** — client closing connection signals end of push/fetch (transport-specific delivery)
5. **Bidirectional** — both client→server and server→client messages use same pkt-line format
6. **No assumptions about transport** — protocol spec doesn't care if it's HTTP, SSH, git://, or socket

---

## Full Push Example (Wire Protocol Only)

```
# Reference discovery phase
S: 006274730d410fcb6603ace96f1dc55ea6196122532d refs/heads/local\0report-status delete-refs ofs-delta\n
S: 003e7d1665144a3a975c05f1f43902ddaf084e784dbe refs/heads/debug\n
S: 003f74730d410fcb6603ace96f1dc55ea6196122532d refs/heads/master\n
S: 0000

# Client push commands (with capabilities on first line)
C: 00677d1665144a3a975c05f1f43902ddaf084e784dbe 74730d410fcb6603ace96f1dc55ea6196122532d refs/heads/debug\0report-status\n
C: 006874730d410fcb6603ace96f1dc55ea6196122532d 5a3f6be755bbb7deae50065988cbfa1ffa9ab68a refs/heads/master\n
C: 0000
C: [PACKDATA]

# Server report (because client requested report-status)
S: 000eunpack ok\n
S: 0018ok refs/heads/debug\n
S: 002ang refs/heads/master non-fast-forward\n
S: 0000
```

---

## ExGitEngine Implementation Notes

### Capabilities Fields in WireProtocol.ReceivePack

- **`caps`**: Capabilities parsed from CLIENT's first command line (via `parse_caps/1`)
  - Source: parsed from push request body (first command pkt-line, NUL-separated)
  - This is what CLIENT chose to request (subset of advertised)
  - Used for all decision-making (report-status, etc.)
  - MUST be validated against advertised capabilities
  - Format: list of strings like ["report-status", "side-band-64k", "agent=git/2.54.0"]

- **`advertised_caps`**: Capabilities server advertised during reference discovery
  - Source: initial capabilities sent in discovery phase (server side)
  - Contains ONLY server capabilities, NOT client capabilities
  - Used for validation: ensures client didn't request unknown capabilities
  - CRITICAL: Should NEVER be concatenated with `caps` (client capabilities)
  - Format: list of strings like ["agent=ex_git_engine/0.3.9", "report-status", "delete-refs", ...]

### Protocol Rule: "Requests" Means Client Sends It

From gitprotocol-capabilities spec:
> "The receive-pack process can receive a report-status capability, which tells it that the client wants a report of what happened after a packfile upload and reference update. **If the pushing client requests this capability**, after unpacking and updating references the server will respond..."

"Requests" = client includes it in the first command line (stored in `caps`), NOT that server advertised it.

**`report_status/1` and other decision logic MUST check `caps` (what client sent), NEVER `advertised_caps` (what server advertised).**

### Capability Validation Requirements

From gitprotocol-capabilities v1 spec:
> "The client MUST NOT ask for capabilities the server did not say it supports."
> "Server MUST diagnose and abort if capabilities it does not understand were sent."

After extracting `caps` from client request:

```elixir
# caps = what client requested (from first command line)
# advertised_caps = what server advertised in discovery (ONLY server capabilities)

# MUST NOT concatenate them
advertised_caps = get_server_advertised_capabilities()  # NOT: ++ client_caps

# MUST validate
unknown_caps = caps -- advertised_caps
if unknown_caps != [] do
  abort_with_error("unknown capabilities: #{inspect(unknown_caps)}")
end
```

**CRITICAL**: `advertised_caps` contains ONLY server capabilities. It should NEVER include client capabilities.

Only after validation passes should the server process client requests.

### Parameterized Capabilities

Some capabilities have parameters (using `=` syntax) where negotiation rules vary by capability type.

#### Capability Classes

**1. Informational/Negotiable — Client Has Freedom**

- **`agent=X`** (both receive-pack and upload-pack)
  - Server advertises: `agent=ex_git_engine/1.0.0`
  - Client may respond: `agent=git/2.54.0-Darwin` (DIFFERENT value allowed)
  - Spec: "The client may optionally return its own agent string by responding with an `agent=Y` capability (but it MUST NOT do so if the server did not mention the agent capability)."
  - Purpose: Purely informational for statistics/debugging; MUST NOT programmatically assume features
  - Validation: Allow ANY `agent=*` value from client if server advertised `agent=*`

- **`session-id=<id>`** (both services)
  - Server advertises: `session-id=abc123def456`
  - Client may respond: `session-id=xyz789qrs012` (own independent session ID)
  - Spec: "The client may advertise its own session ID back to the server as well."
  - Purpose: Parallel tracking of request flow across connections
  - Validation: Accept any `session-id=*` value from client

**2. Constrained — Client Chooses From Advertised Set**

- **`object-format=<algorithm>`** (both services)
  - Server advertises: Multiple options, e.g., `object-format=sha256 object-format=sha1`
  - Client must respond: With ONE of the advertised algorithms only
  - Spec: "When provided by the client, this indicates that it intends to use the given hash algorithm to communicate. The algorithm provided must be one that the server supports."
  - Purpose: Hash algorithm negotiation for object IDs
  - Validation: Client value MUST be in set of advertised values

- **`filter=<type>`** (upload-pack only, partial clone)
  - Server advertises: Supported filter types
  - Client requests: From advertised set only
  - Spec: "If the upload-pack server advertises the *filter* capability, fetch-pack may send 'filter' commands to request a partial clone..."
  - Validation: Client value MUST be in advertised set

**3. One-Directional — Server Only**

- **`symref=<name>:<target>`** (both services, informational)
  - Server advertises: Which symbolic refs point to which refs, e.g., `symref=HEAD:refs/heads/main`
  - Client: Consumes information, does NOT send back
  - Spec: "This parameterized capability is used to inform the receiver which symbolic ref points to which ref... This capability can be repeated to represent multiple symrefs."
  - Purpose: Inform client of initial HEAD without extra round-trip
  - Validation: Clients never send this capability

**4. Challenge-Response — Server Provides, Client Uses**

- **`push-cert=<nonce>`** (receive-pack only)
  - Server advertises: A nonce value for this push
  - Client includes: The EXACT nonce in signed push certificate
  - Spec: "A send-pack client MUST NOT send a push-cert packet unless the receive-pack server advertises this capability."
  - Purpose: Prevent replay attacks on signed pushes
  - Validation: Client MUST use the exact nonce server provided

#### Binary Flag Capabilities (No Parameters)

These are on/off flags, not parameterized:
- `multi_ack`, `multi_ack_detailed` — multi-ACK protocol support
- `no-done` — omit "done" command requirement
- `thin-pack` — server understands thin pack format
- `side-band`, `side-band-64k` — multiplexing progress/error on side channel
- `ofs-delta` — server understands OBJ_OFS_DELTA format
- `delete-refs` — server accepts zero-id (ref deletion)
- `quiet` — suppress progress output if requested
- `atomic` — apply all ref updates atomically or none
- `report-status`, `report-status-v2` — server sends push result report
- `allow-tip-sha1-in-want`, `allow-reachable-sha1-in-want` — permit requesting arbitrary SHAs
- `push-options` — server accepts push options
- `shallow`, `include-tag`, `no-progress`, `deepen-relative` — fetch-related flags

#### Protocol v2 Differences

In Protocol v2, capabilities are in their own section (not hidden behind NUL byte):

```
key[=value] LF
key[=value] LF
...
```

Rules:
- `key = 1*(ALPHA | DIGIT | "-_")`
- `value = 1*(ALPHA | DIGIT | " -_.,?\/{}[]()<>!@#$%^&*+=:;")`

Parameterized capabilities in v2:
- `agent=X` (same rules as v0/v1)
- `ls-refs` (with features: `ls-refs=symrefs peel ref-prefix`)
- `fetch` (with features: `fetch=<feature> <feature>`)
- `push` (with features)

#### Implementation: Validation Pattern

```elixir
# Correct validation for mixed parameterized/binary capabilities
unknown_caps = Enum.reject(caps, fn cap ->
  # Binary flags: exact match
  cap in advertised_caps or
  # Parameterized with free choice (agent, session-id)
  String.starts_with?(cap, "agent=") or
  String.starts_with?(cap, "session-id=") or
  # Parameterized with constraints (object-format, filter)
  cap_name_in_advertised?(cap, advertised_caps, ["object-format", "filter"]) or
  # Parameterized one-way (symref) — never from client
  String.starts_with?(cap, "symref=")
end)

if unknown_caps != [] do
  abort_with_error("unknown capabilities: #{inspect(unknown_caps)}")
end

defp cap_name_in_advertised?(cap, advertised_caps, names) do
  Enum.any?(names, fn name ->
    String.starts_with?(cap, name <> "=") and
    Enum.any?(advertised_caps, &String.starts_with?(&1, name <> "="))
  end)
end
```

#### Summary: Implementation Decision Tree

When validating client capability `cap` against server `advertised_caps`:

1. **Is `cap` exactly in `advertised_caps`?** → ALLOW (binary flag match)
2. **Does `cap` start with `agent=` or `session-id=`?** → ALLOW (client has freedom)
3. **Does `cap` start with `object-format=` or `filter=`?** → ALLOW if name is advertised and value is from advertised set
4. **Does `cap` start with `symref=`?** → REJECT (server-only)
5. **Anything else?** → REJECT (unknown capability)

**Key Insight**: The protocol distinguishes between capabilities where clients have freedom to provide different values (agent, session-id) versus capabilities where clients must choose from a constrained set (object-format, filter). Conflating these leads to protocol violations.

### Key Invariants

1. **After `parse_caps/1` extracts client capabilities**: `caps` = client-requested, `advertised_caps` = server-advertised
2. **Validation**: All items in `caps` MUST be subset of `advertised_caps`
3. **Decisions (like report-status)**: Use `caps` only, but only after validation passes
4. **Missing capabilities**: If client sends no capabilities, `parse_caps` returns `[]`, and server MUST NOT send report-status

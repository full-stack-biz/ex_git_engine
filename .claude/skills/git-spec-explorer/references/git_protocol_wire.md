# Git Wire Protocol (Universal)

Core wire protocol specification shared by both HTTP smart protocol and SSH transport.

Sources:
- https://git-scm.com/docs/gitprotocol-pack
- https://git-scm.com/docs/gitprotocol-capabilities

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

### Valid receive-pack Capabilities

- `report-status` — server can send push result report
- `report-status-v2` — extended report-status with proc-receive hook support
- `delete-refs` — server accepts zero-id as target (ref deletion)
- `ofs-delta` — server understands OBJ_OFS_DELTA pack format
- `atomic` — server can apply all ref updates atomically or none
- `push-options` — server accepts push options
- `push-cert=<nonce>` — server accepts signed push certificates
- `quiet` — server can suppress progress output if client requests it
- `agent=X` — informational server version string

**Server MUST NOT advertise capabilities it does not support.**

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

---

## Report-Status Response Phase (receive-pack)

**The server sends a report IF AND ONLY IF the client included `report-status` in the capability-list of its first command line.**

From gitprotocol-capabilities spec:
> "The receive-pack process can receive a report-status capability, which tells it that the client wants a report of what happened after a packfile upload and reference update. **If the pushing client requests this capability**, after unpacking and updating references the server will respond..."

Report format:
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

## GitRekt Implementation Notes

### Capabilities Fields in WireProtocol.ReceivePack

- **`caps`**: Capabilities parsed from CLIENT's first command line (via `parse_caps/1`)
  - Source: parsed from push request body (first command pkt-line, NUL-separated)
  - This is what CLIENT chose to request
  - Used for all decision-making (report-status, etc.)
  - MUST be validated against advertised capabilities

- **`advertised_caps`**: Capabilities server advertised during reference discovery
  - Source: initial capabilities sent in discovery phase
  - Used for validation: unknown capabilities received from client must abort
  - HTTP transport may skip actual discovery phase and seed this from initial caps

### Protocol Rule: "Requests" Means Client Sends It

From gitprotocol-capabilities spec:
> "The receive-pack process can receive a report-status capability, which tells it that the client wants a report of what happened after a packfile upload and reference update. **If the pushing client requests this capability**, after unpacking and updating references the server will respond..."

"Requests" = client includes it in the first command line (stored in `caps`), NOT that server advertised it.

**`report_status/1` and other decision logic MUST check `caps` (what client sent), NEVER `advertised_caps` (what server advertised).**

### Capability Validation Requirements

After extracting `caps` from client request, validate:

```elixir
unknown_caps = caps -- advertised_caps
if unknown_caps != [] do
  abort_with_error("unknown capabilities: #{inspect(unknown_caps)}")
end
```

Only after validation passes should the server process client requests.

### Key Invariants

1. **After `parse_caps/1` extracts client capabilities**: `caps` = client-requested, `advertised_caps` = server-advertised
2. **Validation**: All items in `caps` MUST be subset of `advertised_caps`
3. **Decisions (like report-status)**: Use `caps` only, but only after validation passes
4. **Missing capabilities**: If client sends no capabilities, `parse_caps` returns `[]`, and server MUST NOT send report-status

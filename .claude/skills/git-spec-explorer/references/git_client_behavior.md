# Git Client Behavior (Transport-Agnostic)

Client-side parsing and behavior for git push/fetch operations. Applies to all transports (HTTP, SSH, etc).

Sources:
- https://github.com/git/git/blob/v2.54.0/builtin/push.c — Push command entry point
- https://github.com/git/git/blob/v2.54.0/send-pack.c — Push protocol handling
- https://github.com/git/git/blob/v2.54.0/remote-curl.c — HTTP transport (applies principles to all transports)

## Table of Contents

- [Push Flow (git push)](#push-flow-git-push)
- [Transport Integration](#transport-integration)
- [Debugging "error: failed to push some refs"](#debugging-error-failed-to-push-some-refs)
- [Reference Format Validation](#reference-format-validation)
- [Implementation Notes for Servers](#implementation-notes-for-servers)

---

## Push Flow (git push)

### High-Level Flow

```
cmd_push()
  → do_push()
    → push_with_options()
      → transport_push()  ← Returns error code (0 = success, non-zero = failure)
        → sends reference discovery request
        → sends packfile + commands
        → receives report-status response via stdin (or no response if not requested)
      ← Returns status from send-pack subprocess
    ← If status != 0, prints: "error: failed to push some refs to '%s'"
```

### Success/Failure Determination

**Reference: `builtin/push.c` lines 360-362**

```c
if (err != 0) {
    error(_("failed to push some refs to '%s'"), anon_url);
    return 1;
}
```

The push is considered **successful** only if:
1. `transport_push()` returns `0` (zero error code)
2. All refs have status `REF_STATUS_OK`, `REF_STATUS_UPTODATE`, or `REF_STATUS_NONE`

The push is **failed** if:
1. `transport_push()` returns non-zero
2. Any ref has status other than OK/UPTODATE/NONE (e.g., `REF_STATUS_REMOTE_REJECT`)

### Report-Status Parsing

**Reference: `send-pack.c` lines 177+, function `receive_status()`**

The report-status response is read from **subprocess stdin** (regardless of transport):
- **HTTP transport**: remote-curl pipes HTTP response body to stdin
- **SSH transport**: SSH channel stdout is connected to stdin
- **Git protocol**: Native protocol stdin

The parser calls `receive_unpack_status()` which expects:
```
"unpack ok"    → Success, continue to ref statuses
"unpack <err>" → Failure, report error and stop
```

Then for each ref update, expects:
```
"ok <refname>"       → Ref update succeeded
"ng <refname> <msg>" → Ref update failed (rejected)
```

### Critical Behavior: No Report-Status Handling

**If client did NOT send `report-status` capability:**
- Server sends **no response** (per protocol)
- Client expects **no response** 
- If client gets a response anyway, it may fail to parse it
- Result: Git client may report push as failed even if it succeeded on server

**If client DID send `report-status` capability:**
- Server MUST send report-status response
- Client EXPECTS and PARSES the response
- Any parsing error → push marked as failed
- If response can't be parsed → subprocess returns error code → git reports "failed to push some refs"

---

## Transport Integration

### HTTP (remote-curl.c)

**Response handling:**
```c
// Lines ~350-360 in remote-curl.c
rpc_in()  // CURLOPT_WRITEFUNCTION callback
  ↓
write_or_die(1, buffer, len)  // Write response to send-pack stdin
  ↓
send-pack subprocess receives via stdin  // Sees report-status response
```

**Key behavior:** HTTP response body is piped directly to send-pack subprocess stdin. The subprocess must be able to parse what arrives on stdin.

### SSH

SSH works identically: SSH channel stdout is piped to send-pack stdin.

### Common Pattern

Regardless of transport:
1. Server sends pkt-line encoded response
2. Response is delivered to send-pack subprocess via stdin
3. send-pack parses response from stdin
4. If parsing fails or status is bad, send-pack exits with non-zero code
5. Git interprets non-zero exit as push failure

---

## Debugging "error: failed to push some refs"

This error means `send-pack` subprocess returned non-zero exit code. Possible causes:

1. **Malformed report-status response**
   - Format doesn't match: `unpack ok` / `ok <ref>` / `flush`
   - PKT-LINE encoding is broken
   - Response is incomplete or truncated

2. **Client didn't expect report-status but got one**
   - Client didn't send `report-status` capability
   - Server sent report-status anyway
   - Client can't parse unexpected data

3. **Server sent error status**
   - `unpack ng <error>` instead of `unpack ok`
   - `ng <refname>` instead of `ok <refname>`

4. **Response delivery issue**
   - Response not delivered to stdin (e.g., HTTP response body issues)
   - Response truncated during delivery
   - Encoding/compression breaking pkt-line format

5. **Send-pack subprocess crash**
   - Invalid input causes segfault
   - Out of memory
   - Assertion failure

---

## Reference Format Validation

For Git 2.54.0, these MUST match exactly:

### Successful Push Response
```
PKT-LINE("unpack ok")
PKT-LINE("ok refs/heads/main")
...more ref statuses...
flush-pkt (just "0000")
```

Example bytes:
```
000eunpack ok\n
0017ok refs/heads/main\n
0000
```

### Failed Push (Unpack)
```
PKT-LINE("unpack ng <error message>")
flush-pkt
```

### Failed Ref Update
```
PKT-LINE("unpack ok")
PKT-LINE("ng refs/heads/main rejected: protected")
...more statuses...
flush-pkt
```

---

## Implementation Notes for Servers

1. **Always send report-status if client requested it**
   - Not sending it causes client to fail even if push succeeded
   - Sending it when not requested can confuse client parsing

2. **Match format exactly**
   - PKT-LINE encoding with hex length prefix
   - Newline at end of each data line (added by pkt_line function)
   - Flush packet is exactly "0000" (4 bytes, no newline)

3. **Use correct subprocess communication**
   - HTTP: Response body must reach send-pack stdin
   - SSH: Channel stdout must be connected
   - No buffering issues that break pkt-line frames

4. **For HTTP specifically**
   - Set `Content-Type: application/x-git-receive-pack-result`
   - Set `Cache-Control: no-cache` (per spec)
   - Response is delivered via HTTP response body
   - Chunked encoding is acceptable if handled correctly

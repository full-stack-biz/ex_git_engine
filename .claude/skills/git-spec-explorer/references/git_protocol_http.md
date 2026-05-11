# Git HTTP Smart Protocol

HTTP-specific transport layer for Git's wire protocol.

Sources:
- https://git-scm.com/docs/gitprotocol-http
- https://git-scm.com/docs/gitprotocol-pack

**Core wire protocol:** See `git_protocol_wire.md` for pkt-line format, capability negotiation, push/fetch flows.

---

## HTTP Smart Protocol Overview

Git over HTTP uses the HTTP protocol to deliver the wire protocol via GET and POST requests. The wire protocol (pkt-line format, capabilities, commands, packfile) is identical to SSH transport; HTTP provides the transport wrapper.

### URL Format
```
https://github.com/user/repo.git
http://example.com/path/to/repo.git
```

### HTTP vs SSH Comparison

| Aspect | HTTP | SSH |
|--------|------|-----|
| Discovery Request | GET /info/refs?service=git-receive-pack | SSH exec (immediate server response) |
| Content-Type headers | Required (application/x-git-*) | Not used |
| Command Request | POST /git-receive-pack | SSH channel stdin/stdout |
| Response Headers | Content-Type, Cache-Control, etc. | Not used |
| Authentication | HTTP auth (basic, token, etc.) | SSH key/password |
| Disconnect signal | HTTP response end | SSH channel close |
| Pipelining | Separate HTTP requests | Single SSH channel |

---

## Reference Discovery (GET /info/refs)

### Request

```
GET /info/refs?service=git-receive-pack HTTP/1.1
Host: example.com
```

### Response

```
HTTP/1.1 200 OK
Content-Type: application/x-git-receive-pack-advertisement
Cache-Control: no-cache, no-store, must-revalidate, max-age=0
Expires: 1 Jan 1970 00:00:00 UTC
Pragma: no-cache

[Pkt-line wire protocol response]
```

Content:
```
PKT-LINE("# service=git-receive-pack")
flush-pkt
[Reference discovery pkt-lines]
[Capability list on first ref]
flush-pkt
```

Example:
```
# service=git-receive-pack
0062 74730d410fcb6603ace96f1dc55ea6196122532d refs/heads/local\0report-status delete-refs ofs-delta
003e 7d1665144a3a975c05f1f43902ddaf084e784dbe refs/heads/debug
003f 74730d410fcb6603ace96f1dc55ea6196122532d refs/heads/master
0000
```

### Critical Headers

- **Content-Type**: MUST be `application/x-git-receive-pack-advertisement` (not negotiable)
- **Cache-Control**: MUST include `no-cache, no-store, must-revalidate` (prevent caching advertisements)
- **Expires**: MUST be in the past (prevent proxy caching)
- **Pragma**: SHOULD include `no-cache` (HTTP/1.0 compatibility)

Not caching reference discovery is critical: if the client gets stale ref information, push attempts will fail with confusing errors.

---

## Push Request (POST /git-receive-pack)

### Request

```
POST /git-receive-pack HTTP/1.1
Host: example.com
Content-Type: application/x-git-receive-pack-request
Content-Length: [length of body]

[Pkt-line wire protocol request + packfile]
```

Body contents (wire protocol):
```
[Push commands with capabilities on first line]
flush-pkt
[Packfile data]
```

Example:
```
0067 7d1665144a3a975c05f1f43902ddaf084e784dbe 74730d410fcb6603ace96f1dc55ea6196122532d refs/heads/debug\0report-status
0068 74730d410fcb6603ace96f1dc55ea6196122532d 5a3f6be755bbb7deae50065988cbfa1ffa9ab68a refs/heads/master
0000
[PACKDATA]
```

### Response

```
HTTP/1.1 200 OK
Content-Type: application/x-git-receive-pack-result

[Report-status pkt-lines, if client requested]
```

Response body (if client sent `report-status` capability):
```
0009 unpack ok
0018 ok refs/heads/debug
0000
```

Response body (if client did NOT send `report-status`):
```
[Empty response, no pkt-lines]
```

### Important Notes

- **HTTP method**: MUST be POST (not PUT, not PATCH)
- **Content-Type**: MUST be `application/x-git-receive-pack-request`
- **Response Content-Type**: MUST be `application/x-git-receive-pack-result`
- **Empty response on no report-status**: Server sends no pkt-lines if client didn't request it (not even a flush-pkt)
- **Status code**: Always 200, even if push failed (failures reported via pkt-line, not HTTP status)

---

## Fetch Request (GET /info/refs + POST/GET body)

### Reference Discovery (GET /info/refs)

Same as push, but with `service=git-upload-pack`:

```
GET /info/refs?service=git-upload-pack HTTP/1.1

Content-Type: application/x-git-upload-pack-advertisement
Cache-Control: no-cache, no-store, must-revalidate, max-age=0

# service=git-upload-pack
[Reference list with capabilities]
```

### Fetch Request

If request is small enough, can be GET with body (rare). Usually POST:

```
POST /git-upload-pack HTTP/1.1
Content-Type: application/x-git-upload-pack-request

[Want/have negotiation pkt-lines]
flush-pkt
```

### Response

```
HTTP/1.1 200 OK
Content-Type: application/x-git-upload-pack-result

[Packfile data or negotiation response]
```

---

## HTTP Authentication

Authentication happens at the HTTP level, not Git protocol level:

### Basic Auth

```
GET /info/refs?service=git-receive-pack HTTP/1.1
Authorization: Basic base64(username:password)
```

### Token Auth

```
GET /info/refs?service=git-receive-pack HTTP/1.1
Authorization: Bearer token
```

### TLS Client Certs

```
GET /info/refs?service=git-receive-pack HTTP/1.1
[TLS client certificate in connection]
```

The Git service doesn't validate HTTP auth—the HTTP server (nginx, Apache, custom handler) validates and returns 401 or 403 on auth failure.

---

## HTTP Smart Protocol vs Dumb Protocol

Git HTTP has two modes: "smart" (our focus) and "dumb" (legacy, rarely used).

**Smart Protocol** (what we implement):
- Service parameter triggers smart protocol
- Dynamic reference discovery
- Capability negotiation
- Efficient object negotiation
- Used by modern Git clients

**Dumb Protocol** (not our concern):
- No service parameter
- Static .git/info/refs file
- Full packfile on every fetch
- Very inefficient

The smart protocol is always preferred by modern clients.

---

## Common HTTP Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| "403 Forbidden" on discovery | HTTP auth failed | Check credentials, server auth |
| "404 Not Found" | Wrong URL path | Check repo path |
| "Content-Type: text/html" | Server returned error page | Check auth, repo existence |
| Client doesn't see auth failure | No WWW-Authenticate header | Server must send on 401 |
| Stale refs after push | Discovery response cached | Add Cache-Control headers |
| "fatal: protocol error" | Broken pkt-line response | Check response format |
| "fatal: the remote end hung up" | Response cut short | Check Content-Length, connection handling |

---

## HTTP Redirects

If the server issues a redirect (301, 302, etc.):

```
HTTP/1.1 302 Found
Location: https://other.example.com/repo.git

[Empty body]
```

The client MUST follow the redirect by making a new request to the new URL. The Git server implementation should:
- Use permanent redirects (301) for permanent moves
- Use temporary redirects (302) for temporary unavailability
- Include full path in redirect (don't rely on client reconstruction)

---

## Protocol Version Negotiation

Modern Git uses protocol version 2, negotiated via HTTP header:

```
GET /info/refs?service=git-receive-pack HTTP/1.1
Git-Protocol: version=2
```

Server responds (if supporting v2):
```
HTTP/1.1 200 OK
...

000eversion 2
[v2 advertisement]
```

Or (if only supporting v0/v1):
```
HTTP/1.1 200 OK
...

[v0/v1 advertisement, no version line]
```

Protocol v2 uses different capability naming and negotiation, but the fundamental flows are similar.

---

## GitRekt HTTP Transport Implementation

When GitRekt receives an HTTP request:

1. **Reference discovery** (GET /info/refs?service=git-receive-pack)
   - Parse service parameter
   - Call wire protocol discovery phase
   - Wrap response in HTTP headers
   - Return pkt-line response body

2. **Push request** (POST /git-receive-pack)
   - Read request body (commands + packfile)
   - Call wire protocol push phase
   - Return pkt-line response (if client requested report-status)
   - Return empty response (if no report-status requested)

3. **Fetch request** (POST /git-upload-pack)
   - Read request body (wants/haves)
   - Call wire protocol fetch phase
   - Return pkt-line response (acks/naks + packfile)

The `WireProtocol` module is transport-agnostic—HTTP handler just provides the body bytes and collects the response bytes.

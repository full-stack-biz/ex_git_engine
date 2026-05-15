# Git Wire Protocol Version 2

Official spec: https://git-scm.com/docs/gitprotocol-v2

## Table of Contents

- [Overview](#overview)
- [Packet-Line Framing](#packet-line-framing)
- [Initial Client Request](#initial-client-request)
- [Capability Advertisement](#capability-advertisement)
- [Command Request](#command-request)
- [Statelessness Requirement](#statelessness-requirement)
- [Key Differences from v1](#key-differences-from-v1)
- [Commands in v2](#commands-in-v2)
  - [ls-refs](#ls-refs)
  - [fetch](#fetch)
  - [push](#push)
  - [object-info](#object-info)
- [Capability Classes in v2](#capability-classes-in-v2)
  - [agent](#agent)
  - [object-format](#object-formatx)
  - [session-id](#session-idsession-id)
  - [server-option](#server-option)
  - [side-band-64k](#side-band-64k)
- [Validation Summary (v2)](#validation-summary-v2)
- [HTTP Transport in v2](#http-transport-in-v2)
- [SSH Transport in v2](#ssh-transport-in-v2)
- [bundle-uri Command](#bundle-uri-command)
- [promisor-remote Capability](#promisor-remotepr-info)
- [Key Implementation Rules for gitrekt](#key-implementation-rules-for-gitrekt)

---

## Overview

Protocol v2 improvements over v1:
- Single service with multiple commands (instead of multiple service names)
- Capabilities in separate section (not hidden behind NUL bytes)
- Stateless by default (enable load-balancing)
- Reference advertisement omitted unless explicitly requested
- Better HTTP and stateless-rpc support

---

## Packet-Line Framing

All communication uses pkt-line framing (same as v1).

Special packets in v2:
- `0000` = Flush Packet (flush-pkt) - indicates end of message
- `0001` = Delimiter Packet (delim-pkt) - separates sections of a message
- `0002` = Response End Packet (response-end-pkt) - indicates end of response for stateless connections

---

## Initial Client Request

Client requests v2 by sending `version=2` through transport side-channel, which sets `GIT_PROTOCOL` environment variable.

### Git Transport
```
003egit-upload-pack /project.git\0host=myserver.com\0\0version=2\0
```

### SSH and File Transport
Set `GIT_PROTOCOL` environment variable explicitly to include "version=2".
Server must be configured to allow this env var to pass.

### HTTP Transport
Client sends:
```
GET $GIT_URL/info/refs?service=git-upload-pack HTTP/1.0
Git-Protocol: version=2
```

Server responds:
```
200 OK
<headers>

000eversion 2\n
<capability-advertisement>
```

Subsequent requests go to: `$GIT_URL/git-upload-pack` (or `git-receive-pack` for push).

Server uses `--http-backend-info-refs` option with git-upload-pack.
May need configured to pass `GIT_PROTOCOL` header via git-http-backend.

---

## Capability Advertisement

Server sends initial response with:
```
protocol-version = PKT-LINE("version 2" LF)
capability-list = *capability
capability = PKT-LINE(key[=value] LF)
```

Format:
```
key = 1*(ALPHA | DIGIT | "-_")
value = 1*(ALPHA | DIGIT | " -_.,?\/{}[]()<>!@#$%^&*+=:;")
```

**Critical: Capabilities are separate pkt-lines, not NUL-separated like v1.**

---

## Command Request

After receiving capability advertisement, client can issue a request to select a command with specific capabilities or arguments. Only a single command can be requested at a time.

**Structure**:
```
request = empty-request | command-request

empty-request = flush-pkt

command-request = command
    capability-list
    delim-pkt
    command-args
    flush-pkt

command = PKT-LINE("command=" key LF)
command-args = *command-specific-arg
```

**Details**:
- `command`: Named command to execute (e.g., "ls-refs", "fetch", "push")
- `capability-list`: Capabilities client wants to use (each as separate pkt-line)
- `delim-pkt`: Separator between capabilities and command-specific arguments
- `command-args`: Command-specific arguments (format defined per command)
- `flush-pkt`: Marks end of request

**Empty Request**: Client can send just `flush-pkt` to indicate no more requests and terminate connection.

**Server Processing**:
1. Wait until entire client request received before responding
2. Validate command is recognized
3. Validate all client capabilities were advertised
4. If valid: execute command
5. Return response (format determined by command)
6. End response with flush-pkt

**Client Continuation**: After receiving complete response, client can:
- Request another command (send new command-request)
- Send empty request to terminate (send just flush-pkt)
- Terminate without notice

**Capability Validation (MUST follow)**:

> "The server will then check to ensure that the client's request is comprised of a valid command as well as valid capabilities which were advertised."

This means:
1. Client can ONLY request capabilities the server advertised
2. Server MUST validate client capabilities against advertised set
3. Server MUST abort if client requests unknown capabilities

**Key distinction**:
- `advertised` = capabilities the SERVER sent in initial response
- `requested` = capabilities the CLIENT sends in command request
- Validation: `unknown = requested - advertised`
- Action: If unknown != empty, server MUST abort

---

## Statelessness Requirement

> "Protocol version 2 is stateless by default. This means that all commands must only last a single round and be stateless from the perspective of the server side, unless the client has requested a capability indicating that state should be maintained by the server."

Implication: Each command is independent. Capabilities do NOT carry over between commands unless explicitly negotiated per-command.

---

## Key Differences from v1

### Reference Advertisement
- v1: Server advertises all refs automatically
- v2: Client MUST explicitly request refs via `ls-refs` command

### Capability Placement
- v1: Capabilities NUL-separated on first ref line
- v2: Capabilities as separate pkt-lines with keys and optional values

### Command vs Service
- v1: Different service names (git-upload-pack, git-receive-pack)
- v2: Single service with commands (fetch, push, ls-refs, etc.)

### Packet Delimiters
- v2 adds: `0001` (delim-pkt) to separate sections and `0002` (response-end-pkt) for stateless connections
- v1: Only `0000` (flush-pkt)

---

## Commands in v2

### ls-refs

**Command**: Request reference advertisement in v2

**Features**: Advertised as `ls-refs=<feature-1> <feature-2>` if additional features supported

**Arguments**:

- `symrefs`: Show symbolic ref targets
  - In addition to object pointed by ref, show underlying ref
  - For symbolic refs

- `peel`: Show peeled tags
  - Dereferenced tag values

- `ref-prefix <prefix>`: Filter refs by prefix  
  - Only references matching prefix displayed
  - Multiple instances allowed (OR logic)
  - Optional optimization: server MAY show non-matching refs, client should filter

- `unborn` (if advertised): Show unborn HEAD
  - Server sends info about HEAD even if symref to unborn branch
  - Format: `unborn HEAD symref-target:<target>`

**Output Format**:
```
output = *ref flush-pkt

obj-id-or-unborn = (obj-id | "unborn")
ref = PKT-LINE(obj-id-or-unborn SP refname *(SP ref-attribute) LF)
ref-attribute = (symref | peeled)
symref = "symref-target:" symref-target
peeled = "peeled:" obj-id
```

**Semantics**:
- Replaces implicit reference advertisement from v1
- Client explicitly requests refs using this command
- Allows filtering to optimize bandwidth

### fetch

**Purpose**: Command to fetch a packfile in v2. Modified version of v1 fetch where ref-advertisement is omitted (replaced by `ls-refs` command).

**Features**: Additional features advertised as space-separated list in capability advertisement: `fetch=<feature-1> <feature-2>`

**Core Arguments**:
- `want <oid>`: Object client wants to retrieve. Can be anything, not limited to advertised objects.
- `have <oid>`: Object client already has locally. Multiple lines allowed. Helps server minimize packfile size.
- `done`: Signal to server that negotiation is complete and packfile should be constructed.

**Optional Arguments (always supported)**:
- `thin-pack`: Request thin pack with deltas referencing bases not in pack (reduces network traffic, requires client to "thicken" pack).
- `no-progress`: Suppress progress information on sideband channel 2 (channel 3 still used for errors).
- `include-tag`: Send annotated tags if their objects are being sent.
- `ofs-delta`: Client understands PACKv2 with delta referring to base by position (OBJ_OFS_DELTA / type 6).

**Shallow-Related Arguments** (if *shallow* feature advertised):
- `shallow <oid>`: Client has only shallow copy of commit (lacks parents). Server uses to understand client limitations.
- `deepen <depth>`: Make fetch/clone shallow to specified depth relative to remote.
- `deepen-relative`: Make depth relative to client's current shallow boundary instead of remote.
- `deepen-since <timestamp>`: Cut shallow fetch at specific time instead of depth (equivalent to `git rev-list --max-age=<timestamp>`). Cannot be used with `deepen`.
- `deepen-not <rev>`: Cut at specific revision instead of depth (equivalent to `git rev-list --not <rev>`). Can be used with `deepen-since` but not `deepen`.

**Filter-Related Arguments** (if *filter* feature advertised):
- `filter <filter-spec>`: Omit various objects using filtering technique (for partial clone/fetch). See `git rev-list` for filter specs.
  - When communicating: SHOULD translate scaled integers (e.g., "1k") to expanded form (e.g., "1024")
  - Receivers SHOULD accept suffixes: 'k' (1024), 'm' (1048576), 'g' (1073741824)

**Ref-in-Want Arguments** (if *ref-in-want* feature advertised):
- `want-ref <ref>`: Request specific ref by full name. Protocol error to send same ref more than once.

**Sideband Arguments** (if *sideband-all* feature advertised):
- `sideband-all`: Server sends whole response multiplexed (not just packfile). All non-flush/non-delim PKT-LINEs start with sideband byte (1, 2, or 3). Server may send "0005\2" (sideband 2 with no payload) as keepalive.

**PackFile-URIs Arguments** (if *packfile-uris* feature advertised):
- `packfile-uris <comma-separated-list-of-protocols>`: Client willing to receive URIs of given protocols instead of objects in packfile. Before connectivity check, client downloads from all URIs. Currently supports "http" and "https". At most one line allowed.

**Wait-for-Done Arguments** (if *wait-for-done* feature advertised):
- `wait-for-done`: Server never sends "ready", waits for client to say "done" before sending packfile.

**Response Structure** (delimited by delim-pkt/flush-pkt):
```
output = acknowledgements flush-pkt |
  [acknowledgements delim-pkt] [shallow-info delim-pkt]
  [wanted-refs delim-pkt] [packfile-uris delim-pkt]
  packfile flush-pkt
```

**Acknowledgements Section**:
- Always begins with section header "acknowledgements"
- Contains NAK if no common objects, or ACK lines for each common have object
- Cannot have both ACK and NAK lines
- May include "ready" line indicating server found acceptable base and is ready to send packfile
- Omitted entirely if client sent "done" line (server skips negotiation)
- Server may omit ACK lines as optimization if "ready" already sent

**Shallow-Info Section** (if shallow fetch/clone requested):
- Included if client requested shallow or server is shallow and needs to inform client
- Always begins with "shallow-info"
- Server sends "shallow obj-id" for each commit whose parents won't be sent
- Server sends "unshallow obj-id" for commits no longer shallow after fetch
- Server MUST NOT send "unshallow" for commits not indicated as shallow by client

**Wanted-Refs Section** (if client requested ref via want-ref AND packfile included):
- Always begins with "wanted-refs"
- Server sends "<oid> <refname>" for each requested ref
- Server MUST NOT send unrequested refs

**PackFile-URIs Section** (if client sent packfile-uris AND server has URIs):
- Always begins with "packfile-uris"
- For each URI: sends hash of pack contents (40 hex chars, as from `git index-pack`) followed by URI

**PackFile Section** (if client sent want lines AND sent done OR server found cut point):
- Always begins with "packfile"
- Transmission begins immediately after header
- **CRITICAL: The data transfer of the packfile is ALWAYS multiplexed using side-band-64k semantics from protocol v1. This is NOT optional or negotiated.**
  - Each packet: 4-byte pkt-line length + 1-byte stream code + data (up to 65519 bytes)
  - This is true regardless of whether client sent `sideband-all` or not
  - `sideband-all` multiplexes OTHER response sections too; packfile is ALWAYS multiplexed
- Stream codes:
  - 1 = pack data
  - 2 = progress messages
  - 3 = fatal error (aborts stream)

### push
Not explicitly detailed in v2 spec (still uses v1 wire protocol for push messages).

### object-info

**Purpose**: Retrieve information about one or more objects without having to fully fetch them.

**Use Case**: Allow client to make decisions based on object metadata (e.g., size) without fetching object contents.

**Arguments** (in request):
- `size`: Request size information to be returned for each listed object ID
- `oid <oid>`: Object ID to obtain information for (can be multiple)

**Response Format**:
```
output = info flush-pkt

info = PKT-LINE(attrs) LF)
       *PKT-LINE(obj-info LF)

attrs = attr | attrs SP attrs
attr = "size"

obj-info = obj-id SP obj-size
```

**Response Details**:
- First line: space-separated attribute names (e.g., "size")
- Following lines: one per requested object, containing object ID and corresponding size
- Each line is PKT-LINE encoded
- Response ends with flush-pkt

**Current Support**: Only `size` attribute is currently supported by Git protocol

---

## Capability Classes in v2

### agent

Server advertises: `agent=X` where X is server version
Client may respond: `agent=Y` (ONLY if server advertised `agent`)

**Format**: `agent=package/version-os`
- Examples: `agent=git/1.8.3.1-Linux`, `agent=gitrekt/0.3.9-Darwin`
- Characters: any printable ASCII except space (byte range 33-126)
- OS retrieved from `uname(2)` sysname field

**Configuration**:
- Can be set via `GIT_USER_AGENT` environment variable (takes priority)
- OS determined via system calls

**Purpose**: Purely informational for statistics and debugging
- MUST NOT be used to programmatically assume features
- MUST NOT drive protocol decisions

### object-format=X

**Purpose**: Negotiate hash algorithm between client and server.

**Server Behavior**: Server advertises `object-format=X` where X is a hash algorithm identifier (e.g., `sha1`, `sha256`).
- If NOT advertised: Server is assumed to only handle SHA-1
- Server only handles the specific algorithm advertised

**Client Behavior**: If client wants to use a hash algorithm other than SHA-1, it MUST specify its desired object-format string in the capability list.
- Format: `object-format=X` where X matches algorithm name
- Client MUST only request algorithms it actually supports
- If client requests algorithm, server MUST verify it matches advertised support

### session-id=<session-id>

**Purpose**: Identify a process across multiple requests for tracing and debugging.

**Server Behavior**: Server MAY advertise `session-id=<session-id>` in capability advertisement.

**Client Behavior**: Client MAY advertise its own session ID back to the server (`session-id=<session-id>`).

**Constraints**:
- Session IDs must be unique to a given process
- MUST fit within a single packet-line (4-byte length prefix + data)
- MUST NOT contain non-printable or whitespace characters
- Current implementation uses trace2 session IDs (see git api-trace2 documentation)
- Users of session ID MUST NOT rely on specific trace2 format (may change)

### server-option

**Purpose**: Allows server to advertise support for server-specific options that clients can include in requests.

**Capability**: If advertised, indicates that any number of server-specific options can be included in a request.

**Usage**: Client sends each option as `server-option=<option>` capability line in the capability-list section of a request.

**Constraints**:
- Option values must NOT contain NUL (`\0`) or LF (`\n`) characters
- Follows standard capability format with key-value pairs
- Multiple server-option capabilities can be sent per request

### side-band-64k

**Purpose**: Server can send, and client can understand, multiplexed progress reports and error info interleaved with packfile data.

**Relationship**: Mutually exclusive with `side-band` (older variant). Modern clients always favor `side-band-64k`.

**Packet Structure**: Packfile data streamed in packets up to 65520 bytes.
- Each packet: 4-byte pkt-line length + 1-byte stream code + up to 65519 bytes data
- Stream codes:
  - 1 = pack data
  - 2 = progress messages
  - 3 = fatal error (aborts stream)

**Client Usage**: Client MUST send only one of `side-band` or `side-band-64k`, NEVER both.

**Server Validation**: Server MUST diagnose as error if client requests both `side-band` and `side-band-64k`.

**History**: Allows newer clients handling large packets to request nearly-full 65520-byte packets while maintaining backward compatibility with older clients that use `side-band` (up to 1000 bytes).

### Features (with modifiers)
Some commands advertise features as: `<command>=<feature-1> <feature-2>`

Example: `fetch=shallow ofs-delta include-tag`

---

## Validation Summary (v2)

When processing command request:

```
advertised_capabilities = capabilities sent in initial response
client_requested_capabilities = capabilities in command request

# MUST validate
unknown = client_requested - advertised
if unknown.length > 0:
  server MUST abort with error
  
# MUST process advertised capabilities
for each cap in client_requested:
  if cap is_supported:
    enable feature
  else:
    ERROR (should have been caught above)
```

**Note:** In v2, unlike v1, there's a clear separation between what's advertised (server side) and what's requested (client side). The server does NOT send back advertised capabilities; it only advertises once. Client sends which subset it wants.

---

## HTTP Transport in v2

Request:
```
C: GET $GIT_URL/info/refs?service=git-upload-pack HTTP/1.0
C: Git-Protocol: version=2
```

Response:
```
S: 200 OK
S: <headers>
S:
S: 000eversion 2\n
S: <capability-advertisement>
```

Subsequent requests to: `$GIT_URL/git-upload-pack`

---

## SSH Transport in v2

Client sets `GIT_PROTOCOL=version=2` environment variable when calling:
- `git-upload-pack /path`
- `git-receive-pack /path`

Server responds with capability advertisement if v2 is requested.

---

## bundle-uri Command

**Capability**: `bundle-uri` (currently advertised with no value)

**Purpose**: Optimize clones/fetches by providing pre-computed bundle files to seed the fetch.

**When to Use**: Issued before `fetch` to get URIs to bundle files. Can be issued after `ls-refs` and before `fetch`, or at any time.

**Request**: Takes no arguments. Client sends `command=bundle-uri`.

**Response**: List of key-value pairs (PKT-LINE format) in `bundle.*` namespace.
- Keys grouped by `bundle.<id>.` subsection
- Each `<id>` defines one bundle with attributes
- Format: `<key>=<value>` per git-config specification
- Clients MUST ignore unknown keys/values
- Malformed lines SHOULD be discarded

**URI Contents** (two types):
1. Bundle file (verifiable with `git bundle verify`):
   - MUST contain one or more reference tips
   - MUST indicate prerequisites with "-" prefix
   - MUST indicate object-format if applicable

2. Plaintext config file (parseable with `git config --file`):
   - Key-value pairs in `bundle.*` namespace

**Client Error Recovery**:
- MUST gracefully degrade on errors
- Must work even if CDN fails, bundles incomplete, or prerequisites missing
- Should fall back to normal `fetch` if bundles unavailable
- Can perform early disconnect while downloading bundles

**Server to Client Semantics**:
- Bundle URIs order is not significant
- Client MUST inspect bundle headers to discover OIDs and prerequisites
- Bundle headers are source of truth
- Server MAY return bundles unrelated to repository (client filters)

**Client to Server Semantics**:
- Client SHOULD provide bundle ref tips as `have` lines in subsequent `fetch`
- Client MAY ignore bundles entirely if disadvantageous

**Negotiation Scenarios**:

1. **Bundles satisfy all wants**: 
   - Client MAY disconnect after getting bundle headers
   - Clone/fetch result identical to not using bundle-uri

2. **Bundles need further negotiation**:
   - Client can start PACK negotiation via `fetch` using bundle tips as `have` lines
   - Server computes incremental PACK for difference
   - Client downloads bundles concurrently, inflates/validates when ready
   - Early disconnect allowed during bundle download; falls back to full fetch if needed

**Protocol Features**:

Key `bundle.version`: Integer value. Currently only `1` accepted.
- If client sees unexpected version, MUST ignore entire bundle list
- All other unknown keys MAY be ignored

Backwards-compatible: New features guarded by `bundle.version` changes or new `bundle-uri` capability values/arguments.

**Future Extensions** (examples, not implemented yet):
- `hash=<val>` or `size=<bytes>`: Expected hash/size of bundle file
- `oid=<OID>`: Shortcut for single-tip bundles (avoids header inspection)
- `prerequisite=<OID>`: Shortcut for prerequisites
- Bundle aliasing: Indicate multiple files with same content (for round-robin)

---

## promisor-remote=<pr-info>

**Purpose**: Server advertises promisor remotes that client can use instead of this repository.

**Format**:
```
pr-info = pr-fields | pr-info ";" pr-fields
pr-fields = pr-field | pr-fields "," pr-field
pr-field = field-name "=" field-value
```

Multiple promisor remotes separated by `;`
Multiple fields within a remote separated by `,`

**Mandatory Fields** (must appear first in each pr-fields, in this order):
1. `name` = valid remote name
2. `url` = remote URL

**Optional Fields** (any order after mandatory fields):

`partialCloneFilter`
- Filter specification for the remote
- Corresponds to `remote.<name>.partialCloneFilter` config
- Client can determine if filtering strategy compatible
- Can use via `--filter=auto` in git-clone
- Allows automatic filter combination across promisor remotes

`token`
- Authentication token for connecting to remote
- Corresponds to `remote.<name>.token` config

**Field Value Rules**:
- MUST be urlencoded (`;` and `,` must be encoded if they appear)
- Field names are case-sensitive, transmitted exactly as specified
- Clients MUST ignore unrecognized fields (future extensibility)
- Field names MUST NOT appear more than once in a given pr-fields

**Client Response**:
If client accepts advertised promisor remotes:
```
promisor-remote=<pr-names>

pr-names = pr-name | pr-names ";" pr-name
```

Where `pr-name` is urlencoded name of accepted promisor remote.

**When NOT to Advertise**:
- Server doesn't know suitable promisor remotes
- Server prefers client not use promisor remotes

**When Client Doesn't Respond**:
- Client doesn't want to use advertised promisor remotes
- Client doesn't accept any of the advertised remotes

**Configuration**:
- Server-side: `promisor.advertise`, `promisor.sendFields`
- Client-side: `promisor.acceptFromServer`, `promisor.storeFields`

**Future Direction**:
Eventually, server could advertise better-connected remotes during `fetch`/`clone` for lazy object fetching, omitting objects available on those remotes from its response. Not yet implemented.

**Current Use Case**:
Server advertises promisor remotes it already uses to borrow objects from.

---

## Key Implementation Rules for gitrekt

1. **Statelessness**: Each command is independent. Don't carry state between commands.
2. **Capability Validation**: Client capabilities MUST be subset of advertised.
   - Variable naming: `advertised_caps` = server capabilities (from initial advertisement)
   - Variable naming: `requested_caps` or `caps` = client capabilities (from request)
   - Validation: `reject_if(requested_caps - advertised_caps != empty)`
3. **Clear Separation**: Never concatenate advertised + requested. They are distinct sets.
4. **Sideband in fetch**: Packfile data is always multiplexed with sideband (1/2/3).
5. **Reference Discovery**: Clients must use `ls-refs` command, not implicit ref advertisement.

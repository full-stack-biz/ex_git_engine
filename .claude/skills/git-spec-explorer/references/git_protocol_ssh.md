# Git SSH Protocol

SSH-specific transport layer for Git's wire protocol.

Sources:
- https://git-scm.com/book/en/v2/Git-Internals-Transfer-Protocols
- https://git-scm.com/docs/gitprotocol-pack
- RFC 4254 (SSH Connection Protocol)

**Core wire protocol:** See `git_protocol_wire.md` for pkt-line format, capability negotiation, push/fetch flows.

## Table of Contents

- [SSH Transport Overview](#ssh-transport-overview)
- [SSH Connection Phases](#ssh-connection-phases)
- [SSH Command Execution Details](#ssh-command-execution-details)
- [SSH Environment Variables](#ssh-environment-variables)
- [SSH Authentication Authorization](#ssh-authentication-authorization)
- [SSH Wire Protocol (Identical with HTTP)](#ssh-wire-protocol-identical-with-http)
- [SSH Error Handling](#ssh-error-handling)
- [SSH Debugging](#ssh-debugging)
- [Common SSH Issues](#common-ssh-issues)
- [Pack Fragmentation Over SSH](#pack-fragmentation-over-ssh)
- [ExGitEngine SSH Implementation](#ex_git_engine-ssh-implementation)

---

## SSH Transport Overview

Git over SSH uses the SSH protocol to establish a secure channel and execute git services (git-receive-pack, git-upload-pack) on the remote server. The wire protocol (pkt-line format, capabilities, commands, packfile) is identical to HTTP smart protocol; SSH provides the transport wrapper.

### URL Format
```
ssh://git@github.com/user/repo.git
git@github.com:user/repo.git  (shorthand, equivalent to ssh://)
ssh://[user@]hostname[:port]/path/to/repo.git
```

### SSH vs HTTP Comparison

| Aspect | SSH | HTTP |
|--------|-----|------|
| Connection | SSH socket (port 22) | HTTP/HTTPS socket (port 80/443) |
| Command Execution | `git-receive-pack /repo` | GET /info/refs + POST /git-receive-pack |
| Content-Type headers | Not used (raw pkt-line) | Required (application/x-git-*) |
| Capability Advertisement | Implicit on service start | GET /info/refs response |
| Wire Protocol Delivery | SSH channel stdin/stdout | HTTP request/response body |
| Authentication | SSH keys/password | HTTP auth (basic, token, certs) |
| Disconnect Signal | SSH channel close/EOF | HTTP response end |
| Pipelining | Single SSH channel | Multiple HTTP requests |
| Bidirectional | Yes, simultaneously | Yes, but sequential (request→response) |

---

## SSH Connection Phases

### 1. SSH Handshake

Client connects via SSH to remote host (typically port 22):

```
ssh -i ~/.ssh/id_rsa git@github.com
```

SSH handshake includes:
- Protocol version negotiation
- Key exchange
- Host key verification
- Authentication method selection

### 2. Authentication

Client authenticates to SSH server:

**SSH Key Authentication** (most common for git):
```bash
git@hostname's password: [SSH server uses public key]
```

**Password Authentication**:
```bash
git@hostname's password: [user enters password]
```

**Agent Forwarding**:
```bash
ssh -A git@hostname  # Forward SSH agent to remote
```

### 3. Channel Request

After authentication, client requests a session channel and executes the git service command:

```
ssh git@hostname "git-receive-pack /path/to/repo.git"
```

Or implicitly (when using git clone, push, etc.):
```
ssh git@hostname "git-upload-pack /user/repo.git"
```

### 4. Git Protocol Exchange

Git service (git-receive-pack, git-upload-pack) executes on remote and communicates via SSH channel stdin/stdout. Wire protocol flows (pkt-line framing, capabilities, commands) are identical to HTTP smart protocol.

### 5. Channel Close

When git service completes, SSH channel closes. Exit status indicates success/failure.

---

## SSH Command Execution Details

**CRITICAL: Repository path quoting** — Git always quotes repository path with **single quotes**:
```bash
ssh git@host 'git-receive-pack /path/to/repo.git'  # Correct
ssh git@host "git-receive-pack /path/to/repo.git"  # Wrong (allows shell expansion)
```

The command name `git-receive-pack` is spelled with dashes (not underscores). Can be overridden by client configuration.

### Push (git-receive-pack)

Client requests execution:
```bash
ssh git@host "git-receive-pack '/path/to/repo.git'"
```

For `ssh://user@host/path/to/repo.git` URLs: path is absolute (leading `/`)
```bash
ssh user@host "git-receive-pack '/path/to/repo.git'"
```

For `user@host:path/to/repo.git` URLs: path is relative to home directory (no `/`)
```bash
ssh user@host "git-receive-pack 'path/to/repo.git'"
```

For `~alice/project.git` URLs: home directory reference
```bash
ssh user@host "git-receive-pack '~alice/project.git'"
```

Server executes `git-receive-pack` with the repository path. Process runs as the authenticated SSH user.

**Service starts and immediately sends**:
```
S: PKT-LINE(obj-id SP refname NUL capability-list)
...
S: flush-pkt
```

**Client sends**:
```
C: PKT-LINE(command NUL capability-list)
C: flush-pkt
C: [PACKDATA]
```

**Server responds** (if client requested report-status):
```
S: PKT-LINE("unpack" SP result)
S: PKT-LINE(command-status)
...
S: flush-pkt
```

### Fetch/Pull (git-upload-pack)

Client requests execution:
```bash
ssh git@host "git-upload-pack /path/to/repo.git"
```

Server executes `git-upload-pack` with the repository path.

**Service starts and immediately sends**:
```
S: PKT-LINE(obj-id SP refname NUL capability-list)
...
S: flush-pkt
```

**Client sends negotiation**:
```
C: PKT-LINE("want" SP obj-id)
...
C: PKT-LINE("have" SP obj-id)
...
C: flush-pkt
```

**Server responds**:
```
S: PKT-LINE("ACK" / "NAK" ...)
S: [PACKDATA]
```

### Archive (git-upload-archive)

Client requests execution:
```bash
ssh git@host "git-upload-archive /path/to/repo.git"
```

Server sends tar/zip archive data (different protocol from push/fetch).

---

## SSH Environment Variables

Git passes Extra Parameters via the `GIT_PROTOCOL` environment variable. This requires SSH variant support:

**Protocol Version 2 (GIT_PROTOCOL header)**:
```bash
GIT_PROTOCOL=version=2 ssh git@host "git-receive-pack '/repo.git'"
```

The `ssh.variant` configuration variable must indicate SSH supports passing environment variables. Standard OpenSSH supports this.

**Standard Environment Variables**:
- `GIT_PROTOCOL` — Extra Parameters (e.g., "version=2") as colon-separated string
- `GIT_USER_AGENT` — client version string
- `SSH_CLIENT` — connection info from SSH server (if set by SSH server)
- `USER` — authenticated username
- `HOME` — home directory of authenticated user

Git service reads these to customize behavior (e.g., protocol version support, user identification).

**Important**: If SSH variant doesn't support environment variables (e.g., restricted shells), GIT_PROTOCOL is not passed, and protocol falls back to version 0/1.

---

## SSH Authentication Authorization

SSH authentication happens at the SSH layer. Once authenticated, the git service runs with the authenticated user's privileges.

### Common SSH Setup

**Shared git user** (typical for bare repositories):
```bash
/etc/passwd: git:x:74:74:Git Repository User:/opt/git/repositories:/usr/bin/git-shell
```

Clients authenticate as `git` user, but individual SSH keys in `~git/.ssh/authorized_keys` identify actual users.

**Individual system users**:
```bash
/etc/passwd: alice:x:1001:1001:Alice:/home/alice:/bin/bash
/etc/passwd: bob:x:1002:1002:Bob:/home/bob:/bin/bash
```

Clients authenticate as their own system users.

### Authorization Logic

The git service doesn't validate SSH credentials. Authorization is handled by:
1. **SSH key validation** — SSH server checks authorized_keys
2. **File permissions** — Repository ownership/permissions
3. **Repository server logic** — Custom hooks, permissions in gitRekt

Example: gitRekt can check authenticated user (from environment) and call `pre_push` hook with user context.

---

## SSH Wire Protocol (Identity with HTTP)

The pkt-line protocol flowing over SSH is **identical** to HTTP smart protocol:

### Same Elements

- Pkt-line framing (4-byte ASCII hex size + payload)
- Capability negotiation (advertised on first ref, requested on first command)
- Command format (create/delete/update with NUL-separated capabilities)
- Report-status rules (sent only if client requested)
- Packfile format (binary Git packfile)
- Error handling (ERR pkt-line terminates session)

### Same Rules

- Server advertises capabilities in reference discovery
- Client selects from advertised, sends in first command line
- Server MUST NOT send report-status unless client requested
- Client MUST NOT request capabilities server didn't advertise
- Server MUST validate unknown capabilities and abort

### No Wrapper

Unlike HTTP (which wraps pkt-lines in HTTP headers), SSH sends **raw pkt-line protocol** over the channel:

```
SSH Channel:
[pkt-line bytes]
[pkt-line bytes]
...
[channel closes]
```

Not:
```
HTTP Response:
Content-Type: application/x-git-receive-pack-result
Content-Length: 123

[pkt-line bytes]
```

---

## SSH Error Handling

### Protocol-Level Errors

Handled via pkt-line ERR packet (same as HTTP):
```
S: PKT-LINE("ERR" SP error-explanation)
```

Terminates session immediately.

Example:
```
S: 0033ERR unknown capability: no-such-cap\n
```

Channel closes after error.

### SSH-Level Errors

If the git service command itself fails:

**Command not found**:
```bash
$ ssh git@host git-receive-pack /repo.git
bash: git-receive-pack: command not found
```

SSH returns non-zero exit code, channel closes.

**Repository not accessible**:
```bash
git-receive-pack: fatal: /path/to/repo.git not found
```

Service returns error via pkt-line ERR before terminating, or exits with error code.

**SSH disconnection**:
```bash
Connection reset by peer
```

Service stdin hits EOF, process terminates.

### Client Detection

Client detects SSH-level failures by:
1. **SSH exit code** — Non-zero indicates failure
2. **Channel closure** — Unexpected close means error
3. **Pkt-line ERR** — Service sent error packet before closing

---

## SSH Debugging

### Verbose SSH Logging

```bash
ssh -v git@host git-receive-pack /repo.git
ssh -vv git@host git-receive-pack /repo.git    # More verbose
ssh -vvv git@host git-receive-pack /repo.git   # Very verbose
```

Shows SSH handshake, authentication, command execution, and channel events.

### Capture Raw Protocol

```bash
ssh git@host git-receive-pack /repo.git | xxd > protocol.bin
```

Inspect hex dump of pkt-line protocol flowing over SSH.

### SSH Debug Mode

```bash
GIT_SSH_COMMAND='ssh -vv' git push origin main
```

Git uses specified SSH command with verbose logging.

### Compare SSH with HTTP

If push works over HTTP but fails over SSH:

1. **Check command execution**: Can you manually run `git-receive-pack`?
   ```bash
   ssh git@host git-receive-pack /repo.git
   ```

2. **Check authentication**: Do SSH keys work?
   ```bash
   ssh -i ~/.ssh/id_rsa git@host echo OK
   ```

3. **Check repository path**: Is the path correct?
   ```bash
   ssh git@host ls -la /path/to/repo.git
   ```

4. **Check wire protocol**: Use xxd to compare HTTP vs SSH pkt-line bytes

5. **Check capabilities**: Do both transports advertise same capabilities?

---

## Common SSH Issues

| Symptom | Likely Cause | Check |
|---------|--------------|-------|
| "Permission denied (publickey)" | SSH key not authorized or wrong key | `~/.ssh/authorized_keys`, `ssh -v` |
| "ssh: command not found" | git-receive-pack not installed on remote | SSH to host, run `which git-receive-pack` |
| "fatal: repository not found" | Wrong repository path or no access | Path correct? Permissions on repo? |
| "fatal: protocol error" | Broken pkt-line format (same as HTTP) | Capture with xxd, compare to spec |
| "Connection closed by remote host" | Server crashed or hung | Check server logs, try again |
| "Timeout" | Network issue or service hung | Check connectivity, service logs |
| "unpack error" then refs appear | Report-status capability issue (same as HTTP) | Check if client requested it |

---

## Pack Fragmentation Over SSH

### The Problem

Git pack data may arrive in multiple SSH DATA messages. A single SSH DATA message contains a chunk of the packfile — not necessarily aligned to any pack boundary. In particular, the 20-byte SHA1 trailer at the end of a packfile may arrive in a separate SSH DATA message after the first message already made libgit2 report the pack as "complete" (`received_objects == total_objects`).

**Do not call `odb_writepack_commit` when `received_objects == total_objects` is first seen.** libgit2 may internally mark the pack as complete at that point, but the 20-byte trailing SHA1 checksum may not yet have been received over the wire. Committing early causes:
```
fatal: missing trailer at the end of the pack
```

### The Solution: Defer to EOF

After every `odb_writepack_append` call (regardless of whether it reports complete), transition to `:buffer` state and wait for EOF before calling `odb_writepack_commit`. The EOF signal arrives via the SSH EOF message, which triggers `WireProtocol.next(service, :discovery)`.

**SSHserver EOF handler** (in gitleaf):
```elixir
def handle_ssh_msg({:ssh_cm, conn, {:eof, chan}}, %__MODULE__{service: service} = state) do
  if service do
    {_new_service, output} = WireProtocol.next(service, :discovery)
    :ssh_connection.send(conn, chan, output)
  end
  :ssh_connection.exit_status(conn, chan, 0)
  :ssh_connection.close(conn, chan)
  {:ok, state}
end
```

The `:discovery` path calls `exec_next(service, [])`, which triggers `next(:buffer, [])` → `handle_push_cmds` → `odb_writepack_commit`.

### SSH DATA vs SSH EOF in the State Machine

```
SSH DATA #1  → WireProtocol.next(service, data1) → :pack → odb_writepack_append → :buffer → {:cont, ...}
SSH DATA #2  → WireProtocol.next(service, data2) → :buffer + binary → :pack → append → :buffer → {:cont, ...}
  (repeat for any additional fragments)
SSH EOF      → WireProtocol.next(service, :discovery) → :buffer + [] → handle_push_cmds → {:halt, output}
```

The output (report-status, sideband messages) from `handle_push_cmds` is sent to the SSH channel as a result of the EOF handler.

---

## ExGitEngine SSH Implementation

When gitRekt receives an SSH connection, the remote side executes:

```bash
git-receive-pack <repo-path>
```

gitRekt's role:

1. **Receive SSH connection** — Get stdin/stdout from SSH channel
2. **Call WireProtocol** — Feed SSH stdin to wire protocol, collect responses
3. **Send over SSH** — Write wire protocol responses to SSH stdout
4. **Detect close** — When client closes channel (EOF on stdin), finish up

The `WireProtocol` module is transport-agnostic. SSH handler just:
- Reads bytes from channel stdin
- Calls `WireProtocol.next/2` with incoming bytes
- Writes response bytes to channel stdout
- Detects EOF when client disconnects

Example flow:
```elixir
{:ok, wire_protocol} = WireProtocol.new(repo: repo, service: :receive_pack)
{:ok, response, new_proto} = WireProtocol.next(wire_protocol, incoming_bytes)
send_to_ssh_channel(response)
# Repeat until client sends final flush-pkt
```

# ExGitEngine Usage Rules

ExGitEngine wraps libgit2 through NIFs and adds a GenServer agent per repository and a
server side of Git's wire protocol (`git-upload-pack`, `git-receive-pack`). libgit2 must be
installed on the host (`libgit2-dev` on Debian/Ubuntu, `brew install libgit2` on macOS).

## Pick the layer

- `ExGitEngine.GitAgent` — use this. A GenServer per repository; serializes access, caches
  immutable objects, runs long jobs off the agent.
- `ExGitEngine.Git` — raw NIFs. A libgit2 handle is not safe to share between processes, and a
  crash in C takes down the VM. Use it only inside `GitAgent.transaction/4` or from a process
  that owns the handle alone.
- `ExGitEngine.GitRepo` — protocol your own repository struct implements to plug into the agent
  and the push hooks.
- `ExGitEngine.WireProtocol` — serve clones, fetches and pushes over SSH or Smart HTTP.

## GitAgent

```elixir
{:ok, agent} = ExGitEngine.GitAgent.start_link("/srv/repos/app.git")
{:ok, branch} = ExGitEngine.GitAgent.branch(agent, "main")
{:ok, commit} = ExGitEngine.GitAgent.peel(agent, branch)
{:ok, message} = ExGitEngine.GitAgent.commit_message(agent, commit)
```

- Every function takes the agent first and returns `{:ok, value}`, `:ok` or `{:error, reason}`.
  There are no bang variants; match with `with`.
- The first argument can be a pid, a raw `Git.repo()` handle, or any value implementing
  `ExGitEngine.GitRepo` (its `get_agent/1` is called).
- `start_link/2` options: `:timeout` (call timeout, default `5_000`), `:stream_chunk_size`
  (default `1_000`), `:idle_timeout` (default `:infinity`; the agent stops when idle that long),
  `:cache`, plus any `GenServer` option such as `:name`. Defaults can also be set with
  `config :ex_git_engine, ExGitEngine.GitAgent, %{...}` at compile time.
- Every call takes `timeout:` in its last keyword argument. Raise it for big repositories rather
  than wrapping calls in `Task`.
- Start one agent per repository and share it. Do not start an agent per request.

### Transactions

Batch several calls into one round trip; give the transaction a key to cache its result:

```elixir
GitAgent.transaction(agent, {:commit_info, commit.oid}, fn agent ->
  with {:ok, author} <- GitAgent.commit_author(agent, commit),
       {:ok, message} <- GitAgent.commit_message(agent, commit) do
    {:ok, %{author: author, message: message}}
  end
end)
```

- The callback must return `{:ok, term}` or `{:error, term}`.
- Only key a transaction by something immutable (an oid). A key built from a branch name caches
  a stale answer after the next push: the cache is never invalidated.

### Streams

`references/2`, `history/3`, `tree_entries/3`, `commit_parents/3`, `branches/2` and `tags/2`
return lazy streams computed on the agent. Each pull fetches `:stream_chunk_size` items.

- Pass a small `stream_chunk_size:` when you only `Enum.take/2` a few items.
- Enumerate the stream in the process that asked for it; the agent tracks resources per caller.

### Long operations

`pack_create`, `pack_file`, `pack_commits_file`, `blame`, `graph_ahead_behind` and
`odb_writepack_commit` run in `ExGitEngine.JobLimiter`, at most `max_jobs` at once.

- They can return `{:error, :busy}` when the queue is full or the wait passes `max_wait`.
  Handle it (retry later, show "busy"); do not treat it as a crash.
- Prefer `pack_file/4` / `pack_commits_file/4` over the in-memory variants for anything big.
- Run your own expensive NIF work through `ExGitEngine.JobLimiter.run(fn -> ... end)`.

### Diffs

Page through large diffs instead of formatting them whole:

```elixir
{:ok, diff} = GitAgent.diff(agent, base, head)
{:ok, %{total: total, files: files}} = GitAgent.diff_files(agent, diff, offset: 0, limit: 100)
{:ok, %{patch: patch, hunks: hunks}} = GitAgent.diff_patch(agent, diff, 42)
{:ok, text} = GitAgent.diff_patch_text(agent, patch, hunks: 0..9)
```

- `diff_files/3` `:limit` is at most 5000; a larger value raises `ArgumentError`.
- For one known path use `diff_file/5`.

## GitRepo protocol

```elixir
defimpl ExGitEngine.GitRepo, for: MyApp.Repo do
  def get_agent(repo), do: {:ok, repo.agent}

  # Before refs move. {:error, reason} rejects the whole push.
  def pre_push(_repo, cmds), do: :ok

  # After refs moved. Optional advisories are shown to the pushing client.
  def push(repo, _cmds), do: {:ok, repo, ["Thanks for pushing"]}
end
```

- Commands are `{:create, new_oid, ref}`, `{:update, old_oid, new_oid, ref}` and
  `{:delete, old_oid, ref}`.
- `pre_push/2` and `push/2` fall back to "allow" and "no-op" when not implemented.

## WireProtocol

```elixir
service = ExGitEngine.WireProtocol.new(agent, "git-receive-pack", repo: my_repo)
```

- Pass `repo:` for receive-pack, otherwise your `GitRepo` push hooks never run.
- `new/3` returns `{:error, :unknown_service}` for anything but `"git-upload-pack"` and
  `"git-receive-pack"`; check `valid_services/0` before calling it with client input.
- HTTP (whole body available): `WireProtocol.run(service, body)` returns `{service, iodata}`.
- SSH (data arrives in chunks): call `WireProtocol.next(service)` for the ref advertisement, then
  `WireProtocol.next(service, data)` per message, which returns `{:cont | :halt, service, iodata}`.
  On EOF call `WireProtocol.next(service, "")` so a buffered push is committed.
- Send the returned iodata as is. It is already PKT-LINE encoded; do not encode it again.

## Configuration

```elixir
config :ex_git_engine,
  max_object_size: 100 * 1024 * 1024,     # largest object accepted in a push
  max_pack_size: 1024 * 1024 * 1024,      # largest pack accepted in a push
  max_jobs: 3,                            # JobLimiter slots (default: dirty CPU schedulers - 1)
  max_wait: 60_000,                       # ms a job may queue before {:error, :busy}
  high_water: 150,                        # queued jobs before {:error, :busy} at once
  pack_window_memory: 64 * 1024 * 1024,   # libgit2 pack.windowMemory
  pack_delta_cache_size: 64 * 1024 * 1024,
  cache_max_size: 64 * 1024 * 1024,       # libgit2 object cache
  mapped_limit: 128 * 1024 * 1024,        # libgit2 mapped pack data
  mapped_window_size: 16 * 1024 * 1024,
  pack_tmp_dir: "/var/tmp"                # pack temp files (default System.tmp_dir!/0)
```

`max_object_size` and `max_pack_size` are read on each push. The rest are read when the
application or `JobLimiter` starts; restart after changing them.

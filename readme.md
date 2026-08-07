## ExGitEngine

Elixir libgit2 wrapper with GenServer-based concurrent access and Git wire protocol (push/fetch).

Originally created by [Mario Flach (@redrabbit)](https://github.com/redrabbit) as part of [git.limo](https://github.com/redrabbit/git.limo). Extracted and updated by [@jtippett](https://github.com/jtippett). Extended with Git wire protocol support and maintained by [Sergey Moiseev](https://github.com/full-stack-biz).

## Requirements

libgit2 must be installed on your system:

```bash
brew install libgit2              # macOS
sudo apt-get install libgit2-dev  # Ubuntu/Linux
```

## Installation

```elixir
{:ex_git_engine, "~> 0.9"}
```

## Architecture

Three abstraction layers:

- **`ExGitEngine.Git`** — direct Erlang NIF bindings to libgit2
- **`ExGitEngine.GitAgent`** — GenServer API with caching and safe concurrent access
- **`ExGitEngine.GitRepo`** — protocol for extensible repository implementations with push/fetch hooks

Wire protocol:

- **`ExGitEngine.WireProtocol`** — Git transport protocol (push/fetch)
- **`ExGitEngine.WireProtocol.ReceivePack`** — handles `git push`
- **`ExGitEngine.WireProtocol.UploadPack`** — handles `git fetch`/`git pull`

## Usage

```elixir
{:ok, agent} = ExGitEngine.GitAgent.start_link("/path/to/repo")
{:ok, ref} = ExGitEngine.GitAgent.reference_lookup(agent, "refs/heads/main")
{:ok, commit} = ExGitEngine.GitAgent.peel(agent, ref)
{:ok, message} = ExGitEngine.GitAgent.commit_message(agent, commit)
```

Implement `ExGitEngine.GitRepo` to add custom push validation or post-push hooks:

```elixir
defimpl ExGitEngine.GitRepo, for: MyRepo do
  def get_agent(repo), do: {:ok, repo.agent_pid}
  def pre_push(repo, cmds), do: :ok
  def push(repo, cmds), do: {:ok, repo}
end
```

## License

MIT

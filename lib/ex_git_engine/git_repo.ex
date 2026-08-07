defprotocol ExGitEngine.GitRepo do
  @moduledoc """
  Protocol for implementing access to Git repositories.
  """

  alias ExGitEngine.GitAgent
  alias ExGitEngine.WireProtocol.ReceivePack

  @type t :: term

  @doc """
  Returns the agent for the given `repo`.
  """
  @fallback_to_any true
  @spec get_agent(t) :: {:ok, GitAgent.agent()} | {:error, term}
  def get_agent(repo)

  @doc """
  Validates ref updates before they are applied (pre-push hook).
  Called before push_cmds to allow custom validation logic.
  Return :ok to allow, {:error, reason} to reject the push.
  Optional callback - defaults to always allowing.
  """
  @fallback_to_any true
  @spec pre_push(t, [ReceivePack.cmd()]) :: :ok | {:error, binary}
  def pre_push(repo, cmds)

  @doc """
  Executes after refs have been updated (post-push hook).
  Can optionally return advisory messages to send to the client.
  Returns {:ok, repo} or {:ok, repo, advisories :: [binary]} or {:error, term}
  """
  @fallback_to_any true
  @spec push(t, [ReceivePack.cmd()]) :: {:ok, t} | {:ok, t, [binary]} | {:error, term}
  def push(repo, cmds)
end

defimpl ExGitEngine.GitRepo, for: Any do
  def get_agent(repo),
    do: {:error, "Protocol ExGitEngine.GitRepo not implemented for #{inspect(repo)}"}

  def pre_push(_repo, _cmds), do: :ok
  def push(repo, _cmds), do: {:ok, repo}
end

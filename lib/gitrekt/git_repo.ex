defprotocol GitRekt.GitRepo do
  @moduledoc """
  Protocol for implementing access to Git repositories.
  """

  alias GitRekt.GitAgent
  alias GitRekt.WireProtocol.ReceivePack

  @type t :: term

  @doc """
  Returns the agent for the given `repo`.
  """
  @spec get_agent(t) :: {:ok, GitAgent.agent} | {:error, term}
  def get_agent(repo)

  @doc """
  Validates ref updates before they are applied (pre-push hook).
  Called before push_cmds to allow custom validation logic.
  Return :ok to allow, {:error, reason} to reject the push.
  Optional callback - defaults to always allowing.
  """
  @fallback_to_any true
  @spec pre_push(t, [ReceivePack.cmd]) :: :ok | {:error, binary}
  def pre_push(repo, cmds)

  @doc """
  Executes after refs have been updated (post-push hook).
  """
  @fallback_to_any true
  @spec push(t, [ReceivePack.cmd]) :: {:ok, t} | {:error, term}
  def push(repo, cmds)
end

defimpl GitRekt.GitRepo, for: Any do
  def get_agent(repo), do: {:error, "Protocol GitRekt.GitRepo not implemented for #{inspect(repo)}"}
  def pre_push(_repo, _cmds), do: :ok
  def push(repo, _cmds), do: {:ok, repo}
end

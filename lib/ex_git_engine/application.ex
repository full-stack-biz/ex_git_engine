defmodule ExGitEngine.Application do
  @moduledoc """
  Starts `ExGitEngine.JobLimiter`, which `ExGitEngine.GitAgent` uses for its
  long operations.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([ExGitEngine.JobLimiter],
      strategy: :one_for_one,
      name: ExGitEngine.Supervisor
    )
  end
end

defmodule ExGitEngine.Application do
  @moduledoc """
  Starts `ExGitEngine.JobLimiter`, which `ExGitEngine.GitAgent` uses for its
  long operations, and writes the git config that limits a pack build's memory.

  libgit2 reads `pack.windowMemory` and `pack.deltaCacheSize` only from config, so the pack build
  adds this file to its own repository handle (`ExGitEngine.Git.config_add_file/2`). The defaults
  are overridden with the `:pack_window_memory` and `:pack_delta_cache_size` app env, in bytes.
  `pack.deltaCacheSize` also sets the size above which libgit2 skips delta compression of an
  object (`pack-objects.c` reads that key for both).

  It also sets libgit2's process-wide limits on cached objects (`:cache_max_size`, libgit2's
  default is 256 MB) and on mapped pack data (`:mapped_limit`, `:mapped_window_size`), in bytes.
  """
  use Application

  @default_pack_limit 64 * 1024 * 1024

  @impl true
  def start(_type, _args) do
    write_pack_config()

    :ok =
      ExGitEngine.Git.library_set_memory_limits(
        Application.get_env(:ex_git_engine, :cache_max_size, @default_pack_limit),
        Application.get_env(:ex_git_engine, :mapped_limit, 2 * @default_pack_limit),
        Application.get_env(:ex_git_engine, :mapped_window_size, div(@default_pack_limit, 4))
      )

    Supervisor.start_link([ExGitEngine.JobLimiter],
      strategy: :one_for_one,
      name: ExGitEngine.Supervisor
    )
  end

  @doc "Returns the path of the git config file with the pack memory limits."
  @spec pack_config_path() :: Path.t()
  def pack_config_path do
    Path.join(pack_tmp_dir(), "ex_git_engine-#{System.pid()}.gitconfig")
  end

  @doc "Returns the directory for pack temp files."
  @spec pack_tmp_dir() :: Path.t()
  def pack_tmp_dir, do: Application.get_env(:ex_git_engine, :pack_tmp_dir) || System.tmp_dir!()

  defp write_pack_config do
    window = Application.get_env(:ex_git_engine, :pack_window_memory, @default_pack_limit)
    cache = Application.get_env(:ex_git_engine, :pack_delta_cache_size, @default_pack_limit)

    File.write!(
      pack_config_path(),
      "[pack]\n\twindowMemory = #{window}\n\tdeltaCacheSize = #{cache}\n"
    )
  end
end

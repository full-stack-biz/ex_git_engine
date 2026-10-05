defmodule ExGitEngine.DirtyNifTest do
  @moduledoc """
  Heavy NIFs must run on dirty schedulers: a NIF on a normal scheduler blocks
  every other process queued there for its whole duration.

  With a single normal scheduler online, a ticker process that sleeps 1ms in a
  loop only gets to run if the heavy call left that scheduler free.
  """
  use ExUnit.Case, async: false

  alias ExGitEngine.GitAgent

  @files 400
  @lines 1500

  setup do
    path = Path.join(System.tmp_dir(), "ex_git_engine-dirty-#{:erlang.unique_integer()}")
    File.mkdir_p!(path)
    cmd = fn args -> System.cmd("git", ["-C", path | args], stderr_to_stdout: true) end
    cmd.(["init", "-b", "main"])
    cmd.(["config", "user.email", "test@example.com"])
    cmd.(["config", "user.name", "Test User"])

    write_files = fn tag ->
      for i <- 1..@files do
        body = Enum.map_join(1..@lines, "\n", &"#{tag} line #{&1} of file #{i}")
        File.write!(Path.join(path, "f#{i}.txt"), body)
      end

      cmd.(["add", "."])
      cmd.(["commit", "-qm", tag])
    end

    write_files.("old")
    write_files.("new")

    {:ok, agent} = GitAgent.start_link(path)
    {:ok, {old, _}} = GitAgent.revision(agent, "main~1")
    {:ok, {new, _}} = GitAgent.revision(agent, "main")

    on_exit(fn -> File.rm_rf!(path) end)
    %{agent: agent, old: old, new: new}
  end

  test "diff_format leaves the normal scheduler free", %{agent: agent} = ctx do
    {:ok, diff} = GitAgent.diff(agent, ctx.old, ctx.new)
    assert_not_blocking(fn -> GitAgent.diff_format(agent, diff, patch: :patch) end)
  end

  test "pack_create leaves the normal scheduler free", %{agent: agent} = ctx do
    assert_not_blocking(fn -> GitAgent.pack_create(agent, [ctx.old.oid, ctx.new.oid]) end)
  end

  defp assert_not_blocking(fun) do
    online = :erlang.system_flag(:schedulers_online, 1)

    try do
      parent = self()
      ticker = spawn_link(fn -> tick(parent, System.monotonic_time(:millisecond), 0) end)
      {micros, {:ok, _}} = :timer.tc(fun)
      send(ticker, :stop)
      assert_receive {:max_gap, gap}, 5_000

      # A blocking NIF stalls the ticker for (almost) the whole call.
      assert micros > 30_000, "workload too small to tell (#{div(micros, 1000)}ms)"
      assert gap < div(micros, 1000) / 2, "ticker stalled #{gap}ms of #{div(micros, 1000)}ms"
    after
      :erlang.system_flag(:schedulers_online, online)
    end
  end

  defp tick(parent, last, max_gap) do
    receive do
      :stop -> send(parent, {:max_gap, max_gap})
    after
      1 ->
        now = System.monotonic_time(:millisecond)
        tick(parent, now, max(max_gap, now - last))
    end
  end
end

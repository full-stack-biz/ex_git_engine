defmodule ExGitEngine.DirtyNifTest do
  @moduledoc """
  Heavy NIFs must run on dirty schedulers: a NIF on a normal scheduler blocks
  every other process queued there for its whole duration.

  With a single normal scheduler online, a ticker process that sleeps 1ms in a
  loop only gets to run if the heavy call left that scheduler free.
  """
  use ExUnit.Case, async: false

  alias ExGitEngine.{Git, GitAgent, GitDiff}
  alias ExGitEngine.WireProtocol.ReceivePack

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

  test "diff_files pages are bounded and never wait for a dirty scheduler",
       %{agent: agent} = ctx do
    {:ok, many} = GitAgent.start_link(many_files_repo(200_000))
    {:ok, {head, _}} = GitAgent.revision(many, "main")
    {:ok, %GitDiff{__ref__: ref} = diff} = GitAgent.diff(many, nil, head)

    assert {:ok, %{total: 200_000, files: files}} = GitAgent.diff_files(many, diff)
    assert length(files) == 1_000
    assert_raise ArgumentError, fn -> GitAgent.diff_files(many, diff, limit: 5_001) end

    with_dirty_cpu_busy(agent, ctx, fn ->
      {us, {:ok, 200_000, page}} = nif_time(fn -> Git.diff_files(ref, 50_000, 5_000) end)
      assert length(page) == 5_000
      assert us < 200_000, "diff_files waited #{div(us, 1000)}ms for a dirty scheduler"
    end)
  end

  test "patch_text yields on normal schedulers instead of taking a dirty one",
       %{agent: agent} = ctx do
    {big, big_diff} = big_file_diff()
    {:ok, %{patch: %ExGitEngine.GitPatch{__ref__: ref}}} = GitAgent.diff_patch(big, big_diff, 0)

    text =
      with_dirty_cpu_busy(agent, ctx, fn ->
        {us, {:ok, chunks}} = nif_time(fn -> Git.patch_text(ref, 0, -1) end)
        assert us < 200_000, "patch_text waited #{div(us, 1000)}ms for a dirty scheduler"
        IO.iodata_to_binary(chunks)
      end)

    assert {:ok, ^text} = GitAgent.diff_format(big, big_diff, patch: :patch)
  end

  test "the agent alone uses the diffs and patches it created" do
    {agent, diff} = big_file_diff()
    patch = Task.async(fn -> GitAgent.diff_patch(agent, diff, 0) end)
    assert max_running_jobs_until(patch) == 0
    {:ok, %{patch: patch}} = Task.await(patch)

    page = Task.async(fn -> GitAgent.diff_patch_text(agent, patch) end)
    assert max_running_jobs_until(page) == 0
    assert {:ok, _} = Task.await(page)
  end

  test "paging a big file's hunks does not recompute its diff" do
    {agent, diff} = big_file_diff()

    {patch_us, {:ok, %{patch: patch, hunks: hunks}}} =
      :timer.tc(fn -> GitAgent.diff_patch(agent, diff, 0) end)

    assert length(hunks) == 4000

    {page_us, {:ok, text}} =
      :timer.tc(fn -> GitAgent.diff_patch_text(agent, patch, hunks: 100..109) end)

    assert text =~ "+x"

    assert page_us * 10 < patch_us,
           "a page took #{div(page_us, 1000)}ms vs #{div(patch_us, 1000)}ms for the whole file's diff"
  end

  test "diff_format leaves the normal scheduler free", %{agent: agent} = ctx do
    {:ok, diff} = GitAgent.diff(agent, ctx.old, ctx.new)
    assert_not_blocking(fn -> GitAgent.diff_format(agent, diff, patch: :patch) end)
  end

  test "diff_files lists every file without computing any content diff", %{agent: agent} = ctx do
    {:ok, diff} = GitAgent.diff(agent, ctx.old, ctx.new)
    {format_us, {:ok, _}} = :timer.tc(fn -> GitAgent.diff_format(agent, diff, patch: :patch) end)

    {:ok, diff} = GitAgent.diff(agent, ctx.old, ctx.new)
    {files_us, {:ok, %{total: 400}}} = :timer.tc(fn -> GitAgent.diff_files(agent, diff) end)

    assert files_us * 20 < format_us,
           "listing took #{div(files_us, 1000)}ms vs #{div(format_us, 1000)}ms for all content"
  end

  test "pack_create leaves the normal scheduler free", %{agent: agent} = ctx do
    assert_not_blocking(fn -> GitAgent.pack_create(agent, [ctx.old.oid, ctx.new.oid]) end)
  end

  test "the agent runs long operations through the JobLimiter", %{agent: agent} = ctx do
    pack = Task.async(fn -> GitAgent.pack_create(agent, [ctx.old.oid, ctx.new.oid]) end)
    Process.sleep(100)

    assert ExGitEngine.JobLimiter.running() == 1
    assert {:ok, _} = Task.await(pack, 30_000)
  end

  test "pack_create does not hold up other calls to the same agent", %{agent: agent} = ctx do
    assert {:ok, <<"PACK", _::binary>>} =
             assert_agent_free(agent, fn ->
               GitAgent.pack_create(agent, [ctx.old.oid, ctx.new.oid])
             end)
  end

  test "odb_writepack_commit does not hold up other calls to the same agent" do
    source = deep_history_repo(200_000, 1)

    {pack, 0} =
      System.cmd("sh", ["-c", "echo main | git -C #{source} pack-objects --revs --stdout -q"])

    {:ok, target} = GitAgent.start_link(bare_repo())
    {:ok, wp} = GitAgent.odb_writepack(target)

    {:ok, progress} =
      GitAgent.odb_writepack_append(target, wp, pack, %ReceivePack{}.writepack_progress)

    assert {:ok, _} =
             assert_agent_free(target, fn ->
               GitAgent.odb_writepack_commit(target, wp, progress)
             end)
  end

  test "blame does not hold up other calls to the same agent" do
    {:ok, agent} = GitAgent.start_link(deep_history_repo(10_000, 100))
    assert {:ok, [_ | _]} = assert_agent_free(agent, fn -> GitAgent.blame(agent, "f.txt") end)
  end

  test "graph_ahead_behind does not hold up other calls to the same agent" do
    {:ok, agent} = GitAgent.start_link(deep_history_repo(200_000, 1))
    {:ok, {first, _}} = GitAgent.revision(agent, "main~199999")
    {:ok, {last, _}} = GitAgent.revision(agent, "main")

    assert {:ok, {199_999, 0}} =
             assert_agent_free(agent, fn ->
               GitAgent.graph_ahead_behind(agent, last.oid, first.oid)
             end)
  end

  defp assert_agent_free(agent, fun, min_ms \\ 300) do
    started = System.monotonic_time(:millisecond)
    task = Task.async(fun)
    Process.sleep(50)

    {micros, _} = :timer.tc(fn -> GitAgent.empty?(agent) end)
    result = Task.await(task, 120_000)
    took = System.monotonic_time(:millisecond) - started
    assert took > min_ms, "workload too small to tell (#{took}ms)"
    assert micros < 100_000, "other call waited #{div(micros, 1000)}ms of #{took}ms"
    result
  end

  defp nif_time(fun), do: Task.await(Task.async(fn -> :timer.tc(fun) end), 30_000)

  defp with_dirty_cpu_busy(agent, ctx, fun) do
    online = :erlang.system_flag(:dirty_cpu_schedulers_online, 1)

    try do
      pack = Task.async(fn -> GitAgent.pack_create(agent, [ctx.old.oid, ctx.new.oid]) end)
      Process.sleep(100)
      result = fun.()
      assert Task.yield(pack, 0) == nil, "the pack finished first, nothing was tested"
      Task.await(pack, 30_000)
      result
    after
      :erlang.system_flag(:dirty_cpu_schedulers_online, online)
    end
  end

  defp max_running_jobs_until(%Task{} = task, peak \\ 0) do
    if Process.alive?(task.pid) do
      max_running_jobs_until(task, max(peak, ExGitEngine.JobLimiter.running()))
    else
      peak
    end
  end

  defp big_file_diff do
    path = Path.join(System.tmp_dir(), "ex_git_engine-bigfile-#{:erlang.unique_integer()}")
    System.cmd("git", ["init", "-q", "-b", "main", path])
    on_exit(fn -> File.rm_rf!(path) end)
    cmd = fn args -> System.cmd("git", ["-C", path | args], stderr_to_stdout: true) end
    cmd.(["config", "user.email", "t@e"])
    cmd.(["config", "user.name", "T"])

    file = Path.join(path, "big.txt")
    File.write!(file, Enum.map_join(1..200_000, "", &"line #{&1}\n"))
    cmd.(["add", "."])
    cmd.(["commit", "-qm", "old"])

    File.write!(
      file,
      Enum.map_join(1..200_000, "", &if(rem(&1, 50) == 0, do: "x\n", else: "line #{&1}\n"))
    )

    cmd.(["commit", "-qam", "new"])

    {:ok, agent} = GitAgent.start_link(path)
    {:ok, {old, _}} = GitAgent.revision(agent, "main~1")
    {:ok, {new, _}} = GitAgent.revision(agent, "main")
    {:ok, diff} = GitAgent.diff(agent, old, new)
    {agent, diff}
  end

  defp bare_repo do
    path = Path.join(System.tmp_dir(), "ex_git_engine-bare-#{:erlang.unique_integer()}")
    System.cmd("git", ["init", "-q", "--bare", path])
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp many_files_repo(count) do
    path = Path.join(System.tmp_dir(), "ex_git_engine-many-#{:erlang.unique_integer()}")
    System.cmd("git", ["init", "-q", "-b", "main", path])
    on_exit(fn -> File.rm_rf!(path) end)

    files =
      for i <- 1..count,
          into: "",
          do: "M 644 inline d#{rem(i, 100)}/f#{i}.txt\ndata 2\n#{rem(i, 10)}\n\n"

    stream = "commit refs/heads/main\ncommitter T <t@e> 1600000000 +0000\ndata 1\nc\n" <> files

    File.write!(Path.join(path, "fast-import"), stream)
    {_, 0} = System.cmd("sh", ["-c", "git -C #{path} fast-import --quiet < #{path}/fast-import"])
    path
  end

  defp deep_history_repo(commits, lines) do
    path = Path.join(System.tmp_dir(), "ex_git_engine-deep-#{:erlang.unique_integer()}")
    System.cmd("git", ["init", "-q", "-b", "main", path])
    on_exit(fn -> File.rm_rf!(path) end)

    stream =
      for i <- 1..commits, into: "" do
        body = "#{i}\n" <> Enum.map_join(2..lines//1, "", &"#{&1}\n")
        from = if i > 1, do: "from :#{i - 1}\n", else: ""

        "commit refs/heads/main\nmark :#{i}\ncommitter T <t@e> #{1_600_000_000 + i} +0000\n" <>
          "data 1\nc\n#{from}M 644 inline f.txt\ndata #{byte_size(body)}\n#{body}\n"
      end

    File.write!(Path.join(path, "fast-import"), stream)
    {_, 0} = System.cmd("sh", ["-c", "git -C #{path} fast-import --quiet < #{path}/fast-import"])
    path
  end

  defp assert_not_blocking(fun) do
    online = :erlang.system_flag(:schedulers_online, 1)

    try do
      parent = self()
      ticker = spawn_link(fn -> tick(parent, System.monotonic_time(:millisecond), 0) end)
      Process.sleep(20)
      {micros, {:ok, _}} = :timer.tc(fun)
      send(ticker, :stop)
      assert_receive {:max_gap, gap}, 5_000

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

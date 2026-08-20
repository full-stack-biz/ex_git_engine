defmodule ExGitEngine.GitAgentTest do
  use ExUnit.Case, async: true

  alias ExGitEngine.{GitAgent, GitCommit, GitRef, GitTag, GitTree, GitTreeEntry}

  setup do
    path = Path.join(System.tmp_dir(), "ex_git_engine-test-#{:erlang.unique_integer()}")
    File.mkdir_p!(path)

    cmd = fn args -> System.cmd("git", ["-C", path | args], stderr_to_stdout: true) end

    cmd.(["init"])
    cmd.(["config", "user.email", "test@example.com"])
    cmd.(["config", "user.name", "Test User"])

    File.write!(Path.join(path, "README.md"), "# Hello\n")
    File.mkdir_p!(Path.join(path, "src"))
    File.write!(Path.join(path, "src/app.ex"), "defmodule App do\nend\n")

    cmd.(["add", "."])
    cmd.(["commit", "-m", "initial commit"])
    cmd.(["tag", "v1.0"])
    cmd.(["tag", "-a", "v2.0", "-m", "Release v2.0"])
    cmd.(["checkout", "-b", "feature"])
    File.write!(Path.join(path, "feature.txt"), "feature\n")
    cmd.(["add", "."])
    cmd.(["commit", "-m", "feature commit"])
    cmd.(["checkout", "main"])

    cmd.(["checkout", "-b", "group/topic"])
    File.write!(Path.join(path, "group.txt"), "group\n")
    cmd.(["add", "."])
    cmd.(["commit", "-m", "group commit"])
    cmd.(["checkout", "main"])

    {:ok, agent} = GitAgent.start_link(path)

    on_exit(fn ->
      if Process.alive?(agent), do: GenServer.stop(agent)
      File.rm_rf!(path)
    end)

    %{path: path, agent: agent}
  end

  describe "empty?/1" do
    test "returns false for repo with commits", %{agent: agent} do
      assert {:ok, false} = GitAgent.empty?(agent)
    end

    test "returns true for freshly initialized repo" do
      path = Path.join(System.tmp_dir(), "ex_git_engine-empty-#{:erlang.unique_integer()}")
      File.mkdir_p!(path)
      System.cmd("git", ["-C", path, "init"], stderr_to_stdout: true)
      {:ok, agent} = GitAgent.start_link(path)

      on_exit(fn ->
        if Process.alive?(agent), do: GenServer.stop(agent)
        File.rm_rf!(path)
      end)

      assert {:ok, true} = GitAgent.empty?(agent)
    end
  end

  describe "head/1" do
    test "returns HEAD ref pointing to main", %{agent: agent} do
      assert {:ok, %GitRef{name: "main", type: :branch}} = GitAgent.head(agent)
    end
  end

  describe "branches/1" do
    test "returns all branches", %{agent: agent} do
      {:ok, branches} = GitAgent.branches(agent)
      names = branches |> Enum.to_list() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["feature", "group/topic", "main"]
    end

    test "each branch is a GitRef with type :branch", %{agent: agent} do
      {:ok, branches} = GitAgent.branches(agent)

      for branch <- Enum.to_list(branches) do
        assert %GitRef{type: :branch} = branch
      end
    end
  end

  describe "branch/2" do
    test "returns ref for existing branch", %{agent: agent} do
      assert {:ok, %GitRef{name: "main", type: :branch}} = GitAgent.branch(agent, "main")
    end

    test "returns error for non-existent branch", %{agent: agent} do
      assert {:error, _} = GitAgent.branch(agent, "no-such-branch")
    end
  end

  describe "tags/1" do
    test "returns lightweight tag as GitRef", %{agent: agent} do
      {:ok, tags} = GitAgent.tags(agent)
      results = Enum.to_list(tags)
      lightweight = Enum.find(results, &match?(%GitRef{name: "v1.0"}, &1))
      assert %GitRef{name: "v1.0", type: :tag} = lightweight
    end

    test "returns annotated tag as GitTag", %{agent: agent} do
      {:ok, tags} = GitAgent.tags(agent)
      results = Enum.to_list(tags)
      annotated = Enum.find(results, &match?(%GitTag{name: "v2.0"}, &1))
      assert %GitTag{name: "v2.0"} = annotated
    end

    test "returns both lightweight and annotated tags", %{agent: agent} do
      {:ok, tags} = GitAgent.tags(agent)
      names = tags |> Enum.to_list() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["v1.0", "v2.0"]
    end

    test "returns empty enumerable when no tags exist" do
      path = Path.join(System.tmp_dir(), "ex_git_engine-notags-#{:erlang.unique_integer()}")
      File.mkdir_p!(path)
      System.cmd("git", ["-C", path, "init"], stderr_to_stdout: true)
      System.cmd("git", ["-C", path, "config", "user.email", "t@t.com"], stderr_to_stdout: true)
      System.cmd("git", ["-C", path, "config", "user.name", "T"], stderr_to_stdout: true)
      File.write!(Path.join(path, "f"), "x")
      System.cmd("git", ["-C", path, "add", "."], stderr_to_stdout: true)
      System.cmd("git", ["-C", path, "commit", "-m", "c"], stderr_to_stdout: true)
      {:ok, agent} = GitAgent.start_link(path)

      on_exit(fn ->
        if Process.alive?(agent), do: GenServer.stop(agent)
        File.rm_rf!(path)
      end)

      {:ok, tags} = GitAgent.tags(agent)
      assert Enum.to_list(tags) == []
    end
  end

  describe "tag/2" do
    test "returns lightweight tag by name", %{agent: agent} do
      assert {:ok, %GitRef{name: "v1.0", type: :tag}} = GitAgent.tag(agent, "v1.0")
    end

    test "returns annotated tag by name", %{agent: agent} do
      assert {:ok, %GitTag{name: "v2.0"}} = GitAgent.tag(agent, "v2.0")
    end

    test "returns error for non-existent tag", %{agent: agent} do
      assert {:error, _} = GitAgent.tag(agent, "no-such-tag")
    end
  end

  describe "tag_author/2 and tag_message/2" do
    test "returns author for annotated tag", %{agent: agent} do
      {:ok, %GitTag{} = tag} = GitAgent.tag(agent, "v2.0")

      assert {:ok, %{name: "Test User", email: "test@example.com"}} =
               GitAgent.tag_author(agent, tag)
    end

    test "returns message for annotated tag", %{agent: agent} do
      {:ok, %GitTag{} = tag} = GitAgent.tag(agent, "v2.0")
      assert {:ok, message} = GitAgent.tag_message(agent, tag)
      assert message =~ "Release v2.0"
    end
  end

  describe "revision/2" do
    test "resolves branch name to ref and commit", %{agent: agent} do
      assert {:ok, {%GitCommit{}, %GitRef{name: "main"}}} = GitAgent.revision(agent, "main")
    end

    test "resolves tag name to ref and commit", %{agent: agent} do
      assert {:ok, {%GitCommit{}, _ref}} = GitAgent.revision(agent, "v1.0")
    end

    test "resolves branch name with slash to ref and commit", %{agent: agent} do
      assert {:ok, {%GitCommit{}, %GitRef{name: "group/topic"}}} =
               GitAgent.revision(agent, "group/topic")
    end

    test "returns error for unknown revision", %{agent: agent} do
      assert {:error, _} = GitAgent.revision(agent, "no-such-rev")
    end
  end

  describe "peel/2" do
    test "peels branch ref to commit", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      assert {:ok, %GitCommit{}} = GitAgent.peel(agent, ref)
    end

    test "peels lightweight tag ref to commit", %{agent: agent} do
      {:ok, ref} = GitAgent.tag(agent, "v1.0")
      assert {:ok, %GitCommit{}} = GitAgent.peel(agent, ref)
    end

    test "peels annotated tag to commit", %{agent: agent} do
      {:ok, tag} = GitAgent.tag(agent, "v2.0")
      assert {:ok, %GitCommit{}} = GitAgent.peel(agent, tag)
    end
  end

  describe "commit_message/2" do
    test "returns message of the initial commit", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      assert {:ok, message} = GitAgent.commit_message(agent, commit)
      assert message =~ "initial commit"
    end
  end

  describe "commit_author/2" do
    test "returns author name and email", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)

      assert {:ok, %{name: "Test User", email: "test@example.com"}} =
               GitAgent.commit_author(agent, commit)
    end
  end

  describe "commit_committer/2" do
    test "returns committer name and email", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)

      assert {:ok, %{name: "Test User", email: "test@example.com"}} =
               GitAgent.commit_committer(agent, commit)
    end
  end

  describe "commit_timestamp/2" do
    test "returns a DateTime", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      assert {:ok, %DateTime{}} = GitAgent.commit_timestamp(agent, commit)
    end
  end

  describe "commit_parents/2" do
    test "returns empty stream for initial commit", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      {:ok, parents} = GitAgent.commit_parents(agent, commit)
      assert Enum.to_list(parents) == []
    end

    test "returns parent for second commit", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "feature")
      {:ok, commit} = GitAgent.peel(agent, ref)
      {:ok, parents} = GitAgent.commit_parents(agent, commit)
      assert [%GitCommit{}] = Enum.to_list(parents)
    end
  end

  describe "commit_raw/2" do
    test "returns commit content for unsigned commit", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      assert {:ok, data} = GitAgent.commit_raw(agent, commit)
      assert is_binary(data)
      assert data =~ "tree "
      assert data =~ "author "
      refute data =~ "gpgsig"
    end

    test "returns signed data binary for SSH-signed commit" do
      path = Path.join(System.tmp_dir(), "ex_git_engine-signed-#{:erlang.unique_integer()}")
      File.mkdir_p!(path)

      key_path = Path.join(path, "test_key")

      System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", key_path],
        stderr_to_stdout: true
      )

      cmd = fn args -> System.cmd("git", ["-C", path | args], stderr_to_stdout: true) end

      cmd.(["init"])
      cmd.(["config", "user.email", "test@example.com"])
      cmd.(["config", "user.name", "Test User"])
      cmd.(["config", "gpg.format", "ssh"])
      cmd.(["config", "user.signingkey", key_path <> ".pub"])

      File.write!(Path.join(path, "README.md"), "# Hello\n")
      cmd.(["add", "."])
      cmd.(["commit", "-S", "-m", "signed commit"])

      {:ok, agent} = GitAgent.start_link(path)

      on_exit(fn ->
        if Process.alive?(agent), do: GenServer.stop(agent)
        File.rm_rf!(path)
      end)

      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)

      assert {:ok, data} = GitAgent.commit_raw(agent, commit)
      assert is_binary(data)
      assert data =~ "tree "
      assert data =~ "author "
      refute data =~ "gpgsig"
    end
  end

  describe "history/2" do
    test "returns all commits reachable from main", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      {:ok, stream} = GitAgent.history(agent, commit)
      assert [%GitCommit{}] = Enum.to_list(stream)
    end

    test "returns two commits from feature branch", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "feature")
      {:ok, commit} = GitAgent.peel(agent, ref)
      {:ok, stream} = GitAgent.history(agent, commit)
      assert length(Enum.to_list(stream)) == 2
    end
  end

  describe "tree_entries/2" do
    test "returns top-level entries for main commit", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      {:ok, entries} = GitAgent.tree_entries(agent, commit)
      names = entries |> Enum.to_list() |> Enum.map(& &1.name) |> Enum.sort()
      assert "README.md" in names
      assert "src" in names
    end

    test "each entry is a GitTreeEntry", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      {:ok, entries} = GitAgent.tree_entries(agent, commit)

      for entry <- Enum.to_list(entries) do
        assert %GitTreeEntry{} = entry
      end
    end
  end

  describe "tree_entry_by_path/3" do
    test "returns entry for existing file", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)

      assert {:ok, %GitTreeEntry{name: "README.md", type: :blob}} =
               GitAgent.tree_entry_by_path(agent, commit, "README.md")
    end

    test "returns entry for nested file", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)

      assert {:ok, %GitTreeEntry{name: "app.ex", type: :blob}} =
               GitAgent.tree_entry_by_path(agent, commit, "src/app.ex")
    end

    test "returns error for non-existent path", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      assert {:error, _} = GitAgent.tree_entry_by_path(agent, commit, "no-such-file.txt")
    end
  end

  describe "blob_content/2 and blob_size/2" do
    test "returns file content", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      {:ok, entry} = GitAgent.tree_entry_by_path(agent, commit, "README.md")
      {:ok, blob} = GitAgent.peel(agent, entry)
      assert {:ok, "# Hello\n"} = GitAgent.blob_content(agent, blob)
    end

    test "returns correct blob size", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      {:ok, entry} = GitAgent.tree_entry_by_path(agent, commit, "README.md")
      {:ok, blob} = GitAgent.peel(agent, entry)
      assert {:ok, 8} = GitAgent.blob_size(agent, blob)
    end
  end

  describe "tree/2" do
    test "returns GitTree for a commit", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      assert {:ok, %GitTree{}} = GitAgent.tree(agent, commit)
    end
  end

  describe "references/1" do
    test "returns all refs including branches and tags", %{agent: agent} do
      {:ok, refs} = GitAgent.references(agent)
      names = refs |> Enum.to_list() |> Enum.map(& &1.name) |> Enum.sort()
      assert "main" in names
      assert "feature" in names
      assert "v1.0" in names
    end
  end

  describe "references/2 with target: :commit" do
    test "includes refs/pull/* without crashing", %{path: path, agent: agent} do
      {:ok, {commit, _}} = GitAgent.revision(agent, "main")
      oid_hex = Base.encode16(commit.oid, case: :lower)

      System.cmd("git", ["-C", path, "update-ref", "refs/pull/1/head", oid_hex],
        stderr_to_stdout: true
      )

      {:ok, refs} = GitAgent.references(agent, target: :commit, stream_chunk_size: :infinity)
      names = refs |> Enum.to_list() |> Enum.map(& &1.name)
      assert "pull/1/head" in names
    end
  end

  describe "blame/2" do
    test "returns one hunk for single-commit file", %{agent: agent} do
      assert {:ok, hunks} = GitAgent.blame(agent, "README.md")
      assert [hunk] = hunks
      assert hunk.start_line == 1
      assert hunk.line_count >= 1
      assert hunk.author_name == "Test User"
      assert %DateTime{} = hunk.timestamp
      assert is_binary(hunk.oid) and byte_size(hunk.oid) == 20
    end

    test "returns multiple hunks for file modified across commits", %{path: path, agent: agent} do
      cmd = fn args -> System.cmd("git", ["-C", path | args], stderr_to_stdout: true) end

      File.write!(Path.join(path, "README.md"), "# Hello\nNew line\n")
      cmd.(["add", "README.md"])
      cmd.(["commit", "-m", "add second line"])

      assert {:ok, hunks} = GitAgent.blame(agent, "README.md")
      assert length(hunks) >= 2

      assert Enum.all?(
               hunks,
               &match?(%{oid: _, start_line: _, line_count: _, author_name: _}, &1)
             )
    end

    test "returns error for non-existent path", %{agent: agent} do
      assert {:error, _reason} = GitAgent.blame(agent, "no_such_file.txt")
    end

    test "accepts newest_commit opt and returns same result as default", %{agent: agent} do
      {:ok, {commit, _}} = GitAgent.revision(agent, "main")
      assert {:ok, default_hunks} = GitAgent.blame(agent, "README.md")
      assert {:ok, pinned_hunks} = GitAgent.blame(agent, "README.md", newest_commit: commit.oid)
      assert length(default_hunks) == length(pinned_hunks)
      assert hd(default_hunks).oid == hd(pinned_hunks).oid
    end
  end

  describe "commit_gpg_signature/2" do
    test "returns ok with signature or error if unsigned", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      result = GitAgent.commit_gpg_signature(agent, commit)
      # Either signed (global git config may auto-sign) or unsigned
      assert match?({:ok, sig} when is_binary(sig), result) or match?({:error, _}, result)
    end
  end

  describe "diff/4, diff_stats/3, diff_deltas/3" do
    test "returns a GitDiff between two commits", %{agent: agent} do
      {:ok, main_ref} = GitAgent.branch(agent, "main")
      {:ok, feat_ref} = GitAgent.branch(agent, "feature")
      {:ok, main_commit} = GitAgent.peel(agent, main_ref)
      {:ok, feat_commit} = GitAgent.peel(agent, feat_ref)
      assert {:ok, %ExGitEngine.GitDiff{}} = GitAgent.diff(agent, main_commit, feat_commit)
    end

    test "diff_stats returns files_changed, insertions, deletions", %{agent: agent} do
      {:ok, main_ref} = GitAgent.branch(agent, "main")
      {:ok, feat_ref} = GitAgent.branch(agent, "feature")
      {:ok, main_commit} = GitAgent.peel(agent, main_ref)
      {:ok, feat_commit} = GitAgent.peel(agent, feat_ref)
      {:ok, diff} = GitAgent.diff(agent, main_commit, feat_commit)

      assert {:ok, %{files_changed: files, insertions: ins, deletions: del}} =
               GitAgent.diff_stats(agent, diff)

      assert files > 0
      assert is_integer(ins)
      assert is_integer(del)
    end

    test "diff_deltas returns list of delta maps", %{agent: agent} do
      {:ok, main_ref} = GitAgent.branch(agent, "main")
      {:ok, feat_ref} = GitAgent.branch(agent, "feature")
      {:ok, main_commit} = GitAgent.peel(agent, main_ref)
      {:ok, feat_commit} = GitAgent.peel(agent, feat_ref)
      {:ok, diff} = GitAgent.diff(agent, main_commit, feat_commit)

      assert {:ok, deltas} = GitAgent.diff_deltas(agent, diff)
      assert is_list(deltas)
      assert deltas != []
    end
  end

  describe "branches/2 and branch/3 with :with option" do
    test "branches returns {ref, commit} pairs", %{agent: agent} do
      {:ok, branches} = GitAgent.branches(agent, with: :commit)
      results = Enum.to_list(branches)
      assert length(results) == 3

      for {ref, commit} <- results do
        assert %GitRef{type: :branch} = ref
        assert %ExGitEngine.GitCommit{} = commit
      end
    end

    test "branch returns {ref, commit} pair", %{agent: agent} do
      assert {:ok, {%GitRef{name: "main"}, %ExGitEngine.GitCommit{}}} =
               GitAgent.branch(agent, "main", with: :commit)
    end
  end

  describe "tags/2 and tag/3 with :with option" do
    test "tags returns {tag, commit} pairs", %{agent: agent} do
      {:ok, tags} = GitAgent.tags(agent, with: :commit)
      results = Enum.to_list(tags)
      assert length(results) == 2

      for {tag, commit} <- results do
        assert is_struct(tag)
        assert %ExGitEngine.GitCommit{} = commit
      end
    end

    test "tag returns {ref, commit} pair for lightweight tag", %{agent: agent} do
      assert {:ok, {%GitRef{name: "v1.0"}, %ExGitEngine.GitCommit{}}} =
               GitAgent.tag(agent, "v1.0", with: :commit)
    end
  end

  describe "odb/1 and odb operations" do
    test "odb returns a GitOdb struct", %{agent: agent} do
      assert {:ok, %ExGitEngine.GitOdb{}} = GitAgent.odb(agent)
    end

    test "odb_read returns type and raw data for a known oid", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      {:ok, odb} = GitAgent.odb(agent)

      assert {:ok, {:commit, data}} = GitAgent.odb_read(agent, odb, commit.oid)
      assert is_binary(data)
      assert data =~ "tree "
    end

    test "odb_object_exists? returns true for a known oid", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)
      {:ok, odb} = GitAgent.odb(agent)

      assert {:ok, true} = GitAgent.odb_object_exists?(agent, odb, commit.oid)
    end

    test "odb_object_exists? returns false for unknown oid", %{agent: agent} do
      {:ok, odb} = GitAgent.odb(agent)
      fake_oid = :binary.copy(<<0>>, 20)
      assert {:ok, false} = GitAgent.odb_object_exists?(agent, odb, fake_oid)
    end
  end

  describe "pack_create/3" do
    test "returns a binary PACK for a commit oid", %{agent: agent} do
      {:ok, ref} = GitAgent.branch(agent, "main")
      {:ok, commit} = GitAgent.peel(agent, ref)

      assert {:ok, pack} = GitAgent.pack_create(agent, [commit.oid])
      assert is_binary(pack)
      assert byte_size(pack) > 0
      assert binary_part(pack, 0, 4) == "PACK"
    end
  end

  describe "merge_commits/4" do
    test "returns a GitIndex merging two diverged commits", %{agent: agent} do
      {:ok, main_ref} = GitAgent.branch(agent, "main")
      {:ok, feat_ref} = GitAgent.branch(agent, "feature")
      {:ok, main_commit} = GitAgent.peel(agent, main_ref)
      {:ok, feat_commit} = GitAgent.peel(agent, feat_ref)

      assert {:ok, %ExGitEngine.GitIndex{}} =
               GitAgent.merge_commits(agent, main_commit, feat_commit)
    end
  end

  describe "idle_timeout" do
    test "agent stops normally after idle timeout elapses" do
      path = Path.join(System.tmp_dir(), "ex_git_engine-timeout-#{:erlang.unique_integer()}")
      File.mkdir_p!(path)
      System.cmd("git", ["-C", path, "init"], stderr_to_stdout: true)

      {:ok, agent} = ExGitEngine.GitAgent.start_link(path, idle_timeout: 50)
      on_exit(fn -> File.rm_rf!(path) end)

      ref = Process.monitor(agent)
      assert_receive {:DOWN, ^ref, :process, ^agent, :normal}, 500
    end
  end

  describe "start_link with invalid path" do
    test "returns error tuple for non-existent repo" do
      # Use GenServer.start (no link) to avoid EXIT signal propagating to the test process
      assert {:error, _reason} =
               GenServer.start(
                 ExGitEngine.GitAgent,
                 {"/nonexistent/path/that/does/not/exist", []}
               )
    end
  end

  describe "cache callbacks" do
    test "put_cache/3 and fetch_cache/2 round-trip" do
      cache = GitAgent.init_cache("/tmp", [])
      assert :ok = GitAgent.put_cache(cache, :my_key, {:ok, "value"})
      assert {:ok, "value"} = GitAgent.fetch_cache(cache, :my_key)
    end

    test "fetch_cache/2 returns nil on miss" do
      cache = GitAgent.init_cache("/tmp", [])
      assert nil == GitAgent.fetch_cache(cache, :missing)
    end
  end

  describe "make_cache_key/1" do
    test "named transaction returns name" do
      assert GitAgent.make_cache_key({:transaction, "my_tx", fn -> nil end}) == "my_tx"
    end

    test "unnamed transaction returns nil" do
      assert GitAgent.make_cache_key({:transaction, nil, fn -> nil end}) == nil
    end
  end

  describe "handle_info :DOWN" do
    test "removes dead pid from mon map without crashing", %{agent: agent} do
      fake_pid = spawn(fn -> :ok end)
      send(agent, {:DOWN, make_ref(), :process, fake_pid, :normal})
      :timer.sleep(20)
      assert Process.alive?(agent)
    end
  end

  describe "handle_info :timeout with :infinity" do
    test "timeout message is a no-op when idle_timeout is :infinity" do
      path = Path.join(System.tmp_dir(), "ex_git_engine-inf-#{:erlang.unique_integer()}")
      File.mkdir_p!(path)
      System.cmd("git", ["-C", path, "init"], stderr_to_stdout: true)
      {:ok, agent} = GitAgent.start_link(path, idle_timeout: :infinity)

      on_exit(fn ->
        if Process.alive?(agent), do: GenServer.stop(agent)
        File.rm_rf!(path)
      end)

      send(agent, :timeout)
      :timer.sleep(50)
      assert Process.alive?(agent)
    end
  end

  describe "graph_ahead_behind/3" do
    test "feature is 1 ahead and 0 behind main", %{agent: agent} do
      {:ok, main_ref} = GitAgent.branch(agent, "main")
      {:ok, main_commit} = GitAgent.peel(agent, main_ref)
      {:ok, feat_ref} = GitAgent.branch(agent, "feature")
      {:ok, feat_commit} = GitAgent.peel(agent, feat_ref)

      assert {:ok, {1, 0}} =
               GitAgent.graph_ahead_behind(agent, feat_commit.oid, main_commit.oid)
    end

    test "main is 0 ahead and 1 behind feature", %{agent: agent} do
      {:ok, main_ref} = GitAgent.branch(agent, "main")
      {:ok, main_commit} = GitAgent.peel(agent, main_ref)
      {:ok, feat_ref} = GitAgent.branch(agent, "feature")
      {:ok, feat_commit} = GitAgent.peel(agent, feat_ref)

      assert {:ok, {0, 1}} =
               GitAgent.graph_ahead_behind(agent, main_commit.oid, feat_commit.oid)
    end
  end
end

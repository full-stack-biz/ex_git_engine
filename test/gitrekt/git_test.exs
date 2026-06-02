defmodule GitRekt.GitTest do
  use ExUnit.Case, async: true

  alias GitRekt.Git

  describe "repository_init/4" do
    test "creates sha1 repo with explicit :sha1" do
      path = System.tmp_dir!() |> Path.join("gitrekt-test-#{System.unique_integer([:positive])}")

      try do
        assert {:ok, repo} = Git.repository_init(path, true, "main", :sha1)
        assert is_reference(repo)
      after
        File.rm_rf!(path)
      end
    end

    test "creates repo with default hash algo (sha1)" do
      path = System.tmp_dir!() |> Path.join("gitrekt-test-#{System.unique_integer([:positive])}")

      try do
        assert {:ok, repo} = Git.repository_init(path, true, "main")
        assert is_reference(repo)
      after
        File.rm_rf!(path)
      end
    end

    test "default initial_head is main" do
      path = System.tmp_dir!() |> Path.join("gitrekt-test-#{System.unique_integer([:positive])}")

      try do
        assert {:ok, repo} = Git.repository_init(path)
        assert is_reference(repo)
      after
        File.rm_rf!(path)
      end
    end
  end

  describe "repository_oid_type/1" do
    test "returns :sha1 for a sha1 repository" do
      path = System.tmp_dir!() |> Path.join("gitrekt-test-#{System.unique_integer([:positive])}")

      try do
        {:ok, repo} = Git.repository_init(path, true, "main", :sha1)
        assert Git.repository_oid_type(repo) == :sha1
      after
        File.rm_rf!(path)
      end
    end
  end
end

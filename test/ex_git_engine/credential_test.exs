defmodule ExGitEngine.CredentialTest do
  use ExUnit.Case, async: true

  @moduletag timeout: 15_000

  # A server that only advertises Negotiate (GIT_CREDENTIAL_DEFAULT).
  # Our callback cannot satisfy that type, so it must return GIT_PASSTHROUGH
  # without ever contacting the runner.
  test "credential callback not invoked for Negotiate-only server" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server = spawn(fn -> negotiate_server_loop(listen) end)

    test_pid = self()

    runner =
      spawn(fn ->
        receive do
          {:credential_request, res_term, _url} ->
            send(test_pid, :credential_requested)
            ExGitEngine.Git.credential_deliver(res_term, :error)
        after
          10_000 -> :timeout
        end
      end)

    tmp = Path.join(System.tmp_dir(), "cred-test-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    url = "http://127.0.0.1:#{port}/repo.git"

    task =
      Task.async(fn ->
        ExGitEngine.Git.repository_clone(url, Path.join(tmp, "clone"), true, [], runner)
      end)

    Task.await(task, 10_000)

    refute_received :credential_requested

    Process.exit(server, :kill)
    :gen_tcp.close(listen)
    on_exit(fn -> File.rm_rf!(tmp) end)
  end

  test "repository_fetch with runner_pid invokes runner on 401 Basic" do
    tmp = Path.join(System.tmp_dir(), "auth-fetch-test-#{:erlang.unique_integer([:positive])}")
    bare = Path.join(tmp, "target.git")
    File.mkdir_p!(bare)
    System.cmd("git", ["init", "--bare", bare])

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server = spawn(fn -> basic_server_loop(listen) end)

    test_pid = self()

    runner =
      spawn(fn ->
        receive do
          {:credential_request, res_term, _url} ->
            send(test_pid, :credential_requested)
            ExGitEngine.Git.credential_deliver(res_term, :error)
        after
          10_000 -> :timeout
        end
      end)

    task =
      Task.async(fn ->
        ExGitEngine.Git.repository_fetch(
          bare,
          "http://127.0.0.1:#{port}/repo.git",
          ["+refs/heads/*:refs/heads/*"],
          runner
        )
      end)

    Task.await(task, 10_000)

    assert_received :credential_requested

    Process.exit(server, :kill)
    :gen_tcp.close(listen)
    on_exit(fn -> File.rm_rf!(tmp) end)
  end

  defp negotiate_server_loop(listen) do
    case :gen_tcp.accept(listen, 8_000) do
      {:ok, sock} ->
        drain_request(sock)

        :gen_tcp.send(sock, [
          "HTTP/1.1 401 Unauthorized\r\n",
          "WWW-Authenticate: Negotiate\r\n",
          "Content-Length: 0\r\n",
          "Connection: close\r\n",
          "\r\n"
        ])

        :gen_tcp.close(sock)
        negotiate_server_loop(listen)

      _ ->
        :ok
    end
  end

  defp basic_server_loop(listen) do
    case :gen_tcp.accept(listen, 8_000) do
      {:ok, sock} ->
        drain_request(sock)

        :gen_tcp.send(sock, [
          "HTTP/1.1 401 Unauthorized\r\n",
          "WWW-Authenticate: Basic realm=\"git\"\r\n",
          "Content-Length: 0\r\n",
          "Connection: close\r\n",
          "\r\n"
        ])

        :gen_tcp.close(sock)
        basic_server_loop(listen)

      _ ->
        :ok
    end
  end

  defp drain_request(sock) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, data} ->
        unless String.contains?(data, "\r\n\r\n"), do: drain_request(sock)

      _ ->
        :ok
    end
  end
end

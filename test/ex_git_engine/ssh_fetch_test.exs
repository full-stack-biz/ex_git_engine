defmodule ExGitEngine.SshFetchTest do
  @moduledoc """
  Tests for SSH fetch via in-memory private key PEM (argv[3] binary path in repository_fetch/4).
  """
  use ExUnit.Case, async: true

  describe "SSH key credential path" do
    # Spins up a raw TCP server that sends an SSH banner and closes immediately.
    # libssh2 gets a protocol error — not a DNS error — proving the binary PEM
    # branch in argv[3] was taken and libgit2 reached the SSH layer.
    setup do
      tmp = Path.join(System.tmp_dir(), "ssh-fetch-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      {:ok, bare_repo} =
        ExGitEngine.Git.repository_init(Path.join(tmp, "bare"), true)

      _ = bare_repo

      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      server = spawn(fn -> ssh_banner_loop(listen) end)

      private_key = :public_key.generate_key({:rsa, 2048, 65_537})
      pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, private_key)
      pem = :public_key.pem_encode([pem_entry])

      on_exit(fn ->
        Process.exit(server, :kill)
        :gen_tcp.close(listen)
        File.rm_rf!(tmp)
      end)

      %{port: port, pem: pem, tmp: tmp}
    end

    test "gets SSH protocol error, not DNS error", %{port: port, pem: pem, tmp: tmp} do
      result =
        ExGitEngine.Git.repository_fetch(
          Path.join(tmp, "bare"),
          "ssh://git@127.0.0.1:#{port}/nonexistent.git",
          ["+refs/heads/*:refs/heads/*"],
          pem
        )

      assert {:error, error} = result
      refute inspect(error) =~ ~r/resolve address/i
    end
  end

  defp ssh_banner_loop(listen) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, sock} ->
        :gen_tcp.send(sock, "SSH-2.0-TestServer\r\n")
        :gen_tcp.close(sock)
        ssh_banner_loop(listen)

      _ ->
        :ok
    end
  end
end

defmodule ExGitEngine.SshCloneTest do
  @moduledoc """
  Tests for SSH clone via in-memory private key PEM (argv[4] binary path in repository_clone/5).
  """
  use ExUnit.Case, async: true

  test "returns error for unreachable host" do
    tmp = Path.join(System.tmp_dir(), "ssh-clone-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp) end)

    result =
      ExGitEngine.Git.repository_clone(
        "ssh://does-not-exist.invalid/repo.git",
        Path.join(tmp, "clone"),
        true,
        [],
        "not-a-real-key"
      )

    assert match?({:error, _}, result)
  end

  describe "SSH key credential path" do
    # Spins up a raw TCP server that sends an SSH banner and closes immediately.
    # libssh2 gets a protocol error — not a DNS error — proving the binary PEM
    # branch in argv[4] was taken and libgit2 reached the SSH layer.
    setup do
      tmp = Path.join(System.tmp_dir(), "ssh-cred-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      server = spawn(fn -> ssh_banner_loop(listen) end)

      # Client RSA key via stdlib — no ssh-keygen needed
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
        ExGitEngine.Git.repository_clone(
          "ssh://git@127.0.0.1:#{port}/nonexistent.git",
          Path.join(tmp, "clone"),
          true,
          [],
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

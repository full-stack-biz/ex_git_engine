defmodule GitRekt.WireProtocolTest do
  use ExUnit.Case, async: true

  alias GitRekt.WireProtocol

  describe "server_capabilities/2" do
    for {service, algo, other} <- [
          {"git-upload-pack", :sha1, :sha256},
          {"git-upload-pack", :sha256, :sha1},
          {"git-receive-pack", :sha1, :sha256},
          {"git-receive-pack", :sha256, :sha1}
        ] do
      test "#{service} with #{algo} advertises object-format=#{algo}" do
        caps = WireProtocol.server_capabilities(unquote(service), unquote(algo))
        assert "object-format=#{unquote(algo)}" in caps
        refute "object-format=#{unquote(other)}" in caps
      end
    end

    test "defaults to sha1 when no algo given" do
      caps = WireProtocol.server_capabilities("git-upload-pack")
      assert "object-format=sha1" in caps
    end
  end

  describe "new/3 service validation" do
    test "returns upload pack struct for git-upload-pack" do
      assert %GitRekt.WireProtocol.UploadPack{} = WireProtocol.new(nil, "git-upload-pack", [])
    end

    test "returns receive pack struct for git-receive-pack" do
      assert %GitRekt.WireProtocol.ReceivePack{} = WireProtocol.new(nil, "git-receive-pack", [])
    end

    test "returns error for unknown service name" do
      assert {:error, :unknown_service} = WireProtocol.new(nil, "bash", [])
    end

    test "returns error for git-upload-archive (not implemented)" do
      assert {:error, :unknown_service} = WireProtocol.new(nil, "git-upload-archive", [])
    end

    test "returns error for empty string" do
      assert {:error, :unknown_service} = WireProtocol.new(nil, "", [])
    end
  end
end

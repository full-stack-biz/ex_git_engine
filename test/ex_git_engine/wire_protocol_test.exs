defmodule ExGitEngine.WireProtocolTest do
  use ExUnit.Case, async: true

  alias ExGitEngine.WireProtocol

  describe "new/3 service validation" do
    test "returns upload pack struct for git-upload-pack" do
      assert %ExGitEngine.WireProtocol.UploadPack{} =
               WireProtocol.new(nil, "git-upload-pack", [])
    end

    test "returns receive pack struct for git-receive-pack" do
      assert %ExGitEngine.WireProtocol.ReceivePack{} =
               WireProtocol.new(nil, "git-receive-pack", [])
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

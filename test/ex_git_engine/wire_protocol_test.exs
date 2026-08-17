defmodule ExGitEngine.WireProtocolTest do
  use ExUnit.Case, async: true

  alias ExGitEngine.{Git, WireProtocol}
  alias ExGitEngine.WireProtocol.UploadPack

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

  describe "pkt_line/1 variants" do
    test "flush encodes to 0000" do
      assert WireProtocol.pkt_line(:flush) == "0000"
    end

    test "nak encodes correctly" do
      encoded = WireProtocol.pkt_line(:nak)
      assert encoded =~ "NAK"
    end

    test "{:ack, oid} encodes ACK line" do
      oid = Git.oid_parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      encoded = WireProtocol.pkt_line({:ack, oid})
      assert encoded =~ "ACK"
      assert encoded =~ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    end

    test "{:ack, oid, status} includes status" do
      oid = Git.oid_parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      encoded = WireProtocol.pkt_line({:ack, oid, :ready})
      assert encoded =~ "ACK"
      assert encoded =~ "ready"
    end

    test "{:unpack, status} encodes unpack line" do
      encoded = WireProtocol.pkt_line({:unpack, "ok"})
      assert encoded =~ "unpack ok"
    end

    test "{:ok, refname} encodes ok line" do
      encoded = WireProtocol.pkt_line({:ok, "refs/heads/main"})
      assert encoded =~ "ok refs/heads/main"
    end

    test "{:ng, refname, reason} encodes ng line" do
      encoded = WireProtocol.pkt_line({:ng, "refs/heads/main", "permission denied"})
      assert encoded =~ "ng refs/heads/main permission denied"
    end
  end

  describe "pkt_line/2 delegates to pkt_line/1" do
    test "{:unpack, status}" do
      assert WireProtocol.pkt_line({:unpack, "ok"}, []) == WireProtocol.pkt_line({:unpack, "ok"})
    end

    test "{:ok, refname}" do
      assert WireProtocol.pkt_line({:ok, "refs/heads/main"}, []) ==
               WireProtocol.pkt_line({:ok, "refs/heads/main"})
    end

    test "{:ng, refname, reason}" do
      assert WireProtocol.pkt_line({:ng, "refs/heads/main", "denied"}, []) ==
               WireProtocol.pkt_line({:ng, "refs/heads/main", "denied"})
    end

    test ":nak" do
      assert WireProtocol.pkt_line(:nak, []) == WireProtocol.pkt_line(:nak)
    end
  end

  describe "decode/1" do
    test "decodes flush packet to :flush" do
      assert WireProtocol.decode("0000") |> Enum.to_list() == [:flush]
    end

    test "decodes data packet stripping trailing newline" do
      encoded = WireProtocol.pkt_line("hello")
      assert WireProtocol.decode(encoded) |> Enum.to_list() == ["hello"]
    end

    test "decodes want line to {:want, hash}" do
      hash = String.duplicate("a", 40)
      encoded = WireProtocol.pkt_line("want #{hash}")
      assert [{:want, ^hash}] = WireProtocol.decode(encoded) |> Enum.to_list()
    end

    test "decodes have line to {:have, hash}" do
      hash = String.duplicate("b", 40)
      encoded = WireProtocol.pkt_line("have #{hash}")
      assert [{:have, ^hash}] = WireProtocol.decode(encoded) |> Enum.to_list()
    end

    test "decodes done line to :done" do
      encoded = WireProtocol.pkt_line("done")
      assert WireProtocol.decode(encoded) |> Enum.to_list() == [:done]
    end

    test "decodes multiple packets in sequence" do
      data =
        WireProtocol.pkt_line("want #{String.duplicate("a", 40)}") <>
          WireProtocol.pkt_line("have #{String.duplicate("b", 40)}") <>
          "0000"

      result = WireProtocol.decode(data) |> Enum.to_list()
      assert length(result) == 3
      assert {:want, _} = Enum.at(result, 0)
      assert {:have, _} = Enum.at(result, 1)
      assert :flush = Enum.at(result, 2)
    end
  end

  describe "done?/1" do
    test "returns true when state is :done" do
      handle = %UploadPack{state: :done}
      assert WireProtocol.done?(handle)
    end

    test "returns false for non-done state" do
      handle = %UploadPack{state: :disco}
      refute WireProtocol.done?(handle)
    end
  end

  describe "skip/1" do
    test "delegates to the service module's skip/1" do
      handle = %UploadPack{state: :upload_haves}
      skipped = WireProtocol.skip(handle)
      assert skipped.state == :pack
    end
  end

  describe "next/2 with binary data" do
    test "decodes PKT-LINE binary and drives state machine" do
      handle = %UploadPack{
        state: :upload_req,
        advertised_caps: WireProtocol.server_capabilities("git-upload-pack")
      }

      # "0000" is PKT-LINE flush — upload_req treats it as empty request → done
      {:halt, new_handle, _output} = WireProtocol.next(handle, "0000")
      assert new_handle.state == :done
    end

  end
end

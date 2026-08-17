defmodule ExGitEngine.WireProtocol.UploadPackTest do
  use ExUnit.Case

  alias ExGitEngine.WireProtocol.UploadPack

  # Test double for disco_transition_state tests
  defmodule TestAgent do
    defstruct []
  end

  describe "ack_haves/2" do
    test "empty list returns empty" do
      assert UploadPack.ack_haves([], ["multi_ack"]) == []
    end

    test "single have with multi_ack returns ready" do
      have = <<1::256>>
      assert UploadPack.ack_haves([have], ["multi_ack"]) == [{:ack, have, :ready}]
    end

    test "single have with multi_ack_detailed returns ready" do
      have = <<1::256>>
      assert UploadPack.ack_haves([have], ["multi_ack_detailed"]) == [{:ack, have, :ready}]
    end

    test "single have without multi_ack returns ack only" do
      have = <<1::256>>
      assert UploadPack.ack_haves([have], []) == [{:ack, have}]
    end

    test "multiple haves with multi_ack" do
      have1 = <<1::256>>
      have2 = <<2::256>>

      assert UploadPack.ack_haves([have1, have2], ["multi_ack"]) == [
               {:ack, have1, :continue},
               {:ack, have2, :ready}
             ]
    end

    test "multiple haves with multi_ack_detailed" do
      have1 = <<1::256>>
      have2 = <<2::256>>

      assert UploadPack.ack_haves([have1, have2], ["multi_ack_detailed"]) == [
               {:ack, have1, :common},
               {:ack, have2, :ready}
             ]
    end

    test "multiple haves without multi_ack" do
      have1 = <<1::256>>
      have2 = <<2::256>>

      assert UploadPack.ack_haves([have1, have2], []) == [
               {:ack, have1},
               {:ack, have2}
             ]
    end

    test "three haves with multi_ack" do
      have1 = <<1::256>>
      have2 = <<2::256>>
      have3 = <<3::256>>

      assert UploadPack.ack_haves([have1, have2, have3], ["multi_ack"]) == [
               {:ack, have1, :continue},
               {:ack, have2, :continue},
               {:ack, have3, :ready}
             ]
    end
  end

  describe "object-format=sha1 capability" do
    test "client echoing object-format=sha1 in want line is not rejected as unknown" do
      # git/connect.c: when server advertises object-format=sha1, client echoes it back
      # in the first want line's capability string.
      # validate_capabilities must accept it; otherwise upload_req raises and fetch fails.
      handle = UploadPack.skip(%UploadPack{state: :disco, no_done: false})
      oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      lines = [{:want, "#{oid} multi_ack_detailed object-format=sha1"}, :flush]

      {new_handle, _remaining, _output} = UploadPack.next(handle, lines)

      assert "object-format=sha1" in new_handle.caps
    end
  end

  describe "side-band advertisement" do
    test "side-band is in base server capabilities for git-upload-pack" do
      caps = ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      assert "side-band" in caps
    end

    test "side-band-64k is in base server capabilities for git-upload-pack" do
      caps = ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      assert "side-band-64k" in caps
    end

    test "client sending side-band-64k is not rejected as unknown" do
      advertised = ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      unknown = ExGitEngine.WireProtocol.validate_capabilities(["side-band-64k"], advertised)
      assert unknown == []
    end
  end

  describe "pack sideband framing" do
    test "pkt_line {:sideband_pack, ch, data} frames without newline" do
      data = "hello"
      encoded = ExGitEngine.WireProtocol.pkt_line({:sideband_pack, 1, data})

      # size = byte_size("hello") + 5 = 10 = 0x000a
      assert <<size::binary-size(4), channel::binary-size(1), payload::binary>> = encoded
      assert size == "000a"
      assert channel == <<1>>
      assert payload == "hello"
    end

    test "pkt_line {:sideband_pack, ch, data} does not append newline" do
      data = "binary\x00data"
      encoded = ExGitEngine.WireProtocol.pkt_line({:sideband_pack, 1, data})
      assert String.ends_with?(encoded, data)
      refute String.ends_with?(encoded, "\n")
    end

    test "pack_to_sideband_frames chunks at side-band-64k boundary (65515 bytes)" do
      pack = :binary.copy(<<0>>, 65_515 + 100)
      frames = UploadPack.pack_to_sideband_frames(pack, 65_515)

      assert length(frames) == 2
      assert {:sideband_pack, 1, chunk1} = Enum.at(frames, 0)
      assert {:sideband_pack, 1, chunk2} = Enum.at(frames, 1)
      assert byte_size(chunk1) == 65_515
      assert byte_size(chunk2) == 100
    end

    test "pack_to_sideband_frames exact boundary produces one frame" do
      pack = :binary.copy(<<0>>, 995)
      frames = UploadPack.pack_to_sideband_frames(pack, 995)

      assert length(frames) == 1
      assert {:sideband_pack, 1, chunk} = Enum.at(frames, 0)
      assert byte_size(chunk) == 995
    end

    test "pack_to_sideband_frames preserves all bytes across chunks" do
      pack = :crypto.strong_rand_bytes(200)
      frames = UploadPack.pack_to_sideband_frames(pack, 100)

      assert length(frames) == 2

      reassembled =
        Enum.reduce(frames, <<>>, fn {:sideband_pack, 1, chunk}, acc -> acc <> chunk end)

      assert reassembled == pack
    end
  end

  describe "server capability advertisement" do
    test "ofs-delta is in base server capabilities for git-upload-pack" do
      caps = ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      assert "ofs-delta" in caps
    end

    test "client sending ofs-delta is not rejected as unknown" do
      advertised = ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      unknown = ExGitEngine.WireProtocol.validate_capabilities(["ofs-delta"], advertised)
      assert unknown == []
    end

    test "no-done is not in base server capabilities" do
      # no-done is stateless-RPC-only per git/fetch-pack.c:1138:
      #   if (args->stateless_rpc) no_done = 1;
      # SSH clients ignore it even when advertised, but advertising it on SSH
      # is misleading. It belongs only in HTTP's transport-level extras.
      caps = ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      refute "no-done" in caps
    end

    test "base server capabilities include multi_ack and multi_ack_detailed" do
      caps = ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      assert "multi_ack" in caps
      assert "multi_ack_detailed" in caps
    end
  end

  describe "next/2 upload_req state" do
    test "flush packet transitions to :done" do
      handle = %UploadPack{
        state: :upload_req,
        advertised_caps: ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      }

      {new_handle, remaining, output} = UploadPack.next(handle, [:flush])
      assert new_handle.state == :done
      assert remaining == []
      assert output == []
    end

    test "want lines with caps transition to :upload_haves" do
      handle = %UploadPack{
        state: :upload_req,
        advertised_caps: ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      }

      oid = String.duplicate("a", 40)
      lines = [{:want, "#{oid} multi_ack_detailed"}, :flush]

      {new_handle, _remaining, output} = UploadPack.next(handle, lines)
      assert new_handle.state == :upload_haves
      assert "multi_ack_detailed" in new_handle.caps
      assert is_list(new_handle.wants)
      assert output == []
    end

    test "want lines without caps transition to :upload_haves" do
      handle = %UploadPack{
        state: :upload_req,
        advertised_caps: ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      }

      oid = String.duplicate("b", 40)
      lines = [{:want, oid}, :flush]

      {new_handle, _remaining, _output} = UploadPack.next(handle, lines)
      assert new_handle.state == :upload_haves
      assert new_handle.caps == []
    end
  end

  describe "next/2 upload_haves state" do
    test "empty lines transitions to :done" do
      handle = %UploadPack{state: :upload_haves, caps: [], haves: []}

      {new_handle, remaining, output} = UploadPack.next(handle, [])
      assert new_handle.state == :done
      assert remaining == []
      assert output == []
    end

    test "flush with no haves returns nak and stays in :upload_haves" do
      handle = %UploadPack{state: :upload_haves, caps: [], haves: []}

      {new_handle, remaining, output} = UploadPack.next(handle, [:flush])
      assert new_handle.state == :upload_haves
      assert :nak in output
      assert remaining == []
    end

    test "flush with haves and no no-done returns acks plus nak" do
      oid = :crypto.strong_rand_bytes(20)
      handle = %UploadPack{state: :upload_haves, caps: [], haves: [oid]}

      {_new_handle, _remaining, output} = UploadPack.next(handle, [:flush])
      assert Enum.any?(output, &match?({:ack, ^oid}, &1))
      assert :nak in output
    end

    test "flush with no-done and multi_ack transitions to :pack" do
      oid = :crypto.strong_rand_bytes(20)

      handle = %UploadPack{
        state: :upload_haves,
        caps: ["no-done", "multi_ack"],
        haves: [oid]
      }

      {new_handle, _remaining, output} = UploadPack.next(handle, [:flush])
      assert new_handle.state == :pack
      assert :nak in output
      assert Enum.any?(output, &match?({:ack, ^oid}, &1))
    end

    test ":done line transitions to :pack then tries pack_create" do
      # :done with empty wants/haves and nil agent → exec returns {:error, reason}
      # → {:ok, pack} = {:error, reason} raises MatchError
      # This confirms the :done clause transitions state before hitting the agent call
      handle = %UploadPack{state: :upload_haves, caps: [], haves: [], wants: [], agent: nil}

      assert_raise MatchError, fn -> UploadPack.next(handle, [:done]) end
    end
  end

  describe "next/2 pack state" do
    test "non-empty lines are a pass-through (data pending)" do
      handle = %UploadPack{state: :pack, caps: [], haves: [], wants: [], agent: nil}
      lines = ["some", "data"]

      {new_handle, remaining, output} = UploadPack.next(handle, lines)
      assert new_handle.state == :pack
      assert remaining == lines
      assert output == []
    end
  end

  describe "next/2 done state" do
    test "empty lines returns done state with no output" do
      handle = %UploadPack{state: :done}

      {new_handle, remaining, output} = UploadPack.next(handle, [])
      assert new_handle.state == :done
      assert remaining == []
      assert output == []
    end
  end

  describe "skip/1 state transitions" do
    test "upload_req → upload_haves" do
      handle = %UploadPack{
        state: :upload_req,
        advertised_caps: ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      }

      assert %UploadPack{state: :upload_haves} = UploadPack.skip(handle)
    end

    test "upload_haves → pack" do
      handle = %UploadPack{state: :upload_haves}
      assert %UploadPack{state: :pack} = UploadPack.skip(handle)
    end

    test "pack → done" do
      handle = %UploadPack{state: :pack}
      assert %UploadPack{state: :done} = UploadPack.skip(handle)
    end

    test "done → done (no-op)" do
      handle = %UploadPack{state: :done}
      assert %UploadPack{state: :done} = UploadPack.skip(handle)
    end
  end

  describe "next/2 disco state" do
    test "transitions to :done state" do
      handle = %UploadPack{state: :disco, no_done: false, advertised_caps: []}

      new_handle = UploadPack.disco_transition_state(handle, :done)

      assert new_handle.state == :done
      assert new_handle.advertised_caps != []
    end

    test "transitions to :upload_req state" do
      handle = %UploadPack{state: :disco, no_done: false, advertised_caps: []}

      new_handle = UploadPack.disco_transition_state(handle, :upload_req)

      assert new_handle.state == :upload_req
      assert new_handle.advertised_caps != []
    end

    test "no-done in advertised_caps when no_done is true" do
      handle = %UploadPack{state: :disco, no_done: true, advertised_caps: []}

      new_handle = UploadPack.disco_transition_state(handle, :done)

      assert Enum.all?(new_handle.advertised_caps, &is_binary/1)
      assert "no-done" in new_handle.advertised_caps
    end

    test "no-done absent from advertised_caps when no_done is false" do
      handle = %UploadPack{state: :disco, no_done: false, advertised_caps: []}

      new_handle = UploadPack.disco_transition_state(handle, :done)

      refute "no-done" in new_handle.advertised_caps
    end

    test "includes server capabilities in advertised_caps" do
      handle = %UploadPack{state: :disco, no_done: false, advertised_caps: []}

      new_handle = UploadPack.disco_transition_state(handle, :done)

      assert Enum.any?(new_handle.advertised_caps, &String.contains?(&1, "multi_ack"))
    end

    test "preserves agent reference" do
      agent = %TestAgent{}
      handle = %UploadPack{state: :disco, no_done: false, advertised_caps: [], agent: agent}

      new_handle = UploadPack.disco_transition_state(handle, :done)

      assert new_handle.agent == agent
    end

    test "skip from disco state builds advertised_caps from no_done" do
      # HTTP POST creates a new UploadPack per request. It must build advertised_caps
      # reflecting the same no_done flag used in the GET reference_discovery, so that
      # validate_capabilities accepts what the client learned from the GET response.
      handle = %UploadPack{state: :disco, no_done: true, advertised_caps: []}
      skipped = UploadPack.skip(handle)

      assert skipped.state == :upload_req
      assert "no-done" in skipped.advertised_caps
    end
  end
end

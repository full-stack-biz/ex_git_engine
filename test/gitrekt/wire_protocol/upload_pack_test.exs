defmodule GitRekt.WireProtocol.UploadPackTest do
  use ExUnit.Case

  alias GitRekt.WireProtocol.UploadPack

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

  describe "server capability advertisement" do
    test "no-done is not in base server capabilities" do
      # no-done is stateless-RPC-only per git/fetch-pack.c:1138:
      #   if (args->stateless_rpc) no_done = 1;
      # SSH clients ignore it even when advertised, but advertising it on SSH
      # is misleading. It belongs only in HTTP's transport-level extras.
      caps = GitRekt.WireProtocol.server_capabilities("git-upload-pack")
      refute "no-done" in caps
    end

    test "base server capabilities include multi_ack and multi_ack_detailed" do
      caps = GitRekt.WireProtocol.server_capabilities("git-upload-pack")
      assert "multi_ack" in caps
      assert "multi_ack_detailed" in caps
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

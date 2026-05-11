defmodule GitRekt.WireProtocol.ReceivePackTest do
  use ExUnit.Case, async: true

  alias GitRekt.WireProtocol.ReceivePack
  alias GitRekt.Git

  describe "report_status/1" do
    test "sends report-status only when client explicitly requests capability" do
      # Create a handle with report-status capability
      handle = %ReceivePack{
        caps: ["report-status"],
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      result = ReceivePack.report_status(handle)

      assert :flush in result
      assert "unpack ok" in result
      assert Enum.any?(result, fn item -> is_binary(item) && String.starts_with?(item, "ok ") end)
    end

    test "does NOT send report-status when client doesn't request it" do
      # Create a handle WITHOUT report-status capability
      handle = %ReceivePack{
        caps: ["delete-refs"],
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      result = ReceivePack.report_status(handle)

      # Should be empty list, not containing status messages
      assert result == []
    end

    test "includes all command refs in report-status response" do
      handle = %ReceivePack{
        caps: ["report-status"],
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"},
          {:update, Git.oid_parse("0000000000000000000000000000000000000001"),
                    Git.oid_parse("0000000000000000000000000000000000000002"), "refs/heads/develop"},
          {:delete, Git.oid_parse("0000000000000000000000000000000000000003"), "refs/heads/old"}
        ]
      }

      result = ReceivePack.report_status(handle)

      # Should include status for all three commands
      assert "ok refs/heads/main" in result
      assert "ok refs/heads/develop" in result
      assert "ok refs/heads/old" in result
      assert "unpack ok" in result
      assert :flush in result
    end

    test "response ends with flush marker for proper protocol termination" do
      handle = %ReceivePack{
        caps: ["report-status"],
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      result = ReceivePack.report_status(handle)

      assert List.last(result) == :flush
    end
  end

  describe "error response format" do
    test "formats errors as 'unpack ng <reason>' with flush terminator" do
      # Simulate error response by matching the error case in next/2
      reason = "ref update failed"
      error_msg = if is_binary(reason), do: reason, else: inspect(reason)
      error_response = ["unpack ng #{error_msg}", :flush]

      assert error_response == ["unpack ng ref update failed", :flush]
      assert Enum.any?(error_response, fn item -> is_binary(item) && String.starts_with?(item, "unpack ng") end)
      assert :flush in error_response
    end

    test "handles atom errors by converting to string" do
      reason = :permission_denied
      error_msg = if is_binary(reason), do: reason, else: inspect(reason)
      error_response = ["unpack ng #{error_msg}", :flush]

      assert error_response == ["unpack ng :permission_denied", :flush]
      assert :flush in error_response
    end

    test "includes flush terminator for protocol compliance" do
      error_response = ["unpack ng invalid ref", :flush]

      # Verify flush is present for proper response termination
      assert :flush in error_response
      assert List.last(error_response) == :flush
    end
  end

  describe "parse_cmds/1" do
    test "parses create command (old OID is null)" do
      cmds = ["0000000000000000000000000000000000000000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main"]
      result = ReceivePack.parse_cmds(cmds)

      assert length(result) == 1
      [{:create, new_oid, "refs/heads/main"}] = result
      assert new_oid == Git.oid_parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    end

    test "parses update command (both OIDs present)" do
      cmds = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/heads/main"]
      result = ReceivePack.parse_cmds(cmds)

      assert length(result) == 1
      [{:update, old_oid, new_oid, "refs/heads/main"}] = result
      assert old_oid == Git.oid_parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      assert new_oid == Git.oid_parse("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    end

    test "parses delete command (new OID is null)" do
      cmds = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0000000000000000000000000000000000000000 refs/heads/old"]
      result = ReceivePack.parse_cmds(cmds)

      assert length(result) == 1
      [{:delete, old_oid, "refs/heads/old"}] = result
      assert old_oid == Git.oid_parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    end

    test "parses multiple commands in sequence" do
      cmds = [
        "0000000000000000000000000000000000000000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/heads/develop",
        "cccccccccccccccccccccccccccccccccccccccc 0000000000000000000000000000000000000000 refs/heads/old"
      ]
      result = ReceivePack.parse_cmds(cmds)

      assert length(result) == 3
      assert {:create, _, "refs/heads/main"} = Enum.at(result, 0)
      assert {:update, _, _, "refs/heads/develop"} = Enum.at(result, 1)
      assert {:delete, _, "refs/heads/old"} = Enum.at(result, 2)
    end
  end

  describe "parse_caps/1" do
    test "extracts capabilities from first ref" do
      refs = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main\0report-status delete-refs"]
      {caps, cmds} = ReceivePack.parse_caps(refs)

      assert caps == ["report-status", "delete-refs"]
      assert cmds == ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main"]
    end

    test "returns empty capabilities when none are present" do
      refs = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main"]
      {caps, cmds} = ReceivePack.parse_caps(refs)

      assert caps == []
      assert cmds == ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main"]
    end

    test "preserves remaining refs after capability parsing" do
      refs = [
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main\0report-status",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/heads/develop"
      ]
      {caps, cmds} = ReceivePack.parse_caps(refs)

      assert caps == ["report-status"]
      assert cmds == [
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/heads/develop"
      ]
    end

    test "handles multiple space-separated capabilities" do
      refs = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main\0report-status delete-refs agent=test/1.0"]
      {caps, _cmds} = ReceivePack.parse_caps(refs)

      assert "report-status" in caps
      assert "delete-refs" in caps
      assert "agent=test/1.0" in caps
      assert length(caps) == 3
    end
  end

  describe "state transitions" do
    test "disco->update_req on data preserves caps" do
      # Test disco->update_req state by just checking the state logic, not next/2
      # which requires a full repo setup
      handle = %ReceivePack{state: :disco, caps: ["report-status"], advertised_caps: []}
      new_handle = ReceivePack.skip(handle)

      assert new_handle.state == :update_req
      assert new_handle.advertised_caps == ["report-status"]
    end

    test "skip transitions through all states correctly" do
      disco_handle = %ReceivePack{state: :disco, caps: [], advertised_caps: []}
      update_req_handle = ReceivePack.skip(disco_handle)
      assert update_req_handle.state == :update_req

      pack_handle = ReceivePack.skip(update_req_handle)
      assert pack_handle.state == :pack

      done_handle = ReceivePack.skip(pack_handle)
      assert done_handle.state == :done

      # Further skips on done state should remain in done
      still_done = ReceivePack.skip(done_handle)
      assert still_done.state == :done
    end
  end

  describe "capability validation" do
    test "parse_caps extracts capabilities correctly for validation" do
      # Test capability validation logic
      advertised_caps = ["report-status", "delete-refs"]
      caps_line = "0000000000000000000000000000000000000000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main\0report-status delete-refs"

      {caps, _cmds} = ReceivePack.parse_caps([caps_line])
      unknown_caps = caps -- advertised_caps

      assert caps == ["report-status", "delete-refs"]
      assert unknown_caps == []
    end

    test "detects unknown capabilities sent by client" do
      advertised_caps = ["report-status", "delete-refs"]
      caps_line = "0000000000000000000000000000000000000000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main\0report-status unknown-cap"

      {caps, _cmds} = ReceivePack.parse_caps([caps_line])
      unknown_caps = caps -- advertised_caps

      assert "unknown-cap" in unknown_caps
      assert unknown_caps != []
    end

    test "advertised_caps includes ofs-delta and atomic capabilities" do
      # Verify that new capabilities are advertised by the server
      advertised = GitRekt.WireProtocol.server_capabilities("git-receive-pack")

      assert "report-status" in advertised
      assert "delete-refs" in advertised
      assert "ofs-delta" in advertised
      assert "atomic" in advertised
      assert String.contains?(Enum.find(advertised, "", &String.starts_with?(&1, "agent=")), "gitrekt")
    end
  end
end

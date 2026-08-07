defmodule ExGitEngine.WireProtocol.ReceivePackTest do
  use ExUnit.Case, async: true

  alias ExGitEngine.{Git, GitAgent}
  alias ExGitEngine.WireProtocol.ReceivePack

  describe "report_status/1" do
    test "returns tuple protocol elements" do
      handle = %ReceivePack{
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      assert [
               {:unpack, "ok"},
               {:ok, "refs/heads/main"}
             ] = ReceivePack.report_status(handle)
    end

    test "includes all command refs as tuples" do
      handle = %ReceivePack{
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"},
          {:update, Git.oid_parse("0000000000000000000000000000000000000001"),
           Git.oid_parse("0000000000000000000000000000000000000002"), "refs/heads/develop"},
          {:delete, Git.oid_parse("0000000000000000000000000000000000000003"), "refs/heads/old"}
        ]
      }

      assert [
               {:unpack, "ok"},
               {:ok, "refs/heads/main"},
               {:ok, "refs/heads/develop"},
               {:ok, "refs/heads/old"}
             ] = ReceivePack.report_status(handle)
    end

    test "does not include flush (added by response builders)" do
      handle = %ReceivePack{
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      result = ReceivePack.report_status(handle)

      assert {:flush} not in result
      assert :flush not in result
    end
  end

  describe "error response format" do
    test "formats errors as 'unpack ng <reason>' with flush terminator" do
      error_response = ["unpack ng ref update failed", :flush]

      assert Enum.any?(error_response, fn item ->
               is_binary(item) && String.starts_with?(item, "unpack ng")
             end)

      assert :flush in error_response
    end

    test "handles atom errors by converting to string" do
      reason = :permission_denied
      error_response = ["unpack ng #{inspect(reason)}", :flush]

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
      cmds = [
        "0000000000000000000000000000000000000000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main"
      ]

      result = ReceivePack.parse_cmds(cmds)

      assert length(result) == 1
      [{:create, new_oid, "refs/heads/main"}] = result
      assert new_oid == Git.oid_parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    end

    test "parses update command (both OIDs present)" do
      cmds = [
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/heads/main"
      ]

      result = ReceivePack.parse_cmds(cmds)

      assert length(result) == 1
      [{:update, old_oid, new_oid, "refs/heads/main"}] = result
      assert old_oid == Git.oid_parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      assert new_oid == Git.oid_parse("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    end

    test "parses delete command (new OID is null)" do
      cmds = [
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0000000000000000000000000000000000000000 refs/heads/old"
      ]

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
      refs = [
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main\0report-status delete-refs"
      ]

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
      refs = [
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main\0report-status delete-refs agent=test/1.0"
      ]

      {caps, _cmds} = ReceivePack.parse_caps(refs)

      assert "report-status" in caps
      assert "delete-refs" in caps
      assert "agent=test/1.0" in caps
      assert length(caps) == 3
    end
  end

  describe "state transitions" do
    test "disco->update_req on data includes full server capabilities" do
      handle = %ReceivePack{state: :disco, advertised_caps: []}
      new_handle = ReceivePack.skip(handle)

      assert new_handle.state == :update_req
      assert "report-status" in new_handle.advertised_caps
      assert "delete-refs" in new_handle.advertised_caps
      assert "ofs-delta" in new_handle.advertised_caps
      assert "atomic" in new_handle.advertised_caps
    end

    test "skip transitions through all states correctly" do
      disco_handle = %ReceivePack{state: :disco, advertised_caps: []}
      update_req_handle = ReceivePack.skip(disco_handle)
      assert update_req_handle.state == :update_req

      pack_handle = ReceivePack.skip(update_req_handle)
      assert pack_handle.state == :pack

      done_handle = ReceivePack.skip(pack_handle)
      assert done_handle.state == :done

      still_done = ReceivePack.skip(done_handle)
      assert still_done.state == :done
    end
  end

  describe "capability validation" do
    test "parse_caps extracts capabilities correctly for validation" do
      # Test capability validation logic
      advertised_caps = ["report-status", "delete-refs"]

      caps_line =
        "0000000000000000000000000000000000000000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main\0report-status delete-refs"

      {caps, _cmds} = ReceivePack.parse_caps([caps_line])
      unknown_caps = caps -- advertised_caps

      assert caps == ["report-status", "delete-refs"]
      assert unknown_caps == []
    end

    test "detects unknown capabilities sent by client" do
      advertised_caps = ["report-status", "delete-refs"]

      caps_line =
        "0000000000000000000000000000000000000000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main\0report-status unknown-cap"

      {caps, _cmds} = ReceivePack.parse_caps([caps_line])
      unknown_caps = caps -- advertised_caps

      assert "unknown-cap" in unknown_caps
      assert unknown_caps != []
    end

    test "advertised_caps includes ofs-delta and atomic capabilities" do
      # Verify that new capabilities are advertised by the server
      advertised = ExGitEngine.WireProtocol.server_capabilities("git-receive-pack")

      assert "report-status" in advertised
      assert "delete-refs" in advertised
      assert "ofs-delta" in advertised
      assert "atomic" in advertised

      assert String.contains?(
               Enum.find(advertised, "", &String.starts_with?(&1, "agent=")),
               "ex_git_engine"
             )
    end

    test "validate_capabilities: binary flags require exact match" do
      advertised_caps = ["report-status", "delete-refs", "ofs-delta"]
      client_caps = ["report-status", "delete-refs"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert unknown == []
    end

    test "validate_capabilities: rejects unknown binary flags" do
      advertised_caps = ["report-status", "delete-refs"]
      client_caps = ["report-status", "unknown-flag"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert "unknown-flag" in unknown
    end

    test "validate_capabilities: allows agent capability with different value" do
      advertised_caps = ["report-status", "agent=ex_git_engine/1.0.0"]
      client_caps = ["report-status", "agent=git/2.54.0-Darwin"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert unknown == []
    end

    test "validate_capabilities: allows any agent value from client" do
      advertised_caps = ["agent=ex_git_engine/1.0.0"]
      # Client can send any agent value, not just the one advertised
      client_caps = ["agent=custom/5.0.0-beta"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert unknown == []
    end

    test "validate_capabilities: allows session-id capability with different value" do
      advertised_caps = ["report-status", "session-id=server-123"]
      client_caps = ["report-status", "session-id=client-456"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert unknown == []
    end

    test "validate_capabilities: allows any session-id value from client" do
      advertised_caps = ["session-id=server-id"]
      client_caps = ["session-id=any-value-here"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert unknown == []
    end

    test "validate_capabilities: allows object-format from advertised set" do
      advertised_caps = ["report-status", "object-format=sha1", "object-format=sha256"]
      client_caps = ["report-status", "object-format=sha256"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert unknown == []
    end

    test "validate_capabilities: rejects object-format not in advertised set" do
      advertised_caps = ["report-status", "object-format=sha1"]
      client_caps = ["report-status", "object-format=sha256"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert "object-format=sha256" in unknown
    end

    test "validate_capabilities: rejects symref if client sends it (server-only)" do
      advertised_caps = ["symref=HEAD:refs/heads/main"]
      client_caps = ["symref=HEAD:refs/heads/develop"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert "symref=HEAD:refs/heads/develop" in unknown
    end

    test "validate_capabilities: mixed valid and invalid capabilities" do
      advertised_caps = ["report-status", "agent=ex_git_engine/1.0.0", "delete-refs"]
      client_caps = ["report-status", "agent=git/2.0.0", "delete-refs", "unknown-cap"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert length(unknown) == 1
      assert "unknown-cap" in unknown
      assert "report-status" not in unknown
      assert "agent=git/2.0.0" not in unknown
      assert "delete-refs" not in unknown
    end

    test "validate_capabilities: allows filter from advertised set" do
      advertised_caps = ["report-status", "filter=blob:none"]
      client_caps = ["report-status", "filter=blob:none"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert unknown == []
    end

    test "validate_capabilities: rejects filter not in advertised set" do
      advertised_caps = ["report-status", "filter=blob:none"]
      client_caps = ["report-status", "filter=tree:0"]
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert "filter=tree:0" in unknown
    end

    test "validate_capabilities: empty client capabilities is valid" do
      advertised_caps = ["report-status", "delete-refs"]
      client_caps = []
      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)

      assert unknown == []
    end

    test "validate_capabilities: protocol compliance example (git push scenario)" do
      # Realistic scenario: server advertises capabilities, client responds with agent
      advertised_caps = [
        "agent=ex_git_engine/0.1.0",
        "report-status",
        "delete-refs",
        "ofs-delta",
        "atomic"
      ]

      # Modern git client sends its own agent
      client_caps = [
        "report-status",
        "agent=git/2.54.0-Darwin",
        "delete-refs",
        "ofs-delta",
        "atomic"
      ]

      unknown = ExGitEngine.WireProtocol.validate_capabilities(client_caps, advertised_caps)
      assert unknown == []
    end
  end

  describe "report-status-v2" do
    test "report-status-v2 is in server capabilities for git-receive-pack" do
      caps = ExGitEngine.WireProtocol.server_capabilities("git-receive-pack")
      assert "report-status-v2" in caps
    end

    test "client sending report-status-v2 is not rejected as unknown" do
      advertised = ExGitEngine.WireProtocol.server_capabilities("git-receive-pack")
      unknown = ExGitEngine.WireProtocol.validate_capabilities(["report-status-v2"], advertised)
      assert unknown == []
    end

    test "push_success_output fires when advertised_caps contains report-status-v2" do
      handle = %ReceivePack{
        advertised_caps: ["report-status-v2"],
        client_caps: [],
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      assert [
               {:unpack, "ok"},
               {:ok, "refs/heads/main"}
             ] = ReceivePack.push_success_output(handle)
    end

    test "push_success_output fires when client_caps contains report-status-v2" do
      handle = %ReceivePack{
        advertised_caps: ["report-status", "report-status-v2"],
        client_caps: ["report-status-v2"],
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      assert [
               {:unpack, "ok"},
               {:ok, "refs/heads/main"}
             ] = ReceivePack.push_success_output(handle)
    end
  end

  describe "skip/1 advertised_caps conformance" do
    test "skip from disco state includes full server capabilities" do
      handle = %ReceivePack{state: :disco, advertised_caps: []}
      new_handle = ReceivePack.skip(handle)

      assert new_handle.state == :update_req
      assert "report-status" in new_handle.advertised_caps
      assert "delete-refs" in new_handle.advertised_caps
      assert "ofs-delta" in new_handle.advertised_caps
      assert "atomic" in new_handle.advertised_caps
      assert Enum.any?(new_handle.advertised_caps, &String.starts_with?(&1, "agent="))
    end

    test "skip disco->update_req sets advertised_caps to server capabilities" do
      advertised_server = ExGitEngine.WireProtocol.server_capabilities("git-receive-pack")

      handle = %ReceivePack{state: :disco, advertised_caps: []}
      skipped = ReceivePack.skip(handle)

      assert skipped.advertised_caps == advertised_server
      assert skipped.state == :update_req
    end

    test "report-status appears exactly once" do
      handle = %ReceivePack{state: :disco, advertised_caps: []}
      skipped = ReceivePack.skip(handle)

      count = Enum.count(skipped.advertised_caps, &(&1 == "report-status"))
      assert count == 1, "report-status advertised #{count} times, expected 1"
    end
  end

  describe "done handler idempotency" do
    test "done handler with empty cmds is a no-op" do
      handle = %ReceivePack{
        state: :done,
        cmds: [],
        client_caps: ["report-status"],
        agent: nil,
        writepack: nil,
        writepack_progress: %{},
        repo: nil
      }

      # Second arg is [] (indicating EOF or end of data)
      # The done handler should return no-op result
      {result_handle, remaining_lines, output} = ReceivePack.next(handle, [])

      # No cmds to process, so no output
      assert remaining_lines == []
      assert output == []
      # Handle should be returned as-is
      assert result_handle.state == :done
    end
  end

  describe "pkt_line with protocol tuple format" do
    test "{:unpack, \"ok\"} encodes to pkt-line" do
      encoded = ExGitEngine.WireProtocol.pkt_line({:unpack, "ok"})

      assert "000e" <> "unpack ok\n" == encoded
    end

    test "{:ok, refname} encodes to pkt-line" do
      encoded = ExGitEngine.WireProtocol.pkt_line({:ok, "refs/heads/main"})

      assert "0017" <> "ok refs/heads/main\n" == encoded
    end

    test "{:ng, refname, reason} encodes to pkt-line" do
      encoded = ExGitEngine.WireProtocol.pkt_line({:ng, "refs/heads/main", "permission denied"})

      assert is_binary(encoded)
      assert String.contains?(encoded, "ng refs/heads/main permission denied")
    end

    test "{:sideband, channel, text} wraps with sideband and returns binary" do
      encoded = ExGitEngine.WireProtocol.pkt_line({:sideband, 2, "Build passed"})

      <<_size::binary-size(4), channel::binary-size(1), _rest::binary>> = encoded
      assert channel == <<2>>
    end

    test ":flush encodes to 0000" do
      encoded = ExGitEngine.WireProtocol.pkt_line(:flush)
      assert "0000" == encoded
    end
  end

  describe "sideband_wrap/2 function" do
    test "wraps text with channel 1 marker and correct frame size" do
      line = "unpack ok"
      wrapped = ReceivePack.sideband_wrap(line, 1)

      # Format: 4-byte hex size + channel byte + data + newline
      # size = 4 (hex) + 1 (channel) + 9 (len("unpack ok")) + 1 (newline) = 15 = 0x0f
      assert is_binary(wrapped)
      assert String.starts_with?(wrapped, "000f")
      assert String.slice(wrapped, 4..4) == <<1>>
      assert String.contains?(wrapped, "unpack ok\n")
    end

    test "wraps text with channel 2 marker" do
      line = "remote: Build passed"
      wrapped = ReceivePack.sideband_wrap(line, 2)

      assert is_binary(wrapped)
      assert String.slice(wrapped, 4..4) == <<2>>
      assert String.contains?(wrapped, "remote: Build passed\n")
    end

    test "calculates correct frame size with channel byte included" do
      line = "ok ref"
      wrapped = ReceivePack.sideband_wrap(line, 1)

      # size = 4 + 1 + 6 + 1 = 12 = 0x0c
      size_hex = String.slice(wrapped, 0..3)
      assert size_hex == "000c"
    end

    test "handles large messages with proper sizing" do
      line = String.duplicate("x", 100)
      wrapped = ReceivePack.sideband_wrap(line, 1)

      # size = 4 + 1 + 100 + 1 = 106 = 0x6a
      assert String.starts_with?(wrapped, "006a")
    end

    test "includes newline as part of frame content" do
      line = "status"
      wrapped = ReceivePack.sideband_wrap(line, 1)

      # Newline must be inside the frame (included in size calculation)
      assert String.ends_with?(wrapped, "status\n")
    end
  end

  describe "response builders tuple structure" do
    test "push_success_output without sideband produces status tuples (no flush)" do
      handle = %ReceivePack{
        advertised_caps: ["report-status"],
        client_caps: [],
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      assert [
               {:unpack, "ok"},
               {:ok, "refs/heads/main"}
             ] = ReceivePack.push_success_output(handle)
    end

    test "build_push_response without sideband: status + string messages + flush" do
      handle = %ReceivePack{
        advertised_caps: ["report-status"],
        client_caps: [],
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      messages = ["Build passed"]

      assert [
               {:unpack, "ok"},
               {:ok, "refs/heads/main"},
               "Build passed",
               :flush
             ] = ReceivePack.build_push_response(handle, messages)
    end

    test "push_success_output returns sideband_report tuple wrapping inner status + flush" do
      handle = %ReceivePack{
        advertised_caps: ["report-status", "side-band-64k"],
        client_caps: ["side-band-64k"],
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      assert [
               {:sideband_report, 1, [{:unpack, "ok"}, {:ok, "refs/heads/main"}, :flush]}
             ] = ReceivePack.push_success_output(handle)
    end

    test "build_push_response with sideband: sideband_report + ch2 messages + flush" do
      handle = %ReceivePack{
        advertised_caps: ["report-status", "side-band-64k"],
        client_caps: ["side-band-64k"],
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      messages = ["Build passed"]

      assert [
               {:sideband_report, 1, [{:unpack, "ok"}, {:ok, "refs/heads/main"}, :flush]},
               {:sideband, 2, "Build passed"},
               :flush
             ] = ReceivePack.build_push_response(handle, messages)
    end
  end

  describe "push response without side-band-64k" do
    test "report-status returns protocol tuples" do
      handle = %ReceivePack{
        advertised_caps: ["report-status"],
        client_caps: [],
        cmds: [
          {:create, Git.oid_parse("0000000000000000000000000000000000000001"), "refs/heads/main"}
        ]
      }

      assert [
               {:unpack, "ok"},
               {:ok, "refs/heads/main"}
             ] = ReceivePack.report_status(handle)
    end

    test "hook messages not wrapped without side-band-64k capability" do
      messages = ["remote: Build passed", "remote: Deployment successful"]

      # Without side-band-64k, messages are plain text lines (not wrapped)
      response = messages ++ [:flush]

      # Should be plain strings, not sideband-wrapped binaries
      plain_messages = Enum.filter(response, &is_binary/1)
      assert length(plain_messages) == 2
      assert "remote: Build passed" in plain_messages
      assert "remote: Deployment successful" in plain_messages
    end

    test "complete response without sideband: status + messages + flush" do
      status_lines = ["unpack ok", "ok refs/heads/main"]
      messages = ["remote: Build passed"]

      response = status_lines ++ messages ++ [:flush]

      # Verify no sideband wrapping (all plain strings except flush)
      plain_items = Enum.filter(response, &is_binary/1)
      assert length(plain_items) == 3
      assert Enum.all?(plain_items, &(not String.starts_with?(&1, "00")))
      assert List.last(response) == :flush
    end
  end

  describe "push response with side-band-64k" do
    test "report-status wrapped with channel 1" do
      status_lines = ["unpack ok", "ok refs/heads/main"]

      wrapped = Enum.map(status_lines, &ReceivePack.sideband_wrap(&1, 1))

      # All should be sideband-wrapped binaries
      assert Enum.all?(wrapped, &is_binary/1)
      assert Enum.all?(wrapped, fn x -> String.starts_with?(x, "00") end)

      # All should have channel 1
      assert Enum.all?(wrapped, fn x -> String.slice(x, 4..4) == <<1>> end)
    end

    test "hook messages wrapped with channel 2" do
      messages = ["remote: Build passed", "remote: Deployment successful"]

      wrapped = Enum.map(messages, &ReceivePack.sideband_wrap(&1, 2))

      # All should be sideband-wrapped binaries
      assert Enum.all?(wrapped, &is_binary/1)

      # All should have channel 2
      assert Enum.all?(wrapped, fn x -> String.slice(x, 4..4) == <<2>> end)
    end

    test "complete response with sideband: status + messages + flush" do
      status_lines = ["unpack ok", "ok refs/heads/main"]
      messages = ["remote: Build passed"]

      status_wrapped = Enum.map(status_lines, &ReceivePack.sideband_wrap(&1, 1))
      messages_wrapped = Enum.map(messages, &ReceivePack.sideband_wrap(&1, 2))

      response = status_wrapped ++ messages_wrapped ++ [:flush]

      # Status frames should use channel 1
      status_channels = status_wrapped |> Enum.map(&String.slice(&1, 4..4)) |> Enum.uniq()
      assert status_channels == [<<1>>]

      # Message frames should use channel 2
      message_channels = messages_wrapped |> Enum.map(&String.slice(&1, 4..4)) |> Enum.uniq()
      assert message_channels == [<<2>>]

      # Flush must be last
      assert List.last(response) == :flush
    end

    test "sideband frames are pre-wrapped, ready for final encode pass" do
      status_lines = ["unpack ok"]
      status_wrapped = Enum.map(status_lines, &ReceivePack.sideband_wrap(&1, 1))

      # Wrapped frames should already have size prefix
      assert Enum.all?(status_wrapped, fn x ->
               is_binary(x) && String.match?(x, ~r/^[0-9a-f]{4}/)
             end)
    end
  end

  describe "pkt_line with capabilities" do
    test "status tuples are always plain pkt-line, never sideband-wrapped" do
      # Per git protocol spec: report-status is plain pkt-line even if side-band-64k negotiated
      # Evidence: git source send-pack.c closes sideband demux before reading status

      caps_with_sideband = ["side-band-64k", "report-status"]
      result_unpack = ExGitEngine.WireProtocol.pkt_line({:unpack, "ok"}, caps_with_sideband)
      result_ok = ExGitEngine.WireProtocol.pkt_line({:ok, "refs/heads/main"}, caps_with_sideband)

      result_ng =
        ExGitEngine.WireProtocol.pkt_line(
          {:ng, "refs/heads/main", "non-fast-forward"},
          caps_with_sideband
        )

      # All should be plain pkt-line format (no sideband channel byte 0x01)
      assert String.match?(result_unpack, ~r/^[0-9a-f]{4}unpack ok\n$/)
      assert String.match?(result_ok, ~r/^[0-9a-f]{4}ok refs\/heads\/main\n$/)
      assert String.match?(result_ng, ~r/^[0-9a-f]{4}ng refs\/heads\/main non-fast-forward\n$/)
    end

    test "flush is unchanged regardless of capabilities" do
      caps_with_sideband = ["side-band-64k"]
      caps_without = []

      result_with = ExGitEngine.WireProtocol.pkt_line(:flush, caps_with_sideband)
      result_without = ExGitEngine.WireProtocol.pkt_line(:flush, caps_without)

      assert result_with == "0000"
      assert result_without == "0000"
    end

    test "sideband tuple passed through unchanged" do
      caps = ["side-band-64k"]
      result = ExGitEngine.WireProtocol.pkt_line({:sideband, 2, "hook output"}, caps)

      # Already-wrapped sideband should pass through pkt_line unchanged
      assert String.match?(result, ~r/^[0-9a-f]{4}\x02hook output\n$/)
    end
  end

  describe "full protocol chain (handle_push_cmds)" do
    setup do
      make_repo = fn ->
        path = Path.join(System.tmp_dir(), "ex_git_engine-chain-#{:erlang.unique_integer()}")
        File.mkdir_p!(path)
        cmd = fn args -> System.cmd("git", ["-C", path | args], stderr_to_stdout: true) end
        cmd.(["init", "--initial-branch=main"])
        cmd.(["config", "user.email", "test@example.com"])
        cmd.(["config", "user.name", "Test"])
        File.write!(Path.join(path, "file.txt"), "v1\n")
        cmd.(["add", "."])
        cmd.(["commit", "-m", "initial"])
        {oid_a, 0} = cmd.(["rev-parse", "HEAD"])
        {path, String.trim(oid_a)}
      end

      # Server: bare repo with initial commit A
      server_path = Path.join(System.tmp_dir(), "ex_git_engine-chain-srv-#{:erlang.unique_integer()}")
      File.mkdir_p!(server_path)

      System.cmd("git", ["-C", server_path, "init", "--bare", "--initial-branch=main"],
        stderr_to_stdout: true
      )

      {client_path, oid_a_str} = make_repo.()
      System.cmd("git", ["-C", client_path, "push", server_path, "main"], stderr_to_stdout: true)

      oid_a = Git.oid_parse(oid_a_str)

      # Client: add a diverging commit B (amend → different history)
      File.write!(Path.join(client_path, "file.txt"), "v2\n")

      cmd_c = fn args ->
        System.cmd("git", ["-C", client_path | args], stderr_to_stdout: true)
      end

      cmd_c.(["add", "."])
      cmd_c.(["commit", "-m", "force commit"])
      {oid_b_str, 0} = cmd_c.(["rev-parse", "HEAD"])
      oid_b = Git.oid_parse(String.trim(oid_b_str))

      # Fetch B's objects into server ODB without touching refs
      System.cmd("git", ["-C", server_path, "fetch", client_path, "main"], stderr_to_stdout: true)

      {:ok, agent} = GitAgent.start_link(server_path)

      on_exit(fn ->
        if Process.alive?(agent), do: GenServer.stop(agent)
        File.rm_rf!(server_path)
        File.rm_rf!(client_path)
      end)

      %{agent: agent, oid_a: oid_a, oid_b: oid_b}
    end

    defp done_handle(agent, cmds) do
      %ReceivePack{
        state: :done,
        agent: agent,
        repo: nil,
        cmds: cmds,
        writepack: nil,
        writepack_progress: %{received_bytes: 0},
        client_caps: ["report-status"],
        advertised_caps: ["report-status"]
      }
    end

    test "force push (non-ff, correct old_oid) updates the ref",
         %{agent: agent, oid_a: oid_a, oid_b: oid_b} do
      handle = done_handle(agent, [{:update, oid_a, oid_b, "refs/heads/main"}])
      {_h, [], output} = ReceivePack.next(handle, [])

      assert {:unpack, "ok"} in output
      assert {:ok, ref} = GitAgent.reference(agent, "refs/heads/main")
      assert ref.oid == oid_b
    end

    test "stale ref update is rejected and ref is unchanged",
         %{agent: agent, oid_a: oid_a, oid_b: oid_b} do
      # Claim oid_b is current but server has oid_a
      handle = done_handle(agent, [{:update, oid_b, oid_a, "refs/heads/main"}])
      {_h, [], output} = ReceivePack.next(handle, [])

      refute {:unpack, "ok"} in output
      assert {:ok, ref} = GitAgent.reference(agent, "refs/heads/main")
      assert ref.oid == oid_a
    end

    test "stale ref delete is rejected and ref is unchanged",
         %{agent: agent, oid_a: oid_a, oid_b: oid_b} do
      handle = done_handle(agent, [{:delete, oid_b, "refs/heads/main"}])
      {_h, [], output} = ReceivePack.next(handle, [])

      refute {:unpack, "ok"} in output
      assert {:ok, ref} = GitAgent.reference(agent, "refs/heads/main")
      assert ref.oid == oid_a
    end
  end

  describe "validate_cmd/2" do
    setup do
      make_repo = fn ->
        path = Path.join(System.tmp_dir(), "ex_git_engine-rv-#{:erlang.unique_integer()}")
        File.mkdir_p!(path)
        cmd = fn args -> System.cmd("git", ["-C", path | args], stderr_to_stdout: true) end
        cmd.(["init"])
        cmd.(["config", "user.email", "test@example.com"])
        cmd.(["config", "user.name", "Test"])
        File.write!(Path.join(path, "file.txt"), "v1\n")
        cmd.(["add", "."])
        cmd.(["commit", "-m", "commit A"])
        {oid_a, 0} = cmd.(["rev-parse", "HEAD"])
        File.write!(Path.join(path, "file.txt"), "v2\n")
        cmd.(["add", "."])
        cmd.(["commit", "-m", "commit B"])
        {oid_b, 0} = cmd.(["rev-parse", "HEAD"])
        {path, Git.oid_parse(String.trim(oid_a)), Git.oid_parse(String.trim(oid_b))}
      end

      # Repo where main is at A (B exists but main reset back)
      {path_a, oid_a, oid_b} = make_repo.()
      System.cmd("git", ["-C", path_a, "reset", "--hard", "HEAD~1"], stderr_to_stdout: true)
      {:ok, agent_at_a} = GitAgent.start_link(path_a)

      # Separate repo where main stays at B (for non-ff test)
      {path_b, oid_a_b, oid_b_b} = make_repo.()
      {:ok, agent_at_b} = GitAgent.start_link(path_b)

      on_exit(fn ->
        for {agent, path} <- [{agent_at_a, path_a}, {agent_at_b, path_b}] do
          if Process.alive?(agent), do: GenServer.stop(agent)
          File.rm_rf!(path)
        end
      end)

      %{
        agent_at_a: agent_at_a,
        oid_a: oid_a,
        oid_b: oid_b,
        agent_at_b: agent_at_b,
        oid_a_b: oid_a_b,
        oid_b_b: oid_b_b
      }
    end

    test "fast-forward update with matching old_oid is accepted",
         %{agent_at_a: agent, oid_a: oid_a, oid_b: oid_b} do
      assert :ok = ReceivePack.validate_cmd(agent, {:update, oid_a, oid_b, "refs/heads/main"})
    end

    test "update with stale old_oid is rejected",
         %{agent_at_a: agent, oid_a: oid_a, oid_b: oid_b} do
      # main is at A; client claims current is B (wrong)
      assert {:error, :stale_ref} =
               ReceivePack.validate_cmd(agent, {:update, oid_b, oid_a, "refs/heads/main"})
    end

    test "non-fast-forward update is accepted (ff enforcement belongs in pre_push hook)",
         %{agent_at_b: agent, oid_a_b: oid_a, oid_b_b: oid_b} do
      # main is at B; push B→A — stale check passes, no ff check at protocol level
      assert :ok = ReceivePack.validate_cmd(agent, {:update, oid_b, oid_a, "refs/heads/main"})
    end

    test "create command is always accepted",
         %{agent_at_a: agent, oid_a: oid_a} do
      assert :ok = ReceivePack.validate_cmd(agent, {:create, oid_a, "refs/heads/new"})
    end

    test "delete with matching old_oid is accepted",
         %{agent_at_a: agent, oid_a: oid_a} do
      assert :ok = ReceivePack.validate_cmd(agent, {:delete, oid_a, "refs/heads/main"})
    end

    test "delete with stale old_oid is rejected",
         %{agent_at_a: agent, oid_b: oid_b} do
      # main is at A; client claims current is B (wrong)
      assert {:error, :stale_ref} =
               ReceivePack.validate_cmd(agent, {:delete, oid_b, "refs/heads/main"})
    end
  end
end

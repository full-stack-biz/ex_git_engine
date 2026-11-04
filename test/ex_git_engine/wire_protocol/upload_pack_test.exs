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

    test "want lines and flush in separate SSH DATA messages" do
      handle = %UploadPack{
        state: :upload_req,
        advertised_caps: ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      }

      oid = String.duplicate("c", 40)

      {handle, [], []} = UploadPack.next(handle, [{:want, "#{oid} multi_ack_detailed"}])
      assert handle.state == :upload_req

      {handle, [], []} = UploadPack.next(handle, [:flush])
      assert handle.state == :upload_haves
      assert handle.caps == ["multi_ack_detailed"]
      assert handle.wants == [ExGitEngine.Git.oid_parse(oid)]
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
      # nil agent → exec returns {:error, reason}: answered with ERR, not a crash
      handle = %UploadPack{state: :upload_haves, caps: [], haves: [], wants: [], agent: nil}

      assert {%UploadPack{state: :done}, [], ["ERR upload-pack failed"]} =
               UploadPack.next(handle, [:done])
    end
  end

  describe "agent errors" do
    # an agent whose every call is answered {:error, :busy}, as JobLimiter does when its
    # queue is full
    defp busy_agent do
      spawn_link(fn -> busy_loop() end)
    end

    defp busy_loop do
      receive do
        {:"$gen_call", from, _op} -> GenServer.reply(from, {:error, :busy})
      end

      busy_loop()
    end

    @busy ["ERR server is busy, try again later"]

    test "pack_create without haves answers ERR instead of crashing" do
      handle = %UploadPack{
        state: :pack,
        caps: ["side-band-64k"],
        haves: [],
        wants: [],
        agent: busy_agent()
      }

      assert {%UploadPack{state: :done}, [], @busy} = UploadPack.next(handle, [])
    end

    test "pack_create with haves answers ERR instead of crashing" do
      oid = :crypto.strong_rand_bytes(20)
      handle = %UploadPack{state: :pack, caps: [], haves: [[oid]], wants: [], agent: busy_agent()}

      assert {%UploadPack{state: :done}, [], @busy} = UploadPack.next(handle, [])
    end

    test "a shallow pack answers ERR instead of crashing" do
      handle = %UploadPack{
        state: :pack,
        caps: [],
        shallow_pack: [],
        wants: [],
        agent: busy_agent()
      }

      assert {%UploadPack{state: :done}, [], @busy} = UploadPack.next(handle, [])
    end

    test "checking haves answers ERR instead of crashing" do
      have = {:have, String.duplicate("a", 40)}

      handle = %UploadPack{
        state: :upload_haves,
        caps: [],
        haves: [],
        wants: [],
        agent: busy_agent()
      }

      assert {%UploadPack{state: :done}, [], @busy} = UploadPack.next(handle, [have])
    end

    test "ERR is framed as a pkt-line the client dies on" do
      assert IO.iodata_to_binary(ExGitEngine.WireProtocol.encode(@busy)) ==
               "0028ERR server is busy, try again later\n"
    end
  end

  describe "waiting for a pack with a transport send function" do
    # an agent that hands each call to the test, which answers it when it wants
    defp held_agent(test) do
      spawn_link(fn -> held_loop(test) end)
    end

    defp held_loop(test) do
      receive do
        {:"$gen_call", from, _op} -> send(test, {:agent_call, from})
      end

      held_loop(test)
    end

    defp waiting_handle(test) do
      %UploadPack{
        state: :pack,
        caps: ["side-band-64k"],
        haves: [],
        wants: [],
        agent: held_agent(test),
        keepalive_ms: 20,
        send: fn data ->
          send(test, {:sent, IO.iodata_to_binary(data)})
          :ok
        end
      }
    end

    test "sends NAK at once, a keepalive while the pack is built, then the pack" do
      test = self()
      result = Task.async(fn -> UploadPack.next(waiting_handle(test), []) end)

      assert_receive {:agent_call, from}
      assert_receive {:sent, "0008NAK\n"}
      assert_receive {:sent, "0005\x01"}
      assert_receive {:sent, "0005\x01"}

      GenServer.reply(from, {:ok, "PACKdata"})

      assert {%UploadPack{state: :done}, [], [{:sideband_pack, 1, "PACKdata"}, :flush]} =
               Task.await(result)
    end

    test "a pack that fails after NAK is reported on side-band 3" do
      test = self()
      result = Task.async(fn -> UploadPack.next(waiting_handle(test), []) end)

      assert_receive {:agent_call, from}
      GenServer.reply(from, {:error, :busy})

      assert {%UploadPack{state: :done}, [], [{:sideband, 3, "server is busy, try again later"}]} =
               Task.await(result)
    end

    test "stops waiting when the client is gone" do
      test = self()
      sends = :counters.new(1, [])

      handle = %{
        waiting_handle(test)
        | send: fn _data ->
            :counters.add(sends, 1, 1)
            if :counters.get(sends, 1) == 1, do: :ok, else: {:error, :closed}
          end
      }

      result = Task.async(fn -> UploadPack.next(handle, []) end)

      assert_receive {:agent_call, {caller, _}}
      ref = Process.monitor(caller)

      assert {%UploadPack{state: :done}, [], []} = Task.await(result)
      assert_receive {:DOWN, ^ref, :process, ^caller, _}
    end

    test "without side-band the send function is not used" do
      test = self()
      handle = %{waiting_handle(test) | caps: []}
      result = Task.async(fn -> UploadPack.next(handle, []) end)

      assert_receive {:agent_call, from}
      GenServer.reply(from, {:ok, "PACKdata"})

      assert {%UploadPack{state: :done}, [], [:nak, "PACKdata"]} = Task.await(result)
      refute_received {:sent, _}
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

  describe "shallow (deepen)" do
    # a bare repo with a linear history of `count` commits; returns the oids, newest first
    defp linear_repo(count) do
      tmp =
        Path.join(System.tmp_dir!(), "upload-pack-shallow-#{System.unique_integer([:positive])}")

      work = Path.join(tmp, "work")
      env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]
      git = fn args -> {_, 0} = System.cmd("git", ["-C", work | args], env: env) end

      File.mkdir_p!(work)
      git.(["init", "-q", "-b", "main"])

      for i <- 1..count do
        File.write!(Path.join(work, "f#{i}.txt"), "#{i}\n")
        git.(["add", "."])
        git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c#{i}"])
      end

      {log, 0} = System.cmd("git", ["-C", work, "rev-list", "main"], env: env)

      {_, 0} =
        System.cmd("git", ["clone", "-q", "--bare", work, Path.join(tmp, "bare")], env: env)

      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, agent} = ExGitEngine.GitAgent.start_link(Path.join(tmp, "bare"))
      {agent, tmp, String.split(log, "\n", trim: true)}
    end

    # commits in `pack`, counted by git itself
    defp pack_commits(tmp, pack) do
      dir = Path.join(tmp, "unpack")
      env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", dir], env: env)
      pack_file = Path.join(tmp, "in.pack")
      File.write!(pack_file, pack)

      {_, 0} =
        System.cmd("git", ["-C", dir, "index-pack", "-o", Path.join(tmp, "in.idx"), pack_file],
          env: env
        )

      {out, 0} = System.cmd("git", ["verify-pack", "-v", Path.join(tmp, "in.idx")], env: env)
      out |> String.split("\n") |> Enum.count(&String.contains?(&1, " commit "))
    end

    test "shallow is advertised for git-upload-pack" do
      assert "shallow" in ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
    end

    test "deepen line is decoded" do
      assert [{:deepen, 3}, :flush] =
               Enum.to_list(ExGitEngine.WireProtocol.decode("000ddeepen 3\n0000"))
    end

    test "shallow and unshallow lines are encoded" do
      oid = :crypto.strong_rand_bytes(20)
      hex = ExGitEngine.Git.oid_fmt(oid)

      assert ExGitEngine.WireProtocol.pkt_line({:shallow, oid}) == "0035shallow #{hex}\n"
      assert ExGitEngine.WireProtocol.pkt_line({:unshallow, oid}) == "0037unshallow #{hex}\n"
    end

    test "deepen 1 answers the tip as shallow and packs only the tip commit" do
      {agent, tmp, [tip | _]} = linear_repo(5)
      tip_oid = ExGitEngine.Git.oid_parse(tip)

      handle = %UploadPack{
        agent: agent,
        state: :upload_req,
        advertised_caps: ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      }

      {handle, [], update} =
        UploadPack.next(handle, [{:want, "#{tip} shallow"}, {:deepen, 1}, :flush])

      assert update == [{:shallow, tip_oid}, :flush]

      {_handle, [], [:nak, pack]} = UploadPack.next(handle, [:done])
      assert pack_commits(tmp, pack) == 1
    end

    test "deepen 3 answers the third commit as shallow and packs three commits" do
      {agent, tmp, [tip, _, third | _]} = linear_repo(5)

      handle = %UploadPack{
        agent: agent,
        state: :upload_req,
        advertised_caps: ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      }

      {handle, [], update} =
        UploadPack.next(handle, [{:want, "#{tip} shallow"}, {:deepen, 3}, :flush])

      assert update == [{:shallow, ExGitEngine.Git.oid_parse(third)}, :flush]

      {_handle, [], [:nak, pack]} = UploadPack.next(handle, [:done])
      assert pack_commits(tmp, pack) == 3
    end

    test "deepen past the root answers no shallow commits and packs the whole history" do
      {agent, tmp, [tip | _]} = linear_repo(3)

      handle = %UploadPack{
        agent: agent,
        state: :upload_req,
        advertised_caps: ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      }

      {handle, [], [:flush]} =
        UploadPack.next(handle, [{:want, "#{tip} shallow"}, {:deepen, 10}, :flush])

      {_handle, [], [:nak, pack]} = UploadPack.next(handle, [:done])
      assert pack_commits(tmp, pack) == 3
    end

    test "a client shallow commit inside the new depth is answered as unshallow" do
      {agent, _tmp, [tip, second | _]} = linear_repo(5)

      handle = %UploadPack{
        agent: agent,
        state: :upload_req,
        advertised_caps: ExGitEngine.WireProtocol.server_capabilities("git-upload-pack")
      }

      lines = [{:want, "#{tip} shallow"}, {:shallow, second}, {:deepen, 3}, :flush]
      {_handle, [], update} = UploadPack.next(handle, lines)

      assert {:unshallow, ExGitEngine.Git.oid_parse(second)} in update
    end
  end
end

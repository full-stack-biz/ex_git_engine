defmodule ExGitEngine.WireProtocol.UploadPack do
  @moduledoc """
  Module implementing the `git-upload-pack` command.
  """

  @behaviour ExGitEngine.WireProtocol

  alias ExGitEngine.Git
  alias ExGitEngine.GitAgent

  require Logger

  import ExGitEngine.WireProtocol, only: [reference_discovery: 3]

  @service_name "git-upload-pack"

  defstruct [
    :agent,
    state: :disco,
    no_done: false,
    caps: [],
    advertised_caps: [],
    wants: [],
    haves: [],
    pending_wants: [],
    shallow_pack: nil,
    pkt_rest: "",
    send: nil,
    keepalive_ms: 5_000
  ]

  @type t :: %__MODULE__{
          agent: GitAgent.agent(),
          state: :disco | :upload_req | :upload_haves | :pack | :done,
          no_done: boolean,
          caps: [binary],
          advertised_caps: [binary],
          wants: [Git.oid()],
          haves: [Git.oid()],
          pending_wants: [term],
          shallow_pack: [Git.oid()] | nil,
          pkt_rest: binary,
          send: (iodata -> term) | nil,
          keepalive_ms: pos_integer
        }

  #
  # Callbacks
  #

  @impl true
  def next(%__MODULE__{state: :disco} = handle, lines) do
    {new_state, remaining_lines} =
      case lines do
        [:flush | rest] -> {:done, rest}
        other -> {:upload_req, other}
      end

    new_handle = disco_transition_state(handle, new_state)

    {new_handle, remaining_lines,
     reference_discovery(new_handle.agent, @service_name, handle.no_done)}
  end

  def next(%__MODULE__{state: :upload_req, pending_wants: []} = handle, [:flush | lines]) do
    {%{handle | state: :done}, lines, []}
  end

  def next(%__MODULE__{state: :upload_req} = handle, lines) do
    # upload-request = want-list *shallow-line *1depth-request flush-pkt
    {wants, lines} =
      Enum.split_while(lines, &(obj_match?(&1, :want) or obj_match?(&1, :shallow) or deepen?(&1)))

    wants = handle.pending_wants ++ wants

    case lines do
      # The terminating flush may arrive in a later SSH DATA message.
      [] -> {%{handle | pending_wants: wants}, [], []}
      [:flush | lines] -> upload_req(%{handle | pending_wants: []}, wants, lines)
    end
  end

  def next(%__MODULE__{state: :upload_haves} = handle, []) do
    {%{handle | state: :done}, [], []}
  end

  def next(%__MODULE__{state: :upload_haves} = handle, [:flush | lines]) do
    acks = ack_haves(handle.haves, handle.caps)

    if "no-done" in handle.caps and multi_ack?(handle.caps) and handle.haves != [] do
      {%{handle | state: :pack}, lines, acks ++ [:nak, {:ack, List.last(handle.haves)}]}
    else
      {handle, lines, acks ++ [:nak]}
    end
  end

  def next(%__MODULE__{state: :upload_haves} = handle, [:done | lines]) do
    next(%{handle | state: :pack}, lines)
  end

  def next(%__MODULE__{state: :upload_haves} = handle, lines) do
    {haves, lines} = Enum.split_while(lines, &obj_match?(&1, :have))

    with {:ok, odb} <- GitAgent.odb(handle.agent),
         {:ok, haves} <- existing_haves(handle.agent, odb, parse_cmds(haves)) do
      {%{handle | haves: haves}, lines, []}
    else
      {:error, reason} -> error_output(handle, reason)
    end
  end

  def next(%__MODULE__{state: :pack, shallow_pack: commits} = handle, []) when is_list(commits) do
    # ponytail: haves are not subtracted, so a deepening fetch gets commits it already has
    pack_reply(
      handle,
      :nak,
      fn -> GitAgent.pack_commits(handle.agent, commits, timeout: :infinity) end,
      &GitAgent.pack_commits_file(handle.agent, commits, &1, timeout: :infinity)
    )
  end

  def next(%__MODULE__{state: :pack} = handle, []) do
    Logger.debug(
      "UPLOAD_PACK: pack state with empty input, haves=#{length(handle.haves)}, wants=#{length(handle.wants)}"
    )

    haves = List.flatten(Enum.reverse(handle.haves))
    oids = handle.wants ++ Enum.map(haves, &{&1, true})

    lead =
      if haves != [] and multi_ack?(handle.caps), do: {:ack, List.first(haves)}, else: :nak

    pack_reply(
      handle,
      lead,
      fn -> GitAgent.pack_create(handle.agent, oids, timeout: :infinity) end,
      &GitAgent.pack_file(handle.agent, oids, &1, timeout: :infinity)
    )
  end

  def next(%__MODULE__{state: :pack} = handle, lines) do
    Logger.debug(
      "UPLOAD_PACK: pack state with data, lines_count=#{length(lines)}, first_line=#{inspect(List.first(lines))}"
    )

    {handle, lines, []}
  end

  def next(%__MODULE__{state: :done} = handle, []) do
    {handle, [], []}
  end

  defp upload_req(%__MODULE__{advertised_caps: advertised_caps} = handle, req, lines) do
    {wants, req} = Enum.split_with(req, &obj_match?(&1, :want))
    client_shallows = req |> Enum.filter(&obj_match?(&1, :shallow)) |> parse_cmds()
    depth = Enum.find_value(req, fn line -> deepen?(line) && elem(line, 1) end)
    {caps, wants} = parse_caps(wants)

    Logger.debug(
      "UPLOAD_REQ: client_caps=#{inspect(caps)}, advertised_caps=#{inspect(advertised_caps)}"
    )

    # Validate client capabilities against advertised capabilities per Git protocol spec
    unknown_caps = ExGitEngine.WireProtocol.validate_capabilities(caps, advertised_caps)

    if unknown_caps != [] do
      Logger.error("UPLOAD_REQ: client sent unknown capabilities: #{inspect(unknown_caps)}")
      raise "unknown capabilities: #{inspect(unknown_caps)}"
    end

    handle = %{handle | state: :upload_haves, caps: caps, wants: parse_cmds(wants)}

    if depth,
      do: shallow_update(handle, client_shallows, depth, lines),
      else: {handle, lines, []}
  end

  # git/upload-pack.c deepen/send_shallow/send_unshallow: boundary commits the
  # client doesn't already have as shallow are answered `shallow`, client
  # shallows now inside the depth `unshallow`, then a flush
  defp shallow_update(handle, client_shallows, depth, lines) do
    {:ok, {within, boundary}} = GitAgent.shallow_commits(handle.agent, handle.wants, depth)

    shallow = for oid <- boundary, oid not in client_shallows, do: {:shallow, oid}
    unshallow = for oid <- client_shallows, oid in within, do: {:unshallow, oid}

    {%{handle | shallow_pack: within ++ boundary}, lines, shallow ++ unshallow ++ [:flush]}
  end

  defp deepen?({:deepen, _depth}), do: true
  defp deepen?(_line), do: false

  @impl true
  def skip(%__MODULE__{state: :disco} = handle) do
    %{handle | state: :upload_req, advertised_caps: build_advertised_caps(handle.no_done)}
  end

  def skip(%__MODULE__{state: :upload_req} = handle), do: %{handle | state: :upload_haves}
  def skip(%__MODULE__{state: :upload_haves} = handle), do: %{handle | state: :pack}
  def skip(%__MODULE__{state: :pack} = handle), do: %{handle | state: :done}
  def skip(%__MODULE__{state: :done} = handle), do: handle

  #
  # Helpers
  #

  @doc "Transitions handle from `:disco` to `new_state`, building `advertised_caps` from `no_done`."
  def disco_transition_state(handle, new_state) do
    %{handle | state: new_state, caps: [], advertised_caps: build_advertised_caps(handle.no_done)}
  end

  defp build_advertised_caps(no_done) do
    base = ExGitEngine.WireProtocol.server_capabilities(@service_name)
    if no_done, do: base ++ ["no-done"], else: base
  end

  defp obj_match?({type, _oid}, type), do: true
  defp obj_match?(_line, _type), do: false

  defp parse_cmds(cmds), do: Enum.uniq(Enum.map(cmds, &Git.oid_parse(elem(&1, 1))))

  defp parse_caps([]), do: {[], []}

  defp parse_caps([{obj_type, first_ref} | wants]) do
    case String.split(first_ref, " ", parts: 2) do
      [first_ref] -> {[], [{obj_type, first_ref} | wants]}
      [first_ref, caps] -> {String.split(caps, " ", trim: true), [{obj_type, first_ref} | wants]}
    end
  end

  def ack_haves(haves, caps) do
    haves
    |> Enum.with_index()
    |> Enum.map(fn {have, idx} ->
      is_last = idx == length(haves) - 1
      build_ack(have, is_last, caps)
    end)
  end

  defp build_ack(have, is_last, caps) do
    cond do
      is_last and multi_ack?(caps) -> {:ack, have, :ready}
      not is_last and "multi_ack" in caps -> {:ack, have, :continue}
      not is_last and "multi_ack_detailed" in caps -> {:ack, have, :common}
      true -> {:ack, have}
    end
  end

  defp existing_haves(agent, odb, haves) do
    Enum.reduce_while(haves, {:ok, []}, fn have, {:ok, acc} ->
      case GitAgent.odb_object_exists?(agent, odb, have) do
        {:ok, true} -> {:cont, {:ok, [have | acc]}}
        {:ok, false} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  # An ERR pkt-line in place of ACK/NAK: git's fetch-pack reads it with
  # PACKET_READ_DIE_ON_ERR_PACKET and exits with "remote error: <msg>"
  # (gitprotocol-pack: "Instead of ACK or NAK, the server may send an error message").
  defp error_output(handle, reason) do
    Logger.warning("UPLOAD_PACK: failed: #{inspect(reason)}")
    {%{handle | state: :done}, [], ["ERR " <> error_message(reason)]}
  end

  defp error_message(:busy), do: "server is busy, try again later"
  defp error_message(_reason), do: "upload-pack failed"

  defp multi_ack?(caps) do
    "multi_ack" in caps or "multi_ack_detailed" in caps
  end

  # With a transport `send` and side-band, the ACK/NAK goes out before the pack is built and a
  # keepalive every `keepalive_ms` while it waits, as git's upload-pack does (create_pack_file:
  # an empty side-band packet every uploadpack.keepAlive seconds, 5 by default). Without
  # side-band nothing may be sent before the pack, so the reply is built in one piece.
  #
  # A streamed pack goes through a temp file: it is never held in memory, and because libgit2 runs
  # to the end without waiting for the client, a slow client holds no JobLimiter slot or dirty
  # scheduler, only disk.
  defp pack_reply(handle, lead, build, build_file) do
    if is_function(handle.send, 1) and sideband_chunk(handle.caps) do
      stream_pack(%{handle | state: :done}, lead, build_file)
    else
      case build.() do
        {:ok, pack} -> {%{handle | state: :done}, [], pack_output(lead, pack, handle.caps)}
        {:error, reason} -> error_output(handle, reason)
      end
    end
  end

  # The pack is built in a linked task so this process can send keepalives; when the client
  # is gone the task is killed and JobLimiter drops its queued job.
  defp stream_pack(handle, lead, build_file) do
    path = pack_path()

    try do
      with :ok <- transmit(handle, [lead]),
           :ok <- File.chmod(path, 0o600),
           {:ok, :ok} <- await_pack(handle, Task.async(fn -> build_file.(path) end)),
           :ok <- send_pack_file(handle, path) do
        {handle, [], [:flush]}
      else
        # After ACK/NAK an ERR line is not read any more; band 3 is (git sideband.c: "remote error").
        {:ok, {:error, reason}} ->
          Logger.warning("UPLOAD_PACK: failed: #{inspect(reason)}")
          {handle, [], [{:sideband, 3, error_message(reason)}]}

        {:error, _closed} ->
          {handle, [], []}
      end
    after
      File.rm(path)
    end
  end

  defp pack_path do
    name = "ex_git_engine-pack-#{System.unique_integer([:positive])}"
    path = Path.join(ExGitEngine.Application.pack_tmp_dir(), name)
    File.touch!(path)
    path
  end

  defp send_pack_file(handle, path) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        send_chunks(handle, file, sideband_chunk(handle.caps))
      after
        File.close(file)
      end
    end
  end

  defp send_chunks(handle, file, chunk_size) do
    case IO.binread(file, chunk_size) do
      :eof ->
        :ok

      {:error, _reason} = error ->
        error

      chunk ->
        with :ok <- transmit(handle, [{:sideband_pack, 1, chunk}]),
             do: send_chunks(handle, file, chunk_size)
    end
  end

  defp await_pack(handle, task) do
    case Task.yield(task, handle.keepalive_ms) do
      {:ok, result} ->
        {:ok, result}

      nil ->
        case transmit(handle, [{:sideband_pack, 1, ""}]) do
          :ok ->
            await_pack(handle, task)

          error ->
            Task.shutdown(task, :brutal_kill)
            error
        end
    end
  end

  defp transmit(handle, lines) do
    case handle.send.(ExGitEngine.WireProtocol.encode(lines)) do
      {:error, _reason} = error -> error
      _sent -> :ok
    end
  end

  defp sideband_chunk(caps) do
    cond do
      "side-band-64k" in caps -> 65_515
      "side-band" in caps -> 995
      true -> nil
    end
  end

  defp pack_output(lead, pack, caps) do
    case sideband_chunk(caps) do
      nil -> [lead, pack]
      chunk -> [lead] ++ pack_to_sideband_frames(pack, chunk) ++ [:flush]
    end
  end

  @doc "Splits a pack binary into `{:sideband_pack, 1, chunk}` tuples sized at most `chunk_size` bytes."
  def pack_to_sideband_frames(pack, chunk_size) do
    do_chunk(pack, chunk_size, [])
  end

  defp do_chunk(<<>>, _chunk_size, acc), do: Enum.reverse(acc)

  defp do_chunk(pack, chunk_size, acc) do
    case pack do
      <<chunk::binary-size(^chunk_size), rest::binary>> ->
        do_chunk(rest, chunk_size, [{:sideband_pack, 1, chunk} | acc])

      _ ->
        Enum.reverse([{:sideband_pack, 1, pack} | acc])
    end
  end
end

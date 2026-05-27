defmodule GitRekt.WireProtocol.ReceivePack do
  @moduledoc """
  Module implementing the `git-receive-pack` command.
  """

  @behaviour GitRekt.WireProtocol

  alias GitRekt.Git
  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  require Logger

  import GitRekt.WireProtocol, only: [reference_discovery: 3]

  @service_name "git-receive-pack"

  @null_oid String.duplicate("0", 40)

  defstruct agent: nil,
            state: :disco,
            caps: [],
            advertised_caps: [],
            cmds: [],
            repo: nil,
            writepack: nil,
            writepack_progress: %{
              total_objects: 0,
              indexed_objects: 0,
              received_objects: 0,
              local_objects: 0,
              total_deltas: 0,
              indexed_deltas: 0,
              received_bytes: 0
            }

  @type cmd ::
          {:create, Git.oid(), binary}
          | {:update, Git.oid(), Git.oid(), binary}
          | {:delete, Git.oid(), binary}

  @type t :: %__MODULE__{
          agent: GitAgent.agent(),
          state: :disco | :update_req | :pack | :buffer | :done,
          caps: [binary],
          cmds: [cmd],
          repo: GitRepo.t(),
          writepack: GitRekt.GitWritePack.t(),
          writepack_progress: Git.odb_writepack_progress()
        }

  #
  # Callbacks
  #

  @impl true
  def next(%__MODULE__{state: :disco} = handle, [:flush | lines]) do
    advertised = GitRekt.WireProtocol.server_capabilities(@service_name) ++ handle.caps
    Logger.debug("RECEIVE_PACK disco->done: clearing caps from #{inspect(handle.caps)}")

    {%{handle | state: :done, caps: [], advertised_caps: advertised}, lines,
     reference_discovery(handle.agent, @service_name, handle.caps)}
  end

  def next(%__MODULE__{state: :disco} = handle, lines) do
    advertised = GitRekt.WireProtocol.server_capabilities(@service_name) ++ handle.caps
    Logger.debug("RECEIVE_PACK disco->update_req: advertised_caps=#{inspect(advertised)}")

    {%{handle | state: :update_req, advertised_caps: advertised}, lines,
     reference_discovery(handle.agent, @service_name, handle.caps)}
  end

  def next(%__MODULE__{state: :update_req} = handle, [:flush | lines]) do
    {%{handle | state: :done}, lines, []}
  end

  def next(%__MODULE__{state: :update_req} = handle, []) do
    {%{handle | state: :done}, [], []}
  end

  def next(%__MODULE__{state: :update_req, advertised_caps: advertised_caps} = handle, lines) do
    require Logger

    case GitAgent.odb_writepack(handle.agent) do
      {:ok, writepack} ->
        {_shallows, lines} = Enum.split_while(lines, &match?({:shallow, _oid}, &1))
        {cmds, lines} = Enum.split_while(lines, &is_binary/1)
        {caps, cmds} = parse_caps(cmds)

        Logger.debug(
          "UPDATE_REQ: client_caps=#{inspect(caps)}, advertised_caps=#{inspect(advertised_caps)}"
        )

        # Validate client capabilities against advertised capabilities per Git protocol spec
        unknown_caps = GitRekt.WireProtocol.validate_capabilities(caps, advertised_caps)

        if unknown_caps != [] do
          Logger.error("UPDATE_REQ: client sent unknown capabilities: #{inspect(unknown_caps)}")
          raise "unknown capabilities: #{inspect(unknown_caps)}"
        end

        [:flush | lines] = lines

        parsed_cmds = parse_cmds(cmds)
        Logger.debug("UPDATE_REQ parsed_cmds=#{inspect(parsed_cmds)}")

        # If all commands are deletions, we transition to :done because no packfile is sent
        state = if Enum.all?(parsed_cmds, &match?({:delete, _, _}, &1)), do: :done, else: :pack

        {%{
           handle
           | state: state,
             caps: caps,
             advertised_caps: advertised_caps || caps,
             cmds: parsed_cmds,
             writepack: writepack
         }, lines, []}

      {:error, error} ->
        raise error
    end
  end

  def next(%__MODULE__{state: :pack} = handle, [{:pack, pack_data}]) do
    case GitAgent.odb_writepack_append(
           handle.agent,
           handle.writepack,
           pack_data,
           handle.writepack_progress
         ) do
      {:ok, progress} when progress.received_objects == progress.total_objects ->
        {%{handle | state: :done, writepack_progress: progress}, [], []}

      {:ok, progress} ->
        {%{handle | state: :buffer, writepack_progress: progress}, [], []}

      {:error, error} ->
        raise error
    end
  end

  def next(%__MODULE__{state: :pack} = handle, []) do
    {%{handle | state: :done}, [], []}
  end

  def next(%__MODULE__{state: :buffer} = handle, pack_data) do
    {%{handle | state: :pack}, [{:pack, pack_data}], []}
  end

  def next(%__MODULE__{state: :done} = handle, []) do
    if handle.cmds == [] do
      {handle, [], []}
    else
      handle_push_cmds(handle)
    end
  end

  @dialyzer {:no_match, handle_push_cmds: 1}
  defp handle_push_cmds(handle) do
    with :ok <- push_pack(handle.agent, handle.writepack, handle.writepack_progress),
         :ok <- GitRepo.pre_push(handle.repo, handle.cmds),
         :ok <- push_cmds(handle.agent, handle.cmds),
         result <- GitRepo.push(handle.repo, handle.cmds) do
      case result do
        {:ok, repo} ->
          output = push_success_output(handle) ++ [:flush]
          Logger.debug("HANDLE_PUSH_CMDS: no messages, output=#{inspect(output)}")
          {%{handle | repo: repo, cmds: []}, [], output}

        {:ok, repo, messages} ->
          output = build_push_response(handle, messages)
          Logger.debug("HANDLE_PUSH_CMDS: combined output=#{inspect(output)}")
          {%{handle | repo: repo, cmds: []}, [], output}

        {:error, reason} ->
          error_msg = format_error_reason(reason)
          output = push_error_output(handle, error_msg) ++ [:flush]
          {handle, [], output}
      end
    else
      {:error, reason} ->
        error_msg = format_error_reason(reason)
        output = push_error_output(handle, error_msg) ++ [:flush]
        {handle, [], output}
    end
  end

  @doc """
  Builds the push response output for successful operations.

  Returns status tuples optionally wrapped in sideband format if the client
  advertised support for it.
  """
  def push_success_output(handle) do
    if "report-status" in handle.advertised_caps do
      report = report_status(handle)

      if "side-band-64k" in handle.caps do
        [{:sideband_report, 1, report ++ [:flush]}]
      else
        report
      end
    else
      []
    end
  end

  @doc """
  Builds the complete push response combining status and hook messages.

  Assembles status output with optional hook messages, handling sideband
  multiplexing when advertised.
  """
  def build_push_response(handle, messages) do
    status_output = push_success_output(handle)

    if "side-band-64k" in handle.caps do
      hook_output = Enum.map(messages, fn msg -> {:sideband, 2, msg} end)
      status_output ++ hook_output ++ [:flush]
    else
      status_output ++ messages ++ [:flush]
    end
  end

  @doc """
  Wraps a line with sideband framing for multiplexed transmission.

  Encodes the line with the specified band number in PKT-LINE format.
  """
  def sideband_wrap(line, band) when is_binary(line) do
    data = line <> "\n"
    size = byte_size(data) + 5
    hex_size = size |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    hex_size <> <<band>> <> data
  end

  defp format_error_reason(reason) when is_binary(reason), do: reason
  defp format_error_reason(reason), do: inspect(reason)

  defp push_error_output(handle, error_msg) do
    if "report-status" in handle.advertised_caps do
      cmd_rejections =
        Enum.map(handle.cmds, fn cmd ->
          refname = elem(cmd, :erlang.tuple_size(cmd) - 1)
          {:ng, refname, error_msg}
        end)

      report = [{:unpack, error_msg}] ++ cmd_rejections

      if "side-band-64k" in handle.caps do
        [{:sideband_report, 1, report ++ [:flush]}]
      else
        report
      end
    else
      []
    end
  end

  @impl true
  def skip(%__MODULE__{state: :disco, caps: caps} = handle) do
    advertised = GitRekt.WireProtocol.server_capabilities(@service_name) ++ caps

    Logger.debug(
      "SKIP disco->update_req: caps=#{inspect(caps)}, advertised_caps=#{inspect(advertised)}"
    )

    %{handle | state: :update_req, advertised_caps: advertised}
  end

  def skip(%__MODULE__{state: :update_req, caps: caps} = handle) do
    Logger.debug("SKIP update_req->pack: caps=#{inspect(caps)}")
    %{handle | state: :pack}
  end

  def skip(%__MODULE__{state: :pack, caps: caps} = handle) do
    Logger.debug("SKIP pack->done: caps=#{inspect(caps)}")
    %{handle | state: :done}
  end

  def skip(%__MODULE__{state: :done} = handle), do: handle

  #
  # Helpers
  #

  @doc """
  Parses ref update commands from the client.

  Converts command strings into structured tuples representing create, delete,
  or update operations.
  """
  def parse_cmds(cmds) do
    Enum.map(cmds, fn cmd ->
      case String.split(cmd, " ", parts: 3) do
        [@null_oid, new, name] ->
          {:create, Git.oid_parse(new), name}

        [old, @null_oid, name] ->
          {:delete, Git.oid_parse(old), name}

        [old, new, name] ->
          {:update, Git.oid_parse(old), Git.oid_parse(new), name}
      end
    end)
  end

  @doc """
  Parses capabilities from the first reference line.

  Extracts client capabilities from the null-delimited first ref line.
  Returns a tuple of {capabilities, refs}.
  """
  def parse_caps([]), do: {[], []}

  def parse_caps([first_ref | refs]) do
    case String.split(first_ref, "\0", parts: 2) do
      [first_ref] -> {[], [first_ref | refs]}
      [first_ref, caps] -> {String.split(caps, " ", trim: true), [first_ref | refs]}
    end
  end

  @doc """
  Generates report-status response for successful ref updates.

  Returns tuples indicating successful update status for each ref command.
  """
  def report_status(%__MODULE__{caps: _caps, cmds: cmds}) do
    ref_statuses =
      Enum.map(cmds, fn cmd ->
        refname = elem(cmd, :erlang.tuple_size(cmd) - 1)
        {:ok, refname}
      end)

    [{:unpack, "ok"} | ref_statuses]
  end

  defp push_pack(_agent, _writepack, progress) when progress.received_bytes == 0, do: :ok

  defp push_pack(agent, writepack, progress) do
    case GitAgent.odb_writepack_commit(agent, writepack, progress) do
      {:ok, _progress} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_cmds(agent, cmds) do
    GitAgent.transaction(agent, fn agent -> Enum.each(cmds, &push_cmd(agent, &1)) end)
  end

  defp push_cmd(agent, {:create, new_oid, name}) do
    case GitAgent.reference_create(agent, name, :oid, new_oid) do
      :ok -> :ok
      {:error, reason} -> raise reason
    end
  end

  defp push_cmd(agent, {:update, _old_oid, new_oid, name}) do
    case GitAgent.reference_create(agent, name, :oid, new_oid, force: true) do
      :ok -> :ok
      {:error, reason} -> raise reason
    end
  end

  defp push_cmd(agent, {:delete, _old_oid, name}) do
    case GitAgent.reference_delete(agent, name) do
      :ok -> :ok
      {:error, reason} -> raise reason
    end
  end
end

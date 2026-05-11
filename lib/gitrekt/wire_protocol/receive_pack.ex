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

  defstruct [
    agent: nil,
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
      received_bytes: 0,
    }
  ]

  @type cmd :: {:create, Git.oid, binary} | {:update, Git.oid, Git.oid, binary} | {:delete, Git.oid, binary}

  @type t :: %__MODULE__{
    agent: GitAgent.agent,
    state: :disco | :update_req | :pack | :buffer | :done,
    caps: [binary],
    cmds: [cmd],
    repo: GitRepo.t,
    writepack: GitWritePack.t,
    writepack_progress: Git.odb_writepack_progress
  }

  #
  # Callbacks
  #

  @impl true
  def next(%__MODULE__{state: :disco} = handle, [:flush|lines]) do
    Logger.debug("RECEIVE_PACK disco->done: clearing caps from #{inspect(handle.caps)}")
    {%{handle|state: :done, caps: []}, lines, reference_discovery(handle.agent, @service_name, handle.caps)}
  end

  def next(%__MODULE__{state: :disco} = handle, lines) do
    Logger.debug("RECEIVE_PACK disco->update_req: preserving caps #{inspect(handle.caps)}")
    {%{handle|state: :update_req}, lines, reference_discovery(handle.agent, @service_name, handle.caps)}
  end

  def next(%__MODULE__{state: :update_req} = handle, [:flush|lines]) do
    {%{handle|state: :done}, lines, []}
  end

  def next(%__MODULE__{state: :update_req, advertised_caps: advertised_caps} = handle, lines) do
    require Logger
    case GitAgent.odb_writepack(handle.agent) do
      {:ok, writepack} ->
        {_shallows, lines} = Enum.split_while(lines, &match?({:shallow, _oid}, &1))
        {cmds, lines} = Enum.split_while(lines, &is_binary/1)
        {caps, cmds} = parse_caps(cmds)
        Logger.debug("UPDATE_REQ: client_caps=#{inspect(caps)}, advertised_caps=#{inspect(advertised_caps)}")

        # Validate: client MUST NOT send capabilities server didn't advertise
        unknown_caps = caps -- advertised_caps
        if unknown_caps != [] do
          Logger.error("UPDATE_REQ: client sent unknown capabilities: #{inspect(unknown_caps)}")
          raise "unknown capabilities: #{inspect(unknown_caps)}"
        end

        [:flush|lines] = lines
        {%{handle|state: :pack, caps: caps, advertised_caps: advertised_caps || caps, cmds: parse_cmds(cmds), writepack: writepack}, lines, []}
      {:error, error} ->
        raise error
    end
  end

  def next(%__MODULE__{state: :pack} = handle, [{:pack, pack_data}]) do
    case GitAgent.odb_writepack_append(handle.agent, handle.writepack, pack_data, handle.writepack_progress) do
      {:ok, progress} when progress.received_objects == progress.total_objects ->
        {%{handle|state: :done, writepack_progress: progress}, [], []}
      {:ok, progress} ->
        {%{handle|state: :buffer, writepack_progress: progress}, [], []}
      {:error, error} ->
        raise error
    end
  end

  def next(%__MODULE__{state: :pack} = handle, []) do
    {%{handle|state: :done}, [], []}
  end

  def next(%__MODULE__{state: :buffer} = handle, pack_data) do
    {%{handle|state: :pack}, [{:pack, pack_data}], []}
  end

  def next(%__MODULE__{state: :done} = handle, []) do
    if handle.cmds != [] do
      with  :ok <- push_pack(handle.agent, handle.writepack, handle.writepack_progress),
            :ok <- GitRepo.pre_push(handle.repo, handle.cmds),
            :ok <- push_cmds(handle.agent, handle.cmds),
           {:ok, repo} <- GitRepo.push(handle.repo, handle.cmds) do
        {%{handle|repo: repo}, [], report_status(handle)}
      else
        {:error, reason} ->
          error_msg = if is_binary(reason), do: reason, else: inspect(reason)
          {handle, [], ["unpack ng #{error_msg}", :flush]}
      end
    else
      {handle, [], []}
    end
  end

  @impl true
  def skip(%__MODULE__{state: :disco, caps: caps, advertised_caps: advertised_caps} = handle) do
    new_advertised = if advertised_caps == [] and caps != [], do: caps, else: advertised_caps
    Logger.debug("SKIP disco->update_req: caps=#{inspect(caps)}, advertised_caps=#{inspect(advertised_caps)}, preserving=#{inspect(new_advertised)}")
    %{handle|state: :update_req, advertised_caps: new_advertised}
  end
  def skip(%__MODULE__{state: :update_req, caps: caps} = handle) do
    Logger.debug("SKIP update_req->pack: caps=#{inspect(caps)}")
    %{handle|state: :pack}
  end
  def skip(%__MODULE__{state: :pack, caps: caps} = handle) do
    Logger.debug("SKIP pack->done: caps=#{inspect(caps)}")
    %{handle|state: :done}
  end
  def skip(%__MODULE__{state: :done} = handle), do: handle

  #
  # Helpers
  #

  @doc false
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

  @doc false
  def parse_caps([]), do: {[], []}
  def parse_caps([first_ref|refs]) do
    case String.split(first_ref, "\0", parts: 2) do
      [first_ref] -> {[], [first_ref|refs]}
      [first_ref, caps] -> {String.split(caps, " ", trim: true), [first_ref|refs]}
    end
  end

  @doc false
  def report_status(%__MODULE__{caps: caps, cmds: cmds}) do
    require Logger
    should_report = "report-status" in caps
    Logger.debug("REPORT_STATUS: client_caps=#{inspect(caps)}, cmds_count=#{length(cmds)}, should_report=#{should_report}")
    result = if should_report,
      do: List.flatten(["unpack ok", Enum.map(cmds, &"ok #{elem(&1, :erlang.tuple_size(&1)-1)}"), :flush]),
    else: []
    Logger.debug("REPORT_STATUS returning: #{inspect(result)}")
    result
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
    case GitAgent.transaction(agent, fn agent -> Enum.each(cmds, &push_cmd(agent, &1)) end) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
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

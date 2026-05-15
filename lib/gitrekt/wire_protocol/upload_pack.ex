defmodule GitRekt.WireProtocol.UploadPack do
  @moduledoc """
  Module implementing the `git-upload-pack` command.
  """

  @behaviour GitRekt.WireProtocol

  alias GitRekt.Git
  alias GitRekt.GitAgent

  require Logger

  import GitRekt.WireProtocol, only: [reference_discovery: 3]

  @service_name "git-upload-pack"

  defstruct [:agent, state: :disco, caps: [], advertised_caps: [], wants: [], haves: []]

  @type t :: %__MODULE__{
          agent: GitAgent.agent(),
          state: :disco | :upload_req | :upload_haves | :pack | :done,
          caps: [binary],
          advertised_caps: [binary],
          wants: [Git.oid()],
          haves: [Git.oid()]
        }

  #
  # Callbacks
  #

  @impl true
  def next(%__MODULE__{state: :disco} = handle, lines) do
    {new_state, remaining_lines} = case lines do
      [:flush | rest] -> {:done, rest}
      other -> {:upload_req, other}
    end

    new_handle = disco_transition_state(handle, new_state)
    {new_handle, remaining_lines, reference_discovery(new_handle.agent, @service_name, handle.caps)}
  end

  def next(%__MODULE__{state: :upload_req} = handle, [:flush | lines]) do
    {%{handle | state: :done}, lines, []}
  end

  def next(%__MODULE__{state: :upload_req, advertised_caps: advertised_caps} = handle, lines) do
    {wants, lines} = Enum.split_while(lines, &obj_match?(&1, :want))
    {caps, wants} = parse_caps(wants)

    Logger.debug(
      "UPLOAD_REQ: client_caps=#{inspect(caps)}, advertised_caps=#{inspect(advertised_caps)}"
    )

    # Validate client capabilities against advertised capabilities per Git protocol spec
    unknown_caps = GitRekt.WireProtocol.validate_capabilities(caps, advertised_caps)

    if unknown_caps != [] do
      Logger.error("UPLOAD_REQ: client sent unknown capabilities: #{inspect(unknown_caps)}")
      raise "unknown capabilities: #{inspect(unknown_caps)}"
    end

    {_shallows, lines} = Enum.split_while(lines, &obj_match?(&1, :shallow))
    [:flush | lines] = lines
    {%{handle | state: :upload_haves, caps: caps, wants: parse_cmds(wants)}, lines, []}
  end

  def next(%__MODULE__{state: :upload_haves} = handle, []) do
    {%{handle | state: :done}, [], []}
  end

  def next(%__MODULE__{state: :upload_haves} = handle, [:flush | lines]) do
    {handle, lines, ack_haves(handle.haves, handle.caps) ++ [:nak]}
  end

  def next(%__MODULE__{state: :upload_haves} = handle, [:done | lines]) do
    next(%{handle | state: :pack}, lines)
  end

  def next(%__MODULE__{state: :upload_haves} = handle, lines) do
    {:ok, odb} = GitAgent.odb(handle.agent)
    {haves, lines} = Enum.split_while(lines, &obj_match?(&1, :have))

    haves =
      Enum.filter(parse_cmds(haves), fn have ->
        case GitAgent.odb_object_exists?(handle.agent, odb, have) do
          {:ok, exists?} -> exists?
          {:error, reason} -> raise reason
        end
      end)

    {%{handle | haves: haves}, lines, []}
  end

  def next(%__MODULE__{state: :pack} = handle, []) do
    Logger.debug("UPLOAD_PACK: pack state with empty input, haves=#{length(handle.haves)}, wants=#{length(handle.wants)}")
    if Enum.empty?(handle.haves) do
      {:ok, pack} = GitAgent.pack_create(handle.agent, handle.wants, timeout: :infinity)
      Logger.debug("UPLOAD_PACK: created pack (no haves), size=#{byte_size(pack)}")
      {%{handle | state: :done}, [], [:nak, pack]}
    else
      haves = List.flatten(Enum.reverse(handle.haves))
      Logger.debug("UPLOAD_PACK: creating pack with haves=#{length(haves)}")

      {:ok, pack} =
        GitAgent.pack_create(handle.agent, handle.wants ++ Enum.map(haves, &{&1, true}),
          timeout: :infinity
        )

      Logger.debug("UPLOAD_PACK: created pack (with haves), size=#{byte_size(pack)}")

      if multi_ack?(handle.caps) do
        {%{handle | state: :done}, [], [{:ack, List.first(haves)}, pack]}
      else
        {%{handle | state: :done}, [], [:nak, pack]}
      end
    end
  end

  def next(%__MODULE__{state: :pack} = handle, lines) do
    Logger.debug("UPLOAD_PACK: pack state with data, lines_count=#{length(lines)}, first_line=#{inspect(List.first(lines))}")
    {handle, lines, []}
  end

  def next(%__MODULE__{state: :done} = handle, []) do
    {handle, [], []}
  end

  @impl true
  def skip(%__MODULE__{state: :disco} = handle) do
    %{handle | state: :upload_req, advertised_caps: build_advertised_caps(handle.caps)}
  end

  def skip(%__MODULE__{state: :upload_req} = handle), do: %{handle | state: :upload_haves}
  def skip(%__MODULE__{state: :upload_haves} = handle), do: %{handle | state: :pack}
  def skip(%__MODULE__{state: :pack} = handle), do: %{handle | state: :done}
  def skip(%__MODULE__{state: :done} = handle), do: handle

  #
  # Helpers
  #

  @doc false
  def disco_transition_state(handle, new_state) do
    %{handle | state: new_state, caps: [], advertised_caps: build_advertised_caps(handle.caps)}
  end

  defp build_advertised_caps(caps) do
    GitRekt.WireProtocol.server_capabilities(@service_name) ++ caps
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

  defp multi_ack?(caps) do
    "multi_ack" in caps or "multi_ack_detailed" in caps
  end
end

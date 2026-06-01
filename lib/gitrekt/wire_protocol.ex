defmodule GitRekt.WireProtocol do
  @moduledoc """
  Conveniences for Git transport protocol and server side commands.

  *This module implements version 2 of [Git's wire protocol](https://git-scm.com/docs/protocol-v2).*

  It functions as a very basic finite-state machine by processing incoming client requests
  and forwarding them to the underlying service implementation (respectively `receive-pack` and `upload-pack`).

  The state machine is initialized by calling `new/2` with the Git repository and command to execute.
  By passing incoming data to `next/2`, the underlying service transit to the next state. Once the client and the server
  are done with exchanging Git objects, the service will reach the `:done` state.

  When processing a entire (not chunked), one can use `run/2` to execute all the steps in a single call.
  """

  require Logger

  alias GitRekt.Git
  alias GitRekt.GitAgent
  alias GitRekt.GitRef
  alias GitRekt.WireProtocol.ReceivePack

  @upload_caps ~w(multi_ack multi_ack_detailed ofs-delta side-band side-band-64k)
  @receive_caps ~w(report-status report-status-v2 delete-refs ofs-delta atomic side-band-64k)

  @doc """
  Callback used to transist a service to the next step.
  """
  @callback next(struct, [term]) :: {struct, [term], iolist}

  @doc """
  Callback used to transist a service to the next step without performing any action.
  """
  @callback skip(struct) :: struct

  @doc """
  Returns an *PKT-LINE* encoded representation of the given `lines`.
  """
  @spec encode(Enumerable.t(), list) :: iolist
  def encode(lines, caps \\ []) do
    require Logger
    lines_list = Enum.to_list(lines)
    Logger.debug("ENCODE: input lines=#{inspect(lines_list)}")
    encoded = Enum.map(lines_list, fn line -> pkt_line(line, caps) end)
    binary_encoded = IO.iodata_to_binary(encoded)
    Logger.debug("ENCODE: hex output=#{Base.encode16(binary_encoded)}")
    encoded
  end

  @doc """
  Returns a stream of decoded *PKT-LINE*s for the given `pkt`.
  """
  @spec decode(binary) :: Enumerable.t()
  def decode(pkt) do
    Stream.map(pkt_stream(pkt), &pkt_decode/1)
  end

  @doc """
  Returns the list of git services implemented by this library.
  """
  @spec valid_services() :: [binary]
  def valid_services, do: ["git-upload-pack", "git-receive-pack"]

  @doc """
  Returns a new service object for the given `repo` and `executable`.
  """
  @spec new(GitAgent.agent(), binary, keyword) :: struct | {:error, :unknown_service}
  def new(agent, executable, init_values \\ []) do
    if executable in valid_services() do
      struct(exec_impl(executable), Keyword.put(init_values, :agent, agent))
    else
      {:error, :unknown_service}
    end
  end

  @doc """
  Runs the given `service` to the next step.
  """
  @spec next(struct) :: {struct, iolist}
  @spec next(struct, :discovery) :: {struct, iolist}
  @spec next(struct, binary) :: {:cont | :halt, struct, iolist}
  def next(service, data \\ :discovery)

  def next(service, :discovery) do
    {service, lines} = exec_next(service, [])
    {service, encode(lines)}
  end

  def next(service, data) do
    if service.state == :buffer do
      # Empty binary is an EOF signal (HTTP reads empty remainder after pack body).
      # Non-empty binary is an additional SSH DATA fragment to append.
      lines = if data == "", do: [], else: data
      {service, lines} = exec_next(service, lines)
      exec_after(service, lines)
    else
      {service, lines} = exec_next(service, Enum.to_list(decode(data)))
      exec_after(service, lines)
    end
  end

  @doc """
  Runs all the steps of the given `service` at once.
  """
  @spec run(struct, binary | :discovery, keyword) :: {struct, iolist}
  def run(service, data \\ :discovery, opts \\ [])
  def run(service, :discovery, opts), do: exec_run(service, [], opts)
  def run(service, data, opts), do: exec_run(service, Enum.to_list(decode(data)), opts)

  @doc """
  Sets the given `service` to the next logical step without performing any action.
  """
  @spec skip(struct) :: struct
  def skip(%{__struct__: module} = service), do: module.skip(service)

  @doc """
  Returns `true` if `service` is done; elsewise returns `false`.
  """
  @spec done?(struct) :: boolean
  def done?(service), do: service.state == :done

  @doc """
  Returns a stream describing each ref and it current value.
  """
  @spec reference_discovery(GitAgent.agent(), binary, boolean) :: [term]
  def reference_discovery(agent, service, no_done \\ false) do
    {:ok, refs} = GitAgent.references(agent, target: :commit, stream_chunk_size: :infinity)
    # Refs returned by libgit2's reference iterator are sorted in C locale order.
    # HEAD is prepended separately to ensure it appears first as per the spec.
    refs =
      [reference_head(agent) | Enum.to_list(refs)]
      |> List.flatten()
      |> Enum.map(&format_ref_line/1)

    # symref=HEAD:<target> is upload-pack only — receive-pack never advertises it.
    # Head target must be captured before reference_head/1 overwrites prefix and name.
    symref_caps =
      if service == "git-upload-pack" do
        case GitAgent.head(agent) do
          {:ok, head} -> ["symref=HEAD:#{head.prefix}#{head.name}"]
          {:error, _} -> []
        end
      else
        []
      end

    no_done_caps = if no_done, do: ["no-done"], else: []
    caps = Enum.join(server_capabilities(service) ++ no_done_caps ++ symref_caps, " ")

    case refs do
      [first | rest] ->
        [first <> "\0" <> caps | rest]

      [] ->
        [String.duplicate("0", 40) <> " capabilities^{}\0" <> caps]
    end
    |> Enum.concat([:flush])
  end

  @doc """
  Returns the given `data` formatted as *PKT-LINE*
  """
  @spec pkt_line(
          :flush
          | {:ack, Git.oid()}
          | {:ack, Git.oid(), binary}
          | :nak
          | binary
          | {:sideband_report, integer, [term]}
          | {:sideband, integer, binary}
          | {:unpack, binary}
          | {:ok, binary}
          | {:ng, binary, binary}
        ) :: binary
  def pkt_line(data \\ :flush)

  def pkt_line(:flush), do: "0000"

  def pkt_line({:sideband_report, channel, inner}) do
    data = IO.iodata_to_binary(Enum.map(inner, &pkt_line/1))
    size = byte_size(data) + 5
    hex_size = size |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    hex_size <> <<channel>> <> data
  end

  def pkt_line({:ack, oid}), do: pkt_line("ACK #{Git.oid_fmt(oid)}")
  def pkt_line({:ack, oid, status}), do: pkt_line("ACK #{Git.oid_fmt(oid)} #{status}")
  def pkt_line(:nak), do: pkt_line("NAK")
  def pkt_line({:unpack, status}), do: pkt_line("unpack #{status}")
  def pkt_line({:ok, refname}), do: pkt_line("ok #{refname}")
  def pkt_line({:ng, refname, reason}), do: pkt_line("ng #{refname} #{reason}")

  def pkt_line({:sideband, channel, text}),
    do: ReceivePack.sideband_wrap(text, channel)

  def pkt_line({:sideband_pack, channel, data}) when is_binary(data) do
    size = byte_size(data) + 5
    hex_size = size |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    hex_size <> <<channel>> <> data
  end

  def pkt_line(<<"PACK", _rest::binary>> = pack), do: pack

  def pkt_line(data) when is_binary(data),
    do:
      String.pad_leading(Integer.to_string(byte_size(data) + 5, 16) |> String.downcase(), 4, "0") <>
        data <> "\n"

  def pkt_line({:unpack, status}, _caps), do: pkt_line("unpack #{status}")
  def pkt_line({:ok, refname}, _caps), do: pkt_line("ok #{refname}")
  def pkt_line({:ng, refname, reason}, _caps), do: pkt_line("ng #{refname} #{reason}")
  def pkt_line({:ack, oid}, _caps), do: pkt_line({:ack, oid})
  def pkt_line({:ack, oid, status}, _caps), do: pkt_line({:ack, oid, status})
  def pkt_line(:nak, _caps), do: pkt_line(:nak)

  def pkt_line({:sideband_pack, channel, data}, _caps),
    do: pkt_line({:sideband_pack, channel, data})

  def pkt_line({:sideband_report, channel, inner}, _caps),
    do: pkt_line({:sideband_report, channel, inner})

  def pkt_line({:sideband, channel, text}, _caps),
    do: ReceivePack.sideband_wrap(text, channel)

  def pkt_line(:flush, _caps), do: "0000"
  def pkt_line(<<"PACK", _rest::binary>> = pack, _caps), do: pack

  def pkt_line(data, _caps) when is_binary(data),
    do:
      String.pad_leading(Integer.to_string(byte_size(data) + 5, 16) |> String.downcase(), 4, "0") <>
        data <> "\n"

  defp __type__(%{__struct__: GitRekt.WireProtocol.UploadPack}), do: :upload_pack
  defp __type__(%{__struct__: GitRekt.WireProtocol.ReceivePack}), do: :receive_pack

  #
  # Helpers
  #

  defp exec_run(service, lines, opts) do
    {service, _skip} =
      if skip = Keyword.get(opts, :skip),
        do: exec_skip(service, skip),
        else: service

    {service, lines} = exec_all(service, lines)
    {service, encode(lines)}
  end

  defp exec_next(service, lines, acc \\ []) do
    ref = make_ref()
    telemetry_start(service, service.state, ref)
    exec_next_state(service, lines, acc, service.state, ref, :os.system_time(:microsecond))
  end

  defp exec_next_state(service, lines, acc, old_state, ref, event_time) do
    Logger.debug(fn ->
      lines_info = if is_list(lines), do: length(lines), else: "binary(#{byte_size(lines)})"

      "EXEC_NEXT_STATE: service.state=#{service.state}, lines_count=#{lines_info}, acc_length=#{length(acc)}"
    end)

    case service.__struct__.next(service, lines) do
      {service, [], out} ->
        Logger.debug("EXEC_NEXT_STATE: got empty lines, output_length=#{length(out)}, returning")
        telemetry_stop(service, old_state, ref, event_time)
        {service, acc ++ out}

      {service, lines, out} ->
        Logger.debug(
          "EXEC_NEXT_STATE: got more lines (#{length(lines)}), output_length=#{length(out)}, recursing with new_state=#{service.state}"
        )

        telemetry_next(service, old_state, ref, event_time)
        exec_next_state(service, lines, acc ++ out, service.state, ref, event_time)
    end
  end

  defp exec_after(service, lines) do
    if service.state == :done do
      {service, lines} = exec_next(service, [], lines)
      {:halt, service, encode(lines)}
    else
      {:cont, service, encode(lines)}
    end
  end

  defp exec_all(service, lines, acc \\ []) do
    done? = done?(service)
    {service, out} = exec_next(service, lines)
    if done?, do: {service, acc ++ out}, else: exec_all(service, [], acc ++ out)
  end

  defp exec_skip(service, count) when count > 0 do
    Enum.reduce(1..count, {service, []}, fn _i, {service, states} ->
      {skip(service), [service.state | states]}
    end)
  end

  defp exec_impl("git-upload-pack"), do: GitRekt.WireProtocol.UploadPack
  defp exec_impl("git-receive-pack"), do: GitRekt.WireProtocol.ReceivePack

  defp telemetry_start(_service, :buffer, _ref), do: :ok

  defp telemetry_start(service, state, ref) do
    :telemetry.execute([:gitrekt, :wire_protocol, :start], %{}, %{
      ref: ref,
      service: __type__(service),
      state: state
    })
  end

  defp telemetry_stop(_service, :buffer, _ref, _event_time), do: :ok

  defp telemetry_stop(service, state, ref, event_time) do
    :telemetry.execute(
      [:gitrekt, :wire_protocol, :stop],
      %{duration: :os.system_time(:microsecond) - event_time},
      %{ref: ref, service: __type__(service), state: state}
    )
  end

  defp telemetry_next(service, state, _ref, _event_time) when service.state == state, do: :ok

  defp telemetry_next(service, state, ref, event_time) do
    telemetry_stop(service, state, ref, event_time)
    telemetry_start(service, service.state, ref)
  end

  @doc """
  Returns the agent capability string for gitrekt.
  """
  def server_agent_capability, do: "agent=gitrekt/#{Application.spec(:gitrekt, :vsn)}"

  @doc """
  Returns the list of server capabilities for the given service.
  """
  def server_capabilities("git-receive-pack"),
    do: [server_agent_capability(), "object-format=sha1" | @receive_caps]

  def server_capabilities("git-upload-pack"),
    do: [server_agent_capability(), "object-format=sha1" | @upload_caps]

  @doc """
  Validates client capabilities against advertised capabilities.

  Returns a list of unknown capabilities requested by the client.
  """
  def validate_capabilities(client_caps, advertised_caps) do
    Enum.reject(client_caps, fn cap ->
      cond do
        # Binary flags: exact match required
        cap in advertised_caps ->
          true

        # Informational/negotiable: client can send different values
        # (agent, session-id) — allowed per Git protocol spec
        String.starts_with?(cap, "agent=") ->
          true

        String.starts_with?(cap, "session-id=") ->
          true

        # Constrained: client must choose from advertised set
        # (object-format, filter) — client value must match an advertised value
        cap_value_in_advertised?(cap, advertised_caps, "object-format=") ->
          true

        cap_value_in_advertised?(cap, advertised_caps, "filter=") ->
          true

        # One-way informational: server-only, reject if client sends
        # (symref) — clients must not send this
        String.starts_with?(cap, "symref=") ->
          false

        # Unknown capability
        true ->
          false
      end
    end)
  end

  defp cap_value_in_advertised?(cap, advertised_caps, prefix) do
    if String.starts_with?(cap, prefix) do
      # For constrained capabilities: client value must exactly match an advertised value
      cap in advertised_caps
    else
      false
    end
  end

  @spec format_ref_line(GitRef.t()) :: binary
  defp format_ref_line(%GitRef{oid: oid, prefix: prefix, name: name}),
    do: "#{Git.oid_fmt(oid)} #{prefix <> name}"

  defp reference_head(agent) do
    case GitAgent.head(agent) do
      {:ok, head} -> %{head | prefix: "", name: "HEAD"}
      {:error, _reason} -> []
    end
  end

  defp pkt_stream(data) do
    Stream.resource(fn -> data end, &pkt_next/1, fn _ -> :ok end)
  end

  defp pkt_next(""), do: {:halt, nil}
  defp pkt_next("0000" <> rest), do: {[:flush], rest}
  defp pkt_next("PACK" <> _rest = pack), do: {[{:pack, pack}], ""}

  defp pkt_next(<<hex::bytes-size(4), payload::binary>> = pkt) do
    case Integer.parse(hex, 16) do
      {payload_size, ""} when payload_size > 4 ->
        data_size = payload_size - 4
        data_size_skip_lf = data_size - 1

        case payload do
          <<data::bytes-size(data_size_skip_lf), "\n", rest::binary>> ->
            {[data], rest}

          <<data::bytes-size(data_size), rest::binary>> ->
            {[data], rest}

          <<data::bytes-size(data_size)>> ->
            {[data], ""}
        end
      {payload_size, ""} ->
        raise "Invalid PKT-LINE size #{payload_size}: must be > 4 bytes"
      :error ->
        # TODO
        raise "Invalid PKT line #{inspect(pkt)}"
    end
  end

  defp pkt_decode("done"), do: :done
  defp pkt_decode("want " <> hash), do: {:want, hash}
  defp pkt_decode("have " <> hash), do: {:have, hash}
  defp pkt_decode("shallow " <> hash), do: {:shallow, hash}
  defp pkt_decode(pkt_line), do: pkt_line
end

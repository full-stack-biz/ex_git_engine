defmodule ExGitEngine.JobLimiter do
  @moduledoc """
  Runs long jobs (packs, blame, ahead/behind counts, pushed pack indexing,
  per-file patches) at most `max_jobs` at a time, outside the processes that
  ask for them.

  These jobs call dirty NIFs, and the VM has only as many dirty CPU schedulers
  as cores, shared with every other NIF. Without a limit, a burst of blames on a
  big repository would take all of them and stall every other diff. The default
  `max_jobs` is one less than the dirty CPU schedulers, so one is always free.
  Set it with `config :ex_git_engine, max_jobs: n`.

  Waiting jobs are dropped when their caller has exited before they start, so a
  page the user left does not still cost a blame.

  Like a busy port, the limiter turns work away when its queue reaches
  `high_water` (default `10 * max_jobs`): callers get `{:error, :busy}` at once
  instead of waiting until they time out. It accepts work again once the queue
  has drained to `low_water` (default `high_water / 2`). Both can be set with
  `config :ex_git_engine, high_water: n, low_water: n`.

  Started by `ExGitEngine.Application`. `GitAgent` sends its long operations
  here; `run/3` is the same for any other function:

      ExGitEngine.JobLimiter.run(fn -> expensive() end)
  """
  use GenServer

  @type server :: GenServer.server()

  @doc """
  Starts a limiter. Options: `:name` (default `#{inspect(__MODULE__)}`, `nil`
  for none), `:max_jobs`, `:high_water` and `:low_water`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Runs `fun` once a slot is free and returns its result. A job that raises
  returns `{:error, exception}`; `{:error, :busy}` means the queue is full.
  """
  @spec run(server, (-> result), timeout) :: result | {:error, :busy | term} when result: term
  def run(server \\ __MODULE__, fun, timeout \\ :infinity),
    do: GenServer.call(server, {:run, fun}, timeout)

  @doc """
  Like `run/3`, but answers `from` (a `GenServer.from()` received by another
  server) instead of the caller, so that server can return `{:noreply, ...}`.
  """
  @spec submit(server, GenServer.from(), (-> term)) :: :ok
  def submit(server \\ __MODULE__, from, fun), do: GenServer.cast(server, {:submit, from, fun})

  @doc "Returns the number of jobs running."
  @spec running(server) :: non_neg_integer
  def running(server \\ __MODULE__), do: GenServer.call(server, :running)

  @doc "Returns the number of jobs waiting for a slot."
  @spec queued(server) :: non_neg_integer
  def queued(server \\ __MODULE__), do: GenServer.call(server, :queued)

  @impl true
  def init(opts) do
    default = max(:erlang.system_info(:dirty_cpu_schedulers_online) - 1, 1)

    setting = fn key, default ->
      Keyword.get(opts, key, Application.get_env(:ex_git_engine, key, default))
    end

    max_jobs = setting.(:max_jobs, default)
    high_water = setting.(:high_water, 10 * max_jobs)

    {:ok,
     %{
       max_jobs: max_jobs,
       high_water: high_water,
       low_water: setting.(:low_water, div(high_water, 2)),
       busy: false,
       running: MapSet.new(),
       queue: :queue.new()
     }}
  end

  @impl true
  def handle_call({:run, fun}, from, state), do: {:noreply, enqueue(state, from, fun)}
  def handle_call(:running, _from, state), do: {:reply, MapSet.size(state.running), state}
  def handle_call(:queued, _from, state), do: {:reply, :queue.len(state.queue), state}

  @impl true
  def handle_cast({:submit, from, fun}, state), do: {:noreply, enqueue(state, from, fun)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, start_next(%{state | running: MapSet.delete(state.running, ref)})}
  end

  defp enqueue(state, from, fun) do
    if state.busy or :queue.len(state.queue) >= state.high_water do
      GenServer.reply(from, {:error, :busy})
      %{state | busy: true}
    else
      start_next(%{state | queue: :queue.in({from, fun}, state.queue)})
    end
  end

  defp start_next(state) do
    case MapSet.size(state.running) < state.max_jobs && :queue.out(state.queue) do
      {{:value, job}, queue} ->
        busy = state.busy and :queue.len(queue) > state.low_water
        start_next(start_job(%{state | queue: queue, busy: busy}, job))

      _full_or_empty ->
        state
    end
  end

  defp start_job(state, {{caller, _} = from, fun}) do
    if Process.alive?(caller) do
      {_pid, ref} = spawn_monitor(fn -> GenServer.reply(from, safely(fun)) end)
      %{state | running: MapSet.put(state.running, ref)}
    else
      state
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    e in [RuntimeError, ErlangError, MatchError, CaseClauseError, ArgumentError] -> {:error, e}
  end
end

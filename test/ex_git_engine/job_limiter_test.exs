defmodule ExGitEngine.JobLimiterTest do
  use ExUnit.Case, async: true

  alias ExGitEngine.JobLimiter

  test "runs at most max_jobs at once and answers every caller" do
    limiter = start_supervised!({JobLimiter, name: nil, max_jobs: 2})
    running = :counters.new(2, [])

    job = fn ->
      :counters.add(running, 1, 1)
      peak = max(:counters.get(running, 1), :counters.get(running, 2))
      :counters.put(running, 2, peak)
      Process.sleep(50)
      :counters.sub(running, 1, 1)
      :done
    end

    results =
      1..5
      |> Enum.map(fn _ -> Task.async(fn -> JobLimiter.run(limiter, job) end) end)
      |> Task.await_many()

    assert results == List.duplicate(:done, 5)
    assert :counters.get(running, 2) == 2
  end

  test "drops a queued job whose caller is gone" do
    limiter = start_supervised!({JobLimiter, name: nil, max_jobs: 1})
    test = self()

    blocker =
      Task.async(fn ->
        JobLimiter.run(limiter, fn ->
          send(test, {:blocking, self()})
          receive(do: (:go -> :ok))
        end)
      end)

    assert_receive {:blocking, job}

    caller = spawn(fn -> JobLimiter.run(limiter, fn -> send(test, :ran) end) end)
    wait_until(fn -> JobLimiter.queued(limiter) == 1 end)
    Process.exit(caller, :kill)

    send(job, :go)
    assert :ok = Task.await(blocker)

    refute_receive :ran, 100
    assert JobLimiter.queued(limiter) == 0
  end

  test "turns work away while its queue is above the high water mark, until it drains to the low one" do
    limiter = start_supervised!({JobLimiter, name: nil, max_jobs: 1, high_water: 2, low_water: 0})
    test = self()

    gate = fn ->
      send(test, {:job, self()})
      receive(do: (:go -> :done))
    end

    running = Task.async(fn -> JobLimiter.run(limiter, gate) end)
    assert_receive {:job, first}

    queued = for _ <- 1..2, do: Task.async(fn -> JobLimiter.run(limiter, gate) end)
    wait_until(fn -> JobLimiter.queued(limiter) == 2 end)

    assert {:error, :busy} = JobLimiter.run(limiter, fn -> :never end)

    send(first, :go)
    assert :done = Task.await(running)
    assert_receive {:job, second}
    assert {:error, :busy} = JobLimiter.run(limiter, fn -> :never end)

    send(second, :go)
    assert_receive {:job, third}
    wait_until(fn -> JobLimiter.queued(limiter) == 0 end)
    send(third, :go)
    assert [:done, :done] = Task.await_many(queued)

    assert :ok = JobLimiter.run(limiter, fn -> :ok end)
  end

  test "answers a submitted caller directly when busy" do
    limiter = start_supervised!({JobLimiter, name: nil, max_jobs: 1, high_water: 1, low_water: 0})
    test = self()

    Task.async(fn ->
      JobLimiter.run(limiter, fn ->
        send(test, :started)
        Process.sleep(:infinity)
      end)
    end)

    assert_receive :started
    Task.async(fn -> JobLimiter.run(limiter, fn -> :queued end) end)
    wait_until(fn -> JobLimiter.queued(limiter) == 1 end)

    ref = make_ref()
    JobLimiter.submit(limiter, {self(), ref}, fn -> :never end)
    assert_receive {^ref, {:error, :busy}}
  end

  defp wait_until(check, tries \\ 100) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(5) && wait_until(check, tries - 1)
    end
  end
end

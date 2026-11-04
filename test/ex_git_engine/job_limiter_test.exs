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

  test "answers the caller when a job raises, throws or exits" do
    limiter = start_supervised!({JobLimiter, name: nil, max_jobs: 1})

    assert {:error, %KeyError{}} =
             JobLimiter.run(limiter, fn -> raise KeyError, key: :x end, 1_000)

    assert {:error, {:throw, :t}} = JobLimiter.run(limiter, fn -> throw(:t) end, 1_000)
    assert {:error, {:exit, :e}} = JobLimiter.run(limiter, fn -> exit(:e) end, 1_000)
    assert {:error, %RuntimeError{}} = JobLimiter.run(limiter, fn -> raise "r" end, 1_000)
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

  test "turns work away while its queue is at the high water mark, and takes it again once a slot frees" do
    limiter = start_supervised!({JobLimiter, name: nil, max_jobs: 1, high_water: 1})
    test = self()

    gate = fn ->
      send(test, {:job, self()})
      receive(do: (:go -> :done))
    end

    running = Task.async(fn -> JobLimiter.run(limiter, gate) end)
    assert_receive {:job, first}

    queued = Task.async(fn -> JobLimiter.run(limiter, gate) end)
    wait_until(fn -> JobLimiter.queued(limiter) == 1 end)

    assert {:error, :busy} = JobLimiter.run(limiter, fn -> :never end)

    send(first, :go)
    assert :done = Task.await(running)
    assert_receive {:job, second}

    again = Task.async(fn -> JobLimiter.run(limiter, fn -> :ok end) end)
    send(second, :go)
    assert :done = Task.await(queued)
    assert :ok = Task.await(again)
  end

  test "a queued job waits at most max_wait, then its caller gets :busy" do
    limiter = start_supervised!({JobLimiter, name: nil, max_jobs: 1, max_wait: 50})
    test = self()

    Task.async(fn ->
      JobLimiter.run(limiter, fn ->
        send(test, :started)
        Process.sleep(:infinity)
      end)
    end)

    assert_receive :started

    {elapsed, result} = :timer.tc(fn -> JobLimiter.run(limiter, fn -> send(test, :ran) end) end)

    assert result == {:error, :busy}
    assert elapsed >= 50_000
    assert JobLimiter.queued(limiter) == 0
    refute_receive :ran, 100
  end

  test "answers a submitted caller directly when busy" do
    limiter = start_supervised!({JobLimiter, name: nil, max_jobs: 1, high_water: 1})
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

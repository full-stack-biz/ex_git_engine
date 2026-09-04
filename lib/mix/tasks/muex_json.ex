defmodule Mix.Tasks.ExGitEngine.MuexJson do
  @moduledoc """
  Run mutation testing and write results to muex-report.json in the project root.

  Accepts all muex flags plus `--exclude <path_substring>` (repeatable) to skip
  specific files that muex itself cannot exclude.
  """

  use Mix.Task

  # Muex is a dev-only dep; suppress undefined warnings when compiled as a path dep.
  @compile {:no_warn_undefined, [Muex, Muex.Config, Muex.Reporter.Json]}

  alias Muex.Reporter.Json

  @shortdoc "Run mutation testing, save JSON report"
  @impl Mix.Task
  def run(args) do
    {excludes, muex_args} = extract_excludes(args)

    case Muex.Config.from_args(muex_args) do
      {:error, reason} ->
        Mix.raise(reason)

      {:ok, config} ->
        config |> apply_excludes(excludes) |> ensure_test_support_linked() |> run_with_config()
    end
  end

  defp run_with_config(config) do
    System.put_env("MUEX", "1")

    case Muex.run(config) do
      {:error, reason} ->
        Mix.raise(reason)

      {:ok, %{results: []}} ->
        Mix.shell().info("No mutations to test; nothing to score.")

      {:ok, %{results: results, score_low: score_low, score_high: score_high}} ->
        Json.generate(results)
        Mix.shell().info("Report written to muex-report.json")
        check_score(score_low, score_high, config.fail_at)
    end
  end

  defp check_score(score_low, _score_high, fail_at) when score_low >= fail_at, do: :ok

  defp check_score(score_low, score_high, fail_at) do
    score_str =
      if score_low == score_high,
        do: "#{score_low}%",
        else: "#{score_low}%..#{score_high}%"

    Mix.raise("Mutation score #{score_str} is below threshold #{fail_at}%")
  end

  defp extract_excludes(args) do
    {excludes, rest, _} =
      Enum.reduce(args, {[], [], false}, fn
        "--exclude", {ex, rest, _} -> {ex, rest, true}
        val, {ex, rest, true} -> {[val | ex], rest, false}
        arg, {ex, rest, false} -> {ex, [arg | rest], false}
      end)

    {Enum.reverse(excludes), Enum.reverse(rest)}
  end

  defp ensure_test_support_linked(config) do
    support = "test/support"

    if support in config.test_paths,
      do: config,
      else: %{config | test_paths: [support | config.test_paths]}
  end

  defp apply_excludes(config, []), do: config

  defp apply_excludes(config, excludes) do
    expanded =
      config.files
      |> Enum.flat_map(fn pattern ->
        if File.dir?(pattern),
          do: Path.wildcard(Path.join([pattern, "**", "*.ex"])),
          else: Path.wildcard(pattern)
      end)
      |> Enum.reject(fn path -> Enum.any?(excludes, &String.contains?(path, &1)) end)

    %{config | files: expanded}
  end
end

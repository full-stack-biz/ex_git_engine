defmodule ExGitEngine.Mixfile do
  use Mix.Project

  def project do
    [
      app: :ex_git_engine,
      version: "0.9.2",
      build_path: "_build",
      config_path: "config/config.exs",
      deps_path: "deps",
      lockfile: "mix.lock",
      elixir: "~> 1.15",
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_args: ["--quiet"],
      description:
        "Elixir libgit2 wrapper with GenServer-based concurrent access and Git wire protocol",
      package: package(),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:ex_unit, :logger, :telemetry, :stream_split]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/full-stack-biz/ex_git_engine"},
      files: ~w(lib c_src Makefile mix.exs LICENSE readme.md)
    ]
  end

  #
  # Helpers
  #

  defp deps do
    [
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1"},
      {:elixir_make, "~> 0.6"},
      {:stream_split, "~> 0.1"},
      {:telemetry, "~> 1.1"},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end

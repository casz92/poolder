defmodule Poolder.MixProject do
  use Mix.Project

  def project do
    [
      app: :poolder,
      description: "A compile-time builder that generates a concurrent pool of worker processes for parallel task execution",
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      packages: packages()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    []
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    []
  end

  defp packages do
    [
      maintainers: ["Carlos Suarez"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/casz92/poolder"}
    ]
  end
end

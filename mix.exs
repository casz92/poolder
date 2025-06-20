defmodule Poolder.MixProject do
  use Mix.Project

  @version "0.1.6"

  def project do
    [
      app: :poolder,
      name: "Poolder",
      description:
        "A compile-time builder that generates a concurrent pool of worker processes, batchers and schedulers for parallel task execution",
      source_url: "https://github.com/casz92/poolder",
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application, do: []

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [{:ex_doc, ">= 0.0.0", only: :dev, runtime: false}]
  end

  defp package do
    [
      maintainers: ["Carlos Suarez"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/casz92/poolder"}
    ]
  end
end

defmodule Bobbin.MixProject do
  use Mix.Project

  def project do
    [
      app: :bobbin,
      version: "0.6.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      source_url: "https://github.com/heddlehq/Bobbin",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :public_key, :ssl],
      mod: {Bobbin.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.40.1", preserve: Mix.env() == :dev, runtime: false},
      {:yaml_elixir, "~> 2.11"},
      {:req, ">= 0.5.0 and < 1.0.0"},
      {:plug, "~> 1.0", only: :test}
    ]
  end

  defp description do
    "Elixir SDK for building custom integrations and extensions for Heddle."
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "guides/manifest.md", "guides/packages.md"],
      groups_for_extras: [Guides: ~r{guides/}]
    ]
  end

  defp package do
    [
      name: "bobbin",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/heddlehq/Bobbin"},
      files: ~w(lib priv guides mix.exs README.md LICENSE)
    ]
  end
end

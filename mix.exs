defmodule Bobbin.MixProject do
  use Mix.Project

  def project do
    [
      app: :bobbin,
      version: "0.2.2",
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
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.40.1", preserve: Mix.env() == :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "guides/writing-a-node.md"],
      groups_for_extras: [Guides: ["guides/writing-a-node.md"]]
    ]
  end

  defp description do
    "Elixir SDK for building custom integrations and extensions for Heddle."
  end

  defp package do
    [
      name: "bobbin",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/heddlehq/Bobbin"},
      files: ~w(lib guides mix.exs README.md LICENSE)
    ]
  end
end

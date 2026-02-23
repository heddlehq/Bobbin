defmodule FusionKit.MixProject do
  use Mix.Project

  def project do
    [
      app: :fusion_kit,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      source_url: "https://github.com/FusionFlow-app/fusion_kit"
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

  defp description do
    "Elixir SDK for building custom integrations and extensions for FusionFlow."
  end

  defp package do
    [
      name: "fusion_kit",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/FusionFlow-app/fusion_kit"}
    ]
  end
end

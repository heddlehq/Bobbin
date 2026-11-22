defmodule Mix.Tasks.Bobbin.Validate do
  @shortdoc "Checks integration manifests"
  @moduledoc """
  Checks one or more integration manifests.

      mix bobbin.validate integrations/acme.yaml

  Exits with an error when a manifest is invalid, listing what is wrong.
  """

  use Mix.Task

  @impl true
  def run([]), do: Mix.raise("Usage: mix bobbin.validate PATH...")

  def run(paths) do
    results =
      for path <- paths do
        case Bobbin.Integration.load(path) do
          {:ok, integration} ->
            Mix.shell().info("#{path}: ok (#{length(integration.actions)} actions)")
            :ok

          {:error, errors} ->
            Mix.shell().error("#{path}:\n  " <> Enum.join(errors, "\n  "))
            :error
        end
      end

    if :error in results, do: Mix.raise("Some manifests are invalid.")
  end
end

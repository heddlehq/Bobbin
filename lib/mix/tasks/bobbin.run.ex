defmodule Mix.Tasks.Bobbin.Run do
  @shortdoc "Runs an action of an integration against the real service"
  @moduledoc """
  Runs one action of a manifest, the way Heddle would, and prints the result.

      mix bobbin.run integrations/acme.yaml "Create Ticket" \\
        --field title="Printer on fire" --credential api_key=$ACME_KEY

  `--field` and `--credential` take `name=value` and can be repeated.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [field: :keep, credential: :keep])

    [path, action] =
      case positional do
        [path, action] ->
          [path, action]

        _other ->
          Mix.raise(~s(Usage: mix bobbin.run PATH "Action" [--field k=v] [--credential k=v]))
      end

    Mix.Task.run("app.start")

    integration =
      case Bobbin.Integration.load(path) do
        {:ok, integration} -> integration
        {:error, errors} -> Mix.raise(Enum.join(errors, "\n"))
      end

    fields = pairs(Keyword.get_values(opts, :field))
    credential = pairs(Keyword.get_values(opts, :credential))

    case Bobbin.Integration.Request.run(integration, action, fields, credential) do
      {:ok, result} -> Mix.shell().info(JSON.encode!(result))
      {:error, message} -> Mix.raise(message)
    end
  end

  defp pairs(values) do
    Map.new(values, fn value ->
      case String.split(value, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
  end
end

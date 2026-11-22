defmodule Mix.Tasks.Bobbin.New do
  @shortdoc "Writes a new integration manifest"
  @moduledoc """
  Writes the manifest of a new integration, to fill in.

      mix bobbin.new acme_crm

  It is written to `acme_crm.yaml`, or to the path given with `--path`.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [path: :string])

    id =
      case positional do
        [id] -> id
        _other -> Mix.raise("Usage: mix bobbin.new ID [--path PATH]")
      end

    unless Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, id) do
      Mix.raise("The id must be lowercase letters, digits and _, like acme_crm.")
    end

    path = opts[:path] || "#{id}.yaml"

    if File.exists?(path), do: Mix.raise("#{path} already exists.")

    File.write!(path, template(id))
    Mix.shell().info("Wrote #{path}. Check it with: mix bobbin.validate #{path}")
  end

  defp template(id) do
    name = id |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)

    """
    # yaml-language-server: $schema=https://raw.githubusercontent.com/heddlehq/Bobbin/main/priv/integration.schema.json
    id: #{id}
    name: #{name}
    version: 0.1.0
    description: What #{name} is, in one line.
    icon: hero-puzzle-piece
    base_url: https://api.example.com/v1/

    credential:
      label: #{name}
      fields:
        - name: api_key
          label: API key
          secret: true
      auth:
        type: bearer
        token: "{{credential.api_key}}"

    actions:
      - name: Get Item
        description: Returns one item.
        fields:
          - name: id
            label: Item ID
        request:
          method: GET
          path: "items/{{fields.id}}"
        output:
          pick: [id, name]
    """
  end
end

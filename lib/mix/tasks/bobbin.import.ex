defmodule Mix.Tasks.Bobbin.Import do
  @shortdoc "Drafts a manifest from an OpenAPI spec"
  @moduledoc """
  Drafts the manifest of an integration from the service's OpenAPI 3 spec, in JSON or
  YAML, from a file or an address:

      mix bobbin.import https://api.acme.test/openapi.json --id acme --tag contacts,deals

  Each operation becomes an action and each parameter or body property a field. The
  draft checks out with `mix bobbin.validate`, but it is a start: give the actions
  the names people would look for, keep the ones worth a node, and add `output` and
  `pagination`. See `Bobbin.Import.OpenAPI`.

  Options:

    * `--id` and `--name`: the integration's, taken from the spec's title otherwise.
    * `--tag`: only the operations with one of these tags, separated by commas.
    * `--path`: where to write it, `<id>.yaml` by default.
  """

  use Mix.Task

  alias Bobbin.Import.OpenAPI

  @impl true
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [id: :string, name: :string, tag: :string, path: :string])

    source =
      case positional do
        [source] -> source
        _other -> Mix.raise("Usage: mix bobbin.import SPEC [--id ID] [--tag a,b] [--path PATH]")
      end

    spec = source |> read() |> decode(source)

    convert_opts =
      [
        id: opts[:id],
        name: opts[:name],
        tags: opts[:tag] && String.split(opts[:tag], ",", trim: true)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    document = OpenAPI.convert(spec, convert_opts)
    {"id", id} = List.keyfind(document, "id", 0)
    {"actions", actions} = List.keyfind(document, "actions", 0) || {"actions", []}

    if actions == [], do: Mix.raise("The spec has no operations to import.")

    path = opts[:path] || "#{id}.yaml"
    if File.exists?(path), do: Mix.raise("#{path} already exists.")

    File.write!(path, header() <> OpenAPI.to_yaml(document))

    Mix.shell().info(
      "Wrote #{path}, with #{length(actions)} actions. Check it with: mix bobbin.validate #{path}"
    )
  end

  defp header do
    "# yaml-language-server: $schema=https://raw.githubusercontent.com/heddlehq/Bobbin/main/priv/integration.schema.json\n" <>
      "# Drafted by mix bobbin.import: review names, fields, output and pagination.\n"
  end

  defp read("http" <> _ = url) do
    Application.ensure_all_started(:req)

    case Req.get(url, decode_body: false, retry: false) do
      {:ok, %{status: 200, body: body}} -> body
      {:ok, %{status: status}} -> Mix.raise("#{url} answered #{status}.")
      {:error, reason} -> Mix.raise("Could not fetch #{url}: #{Exception.message(reason)}")
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> body
      {:error, reason} -> Mix.raise("Can't read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp decode(text, source) do
    result =
      case JSON.decode(text) do
        {:ok, map} -> {:ok, map}
        {:error, _not_json} -> YamlElixir.read_from_string(text)
      end

    case result do
      {:ok, %{"openapi" => "3" <> _} = spec} ->
        spec

      {:ok, %{"swagger" => _}} ->
        Mix.raise("#{source} is Swagger 2. Convert it to OpenAPI 3 first.")

      _other ->
        Mix.raise("#{source} isn't an OpenAPI 3 spec.")
    end
  end
end

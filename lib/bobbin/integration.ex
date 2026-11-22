defmodule Bobbin.Integration do
  @moduledoc """
  An integration written as a manifest: a YAML file that describes a service's
  credential and its actions as HTTP requests, with no code.

  Each action becomes a node in Heddle, with a `success` and an `error` output.

  ## Example

  ```yaml
  id: acme
  name: Acme
  version: 1.0.0
  description: Tickets in Acme.
  icon: hero-ticket
  base_url: https://api.acme.test/v1/

  credential:
    label: Acme
    fields:
      - name: api_key
        label: API key
        secret: true
    auth:
      type: header
      name: X-Api-Key
      value: "{{credential.api_key}}"

  actions:
    - name: Create Ticket
      description: Opens a ticket.
      fields:
        - name: title
          label: Title
      request:
        method: POST
        path: tickets
        body:
          title: "{{fields.title}}"
      output:
        pick: [id, url]
  ```

  ## Templates

  Strings in `request`, `credential.auth` and `output.value` may hold
  `{{fields.<name>}}` and `{{credential.<name>}}`. A string that is a single
  placeholder keeps the value's type. Values that end up empty are left out of the
  query and the body, so optional fields need no extra syntax.

  ## Credential `auth` types

    * `bearer`: `token`
    * `header`: `name` and `value`
    * `query`: `name` and `value`
    * `basic`: `username` and `password`
    * `oauth2`: `authorize_url`, `token_url` and `scopes`. The host runs the
      authorization and passes the access token as `{{credential.access_token}}`.
    * `none`

  ## Responses

    * `errors.ok_path`: a field of the body that must be `true`, for APIs that
      answer 200 when something failed. `errors.message_path` holds why.
    * `output.path`: the part of the body the node returns, like `data.items`.
    * `output.pick`: the keys to keep, from each item of a list.
    * `output.value`: a value built from templates, in place of the body.

  ## Pagination

  `pagination.type` is `cursor`, `offset` or `link` (the `Link` header). The node
  returns the items of every page, from `pagination.items_path`.

  See `priv/integration.schema.json` for the full format.
  """

  @type t :: %{
          id: String.t(),
          name: String.t(),
          version: String.t(),
          description: String.t(),
          icon: String.t(),
          category: String.t(),
          base_url: String.t(),
          credential: map() | nil,
          errors: map(),
          actions: [map()]
        }

  @auth_types ~w(bearer header query basic oauth2 none)
  @methods ~w(GET POST PUT PATCH DELETE)
  @field_types ~w(text textarea number select)
  @pagination_types ~w(cursor offset link)
  @id ~r/\A[a-z][a-z0-9_]*\z/
  @version ~r/\A\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?\z/

  @doc "Reads and checks the manifest at `path`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, [String.t()]}
  def load(path) do
    case File.read(path) do
      {:ok, yaml} -> parse(yaml)
      {:error, reason} -> {:error, ["Can't read #{path}: #{:file.format_error(reason)}"]}
    end
  end

  @doc "Like `load/1`, raising with what is wrong."
  @spec load!(Path.t()) :: t()
  def load!(path) do
    case load(path) do
      {:ok, integration} -> integration
      {:error, errors} -> raise ArgumentError, "#{path}:\n  " <> Enum.join(errors, "\n  ")
    end
  end

  @doc "Parses and checks a manifest written in YAML."
  @spec parse(String.t()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> validate(map)
      {:ok, _other} -> {:error, ["The manifest must be a map."]}
      {:error, error} -> {:error, ["Invalid YAML: #{Exception.message(error)}"]}
    end
  end

  @doc "Checks a manifest already decoded into a map with string keys."
  @spec validate(map()) :: {:ok, t()} | {:error, [String.t()]}
  def validate(map) do
    errors =
      []
      |> required(map, "id", @id, "a lowercase id, like acme_crm")
      |> required(map, "name")
      |> required(map, "version", @version, "a version like 1.0.0")
      |> required(map, "base_url", ~r/\Ahttps?:\/\//, "a URL starting with http")
      |> check_credential(map["credential"])
      |> check_actions(map["actions"])

    if errors == [], do: {:ok, normalize(map)}, else: {:error, Enum.reverse(errors)}
  end

  @doc "The action called `name`, or nil."
  @spec action(t(), String.t()) :: map() | nil
  def action(integration, name), do: Enum.find(integration.actions, &(&1.name == name))

  ## Checks

  defp required(errors, map, key, format \\ nil, hint \\ nil) do
    case map[key] do
      value when is_binary(value) and value != "" ->
        if format && not Regex.match?(format, value),
          do: ["#{key} must be #{hint}" | errors],
          else: errors

      _missing ->
        ["#{key} is required" | errors]
    end
  end

  defp check_credential(errors, nil), do: errors

  defp check_credential(errors, credential) when is_map(credential) do
    errors = check_fields(errors, "credential", credential["fields"] || [])

    case credential["auth"] do
      %{"type" => type} when type in @auth_types ->
        errors

      %{"type" => type} ->
        [
          "credential.auth.type #{inspect(type)} is not one of #{Enum.join(@auth_types, ", ")}"
          | errors
        ]

      _other ->
        ["credential.auth.type is required" | errors]
    end
  end

  defp check_credential(errors, _other), do: ["credential must be a map" | errors]

  defp check_actions(errors, [_ | _] = actions) do
    names = Enum.map(actions, &(is_map(&1) && &1["name"]))

    errors =
      if length(Enum.uniq(names)) == length(names),
        do: errors,
        else: ["actions must have different names" | errors]

    actions
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {action, index}, errors -> check_action(errors, action, index) end)
  end

  defp check_actions(errors, _other), do: ["actions must list at least one action" | errors]

  defp check_action(errors, action, index) when is_map(action) do
    where = "actions[#{index}]"
    request = action["request"]

    errors =
      errors
      |> required_in(action, "name", where)
      |> check_fields(where, action["fields"] || [])

    errors =
      case request do
        %{"method" => method, "path" => path} when method in @methods and is_binary(path) ->
          errors

        %{"method" => method} when method not in @methods ->
          ["#{where}.request.method must be one of #{Enum.join(@methods, ", ")}" | errors]

        _other ->
          ["#{where}.request needs a method and a path" | errors]
      end

    case action["pagination"] do
      nil ->
        errors

      %{"type" => type, "items_path" => _} when type in @pagination_types ->
        errors

      _other ->
        [
          "#{where}.pagination needs a type (#{Enum.join(@pagination_types, ", ")}) and items_path"
          | errors
        ]
    end
  end

  defp check_action(errors, _action, index), do: ["actions[#{index}] must be a map" | errors]

  defp required_in(errors, map, key, where) do
    case map[key] do
      value when is_binary(value) and value != "" -> errors
      _missing -> ["#{where}.#{key} is required" | errors]
    end
  end

  defp check_fields(errors, where, fields) when is_list(fields) do
    fields
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {%{"name" => name} = field, index}, errors when is_binary(name) ->
        type = field["type"] || "text"

        cond do
          type not in @field_types ->
            [
              "#{where}.fields[#{index}].type must be one of #{Enum.join(@field_types, ", ")}"
              | errors
            ]

          type == "select" and not is_list(field["options"]) ->
            ["#{where}.fields[#{index}] is a select and needs options" | errors]

          true ->
            errors
        end

      {_field, index}, errors ->
        ["#{where}.fields[#{index}] needs a name" | errors]
    end)
  end

  defp check_fields(errors, where, _fields), do: ["#{where}.fields must be a list" | errors]

  ## Normalizing

  defp normalize(map) do
    id = map["id"]

    %{
      id: id,
      name: map["name"],
      version: map["version"],
      description: map["description"] || "",
      icon: map["icon"] || "hero-puzzle-piece",
      category: map["category"] || id,
      base_url: map["base_url"],
      credential: normalize_credential(map["credential"], map),
      errors: %{
        ok_path: get_in(map, ["errors", "ok_path"]),
        message_path: get_in(map, ["errors", "message_path"])
      },
      actions: Enum.map(map["actions"], &normalize_action/1)
    }
  end

  defp normalize_credential(nil, _map), do: nil

  defp normalize_credential(credential, map) do
    %{
      kind: credential["kind"] || map["id"],
      label: credential["label"] || map["name"],
      fields: Enum.map(credential["fields"] || [], &normalize_field/1),
      auth: credential["auth"]
    }
  end

  defp normalize_action(action) do
    request = action["request"]

    %{
      name: action["name"],
      description: action["description"] || "",
      fields: Enum.map(action["fields"] || [], &normalize_field/1),
      request: %{
        method: request["method"],
        path: request["path"],
        headers: request["headers"] || %{},
        query: request["query"] || %{},
        body: request["body"],
        body_type: request["body_type"] || "json"
      },
      output: action["output"] || %{},
      pagination: action["pagination"]
    }
  end

  defp normalize_field(field) do
    %{
      name: field["name"],
      label: field["label"] || field["name"],
      type: field["type"] || "text",
      default: to_string(field["default"] || ""),
      options: field["options"],
      secret: field["secret"] == true,
      required: field["required"] == true,
      strip: field["strip"]
    }
  end
end

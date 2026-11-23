defmodule Bobbin.Import.OpenAPI do
  @moduledoc """
  Drafts a manifest from an OpenAPI 3 spec: the credential from its security scheme,
  an action for each operation, a field for each parameter and each property of a
  JSON, form or multipart body, with the field type its schema calls for.

  The draft is a start, not an integration: names, descriptions, `output` and
  `pagination` need someone who knows the service. See `mix bobbin.import`.

      spec |> Bobbin.Import.OpenAPI.convert(tags: ["contacts"]) |> Bobbin.Import.OpenAPI.to_yaml()
  """

  @methods ~w(get post put patch delete)
  @small_words ~w(a an and as at by for from in of on or the to via with)

  @typedoc "A YAML document whose maps keep their order: lists of `{key, value}`."
  @type ordered :: [{String.t(), term()}]

  @doc """
  The manifest for `spec`, a decoded OpenAPI 3 document.

  Options: `:id` and `:name` for the integration, `:tags` to keep only the
  operations with one of them.
  """
  @spec convert(map(), keyword()) :: ordered()
  def convert(spec, opts \\ []) do
    name = opts[:name] || get_in(spec, ["info", "title"]) || "Service"
    id = opts[:id] || slug(name)
    tags = opts[:tags]

    actions =
      for {path, item} <- Enum.sort(spec["paths"] || %{}),
          method <- @methods,
          operation = item[method],
          is_map(operation),
          tags == nil or Enum.any?(operation["tags"] || [], &(&1 in tags)) do
        action(spec, path, method, operation, item["parameters"] || [])
      end
      |> unique_names()

    [
      {"id", id},
      {"name", name},
      {"version", "1.0.0"},
      {"description", first_sentence(get_in(spec, ["info", "description"])) || name},
      {"icon", "hero-puzzle-piece"},
      {"base_url", base_url(spec)}
    ] ++ credential(spec) ++ [{"actions", actions}]
  end

  ## Service

  defp base_url(spec) do
    case spec["servers"] do
      [%{"url" => url} = server | _] ->
        url =
          Enum.reduce(server["variables"] || %{}, url, fn {name, variable}, url ->
            String.replace(url, "{#{name}}", to_string(variable["default"] || ""))
          end)

        if String.ends_with?(url, "/"), do: url, else: url <> "/"

      _none ->
        "https://example.com/"
    end
  end

  defp credential(spec) do
    case spec |> get_in(["components", "securitySchemes"]) |> Kernel.||(%{}) |> Enum.sort() do
      [{_name, scheme} | _] -> [{"credential", scheme(resolve(spec, scheme))}]
      [] -> []
    end
  end

  defp secret(name, label), do: [{"name", name}, {"label", label}, {"secret", true}]

  defp scheme(%{"type" => "http", "scheme" => scheme}) do
    case String.downcase(scheme) do
      "basic" ->
        [
          {"fields",
           [[{"name", "username"}, {"label", "Username"}], secret("password", "Password")]},
          {"auth",
           [
             {"type", "basic"},
             {"username", "{{credential.username}}"},
             {"password", "{{credential.password}}"}
           ]}
        ]

      _bearer ->
        [
          {"fields", [secret("token", "API token")]},
          {"auth", [{"type", "bearer"}, {"token", "{{credential.token}}"}]}
        ]
    end
  end

  defp scheme(%{"type" => "apiKey", "in" => place, "name" => name}) do
    type = if place == "query", do: "query", else: "header"

    [
      {"fields", [secret("api_key", "API key")]},
      {"auth", [{"type", type}, {"name", name}, {"value", "{{credential.api_key}}"}]}
    ]
  end

  defp scheme(%{"type" => "oauth2", "flows" => flows}) do
    client = [
      [{"name", "client_id"}, {"label", "Client ID"}],
      secret("client_secret", "Client secret")
    ]

    case flows do
      %{"authorizationCode" => flow} ->
        [
          {"fields", client},
          {"auth",
           [
             {"type", "oauth2"},
             {"authorize_url", flow["authorizationUrl"]},
             {"token_url", flow["tokenUrl"]},
             {"scopes", Map.keys(flow["scopes"] || %{}) |> Enum.sort()}
           ]}
        ]

      %{"clientCredentials" => flow} ->
        [
          {"fields", client},
          {"auth",
           [
             {"type", "client_credentials"},
             {"token_url", flow["tokenUrl"]},
             {"client_id", "{{credential.client_id}}"},
             {"client_secret", "{{credential.client_secret}}"}
           ]}
        ]

      _other ->
        scheme(%{})
    end
  end

  defp scheme(_other) do
    [
      {"fields", [secret("token", "API token")]},
      {"auth", [{"type", "bearer"}, {"token", "{{credential.token}}"}]}
    ]
  end

  ## Actions

  defp action(spec, path, method, operation, shared) do
    parameters =
      (shared ++ (operation["parameters"] || []))
      |> Enum.map(&resolve(spec, &1))
      |> Enum.filter(&(&1["in"] in ["path", "query"]))
      |> Enum.uniq_by(&{&1["in"], &1["name"]})

    {body_type, body_fields} = body(spec, operation["requestBody"])

    param_fields =
      for parameter <- parameters do
        schema = resolve(spec, parameter["schema"] || %{})
        required = parameter["in"] == "path" or parameter["required"] == true
        field(field_name(parameter["name"]), schema, required)
      end

    taken = MapSet.new(param_fields, &field_key/1)

    body_fields =
      Enum.map(body_fields, fn {key, field} ->
        name = field_key(field)
        name = if MapSet.member?(taken, name), do: name <> "_body", else: name
        {key, List.keystore(field, "name", 0, {"name", name})}
      end)

    request =
      [
        {"method", String.upcase(method)},
        {"path", path |> String.trim_leading("/") |> placeholders()}
      ] ++
        query(parameters) ++
        case body_fields do
          [] ->
            []

          fields ->
            type = if body_type == "json", do: [], else: [{"body_type", body_type}]

            type ++
              [{"body", for({key, field} <- fields, do: {key, "{{fields.#{field_key(field)}}}"})}]
        end

    [{"name", operation_name(operation, method, path)}] ++
      maybe("description", first_sentence(operation["description"])) ++
      maybe("resource", operation["tags"] |> List.wrap() |> List.first() |> resource()) ++
      maybe_list("fields", param_fields ++ Enum.map(body_fields, &elem(&1, 1))) ++
      [{"request", request}]
  end

  defp query(parameters) do
    case for p <- parameters,
             p["in"] == "query",
             do: {p["name"], "{{fields.#{field_name(p["name"])}}}"} do
      [] -> []
      pairs -> [{"query", pairs}]
    end
  end

  defp placeholders(path) do
    Regex.replace(~r/\{([^}]+)\}/, path, fn _match, name -> "{{fields.#{field_name(name)}}}" end)
  end

  defp body(_spec, nil), do: {"json", []}

  defp body(spec, request_body) do
    content = resolve(spec, request_body)["content"] || %{}

    {type, media} =
      cond do
        content["application/json"] ->
          {"json", content["application/json"]}

        content["multipart/form-data"] ->
          {"multipart", content["multipart/form-data"]}

        content["application/x-www-form-urlencoded"] ->
          {"form", content["application/x-www-form-urlencoded"]}

        content["application/octet-stream"] ->
          {"binary", nil}

        true ->
          {"json", nil}
      end

    case {type, media} do
      {"binary", _} ->
        {"binary", []}

      {_type, nil} ->
        {type, []}

      {type, media} ->
        schema = resolve(spec, media["schema"] || %{})
        required = schema["required"] || []

        fields =
          for {key, property} <- Enum.sort(schema["properties"] || %{}),
              property = resolve(spec, property),
              property["readOnly"] != true do
            {key, field(field_name(key), property, key in required)}
          end

        {type, fields}
    end
  end

  defp field(name, schema, required) do
    base = [{"name", name}, {"label", label(name)}]

    typed =
      case schema do
        %{"enum" => [_ | _] = values} ->
          [
            {"type", "select"},
            {"options", for(v <- values, do: [{"label", to_string(v)}, {"value", to_string(v)}])}
          ]

        %{"type" => "array", "items" => %{"enum" => [_ | _] = values}} ->
          [
            {"type", "multiselect"},
            {"options", for(v <- values, do: [{"label", to_string(v)}, {"value", to_string(v)}])}
          ]

        %{"type" => type} when type in ["integer", "number"] ->
          [{"type", "number"}]

        %{"type" => "boolean"} ->
          [{"type", "boolean"}]

        %{"type" => type} when type in ["object", "array"] ->
          [{"type", "json"}]

        %{"format" => format} when format in ["date-time", "date"] ->
          [{"type", "datetime"}]

        %{"format" => "binary"} ->
          [{"type", "file"}]

        _text ->
          []
      end

    base ++ typed ++ if(required, do: [{"required", true}], else: [])
  end

  ## Names

  defp operation_name(operation, method, path) do
    raw =
      cond do
        is_binary(operation["summary"]) and operation["summary"] != "" -> operation["summary"]
        is_binary(operation["operationId"]) -> words(operation["operationId"])
        true -> "#{method} #{path}"
      end

    raw |> String.trim() |> String.trim_trailing(".") |> String.slice(0, 60) |> title()
  end

  defp unique_names(actions) do
    {actions, _seen} =
      Enum.map_reduce(actions, %{}, fn action, seen ->
        {"name", name} = List.keyfind(action, "name", 0)
        count = Map.get(seen, name, 0) + 1
        name_here = if count == 1, do: name, else: "#{name} #{count}"
        {List.keystore(action, "name", 0, {"name", name_here}), Map.put(seen, name, count)}
      end)

    actions
  end

  # listPets, list_pets and list-pets read as "list pets".
  defp words(id) do
    id
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.replace(~r/[_\-.\/]+/, " ")
    |> String.downcase()
  end

  defp title(text) do
    text
    |> String.split(" ", trim: true)
    |> Enum.with_index()
    |> Enum.map_join(" ", fn
      {word, 0} ->
        capitalize(word)

      {word, _i} ->
        if String.downcase(word) in @small_words,
          do: String.downcase(word),
          else: capitalize(word)
    end)
  end

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize(""), do: ""

  defp resource(nil), do: nil
  defp resource(tag), do: tag |> words() |> title()

  defp label(name), do: name |> words() |> capitalize()

  defp field_name(name), do: Regex.replace(~r/[^A-Za-z0-9_]/, to_string(name), "_")
  defp field_key(field), do: elem(List.keyfind(field, "name", 0), 1)

  defp slug(name) do
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
    if slug =~ ~r/\A[a-z]/, do: slug, else: "api_" <> slug
  end

  defp first_sentence(nil), do: nil

  defp first_sentence(text) do
    text
    |> String.split(~r/(?<=\.)\s|\n/, parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, 200)
    |> case do
      "" -> nil
      sentence -> sentence
    end
  end

  defp maybe(_key, nil), do: []
  defp maybe(key, value), do: [{key, value}]

  defp maybe_list(_key, []), do: []
  defp maybe_list(key, list), do: [{key, list}]

  ## References

  defp resolve(spec, %{"$ref" => "#/" <> path}) do
    target = get_in(spec, String.split(path, "/") |> Enum.map(&unescape/1))
    if target, do: resolve(spec, target), else: %{}
  end

  defp resolve(_spec, value), do: value

  defp unescape(part), do: part |> String.replace("~1", "/") |> String.replace("~0", "~")

  ## YAML

  @doc "Writes an `ordered` document as YAML."
  @spec to_yaml(ordered()) :: String.t()
  def to_yaml(document), do: IO.iodata_to_binary(emit_map(document, 0))

  defp emit_map(pairs, indent) do
    Enum.map(pairs, fn {key, value} ->
      [pad(indent), scalar(key), ":", emit_value(value, indent)]
    end)
  end

  defp emit_value([{_k, _v} | _] = pairs, indent), do: ["\n", emit_map(pairs, indent + 2)]
  defp emit_value([], _indent), do: " []\n"

  defp emit_value(list, indent) when is_list(list) do
    ["\n", Enum.map(list, &emit_item(&1, indent + 2))]
  end

  defp emit_value(value, _indent), do: [" ", scalar(value), "\n"]

  defp emit_item([{_k, _v} | _] = pairs, indent) do
    [first | rest] = emit_map(pairs, indent + 2)
    [_pad | line] = first
    [pad(indent), "- ", line, rest]
  end

  defp emit_item(list, indent) when is_list(list),
    do: [pad(indent), "-", emit_value(list, indent)]

  defp emit_item(value, indent), do: [pad(indent), "- ", scalar(value), "\n"]

  defp pad(n), do: String.duplicate(" ", n)

  defp scalar(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp scalar(nil), do: "null"

  defp scalar(value) when is_binary(value) do
    plain? =
      value != "" and value == String.trim(value) and
        not Regex.match?(~r/[:#\{\}\[\],&*!|>'"%@`]|^[-?]|\n/, value) and
        not Regex.match?(~r/\A(true|false|yes|no|on|off|null|~|y|n)\z/i, value) and
        not Regex.match?(~r/\A[-+.0-9][0-9._eE+-]*\z/, value)

    if plain?, do: value, else: JSON.encode!(value)
  end
end

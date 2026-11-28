defmodule Bobbin.Integration.Request do
  @moduledoc """
  Runs an action of a `Bobbin.Integration` against the real service.

  Heddle runs actions through here, and so does `mix bobbin.run`, so an integration
  behaves the same in both.
  """

  alias Bobbin.Integration
  alias Bobbin.Integration.Auth

  @max_pages 100
  @placeholder ~r/\{\{\s*(fields|credential|auth|request|webhook)\.([A-Za-z0-9_]+)\s*\}\}/

  # In a path, `{{fields.repo | path}}` lets a value like owner/name span segments.
  @path_placeholder ~r/\{\{\s*(fields|credential|auth|request|webhook)\.([A-Za-z0-9_]+)\s*(?:\|\s*(path|name)\s*)?\}\}/
  # `{{fields.file | base64}}`, alone in a value, is the file's content (or the text) in
  # Base64, for APIs that take a file inside JSON; `{{fields.file | name}}` its name.
  @item ~r/\A\{\{\s*item\s*\}\}\z/
  @item_inline ~r/\{\{\s*item\s*\}\}/
  @single_placeholder ~r/\A\{\{\s*(fields|credential|auth|request|webhook)\.([A-Za-z0-9_]+)\s*(?:\|\s*(base64|name|keep)\s*)?\}\}\z/

  @doc """
  Runs the action called `action_name`.

  `fields` holds the value of each field of the action, already rendered by the
  host, and `credential` the values of the credential. `req_options` go to `Req`.

  Returns `{:ok, result}` or `{:error, message}`.
  """
  @spec run(Integration.t(), String.t(), map(), map(), keyword()) ::
          {:ok, term()} | {:error, String.t()}
  def run(integration, action_name, fields, credential, req_options \\ []) do
    case Integration.action(integration, action_name) do
      nil ->
        {:error, "#{integration.name} has no action called #{action_name}."}

      action ->
        perform(integration, action, fields, credential, req_options)
    end
  end

  @doc """
  Calls the trigger called `trigger_name` once, for the host to compare with what it
  saw before.

  Returns `{:ok, items}`, each item paired with its id as a string:
  `[{"42", %{"id" => 42, ...}}]`. Items without an id are left out.
  """
  @spec poll(Integration.t(), String.t(), map(), map(), keyword()) ::
          {:ok, [{String.t(), term()}]} | {:error, String.t()}
  def poll(integration, trigger_name, fields, credential, req_options \\ []) do
    case Integration.trigger(integration, trigger_name) do
      nil ->
        {:error, "#{integration.name} has no trigger called #{trigger_name}."}

      %{request: nil} ->
        {:error, "#{trigger_name} waits for #{integration.name} to send an event."}

      trigger ->
        case perform(integration, trigger, fields, credential, req_options) do
          {:ok, items} when is_list(items) ->
            {:ok, for(item <- items, id = item_id(item, trigger.poll.id), do: {id, item})}

          # Some APIs answer 204, with no body, when there is nothing new.
          {:ok, empty} when empty in [nil, ""] ->
            {:ok, []}

          {:ok, _other} ->
            {:error, "#{trigger_name} must return a list, see output.path."}

          error ->
            error
        end
    end
  end

  @doc """
  Lists the options of the field `field_name` of an action or a trigger, from its
  `options_from`. `fields` holds what the node has so far, for options that depend on
  another field.

  Returns `{:ok, [%{"label" => label, "value" => value}]}`, both as text.
  """
  @spec options(Integration.t(), String.t(), String.t(), map(), map(), keyword()) ::
          {:ok, [map()]} | {:error, String.t()}
  def options(integration, action_name, field_name, fields, credential, req_options \\ []) do
    action =
      Integration.action(integration, action_name) ||
        Integration.trigger(integration, action_name)

    field = action && Enum.find(action.fields, &(&1.name == field_name))

    case field do
      %{options_from: %{} = from} ->
        # The other fields may still be empty while the node is being filled.
        lister = %{
          fields: Enum.map(action.fields, &%{&1 | required: false}),
          request: from.request,
          output: %{"path" => from.path},
          pagination: from.pagination
        }

        with {:ok, items} <- perform(integration, lister, fields, credential, req_options) do
          {:ok,
           for item <- List.wrap(items),
               value = dig(item, from.value),
               value != nil do
             %{"label" => text(dig(item, from.label) || value), "value" => text(value)}
           end}
        end

      _other ->
        {:error, "#{action_name} has no options to fetch for #{field_name}."}
    end
  end

  defp item_id(item, path) when is_map(item) do
    case dig(item, path) do
      nil -> nil
      id -> text(id)
    end
  end

  defp item_id(_item, _path), do: nil

  @doc false
  # Sends a request shaped like an action's (`fields`, `request`, `output`,
  # `pagination`), with `extra` templates like `webhook`.
  def send_request(integration, action, fields, credential, req_options, extra \\ %{}),
    do: perform(integration, action, fields, credential, req_options, extra)

  defp perform(integration, action, fields, credential, req_options, extra \\ %{}) do
    credential = credential || %{}

    with {:ok, values} <- field_values(action, fields),
         vars = Map.merge(extra, %{"fields" => values, "credential" => credential}),
         {:ok, base_url} <- base_url(integration, integration.base_url, credential),
         {:ok, url} <- base_url(integration, action_base_url(action, integration), credential) do
      send = fn ->
        with {:ok, request} <-
               build(url, Map.get(integration, :headers, %{}), action, vars, req_options),
             {:ok, request, key} <- Auth.put(request, integration, base_url, vars, req_options) do
          result =
            case action.pagination do
              nil -> request |> call(integration) |> output(action, vars)
              pagination -> paginate(request, integration, pagination, action)
            end

          {:sent, result, key}
        end
      end

      case send.() do
        # A token Bobbin keeps was refused: fetch a new one and try once more.
        {:sent, {:unauthorized, _message}, key} when key != nil ->
          Auth.forget(key)

          case send.() do
            {:sent, result, _key} -> unauthorized_as_error(result)
            error -> error
          end

        {:sent, result, _key} ->
          unauthorized_as_error(result)

        error ->
          error
      end
    end
  end

  defp unauthorized_as_error({:unauthorized, message}), do: {:error, message}
  defp unauthorized_as_error(result), do: result

  ## Address

  @host_value ~r/\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z/

  # The address may take values of the credential: the account's subdomain, or the
  # whole address of a server the user runs. Neither may point the request at
  # another path, a user or a query.
  # An action may go to an address of its own, like a service's host for uploads.
  defp action_base_url(action, integration),
    do: (action.request && Map.get(action.request, :base_url)) || integration.base_url

  defp base_url(integration, template, credential) do
    leading = Regex.match?(~r/\A\{\{/, template)

    bad =
      @placeholder
      |> Regex.scan(template, return: :index)
      |> Enum.find_value(fn [{start, length}, _scope, _name] ->
        [_match, scope, name] = Regex.run(@placeholder, binary_part(template, start, length))
        value = text(get_in(%{"credential" => credential, "fields" => %{}}, [scope, name]))

        ok? =
          if start == 0 and leading,
            do: server_url?(value),
            else: Regex.match?(@host_value, value)

        if ok?, do: nil, else: name
      end)

    case bad do
      nil ->
        {:ok, render(template, %{"credential" => credential, "fields" => %{}})}

      name ->
        {:error,
         "#{integration.name}: the #{name} in the credential isn't valid for the address."}
    end
  end

  defp server_url?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _other ->
        false
    end
  end

  @doc "Fills the templates in `value`, see `Bobbin.Integration`."
  @spec render(term(), map()) :: term()
  def render(value, vars) when is_binary(value) do
    case Regex.run(@single_placeholder, value) do
      nil when is_map_key(vars, "item") ->
        if Regex.match?(@item, value),
          do: vars["item"],
          else:
            Regex.replace(@item_inline, render(value, Map.delete(vars, "item")), fn _ ->
              text(vars["item"])
            end)

      [_match, scope, name] ->
        get_in(vars, [scope, name])

      [_match, scope, name, "base64"] ->
        vars |> get_in([scope, name]) |> base64()

      [_match, scope, name, "name"] ->
        vars |> get_in([scope, name]) |> file_name()

      [_match, scope, name, "keep"] ->
        case get_in(vars, [scope, name]) do
          empty when empty in [nil, ""] -> :bobbin_blank
          value -> value
        end

      nil ->
        Regex.replace(@placeholder, value, fn _match, scope, name ->
          vars |> get_in([scope, name]) |> text()
        end)
    end
  end

  # `_merge` takes a map, usually from a json field, and spreads it into the map that
  # holds it, so custom fields sit next to the fixed ones. Its keys win.
  #
  # `_if` leaves the map out, as nil (or out of its list), when its value is empty, so
  # a map with fixed keys, like `{dateTime, timeZone: UTC}`, isn't sent alone.
  #
  # `_each` makes a copy of the map for each value of a list, or of a text with commas,
  # with the value as `{{item}}`.
  def render(%{"_each" => each} = map, vars) do
    items =
      case render(each, vars) do
        list when is_list(list) -> list
        text when is_binary(text) -> text |> String.split(",") |> Enum.map(&String.trim/1)
        _none -> []
      end
      |> Enum.reject(&(&1 in [nil, ""]))

    template =
      case Map.delete(map, "_each") do
        %{"_value" => value} = only when map_size(only) == 1 -> value
        template -> template
      end

    case items do
      [] -> nil
      items -> Enum.map(items, &render(template, Map.put(vars, "item", &1)))
    end
  end

  def render(map, vars) when is_map(map) do
    if skip?(map, vars) do
      nil
    else
      rendered = map |> Map.delete("_if") |> Map.new(fn {k, v} -> {k, render(v, vars)} end)

      case Map.pop(rendered, "_merge") do
        {extra, rest} when is_map(extra) -> Map.merge(rest, extra)
        {_none, rest} -> rest
      end
    end
  end

  def render(list, vars) when is_list(list),
    do: for(item <- list, not skip?(item, vars), do: render(item, vars))

  def render(value, _vars), do: value

  defp skip?(%{"_if" => condition}, vars),
    do: render(condition, vars) in [nil, "", false, [], %{}]

  defp skip?(_value, _vars), do: false

  @doc """
  Renders the path of a request: each value is encoded as one segment, so a `/`, `?`
  or `#` in it stays part of the value (GitLab's `group/project` becomes
  `group%2Fproject`) and can't reach another address.
  """
  def render_path(path, vars) when is_binary(path) do
    Regex.replace(@path_placeholder, path, fn
      _match, scope, name, "" ->
        vars |> get_in([scope, name]) |> text() |> segment()

      _match, scope, name, "name" ->
        vars |> get_in([scope, name]) |> file_name() |> text() |> segment()

      _match, scope, name, _path ->
        vars
        |> get_in([scope, name])
        |> text()
        |> String.split("/")
        |> Enum.reject(&(&1 in ["", ".", ".."]))
        |> Enum.map_join("/", &segment/1)
    end)
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # A file's name, or the last part of a path like /Reports/2026.pdf.
  defp file_name({:bobbin_file, ref}), do: ref["name"]

  defp file_name(path) when is_binary(path) and path != "",
    do: path |> String.trim_trailing("/") |> String.split("/") |> List.last()

  defp file_name(_other), do: nil

  defp text(nil), do: ""
  defp text(:bobbin_blank), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp text(value), do: JSON.encode!(value)

  ## Fields

  defp field_values(action, fields) do
    Enum.reduce_while(action.fields, {:ok, %{}}, fn field, {:ok, acc} ->
      value = Map.get(fields || %{}, field.name)
      value = if value in [nil, ""], do: field.default, else: value

      case cast(field, value) do
        {:error, message} ->
          {:halt, {:error, message}}

        {:ok, value} when value in [nil, "", []] and field.required ->
          {:halt, {:error, "#{field.label} is required."}}

        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, field.name, value)}}
      end
    end)
  end

  defp cast(%{type: "number"} = field, value) do
    {:ok, integer(value) || integer(field.default)}
  end

  defp cast(%{type: "boolean"}, value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      truthy when truthy in ~w(true 1 yes on) -> {:ok, true}
      falsy when falsy in ~w(false 0 no off) -> {:ok, false}
      _empty -> {:ok, nil}
    end
  end

  defp cast(%{type: "json"} = field, value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      text ->
        case JSON.decode(text) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _reason} -> {:error, "#{field.label} must be JSON, like {\"key\": \"value\"}."}
        end
    end
  end

  # An option written as a number in the manifest goes as a number, though a form
  # sends it as text.
  defp cast(%{type: "select", options: [_ | _] = options}, value)
       when is_binary(value) or is_number(value) do
    case value |> to_string() |> String.trim() do
      "" -> {:ok, nil}
      text -> {:ok, option_value(options, text)}
    end
  end

  defp cast(%{type: "multiselect"} = field, value) when is_binary(value) do
    text = String.trim(value)

    case String.starts_with?(text, "[") && JSON.decode(text) do
      {:ok, list} when is_list(list) ->
        cast(field, list)

      _comma_separated ->
        list = text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        cast(field, list)
    end
  end

  defp cast(%{type: "multiselect"}, []), do: {:ok, nil}

  defp cast(%{type: "multiselect", options: [_ | _] = options}, list) when is_list(list),
    do: {:ok, Enum.map(list, &option_value(options, &1))}

  defp cast(%{type: "file"} = field, value) do
    case Bobbin.Files.ref(value) do
      {:ok, ref} ->
        {:ok, {:bobbin_file, ref}}

      :empty ->
        {:ok, nil}

      :error ->
        {:error, "#{field.label} must be a file, like the result of a node that downloads one."}
    end
  end

  defp cast(%{type: "datetime"} = field, value) when is_binary(value) do
    text = String.trim(value)

    cond do
      text == "" -> {:ok, nil}
      unix = unix(text, field[:format]) -> {:ok, unix}
      match?({:ok, _, _}, DateTime.from_iso8601(text)) -> {:ok, text}
      match?({:ok, _}, NaiveDateTime.from_iso8601(text)) -> {:ok, text}
      match?({:ok, _}, Date.from_iso8601(text)) -> {:ok, text}
      true -> {:error, "#{field.label} must be a date and time, like 2026-01-31T09:00:00Z."}
    end
  end

  defp cast(%{strip: chars}, value) when is_binary(chars) and is_binary(value) do
    {:ok, value |> String.trim() |> String.trim(chars)}
  end

  defp cast(_field, value) when is_binary(value), do: {:ok, String.trim(value)}
  defp cast(_field, value), do: {:ok, value}

  # `format: unix` or `unix_ms` sends the date as seconds or milliseconds since 1970,
  # read as UTC when it has no offset. A number is taken as already converted.
  defp unix(text, format) when format in ["unix", "unix_ms"] do
    unit = if format == "unix", do: :second, else: :millisecond

    with nil <- integer(text),
         {:ok, datetime} <- to_datetime(text) do
      DateTime.to_unix(datetime, unit)
    else
      number when is_integer(number) -> number
      _invalid -> nil
    end
  end

  defp unix(_text, _format), do: nil

  defp to_datetime(text) do
    with {:error, _} <- DateTime.from_iso8601(text) |> ok_datetime(),
         {:error, _} <- NaiveDateTime.from_iso8601(text) |> ok_naive(),
         {:ok, date} <- Date.from_iso8601(text) do
      DateTime.new(date, ~T[00:00:00])
    end
  end

  defp ok_datetime({:ok, datetime, _offset}), do: {:ok, datetime}
  defp ok_datetime(error), do: error
  defp ok_naive({:ok, naive}), do: DateTime.from_naive(naive, "Etc/UTC")
  defp ok_naive(error), do: error

  defp option_value(options, value) do
    case Enum.find(options, &(is_map(&1) and to_string(&1["value"]) == to_string(value))) do
      %{"value" => typed} -> typed
      nil -> value
    end
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) do
    case value |> to_string() |> String.trim() |> Integer.parse() do
      {number, ""} -> number
      _other -> nil
    end
  end

  ## Request

  # A map goes as JSON, with what isn't ASCII escaped, as headers can't carry it.
  defp header_value(value) when is_map(value) or is_list(value) do
    value
    |> JSON.encode!()
    |> String.replace(~r/[^\x00-\x7F]/u, fn char ->
      char
      |> String.to_charlist()
      |> hd()
      |> utf16_escape()
    end)
  end

  defp header_value(value), do: value

  defp utf16_escape(code) when code > 0xFFFF do
    code = code - 0x10000

    utf16_escape(0xD800 + Bitwise.bsr(code, 10)) <>
      utf16_escape(0xDC00 + Bitwise.band(code, 0x3FF))
  end

  defp utf16_escape(code),
    do:
      "\\u" <> (code |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))

  defp build(base_url, headers, action, vars, req_options) do
    request = action.request

    options = [
      method: request.method |> String.downcase() |> String.to_atom(),
      url: base_url <> render_path(request.path, vars),
      params:
        request.query |> render(vars) |> compact() |> unfile() |> Enum.flat_map(&query_pairs/1),
      headers:
        headers
        |> Map.merge(request.headers)
        |> render(vars)
        |> compact()
        |> unfile()
        |> Enum.map(fn {key, value} -> {key, header_value(value)} end),
      retry: false
    ]

    # A file to download is kept as it came, not decoded.
    options =
      if action.output["file"], do: Keyword.put(options, :decode_body, false), else: options

    with {:ok, options} <- put_body(options, request, vars) do
      {:ok, options |> Keyword.merge(req_options) |> Req.new() |> spaces_as_percent_20()}
    end
  end

  # Req writes a space in the query as `+`, as forms do. Some servers, like the OData
  # ones of Banco Central, read `+` as itself, so it goes as `%20`, which every server
  # reads as a space. A `+` in a value was already written as `%2B`. Right after the
  # params are put, so a step that signs the address signs what is sent.
  defp spaces_as_percent_20(request) do
    steps =
      Enum.flat_map(request.request_steps, fn
        {:put_params, _fun} = step -> [step, {:bobbin_query_spaces, &query_spaces/1}]
        step -> [step]
      end)

    %{request | request_steps: steps}
  end

  defp query_spaces(%{url: %URI{query: query} = url} = request) when is_binary(query),
    do: %{request | url: %{url | query: String.replace(query, "+", "%20")}}

  defp query_spaces(request), do: request

  # A list of plain values goes as a,b,c, or once per value when the key ends in []
  # (tags[]=a&tags[]=b); a map, or a list holding one, as JSON.
  defp query_pairs({key, list} = pair) when is_list(list) do
    if String.ends_with?(to_string(key), "[]") and Enum.all?(list, &plain?/1),
      do: Enum.map(list, &{key, &1}),
      else: [query_pair(pair)]
  end

  defp query_pairs(pair), do: [query_pair(pair)]

  defp plain?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  defp query_pair({key, value}) when is_map(value), do: {key, JSON.encode!(value)}

  defp query_pair({key, value}) when is_list(value) do
    if Enum.all?(value, &plain?/1),
      do: {key, Enum.join(value, ",")},
      else: {key, JSON.encode!(value)}
  end

  defp query_pair(pair), do: pair

  # A form repeats the key for each value of a plain list (o:tag=a&o:tag=b), and sends
  # a map, or a list holding one, as JSON.
  defp form_pairs({key, list}) when is_list(list) do
    if Enum.all?(list, &plain?/1),
      do: Enum.map(list, &{key, &1}),
      else: [{key, JSON.encode!(list)}]
  end

  defp form_pairs({key, map}) when is_map(map), do: [{key, JSON.encode!(map)}]
  defp form_pairs(pair), do: [pair]

  defp put_body(options, %{body: nil}, _vars), do: {:ok, options}

  defp put_body(options, %{body: body, body_type: "form"}, vars),
    do:
      {:ok,
       Keyword.put(
         options,
         :form,
         body |> render(vars) |> compact() |> unfile() |> Enum.flat_map(&form_pairs/1)
       )}

  defp put_body(options, %{body: body, body_type: "multipart"}, vars) do
    body
    |> render(vars)
    |> compact()
    |> Enum.reduce_while({:ok, []}, fn {name, value}, {:ok, parts} ->
      case part(value) do
        {:ok, part} -> {:cont, {:ok, parts ++ [{name, part}]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Keyword.put(options, :form_multipart, parts)}
      error -> error
    end
  end

  # multipart/related, as Google's uploads take it: the maps first, as JSON, then the
  # texts and the files, each part with only its type.
  defp put_body(options, %{body: body, body_type: "related"}, vars) do
    rendered = body |> render(vars) |> compact()

    {files, data} =
      Enum.split_with(rendered, fn {_key, value} -> match?({:bobbin_file, _}, value) end)

    {texts, data} = Enum.split_with(data, fn {_key, value} -> is_binary(value) end)

    parts =
      Enum.map(data, fn {_key, value} ->
        {:ok, "application/json; charset=UTF-8", JSON.encode!(unfile(value))}
      end) ++
        Enum.map(texts, fn {_key, text} -> {:ok, "text/plain; charset=UTF-8", text} end) ++
        Enum.map(files, fn {_key, {:bobbin_file, ref}} ->
          with {:ok, content} <- Bobbin.Files.read(ref),
               do: {:ok, ref["mime"] || "application/octet-stream", content_binary(content)}
        end)

    case Enum.find(parts, &(not match?({:ok, _, _}, &1))) do
      nil ->
        boundary = "bobbin" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

        content =
          Enum.map(parts, fn {:ok, type, data} ->
            ["--", boundary, "\r\ncontent-type: ", type, "\r\n\r\n", data, "\r\n"]
          end) ++ ["--", boundary, "--\r\n"]

        headers = [
          {"content-type", "multipart/related; boundary=#{boundary}"}
          | Enum.reject(options[:headers], fn {k, _v} -> String.downcase(k) == "content-type" end)
        ]

        {:ok,
         options
         |> Keyword.put(:body, IO.iodata_to_binary(content))
         |> Keyword.put(:headers, headers)}

      error ->
        error
    end
  end

  defp put_body(options, %{body: body, body_type: "binary"}, vars) do
    case render(body, vars) do
      {:bobbin_file, ref} ->
        with {:ok, content} <- Bobbin.Files.read(ref) do
          headers = options[:headers]

          headers =
            if List.keymember?(headers, "Content-Type", 0) or
                 List.keymember?(headers, "content-type", 0),
               do: headers,
               else: [{"content-type", ref["mime"] || "application/octet-stream"} | headers]

          {:ok, options |> Keyword.put(:body, content) |> Keyword.put(:headers, headers)}
        end

      text ->
        {:ok, Keyword.put(options, :body, text(text))}
    end
  end

  defp put_body(options, %{body: body}, vars),
    do:
      {:ok,
       Keyword.put(options, :json, body |> keep_empty() |> render(vars) |> compact() |> unfile())}

  # A {} or [] written in the manifest, like Microsoft Graph's `folder: {}`, is sent,
  # while compact/1 leaves out one its empty fields left empty. unfile/1 puts it back.
  defp keep_empty(map) when map == %{}, do: :bobbin_empty
  defp keep_empty([]), do: :bobbin_empty_list
  defp keep_empty(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, keep_empty(v)} end)
  defp keep_empty(list) when is_list(list), do: Enum.map(list, &keep_empty/1)
  defp keep_empty(value), do: value

  defp part({:bobbin_file, ref}) do
    with {:ok, content} <- Bobbin.Files.read(ref) do
      options = [filename: ref["name"], content_type: ref["mime"]]

      options =
        if is_integer(ref["size"]) and not is_binary(content) and not is_list(content),
          do: Keyword.put(options, :size, ref["size"]),
          else: options

      {:ok, {content, options}}
    end
  end

  defp part(value) when is_map(value) or is_list(value),
    do: {:ok, value |> unfile() |> JSON.encode!()}

  defp part(value), do: {:ok, text(value)}

  # Outside a multipart form or a binary body, a file is sent as its reference.
  defp base64(nil), do: nil

  defp base64({:bobbin_file, ref}) do
    case Bobbin.Files.read(ref) do
      {:ok, content} -> content |> content_binary() |> Base.encode64()
      _error -> nil
    end
  end

  defp base64(value), do: value |> text() |> Base.encode64()

  defp content_binary(content) when is_binary(content), do: content
  defp content_binary(content), do: content |> Enum.to_list() |> IO.iodata_to_binary()

  defp unfile({:bobbin_file, ref}), do: ref
  defp unfile(:bobbin_empty), do: %{}
  defp unfile(:bobbin_empty_list), do: []
  defp unfile(:bobbin_blank), do: ""
  defp unfile(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, unfile(v)} end)
  defp unfile(list) when is_list(list), do: Enum.map(list, &unfile/1)
  defp unfile(value), do: value

  # Empty values are left out, so an optional field needs no syntax of its own.
  defp compact(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key, compact(value)} end)
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}, []] end)
    |> Map.new()
  end

  # Inside a list too, and a list left empty goes as well.
  defp compact(list) when is_list(list) do
    case list |> Enum.map(&compact/1) |> Enum.reject(&(&1 in [nil, "", %{}, []])) do
      [] -> nil
      kept -> kept
    end
  end

  defp compact(value), do: value

  defp call(request, integration) do
    case Req.request(request) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        check_ok(response, integration)

      {:ok, %{status: 401} = response} ->
        {:unauthorized, refused(integration, response)}

      {:ok, response} ->
        {:error, refused(integration, response)}

      {:error, reason} ->
        {:error, "Could not reach #{integration.name}: #{Exception.message(reason)}"}
    end
  end

  # A 204 has no body to check.
  defp check_ok(%{status: 204} = response, _integration), do: {:ok, response}

  # Some APIs answer 200 when something failed, with the reason in the body.
  defp check_ok(response, %{errors: errors} = integration) do
    failed =
      (errors.ok_path != nil and
         not (is_map(response.body) and dig(response.body, errors.ok_path) == true)) or
        (Map.get(errors, :error_path) != nil and is_map(response.body) and
           dig(response.body, errors.error_path) not in [nil, [], %{}, "", false])

    if failed, do: {:error, refused(integration, response)}, else: {:ok, response}
  end

  defp refused(integration, response) do
    path = integration.errors.message_path

    case (is_map(response.body) and path) && dig(response.body, path) do
      message when is_binary(message) and message != "" ->
        "#{integration.name} refused it: #{message}"

      _other ->
        "#{integration.name} answered #{response.status}"
    end
  end

  ## Output

  defp output({:ok, response}, %{output: %{"file" => file}}, vars)
       when file not in [nil, false] do
    name =
      case file do
        %{"name" => name} -> text(render(name, vars))
        _true -> ""
      end

    name = if name == "", do: filename(response) || "file", else: name

    mime =
      case Req.Response.get_header(response, "content-type") do
        [type | _] -> type |> String.split(";") |> hd() |> String.trim()
        [] -> "application/octet-stream"
      end

    with {:ok, ref} <- Bobbin.Files.store(response.body, %{"name" => name, "mime" => mime}) do
      {:ok, %{"file" => ref}}
    end
  end

  defp output({:ok, response}, action, vars), do: {:ok, shape(response.body, action.output, vars)}
  defp output(error, _action, _vars), do: error

  defp filename(response) do
    response
    |> Req.Response.get_header("content-disposition")
    |> Enum.find_value(fn header ->
      case Regex.run(~r/filename\*?=(?:UTF-8'')?"?([^";]+)"?/i, header) do
        [_match, name] -> URI.decode(name)
        nil -> nil
      end
    end)
  end

  defp shape(body, output, vars) do
    cond do
      output["value"] -> render(output["value"], vars)
      true -> body |> dig(output["path"]) |> pick(output["pick"])
    end
  end

  defp pick(items, keys) when is_list(items) and is_list(keys),
    do: Enum.map(items, &pick(&1, keys))

  defp pick(item, keys) when is_map(item) and is_list(keys), do: Map.take(item, keys)
  defp pick(value, _keys), do: value

  defp dig(value, nil), do: value
  defp dig(value, ""), do: value

  defp dig(value, path), do: dig_keys(value, String.split(path, "."))

  # A key may have dots of its own, like Microsoft Graph's `@odata.nextLink`: the
  # longest run of parts that is a key of the map wins.
  defp dig_keys(value, []), do: value

  defp dig_keys(map, keys) when is_map(map) do
    Enum.find_value(length(keys)..1//-1, fn n ->
      {key, rest} = Enum.split(keys, n)
      key = Enum.join(key, ".")
      if Map.has_key?(map, key), do: {:found, dig_keys(map[key], rest)}
    end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  defp dig_keys(list, [key | rest]) when is_list(list) do
    case Integer.parse(key) do
      {i, ""} -> list |> Enum.at(i) |> dig_keys(rest)
      _other -> nil
    end
  end

  defp dig_keys(_value, _keys), do: nil

  ## Pagination

  defp paginate(request, integration, pagination, action) do
    size = pagination["page_size"] || 100

    request =
      case pagination["limit_param"] do
        nil -> request
        param -> put_param(request, pagination, param, size)
      end

    with {:ok, items} <- pages(request, integration, pagination, size, nil, 1, []) do
      {:ok, pick(items, action.output["pick"])}
    end
  end

  defp pages(_request, _integration, _pagination, _size, _next, page, acc) when page > @max_pages,
    do: {:ok, acc}

  defp pages(request, integration, pagination, size, next, page, acc) do
    request = page_request(request, pagination, size, next, page)

    with {:ok, response} <- call(request, integration) do
      items = List.wrap(dig(response.body, pagination["items_path"]))
      acc = acc ++ items

      case next_page(response, pagination, items, size, page) |> same_host(request, pagination) do
        nil -> {:ok, acc}
        next -> pages(request, integration, pagination, size, next, page + 1, acc)
      end
    end
  end

  defp page_request(request, _pagination, _size, nil, _page), do: request

  defp page_request(request, %{"type" => "cursor"} = pagination, _size, cursor, _page),
    do: put_param(request, pagination, pagination["cursor_param"] || "cursor", cursor)

  defp page_request(request, %{"type" => "offset"} = pagination, _size, offset, _page),
    do: put_param(request, pagination, pagination["offset_param"] || "offset", offset)

  defp page_request(request, %{"type" => "page"} = pagination, _size, number, _page),
    do: put_param(request, pagination, pagination["page_param"] || "page", number)

  defp page_request(request, %{"type" => "link"}, _size, url, _page),
    do: %{request | url: URI.parse(url), options: Map.delete(request.options, :params)}

  # A next page's address may be relative, and is followed only on the same host,
  # so the credential never goes elsewhere.
  defp same_host(nil, _request, _pagination), do: nil

  defp same_host(url, request, %{"type" => "link"}) do
    next = URI.merge(request.url, url)

    if next.scheme == request.url.scheme and next.host == request.url.host and
         next.port == request.url.port,
       do: URI.to_string(next),
       else: nil
  end

  defp same_host(next, _request, _pagination), do: next

  # With `in: body`, the parameter is a path in the JSON body, like `variables.after`
  # for GraphQL.
  defp put_param(request, %{"in" => "body"}, key, value) do
    body = Map.get(request.options, :json) || %{}
    path = String.split(key, ".")
    %{request | options: Map.put(request.options, :json, put_path(body, path, value))}
  end

  defp put_param(request, _pagination, key, value) do
    params = request.options |> Map.get(:params, []) |> List.keydelete(key, 0)
    %{request | options: Map.put(request.options, :params, params ++ [{key, value}])}
  end

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    inner = if is_map(map[key]), do: map[key], else: %{}
    Map.put(map, key, put_path(inner, rest, value))
  end

  defp next_page(response, %{"type" => "cursor"} = pagination, _items, _size, _page) do
    more = pagination["has_more_path"] && dig(response.body, pagination["has_more_path"])

    case dig(response.body, pagination["next_path"]) do
      _next when more == false -> nil
      next when next in [nil, ""] -> nil
      next -> next
    end
  end

  defp next_page(_response, %{"type" => "offset"}, items, size, page) do
    if length(items) < size, do: nil, else: page * size
  end

  # The first request goes without the parameter, so the service starts where it
  # starts: `first_page` (1 by default) says what number that was.
  defp next_page(_response, %{"type" => "page"} = pagination, items, size, page) do
    if length(items) < size, do: nil, else: (pagination["first_page"] || 1) + page
  end

  defp next_page(response, %{"type" => "link", "next_path" => path}, _items, _size, _page)
       when is_binary(path) do
    case dig(response.body, path) do
      next when is_binary(next) and next != "" -> next
      _none -> nil
    end
  end

  defp next_page(response, %{"type" => "link"}, _items, _size, _page) do
    response
    |> Req.Response.get_header("link")
    |> Enum.find_value(fn header ->
      Regex.run(~r/<([^>]+)>;\s*rel="?next"?/, header, capture: :all_but_first)
    end)
    |> case do
      [url] -> url
      nil -> nil
    end
  end
end

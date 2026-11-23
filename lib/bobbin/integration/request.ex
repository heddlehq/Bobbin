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
  @path_placeholder ~r/\{\{\s*(fields|credential|auth|request|webhook)\.([A-Za-z0-9_]+)\s*(?:\|\s*(path)\s*)?\}\}/
  @single_placeholder ~r/\A\{\{\s*(fields|credential|auth|request|webhook)\.([A-Za-z0-9_]+)\s*\}\}\z/

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
         {:ok, base_url} <- base_url(integration, credential) do
      send = fn ->
        with {:ok, request} <-
               build(base_url, Map.get(integration, :headers, %{}), action, vars, req_options),
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
  defp base_url(integration, credential) do
    template = integration.base_url
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
      [_match, scope, name] ->
        get_in(vars, [scope, name])

      nil ->
        Regex.replace(@placeholder, value, fn _match, scope, name ->
          vars |> get_in([scope, name]) |> text()
        end)
    end
  end

  def render(map, vars) when is_map(map), do: Map.new(map, fn {k, v} -> {k, render(v, vars)} end)
  def render(list, vars) when is_list(list), do: Enum.map(list, &render(&1, vars))
  def render(value, _vars), do: value

  @doc """
  Renders the path of a request: each value is encoded as one segment, so a `/`, `?`
  or `#` in it stays part of the value (GitLab's `group/project` becomes
  `group%2Fproject`) and can't reach another address.
  """
  def render_path(path, vars) when is_binary(path) do
    Regex.replace(@path_placeholder, path, fn
      _match, scope, name, "" ->
        vars |> get_in([scope, name]) |> text() |> segment()

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

  defp text(nil), do: ""
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

  defp build(base_url, headers, action, vars, req_options) do
    request = action.request

    options = [
      method: request.method |> String.downcase() |> String.to_atom(),
      url: base_url <> render_path(request.path, vars),
      params: request.query |> render(vars) |> compact() |> Enum.map(&query_pair/1),
      headers:
        headers
        |> Map.merge(request.headers)
        |> render(vars)
        |> compact()
        |> Map.to_list(),
      retry: false
    ]

    # A file to download is kept as it came, not decoded.
    options =
      if action.output["file"], do: Keyword.put(options, :decode_body, false), else: options

    with {:ok, options} <- put_body(options, request, vars) do
      {:ok, options |> Keyword.merge(req_options) |> Req.new()}
    end
  end

  # A list of plain values goes as a,b,c; a map, or a list holding one, as JSON.
  defp query_pair({key, value}) when is_map(value), do: {key, JSON.encode!(value)}

  defp query_pair({key, value}) when is_list(value) do
    if Enum.all?(value, &(is_binary(&1) or is_number(&1) or is_boolean(&1))),
      do: {key, Enum.join(value, ",")},
      else: {key, JSON.encode!(value)}
  end

  defp query_pair(pair), do: pair

  defp put_body(options, %{body: nil}, _vars), do: {:ok, options}

  defp put_body(options, %{body: body, body_type: "form"}, vars),
    do:
      {:ok,
       Keyword.put(options, :form, body |> render(vars) |> compact() |> unfile() |> Map.to_list())}

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
    do: {:ok, Keyword.put(options, :json, body |> render(vars) |> compact() |> unfile())}

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
  defp unfile({:bobbin_file, ref}), do: ref
  defp unfile(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, unfile(v)} end)
  defp unfile(list) when is_list(list), do: Enum.map(list, &unfile/1)
  defp unfile(value), do: value

  # Empty values are left out, so an optional field needs no syntax of its own.
  defp compact(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key, compact(value)} end)
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
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

  # Some APIs answer 200 when something failed, with the reason in the body.
  defp check_ok(response, %{errors: %{ok_path: nil}}), do: {:ok, response}

  defp check_ok(response, %{errors: %{ok_path: path}} = integration) do
    if is_map(response.body) and dig(response.body, path) == true,
      do: {:ok, response},
      else: {:error, refused(integration, response)}
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

  defp dig(value, path) do
    path
    |> String.split(".")
    |> Enum.reduce(value, fn
      key, map when is_map(map) -> Map.get(map, key)
      key, list when is_list(list) -> with {i, ""} <- Integer.parse(key), do: Enum.at(list, i)
      _key, _other -> nil
    end)
  end

  ## Pagination

  defp paginate(request, integration, pagination, action) do
    size = pagination["page_size"] || 100

    request =
      case pagination["limit_param"] do
        nil -> request
        param -> put_param(request, param, size)
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
    do: put_param(request, pagination["cursor_param"] || "cursor", cursor)

  defp page_request(request, %{"type" => "offset"} = pagination, _size, offset, _page),
    do: put_param(request, pagination["offset_param"] || "offset", offset)

  defp page_request(request, %{"type" => "page"} = pagination, _size, number, _page),
    do: put_param(request, pagination["page_param"] || "page", number)

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

  defp put_param(request, key, value) do
    params = request.options |> Map.get(:params, []) |> List.keydelete(key, 0)
    %{request | options: Map.put(request.options, :params, params ++ [{key, value}])}
  end

  defp next_page(response, %{"type" => "cursor"} = pagination, _items, _size, _page) do
    case dig(response.body, pagination["next_path"]) do
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

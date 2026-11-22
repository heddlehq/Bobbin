defmodule Bobbin.Integration.Request do
  @moduledoc """
  Runs an action of a `Bobbin.Integration` against the real service.

  Heddle runs actions through here, and so does `mix bobbin.run`, so an integration
  behaves the same in both.
  """

  alias Bobbin.Integration

  @max_pages 100
  @placeholder ~r/\{\{\s*(fields|credential)\.([A-Za-z0-9_]+)\s*\}\}/
  @single_placeholder ~r/\A\{\{\s*(fields|credential)\.([A-Za-z0-9_]+)\s*\}\}\z/

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
        vars = %{"fields" => field_values(action, fields), "credential" => credential || %{}}
        request = build(integration, action, vars, req_options)

        case action.pagination do
          nil -> request |> call(integration) |> output(action, vars)
          pagination -> paginate(request, integration, pagination, action)
        end
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

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp text(value), do: JSON.encode!(value)

  ## Fields

  defp field_values(action, fields) do
    Map.new(action.fields, fn field ->
      value = Map.get(fields || %{}, field.name)
      value = if value in [nil, ""], do: field.default, else: value
      {field.name, cast(field, value)}
    end)
  end

  defp cast(%{type: "number"} = field, value) do
    integer(value) || integer(field.default)
  end

  defp cast(%{strip: chars}, value) when is_binary(chars) and is_binary(value) do
    value |> String.trim() |> String.trim(chars)
  end

  defp cast(_field, value) when is_binary(value), do: String.trim(value)
  defp cast(_field, value), do: value

  defp integer(value) when is_integer(value), do: value

  defp integer(value) do
    case value |> to_string() |> String.trim() |> Integer.parse() do
      {number, ""} -> number
      _other -> nil
    end
  end

  ## Request

  defp build(integration, action, vars, req_options) do
    request = action.request

    options = [
      method: request.method |> String.downcase() |> String.to_atom(),
      url: integration.base_url <> render(request.path, vars),
      params: request.query |> render(vars) |> compact() |> Map.to_list(),
      headers: request.headers |> render(vars) |> compact() |> Map.to_list(),
      retry: false
    ]

    options
    |> put_body(request, vars)
    |> authenticate(integration.credential, vars)
    |> Keyword.merge(req_options)
    |> Req.new()
  end

  defp put_body(options, %{body: nil}, _vars), do: options

  defp put_body(options, %{body: body, body_type: "form"}, vars),
    do: Keyword.put(options, :form, body |> render(vars) |> compact() |> Map.to_list())

  defp put_body(options, %{body: body}, vars),
    do: Keyword.put(options, :json, body |> render(vars) |> compact())

  defp authenticate(options, nil, _vars), do: options

  defp authenticate(options, %{auth: auth}, vars) do
    auth = render(auth, vars)

    case auth["type"] do
      "bearer" ->
        Keyword.put(options, :auth, {:bearer, text(auth["token"])})

      "oauth2" ->
        Keyword.put(options, :auth, {:bearer, text(vars["credential"]["access_token"])})

      "basic" ->
        Keyword.put(
          options,
          :auth,
          {:basic, "#{text(auth["username"])}:#{text(auth["password"])}"}
        )

      "header" ->
        Keyword.update!(options, :headers, &[{auth["name"], text(auth["value"])} | &1])

      "query" ->
        Keyword.update!(options, :params, &[{auth["name"], text(auth["value"])} | &1])

      _none ->
        options
    end
  end

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

  defp output({:ok, response}, action, vars), do: {:ok, shape(response.body, action.output, vars)}
  defp output(error, _action, _vars), do: error

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

      case next_page(response, pagination, items, size, page) do
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

  defp page_request(request, %{"type" => "link"}, _size, url, _page),
    do: %{request | url: URI.parse(url), options: Map.delete(request.options, :params)}

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

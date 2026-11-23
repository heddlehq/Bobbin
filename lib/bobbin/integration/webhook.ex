defmodule Bobbin.Integration.Webhook do
  @moduledoc """
  Triggers the service calls: Heddle gives each active trigger an address, the
  manifest says how to tell the service about it and how to check that an event came
  from the service.

  The host calls `register/6` when a flow with the trigger is activated and keeps what
  it returns (the webhook's `url`, its `secret` and the `id` the service gave it),
  `receive/5` for each event that reaches the address, and `unregister/6` when the
  flow stops.

  ```yaml
  triggers:
    - name: New Push
      fields:
        - {name: repo, label: Repository}
      webhook:
        register:
          request:
            method: POST
            path: "repos/{{fields.repo}}/hooks"
            body: {url: "{{webhook.url}}", secret: "{{webhook.secret}}"}
          id_path: id           # where the answer holds the webhook's id
          secret_path: secret   # if the service makes the secret
        unregister:
          request: {method: DELETE, path: "repos/{{fields.repo}}/hooks/{{webhook.id}}"}
        signature:
          header: X-Hub-Signature-256
          prefix: "sha256="
          secret: "{{webhook.secret}}"
        output:
          path: commits         # the items an event holds, each one starts the flow
  ```

  Without `register`, the person pastes the address in the service by hand.

  `signature` takes `algorithm` (`sha1`, `sha256`, the default, or `sha512`),
  `encoding` (`hex`, the default, or `base64`), `message` (`{{request.body}}` when
  left out; it may use `{{request.timestamp}}`), and for signatures with a timestamp,
  a `timestamp_header` or a `pattern` with named groups `signature` and `timestamp`
  (`t=(?<timestamp>\\d+),v1=(?<signature>\\w+)`), and `tolerance` in seconds.

  A service that sends the secret itself in a header, like GitLab, takes `token` in
  place of `secret`: `{header: X-Gitlab-Token, token: "{{webhook.secret}}"}`. One that
  calls with a user and a password, like Pipedrive, takes `basic`:
  `{basic: {username: heddle, password: "{{webhook.secret}}"}}`.

  `challenge` answers services that check the address first: `query` names the
  parameter to send back (`hub.challenge`), with `token_query` and `token` to check,
  `path` a key of the body (`challenge`), or `method` a request answered 200 with
  nothing (Trello's `HEAD`).
  """

  alias Bobbin.Integration
  alias Bobbin.Integration.Request

  @type event :: %{headers: map(), body: binary(), query: map()}

  @doc """
  Tells the service about the address in `webhook["url"]`. Returns `webhook` with the
  `id` the service gave it, and its `secret` if the service made one, or `:manual`
  when the person registers the address by hand.
  """
  @spec register(Integration.t(), String.t(), map(), map(), map(), keyword()) ::
          {:ok, map() | :manual} | {:error, String.t()}
  def register(integration, trigger_name, fields, credential, webhook, req_options \\ []) do
    with {:ok, trigger, config} <- config(integration, trigger_name) do
      case config.register do
        nil ->
          {:ok, :manual}

        step ->
          with {:ok, body} <-
                 send(integration, trigger, step, fields, credential, webhook, req_options) do
            webhook =
              webhook
              |> put_found("id", body, step.id_path)
              |> put_found("secret", body, step.secret_path)

            {:ok, webhook}
          end
      end
    end
  end

  @doc "Tells the service to stop calling. A webhook it no longer has is fine."
  @spec unregister(Integration.t(), String.t(), map(), map(), map(), keyword()) ::
          :ok | {:error, String.t()}
  def unregister(integration, trigger_name, fields, credential, webhook, req_options \\ []) do
    with {:ok, trigger, config} <- config(integration, trigger_name) do
      case config.unregister do
        nil ->
          :ok

        step ->
          case send(integration, trigger, step, fields, credential, webhook, req_options) do
            {:ok, _body} ->
              :ok

            {:error, message} ->
              if message =~ ~r/answered (404|410)\z/, do: :ok, else: {:error, message}
          end
      end
    end
  end

  @doc """
  Checks an event that reached the address and returns its items, each a run of the
  flow. `{:reply, status, body}` is an answer the service expects instead, and
  `{:error, :signature}` an event that didn't come from the service.
  """
  @spec receive(Integration.t(), String.t(), event(), map(), map()) ::
          {:ok, [term()]} | {:reply, pos_integer(), binary()} | {:error, :signature | String.t()}
  def receive(integration, trigger_name, event, webhook, credential) do
    with {:ok, _trigger, config} <- config(integration, trigger_name) do
      vars = %{"credential" => credential || %{}, "webhook" => webhook || %{}, "fields" => %{}}
      body = decode(event)

      case challenge(config.challenge, event, body, vars) do
        {:reply, _status, _body} = reply ->
          reply

        :none ->
          if verified?(config.signature, event, vars) do
            output = config.output
            items = body |> dig(output["path"]) |> pick(output["pick"])
            {:ok, if(is_list(items), do: items, else: [items])}
          else
            {:error, :signature}
          end
      end
    end
  end

  defp config(integration, trigger_name) do
    case Integration.trigger(integration, trigger_name) do
      %{webhook: %{} = config} = trigger -> {:ok, trigger, config}
      nil -> {:error, "#{integration.name} has no trigger called #{trigger_name}."}
      _polled -> {:error, "#{trigger_name} doesn't take events, it checks the service."}
    end
  end

  defp send(integration, trigger, step, fields, credential, webhook, req_options) do
    action = %{fields: trigger.fields, request: step.request, output: %{}, pagination: nil}

    Request.send_request(integration, action, fields, credential, req_options, %{
      "webhook" => webhook
    })
  end

  defp put_found(webhook, _key, _body, nil), do: webhook

  defp put_found(webhook, key, body, path) do
    case dig(body, path) do
      nil -> webhook
      value -> Map.put(webhook, key, text(value))
    end
  end

  ## Challenges

  defp challenge(nil, _event, _body, _vars), do: :none

  defp challenge(%{"query" => param} = config, event, _body, vars) do
    value = event.query[param]
    token = config["token"] && Request.render(config["token"], vars)

    cond do
      value == nil -> :none
      token && not equal?(text(event.query[config["token_query"]]), text(token)) -> :none
      true -> {:reply, 200, text(value)}
    end
  end

  # Trello checks the address with a HEAD request before it takes it.
  defp challenge(%{"method" => method}, event, _body, _vars) do
    if String.upcase(to_string(event[:method])) == String.upcase(method),
      do: {:reply, 200, ""},
      else: :none
  end

  defp challenge(%{"path" => path}, _event, body, _vars) when is_map(body) do
    case dig(body, path) do
      value when is_binary(value) -> {:reply, 200, value}
      _none -> :none
    end
  end

  defp challenge(_config, _event, _body, _vars), do: :none

  ## Signatures

  defp verified?(nil, _event, _vars), do: true

  # A service that calls with a user and a password, like Pipedrive.
  defp verified?(%{"basic" => basic}, event, vars) do
    %{"username" => user, "password" => password} =
      Map.merge(%{"username" => "", "password" => ""}, Request.render(basic, vars))

    sent = header(event, "authorization")

    text(password) != "" and sent != nil and
      equal?(sent, "Basic " <> Base.encode64("#{user}:#{password}"))
  end

  # A service that sends the secret itself, like GitLab's X-Gitlab-Token.
  defp verified?(%{"token" => token} = config, event, vars) do
    expected = text(Request.render(token, vars))
    sent = header(event, config["header"])
    expected != "" and sent != nil and equal?(sent, expected)
  end

  defp verified?(config, event, vars) do
    header = header(event, config["header"])

    {signature, timestamp} =
      case config["pattern"] do
        nil ->
          signature = header && strip_prefix(header, config["prefix"])
          {signature, config["timestamp_header"] && header(event, config["timestamp_header"])}

        pattern ->
          case header && Regex.named_captures(Regex.compile!(pattern), header) do
            %{"signature" => signature} = captures -> {signature, captures["timestamp"]}
            _none -> {nil, nil}
          end
      end

    vars = Map.put(vars, "request", %{"body" => event.body, "timestamp" => timestamp})
    config = Request.render(Map.drop(config, ["pattern"]), vars)

    signature != nil and fresh?(timestamp, config["tolerance"]) and
      equal?(normalize(signature, config["encoding"]), expected(config, event.body))
  end

  defp expected(config, body) do
    algorithm = Bobbin.Integration.Auth.hmac_atom(config["algorithm"] || "sha256")
    message = if config["message"], do: text(config["message"]), else: body
    mac = :crypto.mac(:hmac, algorithm, text(config["secret"]), message)

    case config["encoding"] do
      "base64" -> Base.encode64(mac)
      _hex -> Base.encode16(mac, case: :lower)
    end
  end

  defp normalize(signature, "base64"), do: String.trim(signature)
  defp normalize(signature, _hex), do: signature |> String.trim() |> String.downcase()

  defp fresh?(_timestamp, nil), do: true
  defp fresh?(nil, _tolerance), do: false

  defp fresh?(timestamp, tolerance) do
    case Integer.parse(to_string(timestamp)) do
      {seconds, _rest} -> abs(System.system_time(:second) - seconds) <= tolerance
      :error -> false
    end
  end

  defp equal?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp equal?(_a, _b), do: false

  defp strip_prefix(value, nil), do: value

  defp strip_prefix(value, prefix) do
    case value do
      ^prefix <> rest -> rest
      other -> other
    end
  end

  defp header(event, name) do
    name = String.downcase(name)

    Enum.find_value(event.headers, fn {key, value} ->
      if String.downcase(key) == name, do: List.first(List.wrap(value))
    end)
  end

  ## Body

  defp decode(%{body: body} = event) do
    type = header(event, "content-type") || ""

    cond do
      body in [nil, ""] ->
        %{}

      type =~ "application/x-www-form-urlencoded" ->
        URI.decode_query(body)

      true ->
        case JSON.decode(body),
          do: (
            {:ok, decoded} -> decoded
            {:error, _} -> body
          )
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
      _key, _other -> nil
    end)
  end

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value), do: to_string(value)
end

defmodule Bobbin.Integration.Auth do
  @moduledoc """
  Puts the credential of a `Bobbin.Integration` on a request: a key in a header or
  the query, a password, an OAuth token, or a signature.

  Tokens Bobbin fetches itself (`client_credentials`, `login`) are kept until they
  expire, in a table shared by every run, and fetched again when the service refuses
  one. `jwt` and `hmac` sign each request as it leaves, after its body is encoded.
  """

  alias Bobbin.Integration.Request

  @table __MODULE__
  @jwt_algorithms ~w(HS256 HS384 HS512 RS256 ES256)
  @hmac_algorithms ~w(sha1 sha256 sha512)

  @doc false
  def jwt_algorithms, do: @jwt_algorithms

  @doc false
  def hmac_algorithms, do: @hmac_algorithms

  @doc false
  # Erlang calls SHA-1 `:sha`.
  def hmac_atom("sha1"), do: :sha
  def hmac_atom(name) when name in @hmac_algorithms, do: String.to_existing_atom(name)

  @doc false
  def create_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end

  @doc """
  Puts the credential on `request`. Returns the request and the key its token is kept
  under, if Bobbin fetched one, to `forget/1` it when the service refuses it.
  """
  @spec put(Req.Request.t(), map(), String.t(), map(), keyword()) ::
          {:ok, Req.Request.t(), term() | nil} | {:error, String.t()}
  def put(request, integration, base_url, vars, req_options) do
    case integration.credential do
      nil ->
        {:ok, request, nil}

      credential ->
        with {:ok, request} <- put_tls(request, credential[:tls], vars) do
          put_auth(request, integration, base_url, credential.auth, vars, req_options)
        end
    end
  end

  @doc "Drops the token kept under `key`, so the next run fetches a new one."
  @spec forget(term()) :: :ok
  def forget(nil), do: :ok

  def forget(key) do
    :ets.delete(@table, key)
    :ok
  end

  ## Each type

  defp put_auth(request, integration, base_url, auth, vars, req_options) do
    case auth["type"] do
      "client_credentials" ->
        auth = Request.render(auth, vars)

        with_token(integration, auth, fn ->
          client_credentials(integration, auth, request_tls(request), req_options)
        end)
        |> then(&applied(&1, request, auth, vars))

      "login" ->
        rendered = Request.render(Map.drop(auth, ["apply"]), vars)

        with_token(integration, rendered, fn ->
          login(integration, base_url, rendered, request_tls(request), req_options)
        end)
        |> then(&applied(&1, request, auth, vars))

      "jwt" ->
        {:ok, Req.Request.append_request_steps(request, bobbin_jwt: &sign_jwt(&1, auth, vars)),
         nil}

      "hmac" ->
        {:ok, Req.Request.append_request_steps(request, bobbin_hmac: &sign_hmac(&1, auth, vars)),
         nil}

      "aws_sigv4" ->
        auth = Request.render(auth, vars)

        options = [
          access_key_id: text(auth["access_key_id"]),
          secret_access_key: text(auth["secret_access_key"]),
          region: text(auth["region"]),
          service: text(auth["service"])
        ]

        options =
          case text(auth["session_token"]) do
            "" -> options
            token -> Keyword.put(options, :token, token)
          end

        {:ok, Req.merge(request, aws_sigv4: options), nil}

      _simple ->
        {:ok, simple(request, Request.render(auth, vars), vars), nil}
    end
  end

  defp applied({:ok, token, key}, request, auth, vars) do
    apply = auth["apply"] || %{"type" => "bearer", "token" => "{{auth.token}}"}
    vars = Map.put(vars, "auth", %{"token" => token})
    {:ok, simple(request, Request.render(apply, vars), vars), key}
  end

  defp applied({:error, message}, _request, _auth, _vars), do: {:error, message}

  # bearer, header, query, basic, oauth2 (the host keeps the token) and none.
  defp simple(request, auth, vars) do
    case auth["type"] do
      # Headers, not Req's :auth, so this works inside a step that signs too.
      "bearer" ->
        Req.Request.put_header(request, "authorization", "Bearer " <> text(auth["token"]))

      "oauth2" ->
        token = text(vars["credential"]["access_token"])
        Req.Request.put_header(request, "authorization", "Bearer " <> token)

      "basic" ->
        pair = "#{text(auth["username"])}:#{text(auth["password"])}"
        Req.Request.put_header(request, "authorization", "Basic " <> Base.encode64(pair))

      "header" ->
        Req.Request.put_header(request, String.downcase(auth["name"]), text(auth["value"]))

      "query" ->
        params = Map.get(request.options, :params, [])

        %{
          request
          | options:
              Map.put(request.options, :params, params ++ [{auth["name"], text(auth["value"])}])
        }

      _none ->
        request
    end
  end

  ## Tokens Bobbin fetches

  defp with_token(integration, auth, fetch) do
    key = {integration.id, :crypto.hash(:sha256, :erlang.term_to_binary(auth))}
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, token, expires}] when expires > now ->
        {:ok, token, key}

      _missing ->
        with {:ok, token, lifetime} <- fetch.() do
          # A minute early, so a token doesn't expire on its way.
          :ets.insert(@table, {key, token, now + max(lifetime - 60, 1)})
          {:ok, token, key}
        end
    end
  end

  defp client_credentials(integration, auth, tls, req_options) do
    form =
      [grant_type: "client_credentials"] ++
        case auth["scopes"] do
          [_ | _] = scopes -> [scope: Enum.join(scopes, " ")]
          _none -> []
        end

    {form, options} =
      case auth["token_auth"] do
        "body" ->
          {form ++
             [client_id: text(auth["client_id"]), client_secret: text(auth["client_secret"])], []}

        _basic ->
          {form, [auth: {:basic, "#{text(auth["client_id"])}:#{text(auth["client_secret"])}"}]}
      end

    [method: :post, url: text(auth["token_url"]), form: form, retry: false]
    |> Keyword.merge(options)
    |> Keyword.merge(tls)
    |> Keyword.merge(req_options)
    |> Req.request()
    |> token_from(integration, "access_token", "expires_in", auth["expires_in"], "the token")
  end

  defp login(integration, base_url, auth, tls, req_options) do
    request = auth["request"] || %{}
    url = text(request["url"])
    url = if url == "", do: base_url <> text(request["path"]), else: url

    body =
      case request["body_type"] do
        "form" -> [form: request["body"] |> Kernel.||(%{}) |> Map.to_list()]
        _json -> if request["body"], do: [json: request["body"]], else: []
      end

    # Some logins take the user and password as Basic auth, like Correios'.
    basic =
      case request["basic"] do
        %{"username" => user, "password" => password} ->
          [auth: {:basic, "#{text(user)}:#{text(password)}"}]

        _none ->
          []
      end

    [
      method: (request["method"] || "POST") |> String.downcase() |> String.to_atom(),
      url: url,
      headers: Map.to_list(request["headers"] || %{}),
      retry: false
    ]
    |> Keyword.merge(body)
    |> Keyword.merge(basic)
    |> Keyword.merge(tls)
    |> Keyword.merge(req_options)
    |> Req.request()
    |> token_from(
      integration,
      auth["token_path"],
      auth["expires_path"],
      auth["expires_in"],
      "the login"
    )
  end

  defp token_from(result, integration, token_path, expires_path, expires_in, what) do
    case result do
      {:ok, %{status: status, body: body} = response} when status in 200..299 ->
        token =
          case token_path do
            "header:" <> name -> response |> Req.Response.get_header(name) |> List.first()
            path -> dig(body, path)
          end

        lifetime = integer(expires_path && dig(body, expires_path)) || integer(expires_in) || 600

        case token do
          token when is_binary(token) and token != "" -> {:ok, token, lifetime}
          _other -> {:error, "#{integration.name} sent no token for #{what}."}
        end

      {:ok, %{status: status}} ->
        {:error, "#{integration.name} refused #{what}: answered #{status}"}

      {:error, reason} ->
        {:error, "Could not reach #{integration.name}: #{Exception.message(reason)}"}
    end
  end

  ## Signing each request

  defp request_vars(req) do
    body =
      case req.body do
        nil -> ""
        body -> IO.iodata_to_binary(body)
      end

    now = System.system_time(:millisecond)

    %{
      "method" => req.method |> to_string() |> String.upcase(),
      "path" => req.url.path || "/",
      "query" => req.url.query || "",
      "body" => body,
      "timestamp" => now,
      "timestamp_s" => div(now, 1000)
    }
  end

  defp sign_hmac(req, auth, vars) do
    request = request_vars(req)
    vars = Map.put(vars, "request", request)

    req =
      Enum.reduce(Request.render(auth["params"] || %{}, vars), req, fn {k, v}, req ->
        add_query(req, k, text(v))
      end)

    # The query may have grown: sign what is sent.
    vars = put_in(vars, ["request", "query"], req.url.query || "")
    auth = Request.render(Map.drop(auth, ["params"]), vars)

    req =
      Enum.reduce(auth["headers"] || %{}, req, fn {k, v}, req ->
        Req.Request.put_header(req, String.downcase(k), text(v))
      end)

    algorithm = hmac_atom(auth["algorithm"] || "sha256")
    mac = :crypto.mac(:hmac, algorithm, text(auth["secret"]), text(auth["message"]))

    signature =
      case auth["encoding"] do
        "base64" -> Base.encode64(mac)
        _hex -> Base.encode16(mac, case: :lower)
      end

    case auth["signature"] || %{} do
      %{"query" => name} -> add_query(req, name, signature)
      %{"header" => name} -> Req.Request.put_header(req, String.downcase(name), signature)
    end
  end

  defp add_query(req, key, value) do
    pair = URI.encode_query([{key, value}])
    query = if req.url.query in [nil, ""], do: pair, else: req.url.query <> "&" <> pair
    %{req | url: %{req.url | query: query}}
  end

  defp sign_jwt(req, auth, vars) do
    vars = Map.put(vars, "request", request_vars(req))
    rendered = Request.render(Map.drop(auth, ["apply"]), vars)
    now = System.system_time(:second)
    lifetime = integer(rendered["lifetime"]) || 300

    claims =
      %{"iat" => now, "exp" => now + lifetime}
      |> Map.merge(rendered["claims"] || %{})

    case jwt(rendered["algorithm"] || "HS256", rendered["key"], rendered, claims) do
      {:ok, token} ->
        apply = auth["apply"] || %{"type" => "bearer", "token" => "{{auth.token}}"}
        vars = Map.put(vars, "auth", %{"token" => token})
        simple(req, Request.render(apply, vars), vars)

      {:error, message} ->
        {req, RuntimeError.exception(message)}
    end
  end

  defp jwt(algorithm, key, auth, claims) do
    header = Map.merge(%{"alg" => algorithm, "typ" => "JWT"}, auth["header"] || %{})
    input = segment(header) <> "." <> segment(claims)

    with {:ok, signature} <- signature(algorithm, text(key), auth["key_encoding"], input) do
      {:ok, input <> "." <> Base.url_encode64(signature, padding: false)}
    end
  end

  defp segment(map), do: map |> JSON.encode!() |> Base.url_encode64(padding: false)

  defp signature("HS" <> bits, key, encoding, input) do
    with {:ok, secret} <- secret(key, encoding) do
      {:ok, :crypto.mac(:hmac, :"sha#{bits}", secret, input)}
    end
  end

  defp signature("RS256", pem, _encoding, input) do
    with {:ok, key} <- private_key(pem), do: {:ok, :public_key.sign(input, :sha256, key)}
  end

  defp signature("ES256", pem, _encoding, input) do
    with {:ok, key} <- private_key(pem) do
      der = :public_key.sign(input, :sha256, key)
      {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
      {:ok, <<r::256, s::256>>}
    end
  end

  defp secret(key, "hex") do
    case Base.decode16(key, case: :mixed) do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, "The JWT key isn't hex."}
    end
  end

  defp secret(key, "base64") do
    case Base.decode64(key) do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, "The JWT key isn't base64."}
    end
  end

  defp secret(key, _raw), do: {:ok, key}

  defp private_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, "The JWT key isn't a private key in PEM."}
    end
  rescue
    _error -> {:error, "The JWT key isn't a private key in PEM."}
  end

  ## Client certificates

  defp put_tls(request, nil, _vars), do: {:ok, request}

  defp put_tls(request, tls, vars) do
    with {:ok, options} <- tls_options(tls, vars) do
      {:ok, Req.merge(request, connect_options: options)}
    end
  end

  # The token request goes through the same certificate.
  defp request_tls(request) do
    case request.options[:connect_options] do
      nil -> []
      options -> [connect_options: options]
    end
  end

  @doc """
  The connection options for the client certificate in `tls`: `cert` and `key`, both
  in PEM, usually templates of the credential.
  """
  @spec tls_options(map(), map()) :: {:ok, keyword()} | {:error, String.t()}
  def tls_options(tls, vars) do
    tls = Request.render(tls, vars)

    with [{:Certificate, cert, _} | _] <- pem(tls["cert"]),
         [{type, key, _} | _] <- pem(tls["key"]) do
      {:ok, [transport_opts: [cert: cert, key: {type, key}]]}
    else
      _invalid -> {:error, "The client certificate isn't valid PEM."}
    end
  end

  defp pem(text) when is_binary(text) do
    :public_key.pem_decode(text)
  rescue
    _error -> []
  end

  defp pem(_other), do: []

  ## Helpers

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value), do: to_string(value)

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp integer(_value), do: nil

  defp dig(value, nil), do: value

  defp dig(value, path) do
    path
    |> String.split(".")
    |> Enum.reduce(value, fn
      key, map when is_map(map) -> Map.get(map, key)
      _key, _other -> nil
    end)
  end
end

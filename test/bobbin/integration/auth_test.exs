defmodule Bobbin.Integration.AuthTest do
  use ExUnit.Case, async: true

  alias Bobbin.Integration
  alias Bobbin.Integration.{Auth, Request}

  defp manifest(id, auth, extra \\ "") do
    {:ok, integration} =
      Integration.parse("""
      id: #{id}
      name: Svc
      version: 1.0.0
      base_url: https://api.svc.test/
      credential:
        fields:
          - {name: key}
          - {name: secret}
      #{extra}
        auth:
      #{auth |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))}
      actions:
        - name: Get Items
          fields:
            - {name: q}
          request:
            method: POST
            path: items
            query:
              q: "{{fields.q}}"
            body:
              a: 1
      """)

    integration
  end

  defp run(integration, plug, credential \\ %{"key" => "K", "secret" => "S"}) do
    Request.run(integration, "Get Items", %{"q" => "x"}, credential, plug: plug)
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  test "client credentials: fetches a token once and keeps it until it expires" do
    i =
      manifest("cc_#{System.unique_integer([:positive])}", """
      type: client_credentials
      token_url: https://auth.svc.test/oauth/token
      client_id: "{{credential.key}}"
      client_secret: "{{credential.secret}}"
      scopes: [read, write]
      """)

    test = self()

    plug = fn conn ->
      case conn.request_path do
        "/oauth/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:token, header(conn, "authorization"), URI.decode_query(body)})
          Req.Test.json(conn, %{"access_token" => "T1", "expires_in" => 3600})

        "/items" ->
          send(test, {:items, header(conn, "authorization")})
          Req.Test.json(conn, %{"ok" => true})
      end
    end

    assert {:ok, _} = run(i, plug)
    assert {:ok, _} = run(i, plug)

    basic = "Basic " <> Base.encode64("K:S")

    assert_received {:token, ^basic,
                     %{"grant_type" => "client_credentials", "scope" => "read write"}}

    refute_received {:token, _, _}
    assert_received {:items, "Bearer T1"}
    assert_received {:items, "Bearer T1"}
  end

  test "a token the service refuses is fetched again, once" do
    i =
      manifest("cc_#{System.unique_integer([:positive])}", """
      type: client_credentials
      token_url: https://auth.svc.test/token
      client_id: "{{credential.key}}"
      client_secret: "{{credential.secret}}"
      token_auth: body
      """)

    counter = :counters.new(1, [])

    plug = fn conn ->
      case conn.request_path do
        "/token" ->
          :counters.add(counter, 1, 1)
          n = :counters.get(counter, 1)
          Req.Test.json(conn, %{"access_token" => "T#{n}", "expires_in" => 3600})

        "/items" ->
          if header(conn, "authorization") == "Bearer T1",
            do: Plug.Conn.send_resp(conn, 401, "expired"),
            else: Req.Test.json(conn, %{"token" => header(conn, "authorization")})
      end
    end

    assert {:ok, %{"token" => "Bearer T2"}} = run(i, plug)
  end

  test "login: trades the user and password for a token, and puts it where told" do
    i =
      manifest("login_#{System.unique_integer([:positive])}", """
      type: login
      request:
        method: POST
        path: session
        body:
          user: "{{credential.key}}"
          password: "{{credential.secret}}"
      token_path: data.token
      apply:
        type: header
        name: X-Session
        value: "{{auth.token}}"
      """)

    plug = fn conn ->
      case conn.request_path do
        "/session" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert JSON.decode!(body) == %{"user" => "K", "password" => "S"}
          Req.Test.json(conn, %{"data" => %{"token" => "SESS"}})

        "/items" ->
          Req.Test.json(conn, %{"session" => header(conn, "x-session")})
      end
    end

    assert {:ok, %{"session" => "SESS"}} = run(i, plug)
  end

  test "login: may send the user and password as Basic auth" do
    i =
      manifest("login_#{System.unique_integer([:positive])}", """
      type: login
      request:
        method: POST
        path: token
        basic: {username: "{{credential.key}}", password: "{{credential.secret}}"}
        body: {numero: "123"}
      token_path: token
      apply: {type: bearer, token: "{{auth.token}}"}
      """)

    plug = fn conn ->
      case conn.request_path do
        "/token" ->
          assert header(conn, "authorization") == "Basic " <> Base.encode64("K:S")
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert JSON.decode!(body) == %{"numero" => "123"}
          Req.Test.json(conn, %{"token" => "T"})

        "/items" ->
          Req.Test.json(conn, %{"auth" => header(conn, "authorization")})
      end
    end

    assert {:ok, %{"auth" => "Bearer T"}} = run(i, plug)
  end

  test "a login that fails says so" do
    i =
      manifest("login_#{System.unique_integer([:positive])}", """
      type: login
      request: {method: POST, path: session}
      token_path: token
      """)

    assert {:error, "Svc refused the login: answered 403"} =
             run(i, &Plug.Conn.send_resp(&1, 403, "no"))
  end

  test "aws_sigv4 signs the request" do
    i =
      manifest("aws", """
      type: aws_sigv4
      access_key_id: "{{credential.key}}"
      secret_access_key: "{{credential.secret}}"
      region: us-east-1
      service: sqs
      """)

    plug = fn conn ->
      assert "AWS4-HMAC-SHA256 Credential=K/" <> rest = header(conn, "authorization")
      assert rest =~ "/us-east-1/sqs/aws4_request"
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = run(i, plug)
  end

  test "hmac signs the timestamp, the query and the body" do
    i =
      manifest("hmac", """
      type: hmac
      secret: "{{credential.secret}}"
      algorithm: sha256
      params:
        timestamp: "{{request.timestamp}}"
      headers:
        X-Api-Key: "{{credential.key}}"
      message: "{{request.method}}{{request.path}}?{{request.query}}{{request.body}}"
      signature:
        query: signature
      """)

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert header(conn, "x-api-key") == "K"
      [query, _sig] = String.split(conn.query_string, "&signature=")
      assert query =~ "timestamp="
      message = "POST/items?" <> query <> body
      expected = :crypto.mac(:hmac, :sha256, "S", message) |> Base.encode16(case: :lower)
      assert conn.query_params["signature"] == expected
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = run(i, plug)
  end

  test "jwt HS256 signs claims with the secret, in a header the manifest writes" do
    i =
      manifest("jwt_hs", """
      type: jwt
      algorithm: HS256
      key: "{{credential.secret}}"
      key_encoding: hex
      header:
        kid: "{{credential.key}}"
      claims:
        aud: /admin/
      lifetime: 300
      apply:
        type: header
        name: Authorization
        value: "Ghost {{auth.token}}"
      """)

    plug = fn conn ->
      "Ghost " <> token = header(conn, "authorization")
      [h, c, s] = String.split(token, ".")
      assert %{"alg" => "HS256", "kid" => "K", "typ" => "JWT"} = decode(h)
      assert %{"aud" => "/admin/", "iat" => iat, "exp" => exp} = decode(c)
      assert exp - iat == 300
      mac = :crypto.mac(:hmac, :sha256, Base.decode16!("AB"), h <> "." <> c)
      assert Base.url_decode64!(s, padding: false) == mac
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = run(i, plug, %{"key" => "K", "secret" => "ab"})
  end

  test "jwt RS256 and ES256 sign with a private key in PEM" do
    for {alg, key} <- [{"RS256", {:rsa, 2048, 65_537}}, {"ES256", {:namedCurve, :secp256r1}}] do
      private = :public_key.generate_key(key)
      pem = pem(private)

      i =
        manifest("jwt_#{String.downcase(alg)}", """
        type: jwt
        algorithm: #{alg}
        key: "{{credential.secret}}"
        claims:
          iss: "{{credential.key}}"
        """)

      plug = fn conn ->
        "Bearer " <> token = header(conn, "authorization")
        [h, c, s] = String.split(token, ".")
        assert %{"alg" => ^alg} = decode(h)
        assert %{"iss" => "K"} = decode(c)
        assert verify(alg, h <> "." <> c, Base.url_decode64!(s, padding: false), private)
        Req.Test.json(conn, %{})
      end

      assert {:ok, _} = run(i, plug, %{"key" => "K", "secret" => pem})
    end
  end

  test "a client certificate goes to the connection" do
    %{cert: cert, key: private} = :public_key.pkix_test_root_cert(~c"Test", digest: :sha256)
    key_pem = pem(private)
    cert_pem = :public_key.pem_encode([{:Certificate, cert, :not_encrypted}])

    assert {:ok, opts} =
             Auth.tls_options(
               %{"cert" => "{{credential.cert}}", "key" => "{{credential.key}}"},
               %{"credential" => %{"cert" => cert_pem, "key" => key_pem}, "fields" => %{}}
             )

    assert [transport_opts: [cert: der, key: {type, key_der}]] = opts
    assert type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo] and is_binary(key_der)
    assert is_binary(der)

    assert {:error, "The client certificate isn't valid PEM."} =
             Auth.tls_options(%{"cert" => "nope", "key" => "nope"}, %{
               "credential" => %{},
               "fields" => %{}
             })
  end

  test "the manifest checks the new auth types" do
    assert {:error, errors} =
             Integration.parse("""
             id: x
             name: X
             version: 1.0.0
             base_url: https://x.test/
             credential:
               auth: {type: jwt, algorithm: XX}
             actions:
               - {name: A, request: {method: GET, path: a}}
             """)

    assert "credential.auth.algorithm must be one of HS256, HS384, HS512, RS256, ES256" in errors
  end

  defp decode(part), do: part |> Base.url_decode64!(padding: false) |> JSON.decode!()

  defp pem(private) do
    type = elem(private, 0)
    :public_key.pem_encode([:public_key.pem_entry_encode(type, private)])
  end

  defp verify("RS256", data, sig, {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _}),
    do: :public_key.verify(data, :sha256, sig, {:RSAPublicKey, n, e})

  defp verify("ES256", data, <<r::256, s::256>>, {:ECPrivateKey, _, _, params, public, _}) do
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :public_key.verify(data, :sha256, der, {{:ECPoint, public}, params})
  end
end

defmodule Bobbin.Integration.WebhookTest do
  use ExUnit.Case, async: true

  alias Bobbin.Integration
  alias Bobbin.Integration.Webhook

  @manifest """
  id: forge
  name: Forge
  version: 1.0.0
  base_url: https://api.forge.test/
  credential:
    auth: {type: bearer, token: "{{credential.token}}"}
  actions:
    - {name: Ping, request: {method: GET, path: ping}}
  triggers:
    - name: New Push
      fields:
        - {name: repo, label: Repository, required: true}
      webhook:
        register:
          request:
            method: POST
            path: "repos/{{fields.repo}}/hooks"
            body:
              url: "{{webhook.url}}"
              secret: "{{webhook.secret}}"
              events: [push]
          id_path: id
        unregister:
          request: {method: DELETE, path: "repos/{{fields.repo}}/hooks/{{webhook.id}}"}
        signature:
          header: X-Forge-Signature
          prefix: "sha256="
          secret: "{{webhook.secret}}"
        output:
          path: commits

    - name: New Payment
      webhook:
        signature:
          header: Pay-Signature
          pattern: "t=(?<timestamp>\\\\d+),v1=(?<signature>[0-9a-f]+)"
          message: "{{request.timestamp}}.{{request.body}}"
          secret: "{{credential.signing_secret}}"
          tolerance: 300
        challenge:
          query: hub.challenge

    - name: New Merge Request
      webhook:
        signature: {header: X-Gitlab-Token, token: "{{webhook.secret}}"}

    - name: Deal Added
      webhook:
        signature: {basic: {username: heddle, password: "{{webhook.secret}}"}}

    - name: Card Moved
      webhook:
        signature:
          header: X-Trello-Webhook
          algorithm: sha1
          encoding: base64
          message: "{{request.body}}{{webhook.url}}"
          secret: "{{credential.app_secret}}"
        challenge: {method: HEAD}

    - name: Box Event
      webhook:
        signature:
          header: Box-Signature-Primary
          timestamp_header: Box-Delivery-Timestamp
          encoding: base64
          message: "{{request.body}}{{request.timestamp}}"
          secret: "{{credential.signature_key}}"
          tolerance: 600
  """

  setup do
    {:ok, integration} = Integration.parse(@manifest)
    %{integration: integration}
  end

  defp sign(secret, message),
    do: :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)

  test "registers Heddle's address with the service, and keeps what it answers", %{
    integration: i
  } do
    plug = fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/repos/acme/hooks"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert JSON.decode!(body) == %{
               "url" => "https://heddle.test/hooks/1",
               "secret" => "s3",
               "events" => ["push"]
             }

      Req.Test.json(conn, %{"id" => 99})
    end

    assert {:ok, %{"id" => "99", "url" => "https://heddle.test/hooks/1", "secret" => "s3"}} =
             Webhook.register(
               i,
               "New Push",
               %{"repo" => "acme"},
               %{"token" => "t"},
               %{"url" => "https://heddle.test/hooks/1", "secret" => "s3"},
               plug: plug
             )
  end

  test "removes it when the flow stops", %{integration: i} do
    plug = fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/repos/acme/hooks/99"
      Plug.Conn.send_resp(conn, 204, "")
    end

    assert :ok =
             Webhook.unregister(i, "New Push", %{"repo" => "acme"}, %{}, %{"id" => "99"},
               plug: plug
             )
  end

  test "a trigger the user registers by hand has nothing to register", %{integration: i} do
    assert {:ok, :manual} = Webhook.register(i, "New Payment", %{}, %{}, %{"url" => "u"})
    assert :ok = Webhook.unregister(i, "New Payment", %{}, %{}, %{})
  end

  test "takes an event with a good signature, and passes on its items", %{integration: i} do
    body = ~s({"commits": [{"id": "a"}, {"id": "b"}]})

    event = %{
      headers: %{"x-forge-signature" => "sha256=" <> sign("s3", body)},
      body: body,
      query: %{}
    }

    assert {:ok, [%{"id" => "a"}, %{"id" => "b"}]} =
             Webhook.receive(i, "New Push", event, %{"secret" => "s3"}, %{})
  end

  test "refuses an event with a bad or missing signature", %{integration: i} do
    body = ~s({"commits": []})

    for headers <- [%{"x-forge-signature" => "sha256=00"}, %{}] do
      assert {:error, :signature} =
               Webhook.receive(
                 i,
                 "New Push",
                 %{headers: headers, body: body, query: %{}},
                 %{"secret" => "s3"},
                 %{}
               )
    end
  end

  test "checks a signature with a timestamp, and refuses an old one", %{integration: i} do
    body = ~s({"amount": 10})
    now = System.system_time(:second)

    event = fn t ->
      header = "t=#{t},v1=" <> sign("whsec", "#{t}.#{body}")
      %{headers: %{"pay-signature" => header}, body: body, query: %{}}
    end

    assert {:ok, [%{"amount" => 10}]} =
             Webhook.receive(i, "New Payment", event.(now), %{}, %{"signing_secret" => "whsec"})

    assert {:error, :signature} =
             Webhook.receive(i, "New Payment", event.(now - 600), %{}, %{
               "signing_secret" => "whsec"
             })
  end

  test "a timestamp may be a date and time, like Box's", %{integration: i} do
    body = ~s({"trigger": "FILE.UPLOADED"})

    event = fn time ->
      t = DateTime.to_iso8601(time)
      mac = :crypto.mac(:hmac, :sha256, "key", body <> t) |> Base.encode64()

      %{
        headers: %{"box-signature-primary" => mac, "box-delivery-timestamp" => t},
        body: body,
        query: %{}
      }
    end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, [%{"trigger" => "FILE.UPLOADED"}]} =
             Webhook.receive(i, "Box Event", event.(now), %{}, %{"signature_key" => "key"})

    assert {:error, :signature} =
             Webhook.receive(i, "Box Event", event.(DateTime.add(now, -3600)), %{}, %{
               "signature_key" => "key"
             })
  end

  test "answers the service's challenge", %{integration: i} do
    event = %{headers: %{}, body: "", query: %{"hub.challenge" => "abc"}}
    assert {:reply, 200, "abc"} = Webhook.receive(i, "New Payment", event, %{}, %{})
  end

  test "a trigger needs a request or a webhook" do
    yaml = """
    id: x
    name: X
    version: 1.0.0
    base_url: https://x.test/
    actions:
      - {name: A, request: {method: GET, path: a}}
    triggers:
      - {name: T}
      - name: W
        webhook:
          register: {id_path: id}
    """

    assert {:error, errors} = Integration.parse(yaml)
    assert "triggers[0] needs a request to poll or a webhook" in errors
    assert "triggers[1].webhook.register needs a request with a method and a path" in errors
  end

  test "a service that sends the secret itself is checked against it", %{integration: i} do
    event = fn token -> %{headers: %{"x-gitlab-token" => token}, body: "{}", query: %{}} end
    webhook = %{"secret" => "s3"}

    assert {:ok, [%{}]} = Webhook.receive(i, "New Merge Request", event.("s3"), webhook, %{})

    assert {:error, :signature} =
             Webhook.receive(i, "New Merge Request", event.("no"), webhook, %{})
  end

  test "a service that calls with a user and a password is checked against them", %{
    integration: i
  } do
    event = fn auth -> %{headers: %{"authorization" => auth}, body: "{}", query: %{}} end
    webhook = %{"secret" => "s3"}
    good = "Basic " <> Base.encode64("heddle:s3")

    assert {:ok, [%{}]} = Webhook.receive(i, "Deal Added", event.(good), webhook, %{})

    assert {:error, :signature} =
             Webhook.receive(
               i,
               "Deal Added",
               event.("Basic " <> Base.encode64("heddle:no")),
               webhook,
               %{}
             )

    assert {:error, :signature} =
             Webhook.receive(
               i,
               "Deal Added",
               %{headers: %{}, body: "{}", query: %{}},
               webhook,
               %{}
             )
  end

  test "a HEAD that checks the address is answered, and events are signed with the address",
       %{integration: i} do
    webhook = %{"url" => "https://heddle.test/hooks/t"}
    credential = %{"app_secret" => "app"}

    head = %{headers: %{}, body: "", query: %{}, method: "HEAD"}
    assert {:reply, 200, ""} = Webhook.receive(i, "Card Moved", head, webhook, credential)

    body = ~s({"action": {"type": "updateCard"}})
    signature = :crypto.mac(:hmac, :sha, "app", body <> webhook["url"]) |> Base.encode64()

    event = %{headers: %{"X-Trello-Webhook" => signature}, body: body, query: %{}, method: "POST"}

    assert {:ok, [%{"action" => _}]} =
             Webhook.receive(i, "Card Moved", event, webhook, credential)
  end
end

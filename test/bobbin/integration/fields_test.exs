defmodule Bobbin.Integration.FieldsTest do
  use ExUnit.Case, async: true

  alias Bobbin.Integration
  alias Bobbin.Integration.Request

  @manifest """
  id: desk
  name: Desk
  version: 1.0.0
  base_url: "https://{{credential.subdomain}}.desk.test/api/"

  credential:
    fields:
      - {name: subdomain, label: Subdomain}
      - {name: token, label: Token, secret: true}
    auth:
      type: bearer
      token: "{{credential.token}}"

  i18n:
    pt-BR:
      description: Chamados no Desk.
      actions:
        Create Ticket:
          name: Criar chamado
          fields:
            urgent: Urgente

  actions:
    - name: Create Ticket
      resource: Ticket
      fields:
        - {name: subject, label: Subject, required: true}
        - {name: urgent, label: Urgent, type: boolean, default: false}
        - {name: custom, label: Custom fields, type: json}
        - {name: tags, label: Tags, type: multiselect, options: [{label: A, value: a}, {label: B, value: b}]}
        - {name: due, label: Due, type: datetime}
        - {name: start, label: Start, type: datetime, format: unix_ms}
        - {name: until, label: Until, type: datetime, format: unix}
        - {name: list, label: List, type: select, format: number, options_from: {request: {method: GET, path: lists}}}
        - {name: lists, label: Lists, type: multiselect, format: number, options_from: {request: {method: GET, path: lists}}}
      request:
        method: POST
        path: tickets
        body:
          subject: "{{fields.subject}}"
          urgent: "{{fields.urgent}}"
          custom: "{{fields.custom}}"
          tags: "{{fields.tags}}"
          due_at: "{{fields.due}}"
          start: "{{fields.start}}"
          until: "{{fields.until}}"
          list: "{{fields.list}}"
          lists: "{{fields.lists}}"
  """

  setup do
    {:ok, integration} = Integration.parse(@manifest)
    %{integration: integration}
  end

  defp run(integration, fields, credential \\ %{"subdomain" => "acme", "token" => "t"}) do
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn.host, conn.request_path, JSON.decode!(body)})
      Req.Test.json(conn, %{"id" => 1})
    end

    Request.run(integration, "Create Ticket", fields, credential, plug: plug)
  end

  test "the address takes the account's subdomain from the credential", %{integration: i} do
    assert {:ok, _} = run(i, %{"subject" => "Hi"})
    assert_received {:request, "acme.desk.test", "/api/tickets", _body}
  end

  test "an account value that would change the address is refused", %{integration: i} do
    for bad <- ["evil.test/x?", "a b", "x@evil.test", ""] do
      assert {:error, "Desk: the subdomain in the credential" <> _} =
               run(i, %{"subject" => "Hi"}, %{"subdomain" => bad, "token" => "t"})
    end
  end

  test "casts booleans, JSON and lists, and leaves out what is empty", %{integration: i} do
    fields = %{
      "subject" => "Hi",
      "urgent" => "true",
      "custom" => ~s({"plan": "pro"}),
      "tags" => "a, b"
    }

    assert {:ok, _} = run(i, fields)
    assert_received {:request, _host, _path, body}

    assert body == %{
             "subject" => "Hi",
             "urgent" => true,
             "custom" => %{"plan" => "pro"},
             "tags" => ["a", "b"]
           }
  end

  test "a boolean keeps its default false, and lists may come as lists", %{integration: i} do
    assert {:ok, _} =
             run(i, %{"subject" => "Hi", "tags" => ["b"], "due" => "2026-01-02T03:04:05Z"})

    assert_received {:request, _host, _path, body}
    assert body["urgent"] == false
    assert body["tags"] == ["b"]
    assert body["due_at"] == "2026-01-02T03:04:05Z"
  end

  test "a date with format unix or unix_ms goes as a number", %{integration: i} do
    fields = %{"subject" => "Hi", "start" => "2026-01-02T03:04:05Z", "until" => "2026-01-02"}
    assert {:ok, _} = run(i, fields)
    assert_received {:request, _host, _path, body}
    assert body["start"] == 1_767_323_045_000
    assert body["until"] == 1_767_312_000

    assert {:ok, _} = run(i, %{"subject" => "Hi", "start" => "1767323045000"})
    assert_received {:request, _host, _path, %{"start" => 1_767_323_045_000}}

    assert {:error, "Start must be a date and time" <> _} =
             run(i, %{"subject" => "Hi", "start" => "soon"})
  end

  test "a select with format number sends its value as a number", %{integration: i} do
    assert {:ok, _} = run(i, %{"subject" => "Hi", "list" => "7", "lists" => "2, 3.5, x"})
    assert_received {:request, _host, _path, body}
    assert body["list"] == 7
    assert body["lists"] == [2, 3.5, "x"]
  end

  test "bad JSON, a bad date or a missing required field is an error", %{integration: i} do
    assert {:error, "Custom fields must be JSON" <> _} =
             run(i, %{"subject" => "Hi", "custom" => "{nope"})

    assert {:error, "Due must be a date and time" <> _} =
             run(i, %{"subject" => "Hi", "due" => "tomorrow"})

    assert {:error, "Subject is required."} = run(i, %{})
  end

  test "an action has a resource, and the manifest its pt-BR texts", %{integration: i} do
    assert %{resource: "Ticket"} = Integration.action(i, "Create Ticket")

    assert %{"pt-BR" => %{"description" => "Chamados no Desk."}} = i.i18n

    assert Integration.translate(i, "pt-BR", ["actions", "Create Ticket", "name"]) ==
             "Criar chamado"

    assert Integration.translate(i, "pt-BR", ["actions", "Nope", "name"]) == nil
  end

  test "checks the new field types" do
    yaml =
      String.replace(
        @manifest,
        "type: multiselect, options: [{label: A, value: a}, {label: B, value: b}]",
        "type: multiselect"
      )
      |> String.replace("type: datetime", "type: color")

    assert {:error, errors} = Integration.parse(yaml)
    assert "actions[0].fields[3] is a multiselect and needs options" in errors
    assert Enum.any?(errors, &String.starts_with?(&1, "actions[0].fields[4].type must be one of"))
  end
end

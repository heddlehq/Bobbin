defmodule Bobbin.IntegrationTest do
  use ExUnit.Case, async: true

  alias Bobbin.Integration

  @fixture "test/fixtures/acme.yaml"

  test "loads a manifest" do
    assert {:ok, integration} = Integration.load(@fixture)

    assert integration.id == "acme"
    assert integration.category == "acme"
    assert integration.credential.kind == "acme"
    assert integration.credential.label == "Acme"
    assert [%{name: "api_key", secret: true}] = integration.credential.fields

    assert Enum.map(integration.actions, & &1.name) == [
             "Create Ticket",
             "List Tickets",
             "Get Ticket"
           ]

    action = Integration.action(integration, "Create Ticket")
    assert action.request.method == "POST"
    assert %{name: "priority", type: "select", default: "low"} = Enum.at(action.fields, 1)

    trigger = Integration.trigger(integration, "New Ticket")
    assert trigger.poll == %{every: 10, id: "ticket.number"}
    assert trigger.output == %{"path" => "tickets"}
  end

  test "a trigger polls every 5 minutes by id unless it says otherwise" do
    yaml = """
    id: acme
    name: Acme
    version: 1.0.0
    base_url: https://acme.test/
    actions:
      - {name: Ping, request: {method: GET, path: ping}}
    triggers:
      - {name: New, request: {method: GET, path: items}}
    """

    assert {:ok, %{triggers: [%{poll: %{every: 5, id: "id"}}]}} = Integration.parse(yaml)
  end

  test "says what is wrong with a trigger" do
    yaml = """
    id: acme
    name: Acme
    version: 1.0.0
    base_url: https://acme.test/
    actions:
      - {name: Ping, request: {method: GET, path: ping}}
    triggers:
      - name: New
        request: {method: GET}
        poll: {every: 0, id: ""}
      - name: New
        request: {method: GET, path: x}
    """

    assert {:error, errors} = Integration.parse(yaml)

    for expected <- [
          "triggers must have different names",
          "triggers[0].request needs a method and a path",
          "triggers[0].poll.every must be",
          "triggers[0].poll.id must be"
        ] do
      assert expected in Enum.map(errors, &String.slice(&1, 0, String.length(expected))),
             "missing: #{expected}"
    end
  end

  test "says everything that is wrong" do
    yaml = """
    id: Acme CRM
    version: one
    base_url: ftp://acme
    credential:
      auth:
        type: magic
    actions:
      - name: Same
        request: {method: FETCH, path: x}
      - name: Same
        fields:
          - name: kind
            type: select
        request: {method: GET, path: x}
        pagination: {type: pages}
    """

    assert {:error, errors} = Integration.parse(yaml)

    for expected <- [
          "id must be a lowercase id",
          "name is required",
          "version must be",
          "base_url must be",
          "credential.auth.type \"magic\"",
          "actions must have different names",
          "actions[0].request.method",
          "actions[1].fields[0] is a select and needs options",
          "actions[1].pagination needs"
        ] do
      assert Enum.any?(errors, &String.starts_with?(&1, expected)), "missing: #{expected}"
    end
  end

  test "refuses YAML aliases, which yamerl reads wrong" do
    yaml = """
    id: acme
    name: Acme
    version: 1.0.0
    base_url: https://acme.test/
    actions:
      - name: Get
        description: "Stars like *this* and 'a, *b' are text"
        fields:
          - &id {name: id, label: ID}
        request: {method: GET, path: "things/{{fields.id}}"}
      - name: Delete
        fields: [*id]
        request: {method: DELETE, path: "things/{{fields.id}}"}
      - name: Update
        fields:
          - *id # same field
        request: {method: PATCH, path: "things/{{fields.id}}"}
    """

    assert {:error, [first, second]} = Integration.parse(yaml)
    assert first =~ "Line 12 uses a YAML alias"
    assert second =~ "Line 16"
  end

  test "refuses what isn't a manifest" do
    assert {:error, ["The manifest must be a map."]} = Integration.parse("- a\n- b")
    assert {:error, ["Invalid YAML" <> _]} = Integration.parse("a: [")
    assert {:error, ["Can't read nope.yaml" <> _]} = Integration.load("nope.yaml")
  end

  test "the JSON Schema is valid JSON and names every key the parser reads" do
    schema = "priv/integration.schema.json" |> File.read!() |> JSON.decode!()
    action = schema["$defs"]["action"]["properties"]

    assert Map.keys(action) |> Enum.sort() ==
             ~w(description fields name output pagination request resource)

    assert schema["properties"]["actions"]["items"] == %{
             "allOf" => [%{"$ref" => "#/$defs/action"}, %{"required" => ["request"]}]
           }

    assert [%{"$ref" => "#/$defs/action"}, poll] =
             schema["properties"]["triggers"]["items"]["allOf"]

    assert Map.keys(poll["properties"]["poll"]["properties"]) |> Enum.sort() == ~w(every id)

    assert Map.keys(poll["properties"]["webhook"]["properties"]) |> Enum.sort() ==
             ~w(challenge output register signature unregister)
  end
end

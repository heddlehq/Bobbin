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

  test "refuses what isn't a manifest" do
    assert {:error, ["The manifest must be a map."]} = Integration.parse("- a\n- b")
    assert {:error, ["Invalid YAML" <> _]} = Integration.parse("a: [")
    assert {:error, ["Can't read nope.yaml" <> _]} = Integration.load("nope.yaml")
  end

  test "the JSON Schema is valid JSON and names every action key the parser reads" do
    schema = "priv/integration.schema.json" |> File.read!() |> JSON.decode!()
    action = schema["properties"]["actions"]["items"]["properties"]

    assert Map.keys(action) |> Enum.sort() ==
             ~w(description fields name output pagination request)
  end
end

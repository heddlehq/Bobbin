defmodule Bobbin.Integration.DefinitionTest do
  use ExUnit.Case, async: true

  alias Bobbin.Integration
  alias Bobbin.Integration.Definition

  @manifest """
  id: forge
  name: Forge
  version: 1.0.0
  category: developer
  base_url: https://api.forge.test/
  credential:
    label: Forge
    fields: [{name: token, label: Token, secret: true}]
    auth: {type: bearer, token: "{{credential.token}}"}
  actions:
    - name: Create Issue
      resource: Issue
      fields:
        - {name: repo, label: Repository, type: select, required: true,
           options_from: {request: {method: GET, path: repos}, path: items}}
        - {name: title, label: Title}
        - {name: draft, label: Draft, type: boolean, default: false}
        - {name: labels, label: Labels, type: multiselect, options: [{label: Bug, value: bug}]}
      request: {method: POST, path: "repos/{{fields.repo}}/issues"}
  triggers:
    - name: New Push
      webhook:
        signature: {header: X-Sig, secret: "{{credential.token}}"}
    - name: New Issue
      request: {method: GET, path: issues}
  i18n:
    pt-BR:
      actions:
        Create Issue:
          name: Criar issue
          fields: {title: Título}
  """

  setup do
    {:ok, manifest} = Integration.parse(@manifest)
    %{manifest: manifest}
  end

  test "an action has its resource, its field types and its translations", %{manifest: m} do
    definition = Definition.definition(m, Integration.action(m, "Create Issue"))

    assert definition.resource == "Issue"
    assert definition.group == "Issue"
    assert definition.integration == "forge"

    assert definition.i18n == %{
             "pt-BR" => %{name: "Criar issue", description: nil, fields: %{"title" => "Título"}}
           }

    fields = Map.new(definition.ui_fields, &{&1.name, &1})
    assert %{type: :select, required: true, options_from: true} = fields.repo
    assert %{type: :text, required: false} = fields.title
    refute Map.has_key?(fields.title, :options_from)
    assert %{type: :boolean, default: false} = fields.draft
    assert %{type: :multiselect, options: [%{label: "Bug", value: "bug"}]} = fields.labels
  end

  test "a webhook trigger says so, and whether it is pasted by hand", %{manifest: m} do
    push = Definition.trigger_definition(m, Integration.trigger(m, "New Push"))
    assert push.webhook == %{trigger: "New Push", manual: true}
    refute Map.has_key?(push, :poll)

    issue = Definition.trigger_definition(m, Integration.trigger(m, "New Issue"))
    assert issue.poll == %{trigger: "New Issue", every: 5}
    refute Map.has_key?(issue, :webhook)
    assert issue.i18n == %{"pt-BR" => %{name: nil, description: nil, fields: %{}}}
  end

  test "with a logo, the nodes' icon is logo-<id>, which the host shows the logo under" do
    {:ok, plain} = Integration.parse(@manifest)

    assert Definition.definition(plain, Integration.action(plain, "Create Issue")).icon ==
             "hero-puzzle-piece"

    logo = ~s(logo: '<svg xmlns="http://www.w3.org/2000/svg"></svg>'\n)
    {:ok, manifest} = Integration.parse(logo <> @manifest)

    assert Definition.definition(manifest, Integration.action(manifest, "Create Issue")).icon ==
             "logo-forge"

    assert Definition.trigger_definition(manifest, Integration.trigger(manifest, "New Issue")).icon ==
             "logo-forge"

    assert Definition.icon(manifest) == "logo-forge"
  end
end

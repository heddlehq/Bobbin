# Integrations in Elixir

A manifest only sends HTTP requests. When a service needs a driver (a database, SMTP,
FTP) or several calls for one action, the integration is a Mix package written with
Bobbin, in [heddlehq/integrations](https://github.com/heddlehq/integrations).

Code can't be installed from Heddle's Integrations page, since it would run inside
Heddle. A package enters when Heddle is built, listed in `HEDDLE_INTEGRATIONS`.

## A node

Each action is a node of its own, so it shows only the fields it needs.
`Bobbin.Service.run/3` fetches the credential and sends `{:ok, result}` to the
`success` output and `{:error, message}` to `error`.

```elixir
defmodule HeddleIntegrations.Nodes.Acme.GetItem do
  use Bobbin.Node

  @service %{
    title: "Acme",
    category: :acme,
    credential: "acme",
    icon: "hero-cube"
  }

  @impl true
  def definition do
    Bobbin.Service.definition(@service, "Get Item", "Reads an item.", [
      %{type: :text, name: :id, label: "Item ID", default: ""}
    ])
  end

  @impl true
  def handler(context, _input) do
    Bobbin.Service.run(context, "acme", fn credential ->
      id = Bobbin.Service.field(context, "id")
      Acme.Client.get(credential["api_key"], id)
    end)
  end
end
```

`Bobbin.Service` also reads files, JSON and numbers from the node's fields, and
`Bobbin.Connections` keeps a driver's connection open between runs.

## The package

Its `mix.exs` names the nodes, so Heddle finds them:

```elixir
def application do
  [
    extra_applications: [:logger],
    env: [bobbin_nodes: [HeddleIntegrations.Nodes.Acme.GetItem]]
  ]
end

defp deps do
  [{:bobbin, "~> 0.5"}, {:acme_client, "~> 1.0"}]
end
```

The credential and the actions that fit in YAML can stay in `priv/integration.yaml`,
like Slack's package does, with `Bobbin.Integration.Nodes`:

```elixir
defmodule HeddleIntegrations.Slack do
  use Bobbin.Integration.Nodes, manifest: "../../priv/integration.yaml"
end
```

and the module listed in `bobbin_integrations`, next to `bobbin_nodes`.

## Steps

1. Create `integrations/acme/` in heddlehq/integrations, with `mix.exs` and `lib/`.
2. Write a node per action.
3. Test it without Heddle, with `Bobbin.TestHost` as the host.
4. Document each node in `priv/docs.json`.
5. Open a pull request.

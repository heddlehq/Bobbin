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

## What the host does for a package

Since 0.7, `Bobbin.Host` does more than credentials, for packages that keep state or
start flows, like Heddle's Agents:

- **Start runs** of the flows that begin at a trigger of the package
  (`start_runs/1`), now or at a time (`at:`), one at a time per `lane:`, and cancel
  one that hasn't begun (`cancel_run/2`).
- **Keep data** between runs (`store_get/4`, `store_put/5`, `store_delete/4`,
  `store_list/4`). With `with_run:`, what a run writes is kept only if it ends well.
- **Call the AI page's models** (`ai_connection/2`), and charge each call to the step
  (`record_usage/1`).
- **Wait**: a node pauses the run without holding a worker, until a call
  (`Bobbin.Node.wait_for_call/2`, ended by `resume_run/4`) or a person's decision
  (`Bobbin.Node.wait_for_approval/2`). With `again: true`, the handler is called again
  when the wait ends, with `"resumed"` in its context.
- **Use tools**: a handler that answers `{:with_tools, fun}` gets the nodes connected
  to its `tools` output, and calls them by name.

A node module can also give the host a **panel** for its drawer (`c:Bobbin.Node.panel/2`),
and a trigger a **public chat page** (`c:Bobbin.Node.chat_message/4` and
`c:Bobbin.Node.chat_history/3`).

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
  [{:bobbin, "~> 0.7"}, {:acme_client, "~> 1.0"}]
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

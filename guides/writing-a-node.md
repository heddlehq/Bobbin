# Writing a node

A node is one module that says what it is, in `definition/0`, and what it does, in `handler/2`. This guide writes one from scratch, tests it, and puts it in Heddle.

To *use* the nodes Heddle already has, see the [Heddle documentation](https://heddlehq.github.io/website/docs/nodes/) instead.

## The smallest node

```elixir
defmodule MyNodes.Greet do
  use Bobbin.Node

  definition do
    %{
      name: "Greet",
      title: "Greet",
      category: :utility,
      description: "Writes a greeting for a name into the result.",
      icon: "hero-hand-raised-solid",
      inputs: [:exec],
      outputs: [:exec],
      ui_fields: [
        %{type: :text, name: :person, label: "Name", default: "world"}
      ]
    }
  end

  @impl true
  def handler(context, _input) do
    {:ok, Map.put(context, "result", "Hello, #{context["person"]}!"), :exec}
  end
end
```

That is a whole node: it shows in Heddle's sidebar under **Utility**, has one field, and leaves `"Hello, world!"` in `result`.

## The definition

| Key | What it is |
| --- | --- |
| `name` | Its type, unique and stable: flows store it, so renaming it breaks them. |
| `title` | What the sidebar and the canvas show. |
| `category` | The sidebar group, like `:utility`, `:ai` or `:database`. |
| `description` | One sentence on what it does. It shows on hover, and AI agents read it to pick nodes. |
| `icon` | A Heroicon, like `"hero-bolt-solid"`. |
| `inputs` | Usually `[:exec]`, and `[]` for a trigger, which starts runs. |
| `outputs` | The ways out. `[:exec]` for one, `["success", "error"]` for a node that reaches a service. |
| `ui_fields` | The fields of its drawer. |
| `show` | `false` keeps it out of the sidebar. |

### Fields

Each field has a `type`, a `name`, a `label` and a `default`:

| Type | Shows |
| --- | --- |
| `:text` | One line. |
| `:textarea` | Several lines, for queries, JSON or long text. |
| `:select` | A choice, with `options: [%{label: "Info", value: "info"}]` or a list of strings. |
| `:credential` | A stored credential, with `kind: "slack"`. Heddle never shows its secret in the flow. |
| `:code` | The code editor. |

Name fields with care. While the node runs, its fields sit in the context under their names, so a field called `body` would hide the body of the webhook that started the run. Prefer names like `message_body`.

## The handler

`handler(context, input)` gets the run's **context**, a map with string keys, and returns where to go next:

| Return | Means |
| --- | --- |
| `{:ok, context, output}` | Go on through `output`, with this context. |
| `{:error, reason}` | The step failed. Heddle tries again if the node's settings say so, then takes its error path. |

The context holds what earlier steps left, like `"result"` and `"body"`, and the node's own fields by name. Put what the node produces in `"result"`, where the next node looks first.

Fields come as written, placeholders included. Inside Heddle, `HeddleNodes.Template.render(context["person"], context)` fills `{{placeholders}}` in, so a person can write `{{body.name}}`. Render each field that takes them.

### A node that reaches a service

Give it `success` and `error` outputs, and answer through them instead of returning `{:error, ...}`, so a flow can handle the service being down:

```elixir
def handler(context, _input) do
  case Req.get(context["url"]) do
    {:ok, %{status: 200, body: body}} ->
      {:ok, Map.put(context, "result", body), "success"}

    {:ok, %{status: status}} ->
      {:ok, Map.put(context, "result", %{"error" => "HTTP #{status}"}), "error"}

    {:error, reason} ->
      {:ok, Map.put(context, "result", %{"error" => Exception.message(reason)}), "error"}
  end
end
```

## Testing it

A node is a plain module, so it tests without Heddle:

```elixir
defmodule MyNodes.GreetTest do
  use ExUnit.Case, async: true

  test "greets the name it is given" do
    assert {:ok, %{"result" => "Hello, Ana!"}, :exec} =
             MyNodes.Greet.handler(%{"person" => "Ana"}, nil)
  end

  test "its definition is complete" do
    definition = MyNodes.Greet.definition()

    assert definition.name == "Greet"
    assert definition.outputs == [:exec]
  end
end
```

## Registering it

A manifest lists the nodes of an integration:

```elixir
defmodule MyNodes do
  use Bobbin.Manifest

  manifest do
    nodes([MyNodes.Greet])
  end
end
```

It gets `available_nodes/0`, `get_definitions/0` and `get_node_module/1`, which is what Heddle reads.

## Putting it in Heddle

Heddle's own nodes are a manifest, `HeddleNodes`, in `apps/heddle_nodes`. Heddle doesn't load other manifests yet, so a node goes in by adding it there:

1. Put the module in `apps/heddle_nodes/lib/heddle_nodes/nodes/`, and add it to the list in `HeddleNodes`.
2. Document it: an entry in `docs/nodes/<category>.json` with an example of its `result` and notes in English and Portuguese, then `mix heddle.docs`. A test fails until you do.
3. Run `mix precommit`.

See [CONTRIBUTING.md](https://github.com/heddlehq/Heddle/blob/main/CONTRIBUTING.md) in Heddle.

## What a good node looks like

- **One action per node.** `Slack: Send Message` and `Slack: Read Messages`, not a Slack node with a mode, so each shows only the fields it needs.
- **Defaults that chain.** A field that usually takes the previous node's result defaults to `{{result}}`.
- **Errors a person can act on.** `"Channel: give a channel ID, like C0123456789."` beats `"invalid_channel"`.
- **No secrets in fields.** Take them from a `:credential` field.
- **Safe to retry.** A run whose worker died starts again, so a node that charges or sends should be safe to run twice.

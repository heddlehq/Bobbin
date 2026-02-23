# 🤖 AGENTS.md - Development Guide

Welcome to the **FusionKit** project. This document serves as the source of truth for AI agents and developers working on this SDK. Follow these rules strictly to maintain consistency, reliability, and project health.

---

## 🎯 Motivation

**FusionKit** is the bridge between developers and the **FusionFlow** platform. As an SDK, its primary goal is to provide a **simple, predictable, and robust** interface for building custom integrations. Every line of code should prioritize developer experience (DX) and system stability.

---

## 🛠 Architectural Patterns

The project follows a modular and behavior-driven architecture:

### 1. Nodes (`FusionKit.Node`)
Nodes are the core processing units.
- **Strict Pattern**: Every node MUST use `use FusionKit.Node`.
- **Definition Macro**: Metadata must be declared inside the `definition` macro.
- **Handler Arity**: The `handler/3` function must always accept `(config, context, input)`.

### 2. Manifests (`FusionKit.Manifest`)
Manifests register and expose nodes to the platform.
- **Strict Pattern**: Use `use FusionKit.Manifest`.
- **Automatic Generation**: The `nodes` macro generates `available_nodes/0`, `get_definitions/0`, and `get_node_module/1`.

---

## 📏 Coding Standards

- **Namespaces**: Use only the `FusionKit` namespace for SDK core modules (e.g., `FusionKit.Node`, `FusionKit.Manifest`).
- **Typespecs**: Every public function and callback MUST have a `@type` or `@spec`.
- **Documentation**: Modules must have a `@moduledoc` with usage examples. Functions must have a `@doc`.
- **Atoms vs Strings**: 
  - Use **atoms** for categories, internal identifiers, and simple input/output ports. 
  - Use **strings** for user-facing titles and unique node names.

---

## 🧪 Testing Mandate (NON-NEGOTIABLE)

**Every single functionality, macro, or new node added MUST be accompanied by unit tests.**

- **Location**: All tests must reside in `test/fusion_kit/`.
- **Coverage**: Tests should cover the `definition/0` metadata and the `handler/3` logic.
- **Verification**: Run `mix test` before submitting any change.

### Example Test Pattern

```elixir
defmodule FusionKit.ExampleTest do
  use ExUnit.Case, async: true

  defmodule MyNode do
    use FusionKit.Node
    definition do: %{name: "my_node", title: "My Node", inputs: [:exec], outputs: [:ok]}
    @impl true
    def handler(_, context, _), do: {:ok, context, :ok}
  end

  test "verifies node definition" do
    assert MyNode.definition().name == "my_node"
  end

  test "verifies handler execution" do
    assert {:ok, %{state: 1}, :ok} == MyNode.handler(%{}, %{state: 1}, nil)
  end
end
```

---

## 🚀 Common Snippets

### Creating a New Node
```elixir
defmodule MyIntegration.Nodes.GreetingNode do
  use FusionKit.Node

  definition do
    %{
      name: "greeting",
      title: "Send Greeting",
      category: :communication,
      icon: "hero-chat-bubble-bottom-center-text",
      inputs: [:exec],
      outputs: [:success]
    }
  end

  @impl true
  def handler(config, context, _input) do
    # config: UI field values
    # context: Global flow variables
    {:ok, context, :success}
  end
end
```

### Registering in a Manifest
```elixir
defmodule MyIntegration.Manifest do
  use FusionKit.Manifest

  manifest do
    nodes [
      MyIntegration.Nodes.GreetingNode
    ]
  end
end
```

---

*Found an issue with this guide? Update it!*

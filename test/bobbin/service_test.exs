defmodule Bobbin.ServiceTest do
  use ExUnit.Case, async: false

  alias Bobbin.Service

  defmodule Host do
    @behaviour Bobbin.Host

    @impl true
    def fetch(context, path), do: get_in(context, String.split(path, "."))

    @impl true
    def render(template, context) when is_binary(template) do
      Regex.replace(~r/\{\{(.*?)\}\}/, template, fn _match, path ->
        to_string(fetch(context, String.trim(path)))
      end)
    end

    def render(_template, _context), do: ""

    @impl true
    def json(template, context, _check), do: JSON.decode(render(template, context))

    @impl true
    def credential(1, "main", "acme", opts), do: {:ok, %{"key" => "k", "opts" => opts}}
    def credential(_workspace, name, _kind, _opts), do: {:error, "No credential #{name}"}
  end

  setup do
    previous = Application.get_env(:bobbin, :host)
    Application.put_env(:bobbin, :host, Host)
    on_exit(fn -> Application.put_env(:bobbin, :host, previous) end)
  end

  test "a definition takes the credential first and answers through success and error" do
    service = %{title: "Acme", category: :acme, credential: "acme", icon: "hero-cube"}
    definition = Service.definition(service, "Get Item", "Reads.", [%{name: :id}])

    assert definition.name == "Acme: Get Item"
    assert definition.outputs == ["success", "error"]
    assert [%{type: :credential, kind: "acme"}, %{name: :id}] = definition.ui_fields
  end

  test "run calls the function with the credential the node picked" do
    context = %{
      "workspace_id" => 1,
      "credential" => "main",
      "id" => "{{result.id}}",
      "result" => %{"id" => 7}
    }

    assert {:ok, %{"result" => %{"key" => "k", "id" => "7"}}, "success"} =
             Service.run(context, "acme", fn credential ->
               {:ok, %{"key" => credential["key"], "id" => Service.field(context, "id")}}
             end)

    assert {:ok, %{"result" => %{"error" => "boom"}}, "error"} =
             Service.run(context, "acme", fn _credential -> {:error, "boom"} end)

    assert {:ok, %{"result" => %{"error" => "No credential other"}}, "error"} =
             Service.run(%{context | "credential" => "other"}, "acme", fn _ -> {:ok, 1} end)
  end

  test "credential passes refresh on to the host" do
    context = %{"workspace_id" => 1, "credential" => "main"}

    assert {:ok, %{"opts" => [refresh: true]}} =
             Service.credential(context, "acme", refresh: true)
  end

  test "json reads a placeholder as the value it points at" do
    context = %{"rows" => "{{result}}", "result" => [%{"a" => 1}], "text" => ~s({"b": 2})}

    assert Service.json(context, "rows") == {:ok, [%{"a" => 1}]}
    assert Service.json(context, "text") == {:ok, %{"b" => 2}}
  end

  test "to_value makes what a driver returned fit in JSON" do
    assert Service.to_value(%{"at" => ~D[2026-11-22], "kind" => :open, "t" => {1, 2}}) ==
             %{"at" => "2026-11-22", "kind" => "open", "t" => "{1, 2}"}

    assert Service.to_value(<<255, 0>>) == %{"content" => "/wA=", "encoding" => "base64"}
  end
end

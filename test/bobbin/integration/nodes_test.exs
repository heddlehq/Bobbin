defmodule Bobbin.Integration.NodesTest do
  use ExUnit.Case, async: false

  defmodule Acme do
    use Bobbin.Integration.Nodes, manifest: "../../fixtures/acme.yaml"
  end

  setup do
    Application.put_env(:bobbin, :host, Bobbin.TestHost)
    Application.put_env(:bobbin, :req_plug, {Req.Test, __MODULE__})
    Application.put_env(:bobbin, :test_credentials, %{"main" => %{"api_key" => "k"}})

    on_exit(fn ->
      for key <- [:host, :req_plug, :test_credentials], do: Application.delete_env(:bobbin, key)
    end)
  end

  test "makes a module for each trigger and action" do
    assert Acme.manifest().id == "acme"

    assert Acme.nodes() == [
             Acme.Acme.NewTicket,
             Acme.Acme.CreateTicket,
             Acme.Acme.ListTickets,
             Acme.Acme.GetTicket
           ]

    assert %{name: "Acme: Create Ticket", outputs: ["success", "error"]} =
             Acme.Acme.CreateTicket.definition()

    assert %{name: "Acme: New Ticket", inputs: [], poll: %{every: 10}} =
             Acme.Acme.NewTicket.definition()
  end

  test "an action runs with the credential the node picked and a field from the last step" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["k"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body)["title"] == "From 7"
      Req.Test.json(conn, %{"ok" => true, "ticket" => %{"id" => 1, "url" => "u"}})
    end)

    context = %{"credential" => "main", "title" => "From {{result.id}}", "result" => %{"id" => 7}}

    assert {:ok, %{"result" => %{"id" => 1, "url" => "u"}}, "success"} =
             Acme.Acme.CreateTicket.handler(context, nil)

    assert {:ok, %{"result" => %{"error" => "There is no acme credential called nope."}}, "error"} =
             Acme.Acme.CreateTicket.handler(%{context | "credential" => "nope"}, nil)
  end

  test "a trigger passes on its item" do
    assert {:ok, %{"result" => %{"n" => 1}}, :exec} =
             Acme.Acme.NewTicket.handler(%{"item" => %{"n" => 1}}, nil)
  end
end

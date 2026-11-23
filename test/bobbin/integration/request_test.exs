defmodule Bobbin.Integration.RequestTest do
  use ExUnit.Case, async: true

  alias Bobbin.Integration
  alias Bobbin.Integration.Request

  setup do
    %{integration: Integration.load!("test/fixtures/acme.yaml")}
  end

  defp run(integration, action, fields, plug) do
    Request.run(integration, action, fields, %{"api_key" => "k"}, plug: plug)
  end

  test "sends the fields, leaves out the empty ones, and shapes the output", %{integration: i} do
    plug = fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/tickets"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["k"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body) == %{"title" => "Fire", "priority" => "low"}

      Req.Test.json(conn, %{"ok" => true, "ticket" => %{"id" => 7, "url" => "u", "secret" => 1}})
    end

    assert {:ok, %{"id" => 7, "url" => "u"}} =
             run(i, "Create Ticket", %{"title" => " Fire ", "assignee" => ""}, plug)
  end

  test "an answer that says it failed is an error", %{integration: i} do
    plug = &Req.Test.json(&1, %{"ok" => false, "error" => "title_missing"})

    assert {:error, "Acme refused it: title_missing"} = run(i, "Create Ticket", %{}, plug)
  end

  test "a status that isn't 2xx is an error", %{integration: i} do
    plug = &Plug.Conn.send_resp(&1, 503, "down")

    assert {:error, "Acme answered 503"} = run(i, "Create Ticket", %{}, plug)
  end

  test "follows the cursor through every page", %{integration: i} do
    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["limit"] == "2"
      assert conn.query_params["status"] == "open"
      assert conn.query_params["tag"] == "urgent"

      case conn.query_params["cursor"] do
        nil ->
          Req.Test.json(conn, %{
            "ok" => true,
            "tickets" => [%{"id" => 1, "x" => 0}, %{"id" => 2}],
            "meta" => %{"next" => "c2"}
          })

        "c2" ->
          Req.Test.json(conn, %{
            "ok" => true,
            "tickets" => [%{"id" => 3}],
            "meta" => %{"next" => ""}
          })
      end
    end

    assert {:ok, [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]} =
             run(i, "List Tickets", %{"tag" => "#urgent"}, plug)
  end

  test "builds a value from templates, and numbers fall back to their default", %{integration: i} do
    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/v1/tickets/42"
      assert conn.query_params["limit"] == "20"
      Req.Test.json(conn, %{"ok" => true})
    end

    assert {:ok, %{"id" => "42", "label" => "Ticket 42"}} =
             run(i, "Get Ticket", %{"id" => "42", "limit" => "many"}, plug)
  end

  test "an unknown action is an error", %{integration: i} do
    assert {:error, "Acme has no action called Nope."} = run(i, "Nope", %{}, & &1)
  end

  test "a value in the path stays one segment" do
    vars = %{"fields" => %{"project" => "group/app", "q" => "a?b#c d"}}

    assert Request.render_path("projects/{{fields.project}}/x/{{fields.q}}", vars) ==
             "projects/group%2Fapp/x/a%3Fb%23c%20d"
  end

  test "a value marked path keeps its slashes, but not dot segments" do
    vars = %{"fields" => %{"repo" => "/owner/my app/../x/"}}

    assert Request.render_path("repos/{{fields.repo | path}}/issues", vars) ==
             "repos/owner/my%20app/x/issues"
  end

  test "renders templates, keeping the type of a single placeholder" do
    vars = %{"fields" => %{"n" => 3, "s" => "a"}, "credential" => %{}}

    assert Request.render("{{fields.n}}", vars) == 3
    assert Request.render("n={{ fields.n }}, s={{fields.s}}", vars) == "n=3, s=a"
    assert Request.render(%{"a" => ["{{fields.s}}"]}, vars) == %{"a" => ["a"]}
  end

  describe "poll/5" do
    test "returns each item with its id, leaving out items without one", %{integration: i} do
      plug = fn conn ->
        assert conn.query_string == "status=open"

        Req.Test.json(conn, %{
          "ok" => true,
          "tickets" => [
            %{"ticket" => %{"number" => 1}},
            %{"ticket" => %{"number" => "b"}},
            %{"title" => "no id"}
          ]
        })
      end

      assert {:ok, [{"1", %{"ticket" => %{"number" => 1}}}, {"b", _second}]} =
               Request.poll(i, "New Ticket", %{}, %{"api_key" => "k"}, plug: plug)
    end

    test "an output that isn't a list is an error", %{integration: i} do
      plug = &Req.Test.json(&1, %{"ok" => true, "tickets" => %{"one" => 1}})

      assert {:error, "New Ticket must return a list, see output.path."} =
               Request.poll(i, "New Ticket", %{}, %{}, plug: plug)
    end

    test "an unknown trigger is an error", %{integration: i} do
      assert {:error, "Acme has no trigger called Nope."} = Request.poll(i, "Nope", %{}, %{})
    end
  end
end

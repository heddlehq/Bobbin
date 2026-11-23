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

  test "a map in the query goes as JSON, a list as a,b, or repeated with []" do
    yaml = """
    id: acme
    name: Acme
    version: 1.0.0
    base_url: https://acme.test/
    actions:
      - name: Find
        fields:
          - {name: filters, label: Filters, type: json}
          - {name: tags, label: Tags, type: multiselect, options: [{label: A, value: a}, {label: B, value: b}]}
        request: {method: GET, path: things, query: {filters: "{{fields.filters}}", tags: "{{fields.tags}}", "ids[]": "{{fields.tags}}"}}
    """

    {:ok, acme} = Bobbin.Integration.parse(yaml)

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["filters"] == ~s({"type":"equal"})
      assert conn.query_params["tags"] == "a,b"
      assert conn.query_string =~ "ids%5B%5D=a&ids%5B%5D=b"
      Req.Test.json(conn, %{})
    end

    fields = %{"filters" => ~s({"type": "equal"}), "tags" => ["a", "b"]}
    assert {:ok, _} = Request.run(acme, "Find", fields, %{}, plug: plug)
  end

  test "_merge spreads a map into the one that holds it" do
    vars = %{"fields" => %{"custom" => %{"customfield_1" => "x", "summary" => "B"}, "s" => "A"}}
    body = %{"fields" => %{"summary" => "{{fields.s}}", "_merge" => "{{fields.custom}}"}}

    assert Request.render(body, vars) == %{
             "fields" => %{"summary" => "B", "customfield_1" => "x"}
           }

    assert Request.render(%{"a" => 1, "_merge" => "{{fields.none}}"}, vars) == %{"a" => 1}
  end

  test "error_path: a GraphQL answer with errors is an error, even at 200" do
    yaml = """
    id: lin
    name: Lin
    version: 1.0.0
    base_url: https://lin.test/
    errors: {error_path: errors, message_path: errors.0.message}
    actions:
      - name: Query
        request: {method: POST, path: graphql, body: {query: "{ viewer { id } }"}}
    """

    {:ok, lin} = Bobbin.Integration.parse(yaml)

    failing = fn conn -> Req.Test.json(conn, %{"errors" => [%{"message" => "Bad query"}]}) end

    working = fn conn ->
      Req.Test.json(conn, %{"data" => %{"viewer" => %{"id" => "u1"}}, "errors" => []})
    end

    assert {:error, "Lin refused it: Bad query"} =
             Request.run(lin, "Query", %{}, %{}, plug: failing)

    assert {:ok, %{"data" => _}} = Request.run(lin, "Query", %{}, %{}, plug: working)
  end

  test "an option written as a number goes as a number" do
    yaml = """
    id: acme
    name: Acme
    version: 1.0.0
    base_url: https://acme.test/
    actions:
      - name: Make
        fields:
          - {name: status, label: Status, type: select, options: [{label: Open, value: 2}, {label: Closed, value: 5}]}
          - {name: kinds, label: Kinds, type: multiselect, options: [{label: A, value: 1}, {label: B, value: b}]}
        request: {method: POST, path: things, body: {status: "{{fields.status}}", kinds: "{{fields.kinds}}"}}
    """

    {:ok, acme} = Bobbin.Integration.parse(yaml)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body) == %{"status" => 5, "kinds" => [1, "b"]}
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} =
             Request.run(acme, "Make", %{"status" => "5", "kinds" => "1, b"}, %{}, plug: plug)
  end

  test "the integration's headers go in every request, under the request's own" do
    yaml = """
    id: acme
    name: Acme
    version: 1.0.0
    base_url: https://acme.test/
    headers: {Acme-Version: "2.0", Accept: application/json}
    actions:
      - name: Ping
        request: {method: GET, path: ping, headers: {Accept: text/plain}}
    """

    {:ok, acme} = Bobbin.Integration.parse(yaml)

    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "acme-version") == ["2.0"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["text/plain"]
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = Request.run(acme, "Ping", %{}, %{}, plug: plug)
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

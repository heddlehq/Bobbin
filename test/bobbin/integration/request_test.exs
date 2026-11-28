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

  test "a space in the query goes as %20, and a plus as %2B" do
    yaml = """
    id: acme
    name: Acme
    version: 1.0.0
    base_url: https://acme.test/
    actions:
      - name: Find
        fields:
          - {name: q, label: Query}
        request: {method: GET, path: things, query: {"$filter": "Name eq '{{fields.q}}'", "$orderby": Date desc}}
    """

    {:ok, acme} = Bobbin.Integration.parse(yaml)

    plug = fn conn ->
      assert conn.query_string == "%24filter=Name%20eq%20%27a%2Bb%27&%24orderby=Date%20desc"
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["$filter"] == "Name eq 'a+b'"
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = Request.run(acme, "Find", %{"q" => "a+b"}, %{}, plug: plug)
  end

  test "_if leaves a map out when its value is empty, so fixed keys don't go alone" do
    due = %{"dateTime" => "{{fields.due}}", "timeZone" => "UTC", "_if" => "{{fields.due}}"}
    body = %{"title" => "T", "dueDateTime" => due}

    assert Request.render(body, %{"fields" => %{"due" => "2026-12-01"}}) == %{
             "title" => "T",
             "dueDateTime" => %{"dateTime" => "2026-12-01", "timeZone" => "UTC"}
           }

    assert Request.render(body, %{"fields" => %{}}) == %{"title" => "T", "dueDateTime" => nil}
    assert Request.render(body, %{"fields" => %{"due" => false}})["dueDateTime"] == nil
    assert Request.render([due], %{"fields" => %{}}) == []
  end

  test "_each makes a map of each value of a list, or of a text with commas" do
    to = %{"_each" => "{{fields.to}}", "emailAddress" => %{"address" => "{{item}}"}}
    body = %{"toRecipients" => to}

    assert Request.render(body, %{"fields" => %{"to" => "a@x.test, b@y.test"}}) == %{
             "toRecipients" => [
               %{"emailAddress" => %{"address" => "a@x.test"}},
               %{"emailAddress" => %{"address" => "b@y.test"}}
             ]
           }

    assert Request.render(body, %{"fields" => %{"to" => ["c@z.test"]}}) == %{
             "toRecipients" => [%{"emailAddress" => %{"address" => "c@z.test"}}]
           }

    assert Request.render(body, %{"fields" => %{}}) == %{"toRecipients" => nil}

    assert Request.render(%{"ids" => %{"_each" => "{{fields.ids}}", "id" => "{{item}}"}}, %{
             "fields" => %{"ids" => [1, 2]}
           }) ==
             %{"ids" => [%{"id" => 1}, %{"id" => 2}]}
  end

  test "_each with only _value makes a list of values" do
    phones = %{"_each" => "{{fields.phones}}", "_value" => "+55 {{item}}"}

    assert Request.render(%{"p" => phones}, %{"fields" => %{"phones" => "1, 2"}}) ==
             %{"p" => ["+55 1", "+55 2"]}
  end

  test "a {} written in the manifest is sent, while one left empty by its fields isn't" do
    yaml = """
    id: drive
    name: Drive
    version: 1.0.0
    base_url: https://drive.test/
    actions:
      - name: Create Folder
        fields: [{name: name, label: Name}, {name: color, label: Color}]
        request:
          method: POST
          path: children
          body: {name: "{{fields.name}}", folder: {}, style: {color: "{{fields.color}}"}, tags: [{}]}
    """

    {:ok, drive} = Bobbin.Integration.parse(yaml)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body) == %{"name" => "A", "folder" => %{}, "tags" => [%{}]}
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = Request.run(drive, "Create Folder", %{"name" => "A"}, %{}, plug: plug)
  end

  test "an empty field in a list is left out, and so is a list left empty" do
    yaml = """
    id: drive
    name: Drive
    version: 1.0.0
    base_url: https://drive.test/
    actions:
      - name: Copy
        fields: [{name: folder, label: Folder}, {name: tag, label: Tag}]
        request:
          method: POST
          path: copy
          body: {parents: ["{{fields.folder}}"], tags: [a, "{{fields.tag}}"], keep: [], notes: [{value: "{{fields.tag}}", _if: "{{fields.tag}}"}]}
    """

    {:ok, drive} = Bobbin.Integration.parse(yaml)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:body, JSON.decode!(body)})
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = Request.run(drive, "Copy", %{}, %{}, plug: plug)
    assert_received {:body, %{"tags" => ["a"], "keep" => []} = body}
    refute Map.has_key?(body, "parents")
    refute Map.has_key?(body, "notes")

    assert {:ok, _} = Request.run(drive, "Copy", %{"folder" => "F"}, %{}, plug: plug)
    assert_received {:body, %{"parents" => ["F"]}}
  end

  test "| keep sends a value even when empty, as Dropbox names its root \"\"" do
    yaml = """
    id: box
    name: Box
    version: 1.0.0
    base_url: https://api.test/
    actions:
      - name: List
        fields: [{name: folder, label: Folder}]
        request:
          method: POST
          path: list
          query: {q: "{{fields.folder | keep}}"}
          body: {path: "{{fields.folder | keep}}", recursive: false}
    """

    {:ok, box} = Bobbin.Integration.parse(yaml)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:sent, conn.query_string, JSON.decode!(body)})
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = Request.run(box, "List", %{}, %{}, plug: plug)
    assert_received {:sent, "q=", %{"path" => "", "recursive" => false}}

    assert {:ok, _} = Request.run(box, "List", %{"folder" => "/a"}, %{}, plug: plug)
    assert_received {:sent, "q=%2Fa", %{"path" => "/a"}}
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

  test "time placeholders give now and the moments before it, in UTC" do
    yaml = """
    id: cal
    name: Cal
    version: 1.0.0
    base_url: https://api.test/
    actions:
      - name: Changed
        request: {method: GET, path: events, query: {updatedMin: "{{time.day_ago}}", until: "{{time.now}}"}}
    """

    {:ok, cal} = Bobbin.Integration.parse(yaml)

    plug = fn conn ->
      send(self(), {:query, Plug.Conn.fetch_query_params(conn).query_params})
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = Request.run(cal, "Changed", %{}, %{}, plug: plug)
    assert_received {:query, %{"updatedMin" => min, "until" => now}}
    {:ok, min, 0} = DateTime.from_iso8601(min)
    {:ok, now, 0} = DateTime.from_iso8601(now)
    assert DateTime.diff(now, min) == 86_400
    assert abs(DateTime.diff(DateTime.utc_now(), now)) < 5
  end

  test "a form sends a list once per value, and a map as JSON, like Mailgun's o:tag" do
    yaml = """
    id: gun
    name: Gun
    version: 1.0.0
    base_url: https://api.test/
    actions:
      - name: Send
        fields:
          - {name: tags, label: Tags}
          - {name: vars, label: Variables, type: json}
        request:
          method: POST
          path: messages
          body_type: form
          body: {to: a@b.c, "o:tag": {_each: "{{fields.tags}}", _value: "{{item}}"}, "t:variables": "{{fields.vars}}"}
    """

    {:ok, gun} = Bobbin.Integration.parse(yaml)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:form, body})
      Req.Test.json(conn, %{})
    end

    fields = %{"tags" => "news, promo", "vars" => %{"name" => "Ana"}}
    assert {:ok, _} = Request.run(gun, "Send", fields, %{}, plug: plug)

    assert_received {:form, body}

    assert body |> String.split("&") |> Enum.sort() ==
             Enum.sort(
               ~w(o%3Atag=news o%3Atag=promo t%3Avariables=%7B%22name%22%3A%22Ana%22%7D to=a%40b.c)
             )
  end

  test "a nested form writes maps and lists with brackets, like Stripe's metadata[k]" do
    yaml = """
    id: stripe
    name: Stripe
    version: 1.0.0
    base_url: https://api.test/
    actions:
      - name: Create
        fields:
          - {name: email, label: Email}
          - {name: metadata, label: Metadata, type: json}
          - {name: price, label: Price}
          - {name: expand, label: Expand}
          - {name: empty, label: Empty}
        request:
          method: POST
          path: checkout
          body_type: form_nested
          body:
            customer_email: "{{fields.email}}"
            metadata: "{{fields.metadata}}"
            line_items: [{price: "{{fields.price}}", quantity: 1}]
            expand: {_each: "{{fields.expand}}", _value: "{{item}}"}
            shipping: {name: "{{fields.empty}}"}
            livemode: false
    """

    {:ok, stripe} = Bobbin.Integration.parse(yaml)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:form, body})
      Req.Test.json(conn, %{})
    end

    fields = %{
      "email" => "ana@b.c",
      "metadata" => %{"plan" => "pro", "seats" => 3},
      "price" => "price_1",
      "expand" => "customer, invoice"
    }

    assert {:ok, _} = Request.run(stripe, "Create", fields, %{}, plug: plug)

    assert_received {:form, body}

    assert body |> URI.decode_www_form() |> String.split("&") |> Enum.sort() ==
             Enum.sort([
               "customer_email=ana@b.c",
               "metadata[plan]=pro",
               "metadata[seats]=3",
               "line_items[0][price]=price_1",
               "line_items[0][quantity]=1",
               "expand[0]=customer",
               "expand[1]=invoice",
               "livemode=false"
             ])
  end

  test "a header written as a map goes as JSON, in ASCII, like Dropbox's Dropbox-API-Arg" do
    yaml = """
    id: box
    name: Box
    version: 1.0.0
    base_url: https://content.test/
    actions:
      - name: Download
        fields: [{name: path, label: Path}, {name: rev, label: Rev}]
        request:
          method: POST
          path: download
          headers: {Dropbox-API-Arg: {path: "{{fields.path}}", rev: "{{fields.rev}}"}}
    """

    {:ok, box} = Bobbin.Integration.parse(yaml)

    plug = fn conn ->
      send(self(), {:arg, Plug.Conn.get_req_header(conn, "dropbox-api-arg")})
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} =
             Request.run(box, "Download", %{"path" => "/Relatório \"1\" 📄.pdf"}, %{}, plug: plug)

    assert_received {:arg, [arg]}
    assert arg == ~S({"path":"/Relat\u00f3rio \"1\" \ud83d\udcc4.pdf"})
    assert JSON.decode!(arg) == %{"path" => "/Relatório \"1\" 📄.pdf"}
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

    test "an empty answer, like a 204, means nothing new", %{integration: i} do
      plug = &Plug.Conn.send_resp(&1, 204, "")

      assert {:ok, []} = Request.poll(i, "New Ticket", %{}, %{}, plug: plug)
    end

    test "an unknown trigger is an error", %{integration: i} do
      assert {:error, "Acme has no trigger called Nope."} = Request.poll(i, "Nope", %{}, %{})
    end
  end
end

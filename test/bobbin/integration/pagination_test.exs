defmodule Bobbin.Integration.PaginationTest do
  use ExUnit.Case, async: true

  alias Bobbin.Integration
  alias Bobbin.Integration.Request

  @manifest """
  id: desk
  name: Desk
  version: 1.0.0
  base_url: https://desk.test/api/
  credential:
    auth: {type: bearer, token: "{{credential.token}}"}
  actions:
    - name: List Tickets
      request: {method: GET, path: tickets}
      pagination:
        type: page
        items_path: results
        limit_param: per_page
        page_size: 2
    - name: List Zero Based
      request: {method: GET, path: tickets}
      pagination: {type: page, items_path: results, page_param: p, first_page: 0, page_size: 2}
    - name: List Linked
      request: {method: GET, path: tickets}
      pagination: {type: link, limit_param: per_page, page_size: 2}
    - name: List Body Linked
      request: {method: GET, path: tickets}
      pagination: {type: link, items_path: tickets, next_path: next_page_uri}
  """

  setup do
    {:ok, integration} = Integration.parse(@manifest)
    %{integration: integration}
  end

  # Pages of two, three items in all.
  defp desk(param, first) do
    fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:page, conn.query_params[param], conn.query_params["per_page"]})
      page = String.to_integer(conn.query_params[param] || to_string(first)) - first
      items = Enum.slice([%{"id" => 1}, %{"id" => 2}, %{"id" => 3}], page * 2, 2)
      Req.Test.json(conn, %{"results" => items})
    end
  end

  test "asks for each page by its number until one comes short", %{integration: i} do
    assert {:ok, [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]} =
             Request.run(i, "List Tickets", %{}, %{"token" => "t"}, plug: desk("page", 1))

    assert_received {:page, nil, "2"}
    assert_received {:page, "2", "2"}
    refute_received {:page, _, _}
  end

  test "a service that counts pages from 0", %{integration: i} do
    assert {:ok, [_, _, _]} =
             Request.run(i, "List Zero Based", %{}, %{"token" => "t"}, plug: desk("p", 0))

    assert_received {:page, nil, nil}
    assert_received {:page, "1", nil}
  end

  test "follows the Link header, taking a list answer whole", %{integration: i} do
    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:page, conn.query_params["page"]})

      case conn.query_params["page"] do
        nil ->
          conn
          |> Plug.Conn.put_resp_header(
            "link",
            ~s(<https://desk.test/api/tickets?page=2&per_page=2>; rel="next")
          )
          |> Req.Test.json([%{"id" => 1}, %{"id" => 2}])

        "2" ->
          Req.Test.json(conn, [%{"id" => 3}])
      end
    end

    assert {:ok, [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]} =
             Request.run(i, "List Linked", %{}, %{"token" => "t"}, plug: plug)

    assert_received {:page, nil}
    assert_received {:page, "2"}
  end

  test "a link in the body may be relative", %{integration: i} do
    plug = fn conn ->
      send(self(), {:path, conn.request_path, conn.query_string})

      case conn.query_string do
        "" -> Req.Test.json(conn, %{"tickets" => [1], "next_page_uri" => "/api/tickets?Page=1"})
        "Page=1" -> Req.Test.json(conn, %{"tickets" => [2], "next_page_uri" => nil})
      end
    end

    assert {:ok, [1, 2]} = Request.run(i, "List Body Linked", %{}, %{"token" => "t"}, plug: plug)
    assert_received {:path, "/api/tickets", "Page=1"}
  end

  test "a link to another host isn't followed, so the token stays home", %{integration: i} do
    plug = fn conn ->
      send(self(), {:host, conn.host})
      Req.Test.json(conn, %{"tickets" => [1], "next_page_uri" => "https://evil.test/steal"})
    end

    assert {:ok, [1]} = Request.run(i, "List Body Linked", %{}, %{"token" => "t"}, plug: plug)
    assert_received {:host, "desk.test"}
    refute_received {:host, "evil.test"}
  end
end

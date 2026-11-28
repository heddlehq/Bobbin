defmodule Bobbin.Integration.OptionsTest do
  use ExUnit.Case, async: true

  alias Bobbin.Integration
  alias Bobbin.Integration.Request

  @manifest """
  id: sheets
  name: Sheets
  version: 1.0.0
  base_url: https://api.sheets.test/
  credential:
    auth: {type: bearer, token: "{{credential.token}}"}
  actions:
    - name: Add Row
      fields:
        - name: spreadsheet
          label: Spreadsheet
          type: select
          required: true
          options_from:
            request: {method: GET, path: files, query: {kind: sheet}}
            path: files
            label: title
            value: id
            pagination: {type: cursor, items_path: files, next_path: next}
        - name: tab
          label: Tab
          type: multiselect
          options_from:
            request: {method: GET, path: "files/{{fields.spreadsheet}}/tabs"}
            label: meta.name
            value: meta.index
      request: {method: POST, path: rows}
  """

  setup do
    {:ok, integration} = Integration.parse(@manifest)
    %{integration: integration}
  end

  test "lists the options from the service, across pages", %{integration: i} do
    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["kind"] == "sheet"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t"]

      case conn.query_params["cursor"] do
        nil ->
          Req.Test.json(conn, %{"files" => [%{"id" => "a", "title" => "Budget"}], "next" => "2"})

        "2" ->
          Req.Test.json(conn, %{"files" => [%{"id" => "b", "title" => "Sales"}]})
      end
    end

    assert {:ok, [%{"label" => "Budget", "value" => "a"}, %{"label" => "Sales", "value" => "b"}]} =
             Request.options(i, "Add Row", "spreadsheet", %{}, %{"token" => "t"}, plug: plug)
  end

  test "an option may depend on another field, and values become text", %{integration: i} do
    plug = fn conn ->
      assert conn.request_path == "/files/a/tabs"
      Req.Test.json(conn, [%{"meta" => %{"name" => "Q1", "index" => 0}}, %{"other" => 1}])
    end

    assert {:ok, [%{"label" => "Q1", "value" => "0"}]} =
             Request.options(i, "Add Row", "tab", %{"spreadsheet" => "a"}, %{"token" => "t"},
               plug: plug
             )
  end

  test "a field without options_from has none to fetch", %{integration: i} do
    assert {:error, "Add Row has no options to fetch for nope."} =
             Request.options(i, "Add Row", "nope", %{}, %{})
  end

  test "a select with options_from needs no options, but options_from needs a request" do
    yaml =
      String.replace(
        @manifest,
        "request: {method: GET, path: files, query: {kind: sheet}}",
        "path_only: 1"
      )

    assert {:error, errors} = Integration.parse(yaml)
    assert "actions[0].fields[0].options_from needs a request with a method and a path" in errors
  end
end

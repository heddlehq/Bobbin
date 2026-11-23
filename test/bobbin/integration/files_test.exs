defmodule Bobbin.Integration.FilesTest do
  use ExUnit.Case, async: true

  alias Bobbin.Integration
  alias Bobbin.Integration.Request

  @manifest """
  id: drive
  name: Drive
  version: 1.0.0
  base_url: https://api.drive.test/
  actions:
    - name: Upload
      fields:
        - {name: document, label: File, type: file, required: true}
        - {name: title, label: Title}
      request:
        method: POST
        path: upload
        body_type: multipart
        body:
          file: "{{fields.document}}"
          title: "{{fields.title}}"
          meta: {tags: [a]}

    - name: Put
      fields:
        - {name: document, label: File, type: file}
      request:
        method: PUT
        path: raw
        body_type: binary
        body: "{{fields.document}}"

    - name: Upload Related
      fields:
        - {name: document, label: File, type: file, required: true}
        - {name: title, label: Title}
      request:
        method: POST
        path: upload/files
        query: {uploadType: multipart}
        body_type: related
        body:
          metadata: {name: "{{fields.title}}"}
          media: "{{fields.document}}"

    - name: Attach
      fields:
        - {name: document, label: File, type: file, required: true}
        - {name: note, label: Note}
      request:
        method: POST
        path: attachments
        body:
          contentBytes: "{{fields.document | base64}}"
          noteBytes: "{{fields.note | base64}}"
          name: "{{fields.document}}"

    - name: Put Elsewhere
      fields:
        - {name: document, label: File, type: file}
      request:
        method: POST
        base_url: https://content.drive.test/2/
        path: files/upload
        body_type: binary
        body: "{{fields.document}}"

    - name: Download
      fields:
        - {name: id, label: ID}
        - {name: name, label: Name}
      request: {method: GET, path: "files/{{fields.id}}"}
      output:
        file:
          name: "{{fields.name}}"
  """

  setup do
    {:ok, integration} = Integration.parse(@manifest)
    {:ok, ref} = Bobbin.Files.store("hello", %{"name" => "a.txt", "mime" => "text/plain"})
    %{integration: integration, ref: ref}
  end

  test "a stored file is a reference to its content", %{ref: ref} do
    assert %{"id" => _, "name" => "a.txt", "mime" => "text/plain", "size" => 5} = ref
    assert {:ok, content} = Bobbin.Files.read(ref)
    assert content |> Enum.to_list() |> IO.iodata_to_binary() == "hello"
  end

  test "uploads a file in a multipart form", %{integration: i, ref: ref} do
    plug = fn conn ->
      [type] = Plug.Conn.get_req_header(conn, "content-type")
      assert type =~ "multipart/form-data"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ ~s(name="file"; filename="a.txt")
      assert body =~ "content-type: text/plain"
      assert body =~ "hello"
      assert body =~ ~s(name="title")
      assert body =~ ~s({"tags":["a"]})
      Req.Test.json(conn, %{"id" => "f1"})
    end

    # A file from another node arrives as the "file" of its result, or as JSON text.
    for value <- [%{"file" => ref}, ref, JSON.encode!(%{"file" => ref})] do
      assert {:ok, %{"id" => "f1"}} =
               Request.run(i, "Upload", %{"document" => value, "title" => "T"}, %{}, plug: plug)
    end
  end

  test "uploads a file as the whole body", %{integration: i, ref: ref} do
    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "content-type") == ["text/plain"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == "hello"
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = Request.run(i, "Put", %{"document" => ref}, %{}, plug: plug)
  end

  test "uploads the metadata and the file as multipart/related, as Google wants",
       %{integration: i, ref: ref} do
    plug = fn conn ->
      [type] = Plug.Conn.get_req_header(conn, "content-type")
      assert [_, boundary] = Regex.run(~r{\Amultipart/related; boundary=(\S+)\z}, type)
      assert conn.query_string == "uploadType=multipart"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert body ==
               "--#{boundary}\r\ncontent-type: application/json; charset=UTF-8\r\n\r\n" <>
                 ~s({"name":"T"}) <>
                 "\r\n--#{boundary}\r\ncontent-type: text/plain\r\n\r\nhello\r\n--#{boundary}--\r\n"

      Req.Test.json(conn, %{"id" => "f1"})
    end

    assert {:ok, %{"id" => "f1"}} =
             Request.run(i, "Upload Related", %{"document" => ref, "title" => "T"}, %{},
               plug: plug
             )
  end

  test "| base64 puts a file, or a text, in a JSON body", %{integration: i, ref: ref} do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "contentBytes" => "aGVsbG8=",
               "noteBytes" => "aGk=",
               "name" => %{"name" => "a.txt"}
             } =
               JSON.decode!(body)

      Req.Test.json(conn, %{})
    end

    assert {:ok, _} =
             Request.run(i, "Attach", %{"document" => ref, "note" => "hi"}, %{}, plug: plug)
  end

  test "an action may go to an address of its own, like a service's upload host",
       %{integration: i, ref: ref} do
    plug = fn conn ->
      send(self(), {:url, conn.host, conn.request_path})
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = Request.run(i, "Put Elsewhere", %{"document" => ref}, %{}, plug: plug)
    assert_received {:url, "content.drive.test", "/2/files/upload"}
  end

  test "keeps what it downloads as a file", %{integration: i} do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/pdf", nil)
      |> Plug.Conn.send_resp(200, "%PDF-1")
    end

    assert {:ok, %{"file" => file}} =
             Request.run(i, "Download", %{"id" => "9", "name" => "report.pdf"}, %{}, plug: plug)

    assert %{"name" => "report.pdf", "mime" => "application/pdf", "size" => 6} = file
    assert {:ok, content} = Bobbin.Files.read(file)
    assert content |> Enum.to_list() |> IO.iodata_to_binary() == "%PDF-1"
  end

  test "the name comes from the answer when the manifest doesn't give one", %{integration: i} do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-disposition", ~s(attachment; filename="x.csv"))
      |> Plug.Conn.send_resp(200, "a,b")
    end

    assert {:ok, %{"file" => %{"name" => "x.csv"}}} =
             Request.run(i, "Download", %{"id" => "9"}, %{}, plug: plug)
  end

  test "a value that isn't a file is an error", %{integration: i} do
    assert {:error, "File must be a file, like the result of a node that downloads one."} =
             Request.run(i, "Upload", %{"document" => "just text"}, %{})
  end
end

defmodule Mix.Tasks.BobbinTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "new writes a manifest that validate accepts", %{tmp_dir: dir} do
    path = Path.join(dir, "acme_crm.yaml")

    Mix.Tasks.Bobbin.New.run(["acme_crm", "--path", path])
    assert {:ok, %{id: "acme_crm"}} = Bobbin.Integration.load(path)

    Mix.Tasks.Bobbin.Validate.run([path])
    assert_received {:mix_shell, :info, ["Wrote " <> _]}
    assert_received {:mix_shell, :info, [ok]}
    assert ok =~ "ok (1 actions)"

    assert_raise Mix.Error, fn -> Mix.Tasks.Bobbin.New.run(["acme_crm", "--path", path]) end
  end

  @tag :tmp_dir
  test "validate fails on an invalid manifest", %{tmp_dir: dir} do
    path = Path.join(dir, "bad.yaml")
    File.write!(path, "id: bad\\n")

    assert_raise Mix.Error, fn -> Mix.Tasks.Bobbin.Validate.run([path]) end
    assert_received {:mix_shell, :error, [message]}
    assert message =~ "name is required"
  end

  @tag :tmp_dir
  test "import drafts a manifest from a YAML spec, that validate accepts", %{tmp_dir: dir} do
    spec = Path.join(dir, "spec.yaml")

    File.write!(spec, """
    openapi: 3.1.0
    info: {title: Acme CRM}
    servers: [{url: "https://api.acme.test"}]
    components:
      securitySchemes:
        token: {type: http, scheme: bearer}
    paths:
      /contacts/{id}:
        get: {operationId: getContact, tags: [contacts], parameters: [{name: id, in: path}]}
      /deals:
        get: {operationId: listDeals, tags: [deals]}
    """)

    path = Path.join(dir, "acme.yaml")
    Mix.Tasks.Bobbin.Import.run([spec, "--id", "acme", "--tag", "contacts", "--path", path])
    assert_received {:mix_shell, :info, ["Wrote " <> wrote]}
    assert wrote =~ "with 1 actions"

    assert {:ok, %{id: "acme", actions: [%{name: "Get Contact"}]}} = Bobbin.Integration.load(path)
    Mix.Tasks.Bobbin.Validate.run([path])

    assert_raise Mix.Error, ~r/already exists/, fn ->
      Mix.Tasks.Bobbin.Import.run([spec, "--path", path])
    end

    File.write!(spec, "swagger: '2.0'")
    assert_raise Mix.Error, ~r/Swagger 2/, fn -> Mix.Tasks.Bobbin.Import.run([spec]) end
  end
end

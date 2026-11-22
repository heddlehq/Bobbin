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
end

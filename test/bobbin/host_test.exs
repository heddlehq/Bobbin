defmodule Bobbin.HostTest do
  use ExUnit.Case, async: false

  alias Bobbin.Host
  alias Bobbin.TestHost

  defmodule OnlyCredentials do
    @behaviour Bobbin.Host

    @impl true
    def credential(_workspace_id, _name, _kind, _opts), do: {:ok, %{}}
  end

  setup do
    previous = Application.get_env(:bobbin, :host)
    Application.put_env(:bobbin, :host, TestHost)
    TestHost.reset()

    on_exit(fn ->
      Application.put_env(:bobbin, :host, previous)
      Application.delete_env(:bobbin, :test_start_runs)
    end)
  end

  describe "runs" do
    test "keeps what it was asked to start, and can cancel it" do
      request = %{workspace_id: 1, node_type: "Acme: Trigger", match: %{"name" => "A"}}

      assert {:ok, [%{"run_id" => id}]} = Host.start_runs(request)
      assert [%{node_type: "Acme: Trigger", run_id: ^id}] = TestHost.runs()

      assert :ok = Host.cancel_run(1, id)
      assert TestHost.runs() == []
      assert {:error, :not_found} = Host.cancel_run(1, id)
    end

    test "a test can answer in its place" do
      Application.put_env(:bobbin, :test_start_runs, fn _request -> {:ok, []} end)

      assert {:ok, []} = Host.start_runs(%{workspace_id: 1, node_type: "Acme: Trigger"})
    end
  end

  test "answers the AI a test sets, and reports usage to the test" do
    assert {:error, "No AI provider" <> _} = Host.ai_connection(%{})

    Application.put_env(:bobbin, :test_ai, %{model: "openai:gpt-4o-mini", options: []})
    assert {:ok, %{model: "openai:gpt-4o-mini"}} = Host.ai_connection(%{}, :text)
    Application.delete_env(:bobbin, :test_ai)

    assert :ok = Host.record_usage(%{input_tokens: 3})
    assert_received {:bobbin_usage, %{input_tokens: 3}}
  end

  test "keeps what resumes a run" do
    assert :ok = Host.resume_run(1, "run-1", "ask/1", %{"reply" => "yes"})
    assert {:ok, %{"reply" => "yes"}} = TestHost.resumed("run-1", "ask/1")
    assert TestHost.resumed("run-1", "ask/2") == nil
  end

  describe "the store" do
    test "keeps a record by workspace and namespace, and counts its versions" do
      assert {:error, :not_found} = Host.store_get(1, "acme", "a")

      assert {:ok, 1} = Host.store_put(1, "acme", "a", %{"n" => 1})
      assert {:ok, 2} = Host.store_put(1, "acme", "a", %{"n" => 2})

      assert {:ok, %{value: %{"n" => 2}, version: 2}} = Host.store_get(1, "acme", "a")
      assert {:error, :not_found} = Host.store_get(2, "acme", "a")
      assert {:error, :not_found} = Host.store_get(1, "other", "a")
    end

    test "a version that isn't the record's is a conflict" do
      assert {:ok, 1} = Host.store_put(1, "acme", "a", 1, version: 0)
      assert {:error, :conflict} = Host.store_put(1, "acme", "a", 2, version: 0)
      assert {:ok, 2} = Host.store_put(1, "acme", "a", 2, version: 1)
      assert {:error, :conflict} = Host.store_delete(1, "acme", "a", version: 1)
      assert :ok = Host.store_delete(1, "acme", "a", version: 2)
      assert {:error, :not_found} = Host.store_get(1, "acme", "a")
    end

    test "lists by prefix, in the order of the keys" do
      for key <- ["b/2", "a/1", "b/1"], do: Host.store_put(1, "acme", key, key)

      assert {:ok, [%{key: "b/1"}, %{key: "b/2"}]} = Host.store_list(1, "acme", "b/")
      assert {:ok, [%{key: "a/1"}]} = Host.store_list(1, "acme", "", limit: 1)
    end
  end

  test "a host without runs or a store says so" do
    Application.put_env(:bobbin, :host, OnlyCredentials)

    assert {:error, "This app can't start runs of other flows" <> _} =
             Host.start_runs(%{workspace_id: 1, node_type: "Acme: Trigger"})

    assert {:error, "This app can't keep data" <> _} = Host.store_get(1, "acme", "a")
    assert :ok = Host.record_usage(%{input_tokens: 1})
  end
end

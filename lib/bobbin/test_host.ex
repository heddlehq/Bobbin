defmodule Bobbin.TestHost do
  @moduledoc """
  A `Bobbin.Host` for an integration's own tests, so they run without Heddle.

  It returns the credentials a test puts in `:bobbin, :test_credentials`, by name:

      Application.put_env(:bobbin, :host, Bobbin.TestHost)
      Application.put_env(:bobbin, :test_credentials, %{"main" => %{"token" => "t"}})

  A credential can be a function of the options too, to try an OAuth renewal:
  `fn opts -> ... end`. Or name a module in `:bobbin, :credentials_client` whose
  `fetch(workspace_id, name, kind)`, and `fetch/4` with options, answers.

  Runs aren't started: `start_runs/1` keeps each request, which `runs/0` lists, and
  answers a `run_id` for it. A function in `:bobbin, :test_start_runs` answers in its
  place, to try what a node does with a flow that ran.

  The store keeps records in memory, and `with_run: true` keeps them at once, since
  no run ends here. `reset/0` empties both, for a test's `setup`.
  """

  @behaviour Bobbin.Host

  @table __MODULE__

  @impl true
  def credential(workspace_id, name, kind, opts) do
    case Application.get_env(:bobbin, :credentials_client) do
      nil -> from_config(name, kind, opts)
      client when opts == [] -> client.fetch(workspace_id, name, kind)
      client -> client.fetch(workspace_id, name, kind, opts)
    end
  end

  defp from_config(name, kind, opts) do
    case Map.get(Application.get_env(:bobbin, :test_credentials, %{}), name) do
      nil -> {:error, "There is no #{kind} credential called #{name}."}
      fun when is_function(fun, 1) -> fun.(opts)
      values -> {:ok, values}
    end
  end

  @impl true
  def start_runs(request) do
    id = "test-run-#{:ets.update_counter(@table, :run_counter, 1, {:run_counter, 0})}"
    :ets.insert(@table, {{:run, id}, request})

    case Application.get_env(:bobbin, :test_start_runs) do
      nil -> {:ok, [%{"run_id" => id}]}
      fun -> fun.(request)
    end
  end

  @impl true
  def cancel_run(_workspace_id, run_id) do
    case :ets.take(@table, {:run, run_id}) do
      [] -> {:error, :not_found}
      [_run] -> :ok
    end
  end

  @doc "The requests `start_runs/1` got and weren't cancelled, oldest first."
  def runs do
    @table
    |> :ets.match({{:run, :"$1"}, :"$2"})
    |> Enum.sort_by(fn [id, _request] ->
      id |> String.split("-") |> List.last() |> String.to_integer()
    end)
    |> Enum.map(fn [id, request] -> Map.put(request, :run_id, id) end)
  end

  @impl true
  def store_get(workspace_id, namespace, key) do
    case :ets.lookup(@table, {:record, workspace_id, namespace, key}) do
      [{_id, value, version}] -> {:ok, %{key: key, value: value, version: version}}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def store_put(workspace_id, namespace, key, value, opts) do
    with {:ok, current} <- check_version(workspace_id, namespace, key, opts) do
      :ets.insert(@table, {{:record, workspace_id, namespace, key}, value, current + 1})
      {:ok, current + 1}
    end
  end

  @impl true
  def store_delete(workspace_id, namespace, key, opts) do
    with {:ok, _current} <- check_version(workspace_id, namespace, key, opts) do
      :ets.delete(@table, {:record, workspace_id, namespace, key})
      :ok
    end
  end

  @impl true
  def store_list(workspace_id, namespace, prefix, opts) do
    records =
      @table
      |> :ets.match({{:record, workspace_id, namespace, :"$1"}, :"$2", :"$3"})
      |> Enum.filter(fn [key, _value, _version] -> String.starts_with?(key, prefix) end)
      |> Enum.sort()
      |> Enum.take(Keyword.get(opts, :limit, 100))
      |> Enum.map(fn [key, value, version] -> %{key: key, value: value, version: version} end)

    {:ok, records}
  end

  @doc "Forgets every run and record."
  def reset, do: :ets.delete_all_objects(@table)

  @doc false
  def create_table, do: :ets.new(@table, [:named_table, :public, :set])

  defp check_version(workspace_id, namespace, key, opts) do
    current =
      case store_get(workspace_id, namespace, key) do
        {:ok, %{version: version}} -> version
        {:error, :not_found} -> 0
      end

    case Keyword.fetch(opts, :version) do
      {:ok, expected} when expected != current -> {:error, :conflict}
      _any -> {:ok, current}
    end
  end
end

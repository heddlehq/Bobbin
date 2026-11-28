defmodule Bobbin.Host do
  @moduledoc """
  What the app that runs the nodes gives them: Heddle keeps the credentials of each
  workspace, starts runs of its flows and keeps what a package stores. Templates are
  filled by `Bobbin.Template`, the same in Heddle and in an integration's tests.

  The host names its module in config:

      config :bobbin, :host, MyApp.BobbinHost

  `Bobbin.Service` calls it, so an integration never depends on the host. Only
  `credential/4` is required: a host that doesn't start runs or store anything leaves
  the rest out, and the functions here answer `{:error, message}` for them.

  `Bobbin.TestHost` does all of it in memory, for an integration's own tests.
  """

  @typedoc """
  What `start_runs/1` takes:

    * `:workspace_id`: the workspace whose flows start, the one of the run asking.
    * `:node_type`: the type of the node the runs begin at, a trigger of the package.
    * `:match`: the controls that node must have, compared as text without the
      spaces around: `%{"name" => "Billing"}` starts only the flows whose trigger is
      called Billing. Empty starts every flow with that trigger.
    * `:data`: what the run gets, as `result` at its first node.
    * `:lane`: runs with the same lane, in a workspace, run one at a time, in the
      order they were asked for. A run waiting (for a call, an approval) holds its lane.
    * `:at`: a `DateTime` the runs start at, not before.
  """
  @type run_request :: %{
          required(:workspace_id) => term(),
          required(:node_type) => String.t(),
          optional(:match) => map(),
          optional(:data) => map(),
          optional(:lane) => String.t(),
          optional(:at) => DateTime.t()
        }

  @typedoc "A run that `start_runs/1` started: `run_id` and the flow it is of."
  @type run :: %{required(String.t()) => term()}

  @typedoc """
  A record a package stores: its `value`, any JSON value, and its `version`, which
  goes up by one at each change.
  """
  @type record :: %{key: String.t(), value: term(), version: pos_integer()}

  @doc """
  The values of the credential called `name` of `kind`, as `workspace_id` sees it.
  `refresh: true` in `opts` renews an OAuth token first.
  """
  @callback credential(
              workspace_id :: term(),
              name :: String.t() | nil,
              kind :: String.t(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, String.t()}

  @doc """
  Starts runs of the published flows that begin at a node of the package, see
  `t:run_request/0`. Starting none, because no flow has that trigger, is `{:ok, []}`.
  """
  @callback start_runs(run_request()) :: {:ok, [run()]} | {:error, String.t()}

  @doc """
  Cancels a run `start_runs/1` started that hasn't begun, like one with `:at` in the
  future. A run that already began goes on.
  """
  @callback cancel_run(workspace_id :: term(), run_id :: String.t()) ::
              :ok | {:error, :not_found | String.t()}

  @doc """
  Resumes the run `run_id` (the `"run_id"` of a node's context) of `workspace_id`,
  paused by `Bobbin.Node.wait_for_call/2` with `key`, with `value` as its `result`. A
  run still running is waited for a moment, so an answer that comes back fast isn't
  lost. Answers `{:error, :not_waiting}` when it waits for something else or ended.
  """
  @callback resume_run(
              workspace_id :: term(),
              run_id :: String.t(),
              key :: String.t(),
              value :: term()
            ) :: :ok | {:error, :not_found | :not_waiting | String.t()}

  @doc """
  The record `key` of `namespace` in `workspace_id`. With `with_run: run_id`, it is
  what that run left, even before it is kept.
  """
  @callback store_get(
              workspace_id :: term(),
              namespace :: String.t(),
              key :: String.t(),
              opts :: keyword()
            ) :: {:ok, record()} | {:error, :not_found}

  @doc """
  Keeps `value` as `key`. Options:

    * `version: n` keeps it only if the record is at version `n`, and `0` only if
      there is none, or answers `{:error, :conflict}`.
    * `with_run: run_id`, with the `"run_id"` of the node's context, keeps it only
      once that run ends well: a run that fails changes nothing. Until then, that run
      reads what it wrote, when it passes `with_run` to `store_get/4` and
      `store_list/4` too.

  Returns the new version.
  """
  @callback store_put(
              workspace_id :: term(),
              namespace :: String.t(),
              key :: String.t(),
              value :: term(),
              opts :: keyword()
            ) :: {:ok, pos_integer()} | {:error, :conflict | String.t()}

  @doc "Removes `key`, with the same options as `store_put/5`."
  @callback store_delete(
              workspace_id :: term(),
              namespace :: String.t(),
              key :: String.t(),
              opts :: keyword()
            ) :: :ok | {:error, :conflict | String.t()}

  @doc """
  The records of `namespace` whose keys begin with `prefix`, by key. Options: `limit`,
  100 by default, and `with_run`, as for `store_get/4`.
  """
  @callback store_list(
              workspace_id :: term(),
              namespace :: String.t(),
              prefix :: String.t(),
              opts :: keyword()
            ) :: {:ok, [record()]}

  @optional_callbacks start_runs: 1,
                      cancel_run: 2,
                      resume_run: 4,
                      store_get: 4,
                      store_put: 5,
                      store_delete: 4,
                      store_list: 4

  @doc false
  def credential(workspace_id, name, kind, opts),
    do: host().credential(workspace_id, name, kind, opts)

  @doc "Starts runs through the host, see `c:start_runs/1`."
  def start_runs(request), do: call(:start_runs, [request])

  @doc "Cancels a run through the host, see `c:cancel_run/2`."
  def cancel_run(workspace_id, run_id), do: call(:cancel_run, [workspace_id, run_id])

  @doc "Resumes a run through the host, see `c:resume_run/4`."
  def resume_run(workspace_id, run_id, key, value),
    do: call(:resume_run, [workspace_id, run_id, key, value])

  @doc "Reads a record through the host, see `c:store_get/4`."
  def store_get(workspace_id, namespace, key, opts \\ []),
    do: call(:store_get, [workspace_id, namespace, key, opts])

  @doc "Keeps a record through the host, see `c:store_put/5`."
  def store_put(workspace_id, namespace, key, value, opts \\ []),
    do: call(:store_put, [workspace_id, namespace, key, value, opts])

  @doc "Removes a record through the host, see `c:store_delete/4`."
  def store_delete(workspace_id, namespace, key, opts \\ []),
    do: call(:store_delete, [workspace_id, namespace, key, opts])

  @doc "Lists records through the host, see `c:store_list/4`."
  def store_list(workspace_id, namespace, prefix \\ "", opts \\ []),
    do: call(:store_list, [workspace_id, namespace, prefix, opts])

  defp call(name, args) do
    host = host()
    Code.ensure_loaded(host)

    if function_exported?(host, name, length(args)) do
      apply(host, name, args)
    else
      {:error, "This app can't #{describe(name)}, which this node needs."}
    end
  end

  defp describe(:start_runs), do: "start runs of other flows"
  defp describe(:cancel_run), do: "cancel runs"
  defp describe(:resume_run), do: "resume runs"
  defp describe(_store), do: "keep data for an integration"

  defp host do
    Application.get_env(:bobbin, :host) ||
      raise "No Bobbin host: set `config :bobbin, :host, MyHost`, see Bobbin.Host."
  end
end

defmodule Bobbin.Files do
  @moduledoc """
  Where the files nodes pass between them are kept. A node that downloads a file
  stores it here and returns a reference, `%{"file" => %{"id", "name", "mime",
  "size"}}`; a node that uploads one reads it back, so files never travel inside a
  run's data.

  The host names its own storage in config, so files go where it keeps them and
  expire with the run:

      config :bobbin, :files, MyApp.Files

  Without one, files go to a folder in the system's temporary directory
  (`Bobbin.Files.Local`), which is what `mix bobbin.run` uses.
  """

  @type ref :: %{required(String.t()) => term()}

  @doc "Keeps `content` (iodata) with its `name` and `mime`, and returns its reference."
  @callback store(content :: iodata(), meta :: %{required(String.t()) => String.t()}) ::
              {:ok, ref()} | {:error, String.t()}

  @doc "The content of the file `ref` points at, as iodata or a stream of binaries."
  @callback read(ref()) :: {:ok, iodata() | Enumerable.t()} | {:error, String.t()}

  @doc "Keeps a file, see the `store/2` callback."
  @spec store(iodata(), map()) :: {:ok, ref()} | {:error, String.t()}
  def store(content, meta), do: impl().store(content, meta)

  @doc "Reads a file back, see the `read/1` callback."
  @spec read(ref()) :: {:ok, iodata() | Enumerable.t()} | {:error, String.t()}
  def read(ref), do: impl().read(ref)

  @doc """
  The reference in `value`, if it is one: a node's result with a `file`, the
  reference itself, or either written as JSON. `:empty` when there is nothing.
  """
  @spec ref(term()) :: {:ok, ref()} | :empty | :error
  def ref(value) when value in [nil, ""], do: :empty
  def ref(%{"file" => file}), do: ref(file)

  def ref(%{"id" => id, "name" => name} = ref) when is_binary(id) and is_binary(name),
    do: {:ok, ref}

  def ref(value) when is_binary(value) do
    with "{" <> _ <- String.trim(value),
         {:ok, decoded} when is_map(decoded) <- JSON.decode(value) do
      ref(decoded)
    else
      _other -> :error
    end
  end

  def ref(_value), do: :error

  defp impl, do: Application.get_env(:bobbin, :files, Bobbin.Files.Local)
end

defmodule Bobbin.Files.Local do
  @moduledoc """
  Keeps files in a folder of the system's temporary directory. For `mix bobbin.run`
  and tests; a host keeps files its own way, see `Bobbin.Files`.
  """

  @behaviour Bobbin.Files

  @impl true
  def store(content, meta) do
    id = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    path = path(id)
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, content) do
      :ok ->
        {:ok,
         %{
           "id" => id,
           "name" => meta["name"] || "file",
           "mime" => meta["mime"] || "application/octet-stream",
           "size" => File.stat!(path).size
         }}

      {:error, reason} ->
        {:error, "Could not keep the file: #{:file.format_error(reason)}"}
    end
  end

  @impl true
  def read(%{"id" => id}) do
    # The id is ours, so it holds only hex: nothing can point outside the folder.
    if Regex.match?(~r/\A[0-9a-f]{32}\z/, id) and File.exists?(path(id)),
      do: {:ok, File.stream!(path(id), 65_536)},
      else: {:error, "The file is gone: it was kept for a run that ended."}
  end

  defp path(id), do: Path.join([System.tmp_dir!(), "bobbin_files", id])
end

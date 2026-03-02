defmodule Pincer.CLI.History do
  @moduledoc """
  Persistent history for `mix pincer.chat`.

  Stores user input lines in a local file to keep CLI context across runs.
  """

  @default_path "sessions/cli_history.log"
  @default_recent_limit 10

  @type option :: {:path, String.t()}

  @doc """
  Returns the history file path.
  """
  @spec path([option()]) :: String.t()
  def path(opts \\ []) do
    Keyword.get_lazy(opts, :path, fn ->
      System.get_env("PINCER_CLI_HISTORY_FILE") || @default_path
    end)
  end

  @doc """
  Appends one user entry to persistent history.
  """
  @spec append(String.t(), [option()]) :: :ok | {:error, term()}
  def append(entry, opts \\ [])

  def append(entry, opts) when is_binary(entry) do
    sanitized = sanitize_entry(entry)

    if sanitized == "" do
      :ok
    else
      history_path = path(opts)

      with :ok <- ensure_parent_dir(history_path) do
        File.write(history_path, sanitized <> "\n", [:append])
      end
    end
  end

  def append(_entry, _opts), do: {:error, :invalid_entry}

  @doc """
  Reads the most recent history entries in chronological order.
  """
  @spec recent(pos_integer(), [option()]) :: [String.t()]
  def recent(limit \\ @default_recent_limit, opts \\ [])

  def recent(limit, opts) when is_integer(limit) and limit > 0 do
    history_path = path(opts)

    case File.read(history_path) do
      {:ok, content} ->
        content
        |> String.split(~r/\r\n|\n|\r/, trim: true)
        |> Enum.take(-limit)

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        []
    end
  end

  def recent(_limit, opts), do: recent(@default_recent_limit, opts)

  @doc """
  Clears all persisted history entries.
  """
  @spec clear([option()]) :: :ok | {:error, term()}
  def clear(opts \\ []) do
    history_path = path(opts)

    with :ok <- ensure_parent_dir(history_path) do
      File.write(history_path, "")
    end
  end

  defp ensure_parent_dir(history_path) do
    history_path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp sanitize_entry(entry) do
    entry
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.trim()
  end
end

defmodule Pincer.Utils.ETSHelper do
  @moduledoc """
  Shared helpers for named ETS table lifecycle.

  Tables created here name `Pincer.Utils.ETSTableHeir` as their heir, so the
  table outlives whichever process created it instead of vanishing with it.
  Pass an explicit `:heir` option to override (a 3-tuple, `{:heir, pid, data}`,
  is what OTP 26+ accepts).
  """

  alias Pincer.Utils.ETSTableHeir

  @default_options [:named_table, :set, :public, read_concurrency: true]

  @type ensure_result :: :created | :existing

  @spec ensure_named_table(atom(), keyword()) :: ensure_result()
  def ensure_named_table(table, opts \\ []) when is_atom(table) and is_list(opts) do
    options = opts |> Keyword.get(:options, @default_options) |> with_heir()

    case :ets.whereis(table) do
      :undefined ->
        try do
          :ets.new(table, options)
          :created
        rescue
          ArgumentError -> :existing
        end

      _tid ->
        :existing
    end
  end

  defp with_heir(options) do
    cond do
      Enum.any?(options, &heir_option?/1) -> options
      pid = Process.whereis(ETSTableHeir) -> [{:heir, pid, :ets_table_heir} | options]
      true -> options
    end
  end

  defp heir_option?({:heir, _pid}), do: true
  defp heir_option?({:heir, _pid, _data}), do: true
  defp heir_option?(_option), do: false
end

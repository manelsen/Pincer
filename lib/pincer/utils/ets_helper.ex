defmodule Pincer.Utils.ETSHelper do
  @moduledoc """
  Shared helpers for named ETS table lifecycle.
  """

  @default_options [:named_table, :set, :public, read_concurrency: true]

  @type ensure_result :: :created | :existing

  @spec ensure_named_table(atom(), keyword()) :: ensure_result()
  def ensure_named_table(table, opts \\ []) when is_atom(table) and is_list(opts) do
    options = Keyword.get(opts, :options, @default_options)

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
end

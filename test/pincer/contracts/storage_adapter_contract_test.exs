defmodule Pincer.Contracts.StorageAdapterContractTest do
  @moduledoc """
  Contract tests verifying that all storage adapters implement the Pincer.Ports.Storage behaviour.

  Each storage adapter must:
  - Declare `@behaviour Pincer.Ports.Storage`
  - Implement all required callbacks defined by the Storage port
  """
  use ExUnit.Case, async: true

  @storage_adapters [
    Pincer.Storage.Adapters.Postgres
  ]

  @required_callbacks [
    {:get_messages, 1},
    {:save_message, 3},
    {:delete_messages, 1},
    {:save_learning, 2},
    {:save_checkpoint, 2},
    {:load_checkpoint, 2},
    {:search_messages, 2},
    {:search_documents, 2},
    {:memory_report, 1},
    {:forget_memory, 1}
  ]

  test "storage adapters declare Pincer.Ports.Storage behaviour" do
    Enum.each(@storage_adapters, fn adapter_module ->
      behaviours = adapter_module.module_info(:attributes)[:behaviour] || []

      assert Pincer.Ports.Storage in behaviours,
             "#{inspect(adapter_module)} must declare @behaviour Pincer.Ports.Storage"
    end)
  end

  test "storage adapters export required callbacks" do
    Enum.each(@storage_adapters, fn adapter_module ->
      Enum.each(@required_callbacks, fn {fun, arity} ->
        assert function_exported?(adapter_module, fun, arity),
               "#{inspect(adapter_module)} must export #{fun}/#{arity}"
      end)
    end)
  end
end

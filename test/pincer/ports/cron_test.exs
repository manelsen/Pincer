defmodule Pincer.Ports.CronTest do
  use ExUnit.Case, async: false

  alias Pincer.Ports.Cron

  defmodule FakeCronAdapter do
    @behaviour Cron

    @impl true
    def list_jobs, do: [%{id: "job-1"}]

    @impl true
    def list_due_jobs(%DateTime{} = now) do
      send(self(), {:list_due_jobs, now})
      [%{id: "due-1", due_at: now}]
    end

    @impl true
    def update_next_run!(job) do
      send(self(), {:update_next_run!, job})
      Map.put(job, :rescheduled, true)
    end

    @impl true
    def create_job(params), do: {:ok, params}

    @impl true
    def delete_job(id), do: {:ok, %{id: id}}

    @impl true
    def disable_job(id), do: {:ok, %{id: id, enabled: false}}
  end

  test "declares list_due_jobs/1 and update_next_run!/1 callbacks and Storage implements Cron" do
    callbacks = Cron.behaviour_info(:callbacks)
    assert {:list_due_jobs, 1} in callbacks
    assert {:update_next_run!, 1} in callbacks

    behaviours = Pincer.Adapters.Cron.Storage.module_info(:attributes)[:behaviour] || []
    assert Cron in behaviours
  end

  test "dispatches list_due_jobs/0, list_due_jobs/1, and update_next_run!/1 to configured :cron_adapter" do
    previous = Application.fetch_env(:pincer, :cron_adapter)
    Application.put_env(:pincer, :cron_adapter, FakeCronAdapter)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:pincer, :cron_adapter, adapter)
        :error -> Application.delete_env(:pincer, :cron_adapter)
      end
    end)

    assert [%{id: "due-1", due_at: %DateTime{}}] = Cron.list_due_jobs()
    assert_received {:list_due_jobs, %DateTime{}}

    cutoff = ~U[2026-01-01 00:00:00Z]
    assert [%{id: "due-1", due_at: ^cutoff}] = Cron.list_due_jobs(cutoff)
    assert_received {:list_due_jobs, ^cutoff}

    job = %{id: "job-42"}
    assert %{id: "job-42", rescheduled: true} = Cron.update_next_run!(job)
    assert_received {:update_next_run!, ^job}
  end

  test "scheduler routes cron storage calls through Pincer.Ports.Cron" do
    source = File.read!("lib/pincer/adapters/cron/scheduler.ex")
    ast = Code.string_to_quoted!(source)

    {_ast, %{uses_cron_port?: uses_cron_port?, references_storage?: references_storage?}} =
      Macro.prewalk(ast, %{uses_cron_port?: false, references_storage?: false}, fn
        {:@, _, [{:moduledoc, _, _}]}, acc ->
          {nil, acc}

        {:@, _, [{:doc, _, _}]}, acc ->
          {nil, acc}

        {:__aliases__, _, [:Pincer, :Ports, :Cron]} = node, acc ->
          {node, %{acc | uses_cron_port?: true}}

        {:__aliases__, _, [:Pincer, :Adapters, :Cron, :Storage]} = node, acc ->
          {node, %{acc | references_storage?: true}}

        node, acc ->
          {node, acc}
      end)

    assert uses_cron_port?
    refute references_storage?
  end
end

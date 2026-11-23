defmodule Pincer.Storage.ZeroInfraSQLiteIntegrationTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Cron.Job
  alias Pincer.Adapters.Cron.Storage, as: CronStorage
  alias Pincer.Core.AuditLog
  alias Pincer.Core.CircuitBreaker
  alias Pincer.Core.DeadLetterQueue
  alias Pincer.Core.Introspection.Kernel
  alias Pincer.Core.Introspection.LessonSchema
  alias Pincer.Core.Introspection.LessonStore
  alias Pincer.Core.Introspection.Schema, as: SelfStateSchema
  alias Pincer.Core.Introspection.SelfState
  alias Pincer.Core.Skills.PromptIndex
  alias Pincer.Infra.SQLite
  alias Pincer.Ports.Storage

  defmodule ZeroInfraSkillLLMStub do
    def chat_completion(_messages, _opts) do
      payload =
        Jason.encode!(%{
          "name" => "sqlite-zero-infra-skill",
          "description" => "Promoted using zero-infra SQLite persistence without PostgreSQL.",
          "when_to_use" => "When running Pincer in embedded SQLite mode.",
          "steps" => ["Verify SQLite database path is writable.", "Run WAL-backed queries."]
        })

      {:ok, %{"content" => payload}, nil}
    end
  end

  setup do
    prev_storage = Application.get_env(:pincer, :storage_adapter)
    prev_sqlite_server = Application.get_env(:pincer, :sqlite_server)
    prev_sqlite_path = Application.get_env(:pincer, :sqlite_path)

    existing_kernels =
      DynamicSupervisor.which_children(Kernel.Supervisor)
      |> Enum.map(&elem(&1, 1))
      |> MapSet.new()

    db_pid = start_supervised!({SQLite, name: nil, db_path: ":memory:"})
    Application.put_env(:pincer, :storage_adapter, Pincer.Storage.Adapters.SQLite)
    Application.put_env(:pincer, :sqlite_server, db_pid)
    Application.put_env(:pincer, :sqlite_path, ":memory:")

    on_exit(fn ->
      DynamicSupervisor.which_children(Kernel.Supervisor)
      |> Enum.each(fn {_id, pid, _type, _mods} ->
        if is_pid(pid) and not MapSet.member?(existing_kernels, pid) do
          DynamicSupervisor.terminate_child(Kernel.Supervisor, pid)
        end
      end)

      restore_env(:storage_adapter, prev_storage)
      restore_env(:sqlite_server, prev_sqlite_server)
      restore_env(:sqlite_path, prev_sqlite_path)
    end)

    {:ok, db: db_pid}
  end

  defp restore_env(key, nil), do: Application.delete_env(:pincer, key)
  defp restore_env(key, val), do: Application.put_env(:pincer, key, val)

  test "ports storage, introspection stores, cron, audit, dlq, and circuit breaker run on SQLite",
       %{db: db} do
    # 1. Pincer.Ports.Storage dispatcher routes to SQLite
    assert {:ok, _} = Storage.save_message("zi-sess", "user", "zero infra sqlite works")
    assert [%{role: "user", content: "zero infra sqlite works"}] = Storage.get_messages("zi-sess")
    assert {:ok, [%{kind: :message}]} = Storage.search_messages("zero infra", 5)

    # 2. Introspection SelfState
    assert {:ok, %SelfStateSchema{} = s1} = SelfState.load_or_create("zi-agent")
    assert s1.agent_id == "zi-agent"

    assert {:ok, %SelfStateSchema{} = s2} =
             SelfState.update("zi-agent", %{focus: "SQLite mode", concerns: ["none"]})

    assert s2.focus == "SQLite mode"
    assert s2.concerns == ["none"]

    assert {:ok, %{rows: [[1]]}} =
             SQLite.query(db, "SELECT COUNT(*) FROM self_states WHERE agent_id = ?1", ["zi-agent"])

    # 3. Introspection LessonStore
    assert {:ok, %LessonSchema{} = l1} =
             LessonStore.create("zi-agent", %{
               content: "SQLite FTS5 requires safe query token quoting.",
               confidence: 0.85,
               success_count: 2
             })

    assert {:error, :duplicate} =
             LessonStore.create("zi-agent", %{
               content: "SQLite FTS5 requires safe query token quoting."
             })

    assert {:ok, updated_lesson} = LessonStore.record_outcome(l1.id, :success)
    assert updated_lesson.success_count == 3

    assert [%LessonSchema{id: top_id}] =
             LessonStore.top_lessons("zi-agent", 5, min_confidence: 0.5)

    assert top_id == l1.id

    # 4. Cron.Storage
    assert {:error, %Ecto.Changeset{valid?: false}} = CronStorage.create_job(%{name: "bad"})

    assert {:ok, %Job{} = job} =
             CronStorage.create_job(%{
               name: "SQLite Heartbeat",
               cron_expression: "* * * * *",
               prompt: "Ping",
               session_id: "zi-sess"
             })

    assert [%Job{id: job_id}] = CronStorage.list_jobs()
    assert job_id == job.id

    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    assert length(CronStorage.list_due_jobs(future)) == 1
    assert %Job{} = CronStorage.update_next_run!(job)
    assert {:ok, %Job{enabled: false}} = CronStorage.disable_job(job.id)
    assert [] = CronStorage.list_due_jobs(future)
    assert {:ok, %Job{}} = CronStorage.delete_job(job.id)
    assert [] = CronStorage.list_jobs()

    # 5. AuditLog
    assert :ok = AuditLog.record(:tool_approved, :allowed, actor: "admin", target: "safe_shell")
    assert [%AuditLog{actor: "admin"}] = AuditLog.recent(10)
    assert [%AuditLog{event_type: "tool_approved"}] = AuditLog.by_actor("admin", 10)
    assert [%AuditLog{outcome: "allowed"}] = AuditLog.by_type("tool_approved", 10)

    # 6. DeadLetterQueue
    assert {:ok, %DeadLetterQueue{} = dlq} =
             DeadLetterQueue.enqueue("webhook", %{"id" => 1}, "timeout")

    assert [%DeadLetterQueue{id: dlq_id}] = DeadLetterQueue.pending("webhook")
    assert dlq_id == dlq.id
    assert {:ok, %DeadLetterQueue{attempt_count: 2}} = DeadLetterQueue.increment_attempt(dlq.id)

    assert {:ok, %DeadLetterQueue{resolution: "retried"}} =
             DeadLetterQueue.resolve(dlq.id, "retried")

    assert [] = DeadLetterQueue.pending("webhook")

    # 7. CircuitBreaker runs cleanly without an external database
    cb_name = "sqlite_cb_#{System.unique_integer([:positive])}"
    assert :ok = CircuitBreaker.call(cb_name, fn -> :ok end)
    CircuitBreaker.reset(cb_name)
  end

  test "closed-loop Introspection.Kernel -> SKILL.md -> PromptIndex runs on embedded SQLite",
       %{db: db} do
    workspace =
      Path.join(System.tmp_dir!(), "pincer_zi_loop_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    agent_id = "zi_loop_#{System.unique_integer([:positive])}"

    {:ok, lesson} =
      LessonStore.create(agent_id, %{
        content: "Keep WAL enabled when running Pincer on embedded SQLite.",
        confidence: 0.9,
        success_count: 3
      })

    start_supervised!(
      {Kernel,
       [
         agent_id: agent_id,
         workspace_path: workspace,
         tick_interval: 600_000,
         introspection_client: ZeroInfraSkillLLMStub,
         skill_promotion_throttle_ms: 0
       ]}
    )

    Kernel.register_session(agent_id, self())
    Kernel.promote_skills(agent_id)

    assert_receive {:kernel_skills_updated, promoted}, 1_500
    assert promoted.name == "sqlite-zero-infra-skill"
    assert File.exists?(promoted.path)
    assert lesson.id in promoted.lesson_ids

    assert {:ok, %{rows: [[1]]}} =
             SQLite.query(db, "SELECT COUNT(*) FROM lessons WHERE agent_id = ?1", [agent_id])

    section = PromptIndex.build(workspace, shared_dir: nil, bundled_dir: nil)
    assert section =~ "sqlite-zero-infra-skill"
  end
end

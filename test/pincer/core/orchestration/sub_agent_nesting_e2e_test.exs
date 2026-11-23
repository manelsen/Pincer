defmodule Pincer.Core.Orchestration.SubAgentNestingE2ETest do
  @moduledoc """
  End-to-end coverage for bounded nested sub-agent delegation.

  This test drives the real `Orchestrator` -> `SubAgent` -> `Executor` ->
  `ToolRunner` -> `NativeToolRegistry` chain. Only the LLM provider is
  scripted; every dispatch, depth check, approval decision, Blackboard post,
  checkpoint, and registry entry comes from production code.
  """

  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.Orchestrator
  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Core.Orchestration.SubAgentRegistry
  alias Pincer.Core.Orchestration.SubAgentSupervisor
  alias Pincer.Infra.PubSub
  alias Pincer.Infra.Repo
  alias Pincer.Ports.Storage

  @provider "scripted"
  @model "scripted-model"
  @depth_cap 2

  defmodule ScriptedProvider do
    @moduledoc false
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def stream_completion(messages, _model, _config, _tools) do
      {:ok, chunks(messages)}
    end

    @impl true
    def chat_completion(messages, _model, _config, _tools) do
      case reply(messages) do
        {:tool_call, id, args} ->
          {:ok,
           %{
             "role" => "assistant",
             "content" => nil,
             "tool_calls" => [
               %{
                 "id" => id,
                 "type" => "function",
                 "function" => %{"name" => "dispatch_agent", "arguments" => Jason.encode!(args)}
               }
             ]
           }, nil}

        {:final, content} ->
          {:ok, %{"role" => "assistant", "content" => content}, nil}
      end
    end

    defp chunks(messages) do
      case reply(messages) do
        {:tool_call, id, args} ->
          [
            %{
              "choices" => [
                %{
                  "delta" => %{
                    "tool_calls" => [
                      %{
                        "index" => 0,
                        "id" => id,
                        "type" => "function",
                        "function" => %{
                          "name" => "dispatch_agent",
                          "arguments" => Jason.encode!(args)
                        }
                      }
                    ]
                  }
                }
              ]
            }
          ]

        {:final, content} ->
          [%{"choices" => [%{"delta" => %{"content" => content}}]}]
      end
    end

    defp reply(messages) do
      goal = Enum.find_value(messages, fn message -> user_goal(message) end)

      cond do
        is_binary(goal) and String.contains?(goal, "LEVEL1 ") ->
          reply_for_level(messages, goal, :l1, "LEVEL2", "DEPTH1_FINAL")

        is_binary(goal) and String.contains?(goal, "LEVEL2 ") ->
          reply_for_level(messages, goal, :l2, "LEVEL3", nil)

        is_binary(goal) and String.contains?(goal, "LEVEL3 ") ->
          {:final, "UNEXPECTED_DEPTH3_STARTED"}

        true ->
          {:final, "UNEXPECTED_GOAL: #{inspect(goal)}"}
      end
    end

    defp reply_for_level(messages, goal, level, next_level, final_text) do
      case dispatch_tool_result(messages) do
        nil ->
          hold(:"#{level}_first")
          seed = goal |> String.split() |> Enum.at(1)
          {:tool_call, "call_#{level}", dispatch_args("#{next_level} #{seed} nested goal")}

        _content when is_binary(final_text) ->
          hold(:"#{level}_final")
          {:final, final_text}

        content ->
          hold(:"#{level}_final")
          {:final, "DEPTH2_FINAL: " <> content}
      end
    end

    defp dispatch_args(goal) do
      %{"goal" => goal, "provider" => "scripted", "model" => "scripted-model"}
    end

    defp dispatch_tool_result(messages) do
      messages
      |> Enum.filter(&(&1["role"] == "tool" and &1["name"] == "dispatch_agent"))
      |> List.last()
      |> case do
        nil -> nil
        message -> message["content"]
      end
    end

    defp user_goal(%{"role" => "user", "content" => content}) when is_binary(content), do: content
    defp user_goal(_message), do: nil

    # Holds the first/final turn of each scripted agent so the test can inspect
    # runtime state (Blackboard, registry, checkpoints, PubSub subscriptions)
    # before the tool loop continues. Deterministic: no sleeps in the test.
    defp hold(tag) do
      case Application.get_env(:pincer, :nesting_e2e_holder) do
        pid when is_pid(pid) ->
          send(pid, {:scripted_hold, tag, self()})

          receive do
            {:scripted_release, ^tag} -> :ok
          after
            15_000 -> raise "scripted provider timed out waiting for release of #{inspect(tag)}"
          end

        _other ->
          :ok
      end
    end
  end

  setup do
    Application.ensure_all_started(:pincer)
    Blackboard.reset()

    prev_providers = Application.get_env(:pincer, :llm_providers)
    prev_default = Application.get_env(:pincer, :default_llm_provider)
    prev_depth = Application.get_env(:pincer, :max_subagent_depth)
    prev_global = Application.get_env(:pincer, :max_subagents)
    prev_session = Application.get_env(:pincer, :max_subagents_per_session)

    Application.put_env(:pincer, :llm_providers, %{
      @provider => %{
        adapter: ScriptedProvider,
        env_key: "MOCK_KEY",
        default_model: @model
      }
    })

    Application.put_env(:pincer, :default_llm_provider, @provider)
    Application.put_env(:pincer, :max_subagent_depth, @depth_cap)
    Application.put_env(:pincer, :max_subagents, :infinity)
    Application.put_env(:pincer, :max_subagents_per_session, 8)
    Application.put_env(:pincer, :nesting_e2e_holder, self())

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    on_exit(fn ->
      terminate_children()

      restore_env(:llm_providers, prev_providers)
      restore_env(:default_llm_provider, prev_default)
      restore_env(:max_subagent_depth, prev_depth)
      restore_env(:max_subagents, prev_global)
      restore_env(:max_subagents_per_session, prev_session)
      Application.delete_env(:pincer, :nesting_e2e_holder)
      Blackboard.reset()
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    end)

    :ok
  end

  test "nested dispatch is depth-bounded, auto-approved, checkpointed, and terminates" do
    seed = System.unique_integer([:positive])
    root_session = "nesting-root-#{seed}"
    l1_goal = "LEVEL1 #{seed} dispatch the next level"
    l2_goal = "LEVEL2 #{seed} nested goal"
    l3_goal = "LEVEL3 #{seed} nested goal"

    PubSub.subscribe("session:#{root_session}")

    assert {:ok, message} =
             Orchestrator.execute(
               %{"goal" => l1_goal, "provider" => @provider, "model" => @model},
               %{"session_id" => root_session}
             )

    assert [_, depth1_id] = Regex.run(~r/ID: (agent_[0-9a-f]+)/, message)

    # Depth 1 starts, then holds before its first tool call.
    assert_receive {:scripted_hold, :l1_first, depth1_pid}, 5_000
    PubSub.subscribe("session:#{depth1_id}")
    send(depth1_pid, {:scripted_release, :l1_first})

    # Depth 1 dispatches depth 2, which starts and holds before its tool call.
    assert_receive {:scripted_hold, :l2_first, depth2_pid}, 5_000

    started_depth2 =
      await_value(
        fn ->
          find_message(depth1_id, fn msg ->
            msg.content == "Started with goal: #{l2_goal}"
          end)
        end,
        5_000
      )

    assert started_depth2, "depth-2 agent should post its Started message"
    depth2_id = started_depth2.agent_id
    PubSub.subscribe("session:#{depth2_id}")
    send(depth2_pid, {:scripted_release, :l2_first})

    # Depth 2's dispatch of depth 3 is rejected, then both agents hold their
    # final turn. The whole tree is alive at once.
    assert_receive {:scripted_hold, :l1_final, ^depth1_pid}, 5_000
    assert_receive {:scripted_hold, :l2_final, ^depth2_pid}, 5_000

    assert SubAgentRegistry.count_for(root_session) == 2

    assert {:ok, agent1_pid} = SubAgentRegistry.lookup(depth1_id)
    assert {:ok, agent2_pid} = SubAgentRegistry.lookup(depth2_id)
    ref1 = Process.monitor(agent1_pid)
    ref2 = Process.monitor(agent2_pid)

    refute_message(root_session, fn msg -> msg.content == "Started with goal: #{l3_goal}" end)
    refute_message(depth2_id, fn msg -> msg.content == "Started with goal: #{l3_goal}" end)

    running_depth1 = load_checkpoint!(depth1_id)
    running_depth2 = load_checkpoint!(depth2_id)

    assert metadata_value(running_depth1.metadata, :subagent_depth) == 1
    assert metadata_value(running_depth2.metadata, :subagent_depth) == 2
    assert metadata_value(running_depth1.metadata, :root_session_id) == root_session
    assert metadata_value(running_depth2.metadata, :root_session_id) == root_session

    send(depth1_pid, {:scripted_release, :l1_final})
    send(depth2_pid, {:scripted_release, :l2_final})

    finished_depth1 =
      await_value(
        fn ->
          find_message(root_session, fn msg ->
            msg.agent_id == depth1_id and String.starts_with?(msg.content, "FINISHED:")
          end)
        end,
        5_000
      )

    finished_depth2 =
      await_value(
        fn ->
          find_message(depth1_id, fn msg ->
            msg.agent_id == depth2_id and String.starts_with?(msg.content, "FINISHED:")
          end)
        end,
        5_000
      )

    assert finished_depth1
    assert finished_depth1.content =~ "DEPTH1_FINAL"

    assert finished_depth2
    assert finished_depth2.content =~ "DEPTH2_FINAL"
    assert finished_depth2.content =~ "Sub-agent depth limit reached"
    assert finished_depth2.content =~ "cannot dispatch depth 3"

    assert_receive {:DOWN, ^ref1, :process, ^agent1_pid, :normal}, 5_000
    assert_receive {:DOWN, ^ref2, :process, ^agent2_pid, :normal}, 5_000

    refute_message(root_session, fn msg -> msg.content == "Started with goal: #{l3_goal}" end)
    refute_message(depth2_id, fn msg -> msg.content == "Started with goal: #{l3_goal}" end)

    assert wait_until(fn -> SubAgentRegistry.count_for(root_session) == 0 end, 5_000),
           "registry entries should disappear after the tree terminates"

    assert wait_until(
             fn -> DynamicSupervisor.which_children(SubAgentSupervisor) == [] end,
             5_000
           ),
           "supervised sub-agent workers should be gone"

    refute_receive {:approval_required, _, _}, 300

    finished_checkpoint1 = load_checkpoint!(depth1_id, ["finished"])
    finished_checkpoint2 = load_checkpoint!(depth2_id, ["finished"])

    assert finished_checkpoint1.status == "finished"
    assert finished_checkpoint2.status == "finished"
    assert metadata_value(finished_checkpoint1.metadata, :subagent_depth) == 1
    assert metadata_value(finished_checkpoint2.metadata, :subagent_depth) == 2
    assert metadata_value(finished_checkpoint1.metadata, :root_session_id) == root_session
    assert metadata_value(finished_checkpoint2.metadata, :root_session_id) == root_session
  end

  defp terminate_children do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(SubAgentSupervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(SubAgentSupervisor, pid)
    end
  end

  defp load_checkpoint!(
         agent_id,
         statuses \\ ~w(running paused finished failed interrupted completed)
       ) do
    case Storage.load_checkpoint(agent_id, status: statuses) do
      {:ok, checkpoint} -> checkpoint
      other -> flunk("checkpoint for #{agent_id} unavailable: #{inspect(other)}")
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp find_message(scope, predicate) do
    {messages, _last_id} = Blackboard.fetch_new(0, scope: scope)
    Enum.find(messages, predicate)
  end

  defp refute_message(scope, predicate) do
    {messages, _last_id} = Blackboard.fetch_new(0, scope: scope)
    refute Enum.any?(messages, predicate)
  end

  defp await_value(fun, timeout) do
    value = wait_until_value(fun, timeout)
    assert value, "timed out waiting for blackboard state"
    value
  end

  defp wait_until(fun, timeout) do
    wait_until_value(fn -> if fun.(), do: true end, timeout) == true
  end

  defp wait_until_value(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until_value(fun, deadline)
  end

  defp do_wait_until_value(fun, deadline) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          nil
        else
          Process.sleep(20)
          do_wait_until_value(fun, deadline)
        end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:pincer, key)
  defp restore_env(key, value), do: Application.put_env(:pincer, key, value)
end

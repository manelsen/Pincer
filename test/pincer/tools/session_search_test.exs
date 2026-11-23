defmodule Pincer.Tools.SessionSearchTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.SessionSearch

  defmodule StorageStub do
    def reset do
      Process.put(:session_search_calls, [])
      Process.put(:session_search_sessions, {:ok, []})
      Process.put(:session_search_messages, {:ok, []})
      Process.put(:session_search_history, [])
    end

    def calls, do: Process.get(:session_search_calls, []) |> Enum.reverse()

    def put_sessions(result), do: Process.put(:session_search_sessions, result)
    def put_messages(result), do: Process.put(:session_search_messages, result)
    def put_history(messages), do: Process.put(:session_search_history, messages)

    def search_sessions(query, limit) do
      record({:search_sessions, query, limit})
      Process.get(:session_search_sessions, {:ok, []})
    end

    def search_messages(query, limit) do
      record({:search_messages, query, limit})
      Process.get(:session_search_messages, {:ok, []})
    end

    def get_messages(session_id) do
      record({:get_messages, session_id})
      Process.get(:session_search_history, [])
    end

    defp record(call), do: Process.put(:session_search_calls, [call | calls()])
  end

  setup do
    StorageStub.reset()
    {:ok, context: %{storage: StorageStub}}
  end

  defp message(index) do
    role = if rem(index, 2) == 0, do: "assistant", else: "user"
    %{role: role, content: "msg #{index}"}
  end

  describe "spec/0" do
    test "exposes the session_search multi-action tool" do
      spec = SessionSearch.spec()

      assert spec.name == "session_search"
      assert spec.parameters.required == ["action"]
      assert spec.parameters.properties.action.enum == ["discover", "search", "read"]
      assert Map.has_key?(spec.parameters.properties, :query)
      assert Map.has_key?(spec.parameters.properties, :session_id)
    end
  end

  describe "discover" do
    test "renders ranked sessions with hit counts and previews using a single storage call", %{
      context: context
    } do
      StorageStub.put_sessions(
        {:ok,
         [
           %{
             session_id: "s-1",
             hit_count: 3,
             preview: "deploy timeout\nfixed by retry",
             hits: []
           },
           %{session_id: "s-2", hit_count: 1, preview: "other note", hits: []}
         ]}
      )

      assert {:ok, output} =
               SessionSearch.execute(%{"action" => "discover", "query" => "deploy"}, context)

      assert output =~ "#1"
      assert output =~ "s-1"
      assert output =~ "3 hit"
      assert output =~ "deploy timeout fixed by retry"
      assert output =~ "s-2"
      assert StorageStub.calls() == [{:search_sessions, "deploy", 5}]
    end

    test "clamps limit to the documented maximum", %{context: context} do
      assert {:ok, _output} =
               SessionSearch.execute(
                 %{"action" => "discover", "query" => "deploy", "limit" => 999},
                 context
               )

      assert StorageStub.calls() == [{:search_sessions, "deploy", 20}]
    end

    test "reports an empty result without fabricating sessions", %{context: context} do
      assert {:ok, output} =
               SessionSearch.execute(%{"action" => "discover", "query" => "nothing"}, context)

      assert output =~ "No sessions found"
      assert StorageStub.calls() == [{:search_sessions, "nothing", 5}]
    end
  end

  describe "search" do
    test "renders rank, session, role and snippet with a single storage call", %{
      context: context
    } do
      StorageStub.put_messages(
        {:ok,
         [
           %{
             kind: :message,
             role: "user",
             content: "the deploy timeout was fixed",
             source: "session:s-9:message:42",
             citation: "session s-9 / user / message #42",
             score: 0.93
           }
         ]}
      )

      assert {:ok, output} =
               SessionSearch.execute(
                 %{"action" => "search", "query" => "deploy timeout"},
                 context
               )

      assert output =~ "#1"
      assert output =~ "s-9"
      assert output =~ "user"
      assert output =~ "the deploy timeout was fixed"
      assert StorageStub.calls() == [{:search_messages, "deploy timeout", 10}]
    end

    test "clamps limit to the documented maximum", %{context: context} do
      assert {:ok, _output} =
               SessionSearch.execute(
                 %{"action" => "search", "query" => "deploy", "limit" => 500},
                 context
               )

      assert StorageStub.calls() == [{:search_messages, "deploy", 50}]
    end
  end

  describe "read" do
    test "defaults to the tail of the session with the default page size", %{context: context} do
      StorageStub.put_history(Enum.map(1..30, &message/1))

      assert {:ok, output} =
               SessionSearch.execute(%{"action" => "read", "session_id" => "s-1"}, context)

      assert output =~ "showing 11-30 of 30"
      assert output =~ "[30] assistant: msg 30"
      assert output =~ "next_offset: none"
      refute output =~ "[10] user: msg 10"
      assert StorageStub.calls() == [{:get_messages, "s-1"}]
    end

    test "honours explicit offset and limit and reports next_offset", %{context: context} do
      StorageStub.put_history(Enum.map(1..30, &message/1))

      assert {:ok, output} =
               SessionSearch.execute(
                 %{"action" => "read", "session_id" => "s-1", "offset" => 0, "limit" => 10},
                 context
               )

      assert output =~ "showing 1-10 of 30"
      assert output =~ "[1] user: msg 1"
      assert output =~ "next_offset: 10"
      refute output =~ "[11] user: msg 11"
      assert StorageStub.calls() == [{:get_messages, "s-1"}]
    end

    test "reports an empty session clearly", %{context: context} do
      StorageStub.put_history([])

      assert {:ok, output} =
               SessionSearch.execute(%{"action" => "read", "session_id" => "empty"}, context)

      assert output =~ "no messages"
      assert StorageStub.calls() == [{:get_messages, "empty"}]
    end

    test "reports an offset past the end without crashing", %{context: context} do
      StorageStub.put_history(Enum.map(1..5, &message/1))

      assert {:ok, output} =
               SessionSearch.execute(
                 %{"action" => "read", "session_id" => "s-1", "offset" => 99},
                 context
               )

      assert output =~ "no messages at offset 99"
      assert output =~ "total 5"
      assert StorageStub.calls() == [{:get_messages, "s-1"}]
    end
  end

  describe "validation" do
    test "rejects an unknown action without touching storage", %{context: context} do
      assert {:error, reason} = SessionSearch.execute(%{"action" => "explode"}, context)
      assert reason =~ "Unknown action"
      assert StorageStub.calls() == []
    end

    test "rejects a missing action without touching storage", %{context: context} do
      assert {:error, reason} = SessionSearch.execute(%{}, context)
      assert reason =~ "action"
      assert StorageStub.calls() == []
    end

    test "rejects discover/search without a query", %{context: context} do
      assert {:error, _} = SessionSearch.execute(%{"action" => "discover"}, context)
      assert {:error, _} = SessionSearch.execute(%{"action" => "search"}, context)

      assert {:error, _} =
               SessionSearch.execute(%{"action" => "search", "query" => ""}, context)

      assert {:error, _} =
               SessionSearch.execute(%{"action" => "search", "query" => 42}, context)

      assert StorageStub.calls() == []
    end

    test "rejects invalid limit and offset types", %{context: context} do
      assert {:error, _} =
               SessionSearch.execute(
                 %{"action" => "read", "session_id" => "s-1", "limit" => "ten"},
                 context
               )

      assert {:error, _} =
               SessionSearch.execute(
                 %{"action" => "read", "session_id" => "s-1", "offset" => -1},
                 context
               )

      assert {:error, _} =
               SessionSearch.execute(
                 %{"action" => "discover", "query" => "deploy", "limit" => 0},
                 context
               )

      assert StorageStub.calls() == []
    end

    test "rejects read without a session id", %{context: context} do
      assert {:error, _} = SessionSearch.execute(%{"action" => "read"}, context)

      assert {:error, _} =
               SessionSearch.execute(%{"action" => "read", "session_id" => 1}, context)

      assert StorageStub.calls() == []
    end
  end

  describe "storage errors" do
    test "propagates storage failures as tool errors", %{context: context} do
      StorageStub.put_sessions({:error, :db_down})
      StorageStub.put_messages({:error, :db_down})

      assert {:error, reason} =
               SessionSearch.execute(%{"action" => "discover", "query" => "deploy"}, context)

      assert reason =~ "db_down"

      assert {:error, reason} =
               SessionSearch.execute(%{"action" => "search", "query" => "deploy"}, context)

      assert reason =~ "db_down"
    end
  end
end

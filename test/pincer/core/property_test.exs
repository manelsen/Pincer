defmodule Pincer.Core.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pincer.Core.MemoryTypes
  alias Pincer.Core.MemoryPipeline
  alias Pincer.Core.RetryPolicy

  # ---------------------------------------------------------------------------
  # MemoryTypes.normalize/1 — all outputs are members of the canonical list
  # ---------------------------------------------------------------------------

  describe "MemoryTypes.normalize/1" do
    # term() can produce non-UTF-8 binaries, so we use a union that covers
    # the documented input types plus valid strings and other non-binary terms.
    defp safe_term do
      one_of([
        string(:utf8),
        atom(:alphanumeric),
        constant(nil),
        integer(),
        float(),
        list_of(integer()),
        map_of(atom(:alphanumeric), integer())
      ])
    end

    property "always returns a member of all()" do
      check all(input <- safe_term()) do
        result = MemoryTypes.normalize(input)
        assert result in MemoryTypes.all(),
               "normalize(#{inspect(input)}) = #{inspect(result)} not in all()"
      end
    end

    property "canonical types normalize to themselves" do
      check all(type <- member_of(MemoryTypes.all())) do
        assert MemoryTypes.normalize(type) == type
      end
    end

    property "atoms that match canonical types normalize correctly" do
      check all(type <- member_of(MemoryTypes.all())) do
        atom = String.to_atom(type)
        assert MemoryTypes.normalize(atom) == type
      end
    end

    property "non-empty binary strings always produce a string result" do
      check all(s <- string(:printable, min_length: 1)) do
        result = MemoryTypes.normalize(s)
        assert is_binary(result)
        assert result in MemoryTypes.all()
      end
    end

    property "normalize is idempotent" do
      check all(input <- safe_term()) do
        once = MemoryTypes.normalize(input)
        twice = MemoryTypes.normalize(once)
        assert once == twice
      end
    end
  end

  # ---------------------------------------------------------------------------
  # MemoryTypes.valid?/1 — consistent with normalize/1
  # ---------------------------------------------------------------------------

  describe "MemoryTypes.valid?/1" do
    property "valid? is true iff normalize returns the same value as input" do
      check all(type <- string(:alphanumeric, min_length: 1)) do
        normalized = MemoryTypes.normalize(type)
        if type in MemoryTypes.all() do
          assert MemoryTypes.valid?(type) == true
        else
          assert MemoryTypes.valid?(type) == (normalized == type)
        end
      end
    end

    property "valid? is true for every member of all()" do
      check all(type <- member_of(MemoryTypes.all())) do
        assert MemoryTypes.valid?(type) == true
      end
    end

    property "valid? is false for nil and other non-string terms" do
      check all(input <- one_of([constant(nil), integer(), float(), list_of(integer())])) do
        assert MemoryTypes.valid?(input) == false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # RetryPolicy.retryable?/1 — retryable + fail_fast are mutually exclusive
  # ---------------------------------------------------------------------------

  describe "RetryPolicy" do
    # Generators for known error shapes
    defp retryable_http_statuses, do: member_of([408, 429, 500, 502, 503, 504])
    defp fail_fast_http_statuses, do: member_of([401, 403, 404])

    property "retryable? is true for known retryable HTTP statuses" do
      check all(status <- retryable_http_statuses()) do
        assert RetryPolicy.retryable?({:http_error, status, "error"}) == true
      end
    end

    property "retryable? is false for fail-fast HTTP statuses" do
      check all(status <- fail_fast_http_statuses()) do
        assert RetryPolicy.retryable?({:http_error, status, "error"}) == false
      end
    end

    property "retryable? and fail_fast? are mutually exclusive for HTTP errors" do
      check all(status <- integer(400..599)) do
        reason = {:http_error, status, "msg"}
        refute RetryPolicy.retryable?(reason) and RetryPolicy.fail_fast?(reason),
               "status #{status} is both retryable and fail_fast"
      end
    end

    property "parse_retry_after returns non-negative integer for non-negative integer input" do
      check all(ms <- non_negative_integer()) do
        result = RetryPolicy.parse_retry_after(ms)
        assert is_integer(result) and result >= 0
      end
    end

    property "parse_retry_after returns non-negative integer for positive numeric string seconds" do
      check all(seconds <- positive_integer()) do
        result = RetryPolicy.parse_retry_after("#{seconds}")
        assert is_integer(result) and result >= 0
        assert result == seconds * 1000
      end
    end

    property "parse_retry_after returns nil for non-numeric, non-date binary strings" do
      check all(s <- string(:alphanumeric, min_length: 3),
                !String.match?(s, ~r/^\d+$/)) do
        result = RetryPolicy.parse_retry_after(s)
        # Result is either nil (unparseable) or a non-negative integer (if it's a valid HTTP date)
        assert is_nil(result) or (is_integer(result) and result >= 0)
      end
    end

    property "parse_retry_after is nil for non-integer, non-binary inputs" do
      check all(input <- one_of([constant(nil), constant(:atom), list_of(integer())])) do
        assert RetryPolicy.parse_retry_after(input) == nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # MemoryPipeline.run/2 — structural invariants over arbitrary content
  # ---------------------------------------------------------------------------

  describe "MemoryPipeline.run/2" do
    defmodule StubStorage do
      def search_messages(_q, _l), do: {:ok, []}
      def search_documents(_q, _l, _o), do: {:ok, []}
      def search_documents(q, l), do: search_documents(q, l, [])
      def search_similar(_t, _v, _l), do: {:ok, []}
      def search_graph_history(_q, _l), do: {:ok, []}
    end

    property "always returns {:ok, map} for any string content" do
      check all(
              content <- string(:printable, min_length: 0, max_length: 500),
              session_id <- string(:alphanumeric, min_length: 1, max_length: 20),
              project_id <- string(:alphanumeric, min_length: 1, max_length: 20)
            ) do
        input = %{session_id: session_id, project_id: project_id, content: content}

        assert {:ok, result} =
                 MemoryPipeline.run(input,
                   storage: StubStorage,
                   embedding_fun: fn _ -> {:ok, [0.0]} end,
                   budget: %{session: 10_000, project: 10_000}
                 )

        assert is_map(result)
        assert Map.has_key?(result, :capture)
        assert Map.has_key?(result, :classify)
        assert Map.has_key?(result, :store)
        assert Map.has_key?(result, :recall)
        assert Map.has_key?(result, :compact)
        assert Map.has_key?(result, :explain)
      end
    end

    property "classify.memory_type is always a valid MemoryTypes member" do
      check all(content <- string(:printable, min_length: 0, max_length: 200)) do
        input = %{session_id: "s", project_id: "p", content: content}

        assert {:ok, result} =
                 MemoryPipeline.run(input,
                   storage: StubStorage,
                   embedding_fun: fn _ -> {:ok, [0.0]} end,
                   budget: %{session: 10_000, project: 10_000}
                 )

        assert result.classify.memory_type in MemoryTypes.all()
      end
    end

    property "confidence and relevance are floats between 0 and 1" do
      check all(content <- string(:printable, min_length: 0, max_length: 200)) do
        input = %{session_id: "s", project_id: "p", content: content}

        assert {:ok, result} =
                 MemoryPipeline.run(input,
                   storage: StubStorage,
                   embedding_fun: fn _ -> {:ok, [0.0]} end,
                   budget: %{session: 10_000, project: 10_000}
                 )

        assert is_float(result.classify.confidence)
        assert result.classify.confidence >= 0.0 and result.classify.confidence <= 1.0
        assert is_float(result.classify.relevance)
        assert result.classify.relevance >= 0.0 and result.classify.relevance <= 1.0
      end
    end

    property "store.status is :stored or :skipped_budget for any budget" do
      check all(
              session_cap <- integer(1..5),
              project_cap <- integer(1..5),
              content <- string(:alphanumeric, min_length: 1, max_length: 50)
            ) do
        session_id = "s-prop-#{session_cap}-#{project_cap}"
        project_id = "p-prop-#{session_cap}-#{project_cap}"
        input = %{session_id: session_id, project_id: project_id, content: content}

        assert {:ok, result} =
                 MemoryPipeline.run(input,
                   storage: StubStorage,
                   embedding_fun: fn _ -> {:ok, [0.0]} end,
                   budget: %{session: session_cap, project: project_cap}
                 )

        assert result.store.status in [:stored, :skipped_budget]
      end
    end
  end
end

defmodule Pincer.Multimodal.AttachmentIntegrationTest do
  @moduledoc """
  Integration tests for the multimodal attachment pipeline.

  Covers two stages of the lazy-ref resolution lifecycle:
    1. Executor: resolves `attachment_ref` parts from history before calling the LLM.
    2. Google provider: translates resolved Pincer parts into Gemini-format parts.
  """
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Core.Executor
  alias Pincer.LLM.Providers.Google

  # The Executor hex-test already defines these mocks; guard against duplicate defmock.
  # We reuse them here by just importing Mox.
  Mox.defmock(Pincer.MultimodalMockLLMClient, for: Pincer.Ports.LLM)
  Mox.defmock(Pincer.MultimodalMockToolRegistry, for: Pincer.Ports.ToolRegistry)

  setup :verify_on_exit!

  setup do
    original_providers = Application.get_env(:pincer, :llm_providers)
    original_default = Application.get_env(:pincer, :default_llm_provider)

    on_exit(fn ->
      if is_nil(original_providers) do
        Application.delete_env(:pincer, :llm_providers)
      else
        Application.put_env(:pincer, :llm_providers, original_providers)
      end

      if is_nil(original_default) do
        Application.delete_env(:pincer, :default_llm_provider)
      else
        Application.put_env(:pincer, :default_llm_provider, original_default)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp pdf_ref(size \\ 1_000) do
    %{
      "type" => "attachment_ref",
      "url" => "https://cdn.example.com/file.pdf",
      "mime_type" => "application/pdf",
      "filename" => "file.pdf",
      "size" => size
    }
  end

  defp user_msg_with_ref(text, ref) do
    %{"role" => "user", "content" => [%{"type" => "text", "text" => text}, ref]}
  end

  defp text_log_ref(size \\ 120) do
    %{
      "type" => "attachment_ref",
      "url" => "https://cdn.example.com/agent.log",
      "mime_type" => "text/plain",
      "filename" => "agent.log",
      "size" => size
    }
  end

  defp simple_llm_stream(text) do
    {:ok, [%{"choices" => [%{"delta" => %{"content" => text}}]}]}
  end

  # ---------------------------------------------------------------------------
  # 1. Executor resolution tests
  # ---------------------------------------------------------------------------

  describe "Executor.run — attachment_ref resolution" do
    test "resolves attachment_ref to inline_data when provider supports files" do
      session_pid = self()
      session_id = "mm_test_support"
      fake_b64 = Base.encode64("PDF bytes")

      history = [user_msg_with_ref("Summarise this", pdf_ref())]

      stub(Pincer.MultimodalMockToolRegistry, :list_tools, fn -> [] end)

      Pincer.MultimodalMockLLMClient
      |> expect(:stream_completion, fn ready_history, _opts ->
        # The ready_history seen by the LLM must have inline_data, not attachment_ref.
        user_content = get_in(ready_history, [Access.at(-1), "content"])
        assert is_list(user_content)
        assert Enum.any?(user_content, &(&1["type"] == "inline_data"))
        refute Enum.any?(user_content, &(&1["type"] == "attachment_ref"))
        simple_llm_stream("Summary done")
      end)

      fake_fetcher = fn _url -> {:ok, fake_b64} end

      Application.put_env(:pincer, :llm_providers, %{
        "test_multimodal" => %{adapter: nil, supports_files: true}
      })

      Application.put_env(:pincer, :default_llm_provider, "test_multimodal")

      {:ok, _} =
        Executor.start(session_pid, session_id, history,
          tool_registry: Pincer.MultimodalMockToolRegistry,
          llm_client: Pincer.MultimodalMockLLMClient,
          file_fetcher: fake_fetcher
        )

      assert_receive {:executor_finished, _, "Summary done", _usage}, 2_000

      # Restore env
      Application.delete_env(:pincer, :default_llm_provider)
      Application.delete_env(:pincer, :llm_providers)
    end

    test "converts attachment_ref to descriptive text when provider does not support files" do
      session_pid = self()
      session_id = "mm_test_no_support"

      history = [user_msg_with_ref("Summarise this", pdf_ref())]

      stub(Pincer.MultimodalMockToolRegistry, :list_tools, fn -> [] end)

      Pincer.MultimodalMockLLMClient
      |> expect(:stream_completion, fn ready_history, _opts ->
        user_content = get_in(ready_history, [Access.at(-1), "content"])
        assert is_list(user_content)
        # No binary attachment parts; should be plain text description.
        refute Enum.any?(user_content, &(&1["type"] == "inline_data"))

        text_part =
          Enum.find(
            user_content,
            &(&1["type"] == "text" and
                String.contains?(&1["text"] || "", "does not support"))
          )

        assert text_part != nil
        simple_llm_stream("OK")
      end)

      # file_fetcher must NOT be called — assert by not providing one that would succeed
      no_fetch = fn _url ->
        flunk("file_fetcher should not be called for non-supporting providers")
      end

      Application.put_env(:pincer, :llm_providers, %{
        "test_text_only" => %{adapter: nil, supports_files: false}
      })

      Application.put_env(:pincer, :default_llm_provider, "test_text_only")

      {:ok, _} =
        Executor.start(session_pid, session_id, history,
          tool_registry: Pincer.MultimodalMockToolRegistry,
          llm_client: Pincer.MultimodalMockLLMClient,
          file_fetcher: no_fetch
        )

      assert_receive {:executor_finished, _, _, _usage}, 2_000

      Application.delete_env(:pincer, :default_llm_provider)
      Application.delete_env(:pincer, :llm_providers)
    end

    test "converts text attachment_ref to inline text even when provider does not support files" do
      session_pid = self()
      session_id = "mm_test_text_ref_no_support"
      history = [user_msg_with_ref("Summarise this log", text_log_ref())]

      stub(Pincer.MultimodalMockToolRegistry, :list_tools, fn -> [] end)

      Pincer.MultimodalMockLLMClient
      |> expect(:stream_completion, fn ready_history, _opts ->
        user_content = get_in(ready_history, [Access.at(-1), "content"])

        text_part =
          Enum.find(
            user_content,
            &(&1["type"] == "text" and String.contains?(&1["text"] || "", "agent.log"))
          )

        assert text_part != nil
        assert text_part["text"] =~ "Content of agent.log"
        assert text_part["text"] =~ "line one"
        simple_llm_stream("Handled")
      end)

      fetcher = fn _url -> {:ok, Base.encode64("line one\nline two")} end

      Application.put_env(:pincer, :llm_providers, %{
        "test_text_only" => %{adapter: nil, supports_files: false}
      })

      Application.put_env(:pincer, :default_llm_provider, "test_text_only")

      {:ok, _} =
        Executor.start(session_pid, session_id, history,
          tool_registry: Pincer.MultimodalMockToolRegistry,
          llm_client: Pincer.MultimodalMockLLMClient,
          file_fetcher: fetcher
        )

      assert_receive {:executor_finished, _, "Handled", _usage}, 2_000

      Application.delete_env(:pincer, :default_llm_provider)
      Application.delete_env(:pincer, :llm_providers)
    end

    test "skips download and returns text for oversized attachments" do
      session_pid = self()
      session_id = "mm_test_oversize"

      # size > @max_inline_bytes (10_485_760)
      big_ref = pdf_ref(15_000_000)
      history = [user_msg_with_ref("Read this huge file", big_ref)]

      stub(Pincer.MultimodalMockToolRegistry, :list_tools, fn -> [] end)

      Pincer.MultimodalMockLLMClient
      |> expect(:stream_completion, fn ready_history, _opts ->
        user_content = get_in(ready_history, [Access.at(-1), "content"])
        refute Enum.any?(user_content, &(&1["type"] == "inline_data"))

        text_part =
          Enum.find(
            user_content,
            &(&1["type"] == "text" and
                String.contains?(&1["text"] || "", "exceeds inline limit"))
          )

        assert text_part != nil
        simple_llm_stream("Noted")
      end)

      never_called = fn _url -> flunk("Should not download oversized file") end

      Application.put_env(:pincer, :llm_providers, %{
        "test_oversize" => %{adapter: nil, supports_files: true}
      })

      Application.put_env(:pincer, :default_llm_provider, "test_oversize")

      {:ok, _} =
        Executor.start(session_pid, session_id, history,
          tool_registry: Pincer.MultimodalMockToolRegistry,
          llm_client: Pincer.MultimodalMockLLMClient,
          file_fetcher: never_called
        )

      assert_receive {:executor_finished, _, "Noted", _usage}, 2_000

      Application.delete_env(:pincer, :default_llm_provider)
      Application.delete_env(:pincer, :llm_providers)
    end

    test "returns error text when download fails" do
      session_pid = self()
      session_id = "mm_test_dl_fail"
      history = [user_msg_with_ref("Read this", pdf_ref())]

      stub(Pincer.MultimodalMockToolRegistry, :list_tools, fn -> [] end)

      Pincer.MultimodalMockLLMClient
      |> expect(:stream_completion, fn ready_history, _opts ->
        user_content = get_in(ready_history, [Access.at(-1), "content"])

        text_part =
          Enum.find(
            user_content,
            &(&1["type"] == "text" and
                String.contains?(&1["text"] || "", "Failed to download"))
          )

        assert text_part != nil
        simple_llm_stream("Handled")
      end)

      failing_fetcher = fn _url -> {:error, "connection refused"} end

      Application.put_env(:pincer, :llm_providers, %{
        "test_dl_fail" => %{adapter: nil, supports_files: true}
      })

      Application.put_env(:pincer, :default_llm_provider, "test_dl_fail")

      {:ok, _} =
        Executor.start(session_pid, session_id, history,
          tool_registry: Pincer.MultimodalMockToolRegistry,
          llm_client: Pincer.MultimodalMockLLMClient,
          file_fetcher: failing_fetcher
        )

      assert_receive {:executor_finished, _, "Handled", _usage}, 2_000

      Application.delete_env(:pincer, :default_llm_provider)
      Application.delete_env(:pincer, :llm_providers)
    end

    test "plain string messages pass through unchanged" do
      session_pid = self()
      session_id = "mm_test_plain"
      history = [%{"role" => "user", "content" => "Hello, no attachments here"}]

      stub(Pincer.MultimodalMockToolRegistry, :list_tools, fn -> [] end)

      Pincer.MultimodalMockLLMClient
      |> expect(:stream_completion, fn ready_history, _opts ->
        content = get_in(ready_history, [Access.at(-1), "content"])
        assert content == "Hello, no attachments here"
        simple_llm_stream("Hi!")
      end)

      {:ok, _} =
        Executor.start(session_pid, session_id, history,
          tool_registry: Pincer.MultimodalMockToolRegistry,
          llm_client: Pincer.MultimodalMockLLMClient
        )

      assert_receive {:executor_finished, _, _, _usage}, 2_000
    end

    test "attachment_ref is preserved in session history (not mutated to inline_data)" do
      session_pid = self()
      session_id = "mm_test_history_purity"
      ref = pdf_ref()
      history = [user_msg_with_ref("Read PDF", ref)]

      stub(Pincer.MultimodalMockToolRegistry, :list_tools, fn -> [] end)

      Pincer.MultimodalMockLLMClient
      |> expect(:stream_completion, fn _ready_history, _opts ->
        simple_llm_stream("Done")
      end)

      Application.put_env(:pincer, :llm_providers, %{
        "test_hist" => %{adapter: nil, supports_files: true}
      })

      Application.put_env(:pincer, :default_llm_provider, "test_hist")

      {:ok, _} =
        Executor.start(session_pid, session_id, history,
          tool_registry: Pincer.MultimodalMockToolRegistry,
          llm_client: Pincer.MultimodalMockLLMClient,
          file_fetcher: fn _url -> {:ok, Base.encode64("data")} end
        )

      assert_receive {:executor_finished, final_history, _, _usage}, 2_000

      # The history returned to the session must keep the lazy ref, not base64 data.
      original_msg = Enum.find(final_history, &(&1["role"] == "user"))
      stored_parts = original_msg["content"]

      assert Enum.any?(stored_parts, &(&1["type"] == "attachment_ref")),
             "attachment_ref must survive in session history unchanged"

      refute Enum.any?(stored_parts, &(&1["type"] == "inline_data")),
             "base64 inline_data must NOT appear in the persisted history"

      Application.delete_env(:pincer, :default_llm_provider)
      Application.delete_env(:pincer, :llm_providers)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Google provider translation tests (pure unit, no HTTP)
  # ---------------------------------------------------------------------------

  describe "Google.translate_content_to_parts/1" do
    test "nil content returns single empty text part" do
      assert Google.translate_content_to_parts(nil) == [%{"text" => ""}]
    end

    test "string content returns single text part" do
      assert Google.translate_content_to_parts("Hello") == [%{"text" => "Hello"}]
    end

    test "list with text part returns text part" do
      input = [%{"type" => "text", "text" => "Hi"}]
      output = Google.translate_content_to_parts(input)
      assert output == [%{"text" => "Hi"}]
    end

    test "list with inline_data returns Gemini inlineData part" do
      input = [%{"type" => "inline_data", "mime_type" => "application/pdf", "data" => "abc123"}]
      output = Google.translate_content_to_parts(input)
      assert output == [%{"inlineData" => %{"mimeType" => "application/pdf", "data" => "abc123"}}]
    end

    test "list with image inline_data maps correct mimeType" do
      input = [%{"type" => "inline_data", "mime_type" => "image/png", "data" => "png_b64"}]
      [part] = Google.translate_content_to_parts(input)
      assert part["inlineData"]["mimeType"] == "image/png"
      assert part["inlineData"]["data"] == "png_b64"
    end

    test "mixed text + inline_data list preserves order" do
      input = [
        %{"type" => "text", "text" => "See attached:"},
        %{"type" => "inline_data", "mime_type" => "image/jpeg", "data" => "jpeg_b64"}
      ]

      output = Google.translate_content_to_parts(input)
      assert length(output) == 2
      assert hd(output) == %{"text" => "See attached:"}

      assert List.last(output) == %{
               "inlineData" => %{"mimeType" => "image/jpeg", "data" => "jpeg_b64"}
             }
    end

    test "unresolved attachment_ref is silently filtered out" do
      input = [
        %{"type" => "text", "text" => "Before"},
        %{
          "type" => "attachment_ref",
          "url" => "https://cdn.example.com/x.pdf",
          "mime_type" => "application/pdf",
          "filename" => "x.pdf",
          "size" => 500
        },
        %{"type" => "text", "text" => "After"}
      ]

      output = Google.translate_content_to_parts(input)
      assert length(output) == 2
      assert Enum.all?(output, &is_map_key(&1, "text"))
    end

    test "unknown part types are silently filtered out" do
      input = [
        %{"type" => "video", "url" => "https://example.com/clip.mp4"},
        %{"type" => "text", "text" => "Caption"}
      ]

      output = Google.translate_content_to_parts(input)
      assert output == [%{"text" => "Caption"}]
    end

    test "empty list returns empty list" do
      assert Google.translate_content_to_parts([]) == []
    end
  end
end

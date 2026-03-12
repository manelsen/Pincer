defmodule Pincer.Adapters.Tools.BrowserTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.Browser

  # ---------------------------------------------------------------------------
  # Stub pool — replaces Pincer.Adapters.Browser.Pool
  # ---------------------------------------------------------------------------
  defmodule StubPool do
    @pt_key :browser_stub_pool_pid

    def register(pid), do: :persistent_term.put(@pt_key, pid)
    def unregister, do: :persistent_term.erase(@pt_key)
    defp notify(msg), do: if(pid = :persistent_term.get(@pt_key, nil), do: send(pid, msg))

    def cmd(session_id, command, args \\ %{}) do
      notify({:cmd, session_id, command, args})
      stub_response(command, args)
    end

    def close_session(session_id) do
      notify({:close_session, session_id})
      {:ok, "closed"}
    end

    defp stub_response("navigate", %{"url" => url}) do
      {:ok, "Navigated to #{url}\nTitle: Test Page"}
    end

    defp stub_response("click", %{"selector" => sel}), do: {:ok, "Clicked: #{sel}"}
    defp stub_response("fill", %{"selector" => sel}), do: {:ok, "Filled #{sel}"}
    defp stub_response("press", %{"key" => key, "selector" => sel}), do: {:ok, "Pressed #{key} on #{sel}"}
    defp stub_response("select", %{"value" => v, "selector" => sel}), do: {:ok, "Selected '#{v}' in #{sel}"}
    defp stub_response("screenshot", %{"path" => p}), do: {:ok, "Screenshot saved to #{p}"}
    defp stub_response("screenshot_inline", _), do: {:ok, Base.encode64("fake-png-bytes")}
    defp stub_response("text", _), do: {:ok, "Hello World"}
    defp stub_response("attribute", _), do: {:ok, "attr-value"}
    defp stub_response("evaluate", %{"expression" => expr}), do: {:ok, ~s("eval:#{expr}")}
    defp stub_response("content", _), do: {:ok, "<html><body>test</body></html>"}
    defp stub_response("close", _), do: {:ok, "closed"}
    defp stub_response(cmd, _), do: {:error, "Unknown command: #{cmd}"}
  end

  setup do
    StubPool.register(self())
    prev = Application.get_env(:pincer, :browser_pool)
    Application.put_env(:pincer, :browser_pool, StubPool)

    on_exit(fn ->
      StubPool.unregister()

      case prev do
        nil -> Application.delete_env(:pincer, :browser_pool)
        v -> Application.put_env(:pincer, :browser_pool, v)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # spec/0 contract
  # ---------------------------------------------------------------------------

  test "spec/0 returns a valid tool spec" do
    spec = Browser.spec()
    assert spec.name == "browser"
    assert is_binary(spec.description)
    actions = get_in(spec, [:parameters, :properties, :action, :enum])
    assert "navigate" in actions
    assert "click" in actions
    assert "fill" in actions
    assert "press" in actions
    assert "select" in actions
    assert "screenshot" in actions
    assert "screenshot_inline" in actions
    assert "extract_text" in actions
    assert "get_attribute" in actions
    assert "evaluate" in actions
    assert "content" in actions
    assert "close_session" in actions
  end

  test "spec/0 marks 'action' as required" do
    assert "action" in get_in(Browser.spec(), [:parameters, :required])
  end

  # ---------------------------------------------------------------------------
  # Missing-parameter error paths
  # ---------------------------------------------------------------------------

  test "navigate without url returns error" do
    assert {:error, msg} = Browser.execute(%{"action" => "navigate", "session_id" => "s"})
    assert msg =~ "url"
  end

  test "click without selector returns error" do
    assert {:error, msg} = Browser.execute(%{"action" => "click", "session_id" => "s"})
    assert msg =~ "selector"
  end

  test "fill without params returns error" do
    assert {:error, msg} = Browser.execute(%{"action" => "fill", "session_id" => "s"})
    assert msg =~ "selector"
  end

  test "press without params returns error" do
    assert {:error, msg} = Browser.execute(%{"action" => "press", "session_id" => "s"})
    assert msg =~ "selector"
  end

  test "get_attribute without params returns error" do
    assert {:error, msg} = Browser.execute(%{"action" => "get_attribute", "session_id" => "s"})
    assert msg =~ "selector"
  end

  test "evaluate without expression returns error" do
    assert {:error, msg} = Browser.execute(%{"action" => "evaluate", "session_id" => "s"})
    assert msg =~ "expression"
  end

  test "unknown action returns descriptive error" do
    assert {:error, msg} = Browser.execute(%{"action" => "teleport", "session_id" => "s"})
    assert msg =~ "teleport"
  end

  # ---------------------------------------------------------------------------
  # Happy-path delegations to stub pool
  # ---------------------------------------------------------------------------

  test "navigate delegates to pool with url" do
    assert {:ok, text} =
             Browser.execute(%{"action" => "navigate", "url" => "https://example.com", "session_id" => "sess1"})

    assert text =~ "example.com"
    assert_received {:cmd, "sess1", "navigate", %{"url" => "https://example.com"}}
  end

  test "click delegates selector to pool" do
    assert {:ok, text} =
             Browser.execute(%{"action" => "click", "selector" => "button#ok", "session_id" => "s"})

    assert text =~ "button#ok"
    assert_received {:cmd, "s", "click", %{"selector" => "button#ok"}}
  end

  test "fill delegates selector and value to pool" do
    assert {:ok, _} =
             Browser.execute(%{
               "action" => "fill",
               "selector" => "input#name",
               "value" => "Alice",
               "session_id" => "s"
             })

    assert_received {:cmd, "s", "fill", %{"selector" => "input#name", "value" => "Alice"}}
  end

  test "press delegates selector and key to pool" do
    assert {:ok, _} =
             Browser.execute(%{
               "action" => "press",
               "selector" => "input",
               "key" => "Enter",
               "session_id" => "s"
             })

    assert_received {:cmd, "s", "press", %{"selector" => "input", "key" => "Enter"}}
  end

  test "select delegates selector and value to pool" do
    assert {:ok, _} =
             Browser.execute(%{
               "action" => "select",
               "selector" => "select#lang",
               "value" => "en",
               "session_id" => "s"
             })

    assert_received {:cmd, "s", "select", %{"selector" => "select#lang", "value" => "en"}}
  end

  test "screenshot uses default path when not specified" do
    assert {:ok, text} =
             Browser.execute(%{"action" => "screenshot", "session_id" => "s"})

    assert text =~ "screenshot.png"
    assert_received {:cmd, "s", "screenshot", %{"path" => "screenshots/screenshot.png"}}
  end

  test "screenshot uses custom path when specified" do
    assert {:ok, _} =
             Browser.execute(%{
               "action" => "screenshot",
               "screenshot_path" => "custom/path.png",
               "session_id" => "s"
             })

    assert_received {:cmd, "s", "screenshot", %{"path" => "custom/path.png"}}
  end

  test "extract_text defaults to body selector" do
    assert {:ok, text} = Browser.execute(%{"action" => "extract_text", "session_id" => "s"})
    assert is_binary(text)
    assert_received {:cmd, "s", "text", %{"selector" => "body"}}
  end

  test "extract_text uses explicit selector" do
    assert {:ok, _} =
             Browser.execute(%{
               "action" => "extract_text",
               "selector" => "h1",
               "session_id" => "s"
             })

    assert_received {:cmd, "s", "text", %{"selector" => "h1"}}
  end

  test "get_attribute delegates selector and attribute" do
    assert {:ok, _} =
             Browser.execute(%{
               "action" => "get_attribute",
               "selector" => "a",
               "attribute" => "href",
               "session_id" => "s"
             })

    assert_received {:cmd, "s", "attribute", %{"selector" => "a", "attr" => "href"}}
  end

  test "evaluate delegates expression to pool" do
    assert {:ok, _} =
             Browser.execute(%{
               "action" => "evaluate",
               "expression" => "document.title",
               "session_id" => "s"
             })

    assert_received {:cmd, "s", "evaluate", %{"expression" => "document.title"}}
  end

  test "content delegates to pool" do
    assert {:ok, html} = Browser.execute(%{"action" => "content", "session_id" => "s"})
    assert html =~ "<html"
    assert_received {:cmd, "s", "content", _}
  end

  test "close_session delegates to pool" do
    assert {:ok, _} =
             Browser.execute(%{"action" => "close_session", "session_id" => "my_sess"})

    assert_received {:close_session, "my_sess"}
  end

  test "session_id falls back to 'default' when not provided" do
    assert {:ok, _} = Browser.execute(%{"action" => "content"})
    assert_received {:cmd, "default", "content", _}
  end

  test "browser tool appears in its own spec registry" do
    spec = Browser.spec()
    assert spec.name == "browser"
  end

  # ---------------------------------------------------------------------------
  # screenshot_inline
  # ---------------------------------------------------------------------------

  test "screenshot_inline returns list of multimodal parts" do
    assert {:ok, parts} = Browser.execute(%{"action" => "screenshot_inline", "session_id" => "s"})
    assert is_list(parts)
    assert length(parts) == 2

    text_part = Enum.find(parts, &(&1["type"] == "text"))
    assert text_part["text"] =~ "Screenshot"

    image_part = Enum.find(parts, &(&1["type"] == "inline_data"))
    assert image_part["mime_type"] == "image/png"
    assert is_binary(image_part["data"])
    assert image_part["data"] != ""
  end

  test "screenshot_inline sends screenshot_inline command to pool" do
    Browser.execute(%{"action" => "screenshot_inline", "session_id" => "s"})
    assert_received {:cmd, "s", "screenshot_inline", %{}}
  end

  test "screenshot_inline returns error when pool fails" do
    Application.put_env(:pincer, :browser_pool, __MODULE__.ErrorPool)

    assert {:error, _msg} =
             Browser.execute(%{"action" => "screenshot_inline", "session_id" => "s"})
  after
    Application.put_env(:pincer, :browser_pool, StubPool)
  end

  defmodule ErrorPool do
    def cmd(_session_id, _command, _args \\ %{}), do: {:error, "browser not available"}
    def close_session(_session_id), do: {:error, "browser not available"}
  end
end

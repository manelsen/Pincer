defmodule Pincer.Adapters.Tools.Browser do
  @moduledoc """
  Browser automation tool for Pincer agents, powered by a Playwright Node.js sidecar.

  Each Pincer session gets its own browser page managed by
  `Pincer.Adapters.Browser.Pool`. Playwright is controlled via a Port
  process (`priv/browser/server.js`) — no conflicting Elixir dependencies.

  ## Prerequisites

  Node.js and Playwright must be installed in the runtime environment:

      npm install -g playwright
      npx playwright install chromium

  Enable the browser pool in config:

      config :pincer, :enable_browser, true

  ## Actions

  | Action          | Required params         | Description                             |
  |-----------------|-------------------------|-----------------------------------------|
  | `navigate`      | `url`                   | Navigate to a URL                       |
  | `click`         | `selector`              | Click an element                        |
  | `fill`          | `selector`, `value`     | Fill an input field                     |
  | `press`         | `selector`, `key`       | Press a keyboard key on an element      |
  | `select`        | `selector`, `value`     | Select an option from a `<select>`      |
  | `screenshot`    | —                       | Save a PNG screenshot to workspace      |
  | `screenshot_inline` | —                   | Take a screenshot and return it inline so the LLM can see it (multimodal) |
  | `extract_text`  | `selector` (optional)   | Get visible text content                |
  | `get_attribute` | `selector`, `attribute` | Get an attribute value                  |
  | `evaluate`      | `expression`            | Run a JavaScript expression             |
  | `content`       | —                       | Get the full HTML source                |
  | `close_session` | —                       | Close the browser page for this session |

  """
  @behaviour Pincer.Ports.Tool

  @impl true
  def spec do
    if Application.get_env(:pincer, :enable_browser, false) do
      %{
        name: "browser",
        description:
          "Controls an interactive browser session for sites that require navigation, clicks, form filling, screenshots, or dynamic page interaction. Prefer lighter web tools for simple search/fetch tasks.",
        parameters: %{
          type: "object",
          properties: %{
            action: %{
              type: "string",
              description:
                "Action to perform: 'navigate', 'click', 'fill', 'press', 'select', 'screenshot', 'extract_text', 'get_attribute', 'evaluate', 'content', or 'close_session'",
              enum: [
                "navigate",
                "click",
                "fill",
                "press",
                "select",
                "screenshot",
                "screenshot_inline",
                "extract_text",
                "get_attribute",
                "evaluate",
                "content",
                "close_session"
              ]
            },
            url: %{
              type: "string",
              description: "URL to navigate to (required for 'navigate')"
            },
            selector: %{
              type: "string",
              description:
                "CSS or XPath selector (required for 'click', 'fill', 'press', 'select', 'get_attribute'; optional for 'extract_text')"
            },
            value: %{
              type: "string",
              description: "Value to fill or option to select (required for 'fill', 'select')"
            },
            key: %{
              type: "string",
              description: "Key to press, e.g. 'Enter', 'Tab', 'Escape' (required for 'press')"
            },
            attribute: %{
              type: "string",
              description: "HTML attribute name to retrieve (required for 'get_attribute')"
            },
            expression: %{
              type: "string",
              description: "JavaScript expression to evaluate (required for 'evaluate')"
            },
            screenshot_path: %{
              type: "string",
              description:
                "Relative file path within workspace for the screenshot (default: 'screenshots/screenshot.png'). Only used by 'screenshot', not 'screenshot_inline'."
            }
          },
          required: ["action"]
        }
      }
    else
      []
    end
  end

  @impl true
  def execute(%{"action" => action} = args, context \\ %{}) do
    session_id = Map.get(args, "session_id") || Map.get(context, "session_id") || "default"
    pool = Application.get_env(:pincer, :browser_pool, Pincer.Adapters.Browser.Pool)

    try do
      run_action(action, session_id, args, pool)
    catch
      :exit, {:noproc, _} ->
        {:error, "browser pool unavailable: process not started"}

      :exit, reason ->
        {:error, "browser pool unavailable: #{Exception.format_exit(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Action dispatchers
  # ---------------------------------------------------------------------------

  defp run_action("navigate", sid, %{"url" => url}, pool) do
    pool.cmd(sid, "navigate", %{"url" => url})
  end

  defp run_action("navigate", _sid, _args, _pool),
    do: {:error, "Missing required parameter: url"}

  defp run_action("click", sid, %{"selector" => sel}, pool) do
    pool.cmd(sid, "click", %{"selector" => sel})
  end

  defp run_action("click", _sid, _args, _pool),
    do: {:error, "Missing required parameter: selector"}

  defp run_action("fill", sid, %{"selector" => sel, "value" => val}, pool) do
    pool.cmd(sid, "fill", %{"selector" => sel, "value" => val})
  end

  defp run_action("fill", _sid, _args, _pool),
    do: {:error, "Missing required parameters: selector, value"}

  defp run_action("press", sid, %{"selector" => sel, "key" => key}, pool) do
    pool.cmd(sid, "press", %{"selector" => sel, "key" => key})
  end

  defp run_action("press", _sid, _args, _pool),
    do: {:error, "Missing required parameters: selector, key"}

  defp run_action("select", sid, %{"selector" => sel, "value" => val}, pool) do
    pool.cmd(sid, "select", %{"selector" => sel, "value" => val})
  end

  defp run_action("select", _sid, _args, _pool),
    do: {:error, "Missing required parameters: selector, value"}

  defp run_action("screenshot", sid, args, pool) do
    screenshot_path = Map.get(args, "screenshot_path", "screenshots/screenshot.png")
    pool.cmd(sid, "screenshot", %{"path" => screenshot_path})
  end

  defp run_action("screenshot_inline", sid, _args, pool) do
    case pool.cmd(sid, "screenshot_inline", %{}) do
      {:ok, base64} ->
        {:ok,
         [
           %{"type" => "text", "text" => "Screenshot captured. The image is shown below."},
           %{"type" => "inline_data", "mime_type" => "image/png", "data" => base64}
         ]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_action("extract_text", sid, args, pool) do
    selector = Map.get(args, "selector", "body")
    pool.cmd(sid, "text", %{"selector" => selector})
  end

  defp run_action("get_attribute", sid, %{"selector" => sel, "attribute" => attr}, pool) do
    pool.cmd(sid, "attribute", %{"selector" => sel, "attr" => attr})
  end

  defp run_action("get_attribute", _sid, _args, _pool),
    do: {:error, "Missing required parameters: selector, attribute"}

  defp run_action("evaluate", sid, %{"expression" => expr}, pool) do
    pool.cmd(sid, "evaluate", %{"expression" => expr})
  end

  defp run_action("evaluate", _sid, _args, _pool),
    do: {:error, "Missing required parameter: expression"}

  defp run_action("content", sid, _args, pool) do
    pool.cmd(sid, "content")
  end

  defp run_action("close_session", sid, _args, pool) do
    pool.close_session(sid)
  end

  defp run_action(unknown, _sid, _args, _pool),
    do: {:error, "Unknown browser action: #{unknown}"}
end

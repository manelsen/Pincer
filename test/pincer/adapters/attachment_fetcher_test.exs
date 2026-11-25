defmodule Pincer.Adapters.AttachmentFetcherTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.AttachmentFetcher

  test "returns raw bytes from a pinned public URL with a bounded response" do
    http_client = fn "https://93.184.216.34/file.txt", opts ->
      assert opts[:connect_options][:hostname] == "93.184.216.34"
      assert {"Host", "93.184.216.34"} in opts[:headers]
      assert opts[:decode_body] == false
      assert opts[:redirect] == false
      assert is_function(opts[:into], 2)
      {:ok, %Req.Response{status: 200, body: "attachment-body"}}
    end

    assert {:ok, "attachment-body"} =
             AttachmentFetcher.fetch("https://93.184.216.34/file.txt", {:inline, 128},
               http_client: http_client
             )
  end

  test "rejects invalid and internal links before downloading" do
    http_client = fn _url, _opts -> flunk("must not fetch a rejected URL") end

    assert {:error, :invalid_attachment_url} =
             AttachmentFetcher.fetch(nil, {:inline, 128}, http_client: http_client)

    assert {:error, reason} =
             AttachmentFetcher.fetch("http://127.0.0.1/file.txt", {:inline, 128},
               http_client: http_client
             )

    assert reason =~ "internal hosts"
  end

  test "follows public inline redirects with a freshly pinned destination" do
    http_client = fn
      "https://93.184.216.34/start", _opts ->
        {:ok,
         Req.Response.new(status: 302, headers: [{"location", "https://93.184.216.35/file"}])}

      "https://93.184.216.35/file", opts ->
        assert opts[:connect_options][:hostname] == "93.184.216.35"
        assert {"Host", "93.184.216.35"} in opts[:headers]
        {:ok, %Req.Response{status: 200, body: "redirected"}}
    end

    assert {:ok, "redirected"} =
             AttachmentFetcher.fetch("https://93.184.216.34/start", {:inline, 128},
               http_client: http_client
             )
  end

  test "halts oversized downloads while streaming" do
    http_client = fn _url, opts ->
      response = %Req.Response{status: 200, body: ""}
      assert {:halt, {nil, response}} = opts[:into].({:data, "too large"}, {nil, response})
      {:ok, response}
    end

    assert {:error, :attachment_too_large} =
             AttachmentFetcher.fetch("https://93.184.216.34/huge.bin", {:inline, 4},
               http_client: http_client
             )
  end

  test "resolves an existing Telegram reference using the configured token" do
    with_env(:telegex, :token, "test_token")

    with_env(:pincer, :network_guard_resolver, fn "api.telegram.org" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    workspace_client = fn "https://api.telegram.org/file/bottest_token/docs/a.txt", opts ->
      assert opts[:receive_timeout] == 300_000
      assert opts[:redirect] == false
      {:ok, %Req.Response{status: 200, body: "file contents"}}
    end

    inline_client = fn "https://93.184.216.34/file/bottest_token/docs/a.txt", opts ->
      assert opts[:connect_options][:hostname] == "api.telegram.org"
      assert {"Host", "api.telegram.org"} in opts[:headers]
      {:ok, %Req.Response{status: 200, body: "file contents"}}
    end

    reference = "telegram://file/docs/a.txt"

    assert {:ok, "file contents"} =
             AttachmentFetcher.fetch(reference, :workspace, http_client: workspace_client)

    assert {:ok, "file contents"} =
             AttachmentFetcher.fetch(reference, {:inline, 128}, http_client: inline_client)
  end

  test "returns errors for a missing token, an unsupported workspace reference, and HTTP failure" do
    assert {:error, :telegram_token_missing} =
             AttachmentFetcher.fetch("telegram://file/docs/a.txt", :workspace, telegram_token: "")

    assert {:error, :unsupported_url} =
             AttachmentFetcher.fetch("https://93.184.216.34/file.txt", :workspace)

    assert {:error, {:http_error, 404}} =
             AttachmentFetcher.fetch("telegram://file/docs/a.txt", :workspace,
               telegram_token: "test_token",
               http_client: fn _, _ -> {:ok, %Req.Response{status: 404}} end
             )
  end

  defp with_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, previous_value} -> Application.put_env(app, key, previous_value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end

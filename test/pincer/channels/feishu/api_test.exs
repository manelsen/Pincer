defmodule Pincer.Channels.Feishu.APITest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Feishu.API
  alias Pincer.Channels.Shared.TokenCache

  @test_token "test-tenant-token"

  setup do
    # Start a TokenCache with a static fetch_fn for testing
    cache_name = :"feishu_test_cache_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      TokenCache.start_link(
        name: cache_name,
        fetch_fn: fn ->
          {:ok, @test_token, System.system_time(:second) + 3600}
        end
      )

    on_exit(fn ->
      if pid = Process.whereis(cache_name) do
        GenServer.stop(pid, :shutdown)
      end
    end)

    %{cache_name: cache_name}
  end

  describe "base_url/0" do
    test "defaults to open.feishu.cn" do
      # Clear any env override
      original = Application.get_env(:pincer, :feishu_base_url)
      Application.delete_env(:pincer, :feishu_base_url)

      assert API.base_url() == "https://open.feishu.cn"

      if original do
        Application.put_env(:pincer, :feishu_base_url, original)
      end
    end

    test "can be overridden for Lark (international)" do
      original = Application.get_env(:pincer, :feishu_base_url)

      Application.put_env(:pincer, :feishu_base_url, "https://open.larksuite.com")
      assert API.base_url() == "https://open.larksuite.com"

      if original do
        Application.put_env(:pincer, :feishu_base_url, original)
      else
        Application.delete_env(:pincer, :feishu_base_url)
      end
    end
  end

  describe "build_request/3 for POST" do
    test "send_message builds correct URL, body, and auth header", %{cache_name: cache_name} do
      receive_id = "ou_abc123"
      content = ~s({"text":"hello"})
      msg_type = "text"

      {url, opts} =
        API.build_request(
          :post,
          "#{API.base_url()}/im/v1/messages?receive_id_type=open_id",
          %{
            "receive_id" => receive_id,
            "msg_type" => msg_type,
            "content" => content
          },
          cache_name
        )

      assert url == "#{API.base_url()}/im/v1/messages?receive_id_type=open_id"

      body = Keyword.get(opts, :json)
      assert body["receive_id"] == receive_id
      assert body["msg_type"] == msg_type
      assert body["content"] == content

      headers = Keyword.get(opts, :headers, [])
      assert {"Authorization", "Bearer #{@test_token}"} in headers
    end

    test "reply_message builds correct URL with message_id interpolated", %{
      cache_name: cache_name
    } do
      message_id = "om_msg456"
      content = ~s({"text":"reply"})
      msg_type = "text"

      {url, opts} =
        API.build_request(
          :post,
          "#{API.base_url()}/im/v1/messages/#{message_id}/reply",
          %{
            "msg_type" => msg_type,
            "content" => content
          },
          cache_name
        )

      assert url == "#{API.base_url()}/im/v1/messages/#{message_id}/reply"

      body = Keyword.get(opts, :json)
      assert body["msg_type"] == msg_type
      assert body["content"] == content
      refute Map.has_key?(body, "receive_id")

      headers = Keyword.get(opts, :headers, [])
      assert {"Authorization", "Bearer #{@test_token}"} in headers
    end
  end

  describe "build_request/3 for PATCH" do
    test "update_card builds correct PATCH request", %{cache_name: cache_name} do
      card_token = "card_tok_789"
      new_content = %{"config" => %{"wide_screen_mode" => true}, "elements" => []}

      {url, opts} =
        API.build_request(
          :patch,
          "#{API.base_url()}/interactive/v1/card/update",
          %{"token" => card_token, "card" => new_content},
          cache_name
        )

      assert url == "#{API.base_url()}/interactive/v1/card/update"

      body = Keyword.get(opts, :json)
      assert body["token"] == card_token
      assert body["card"] == new_content

      headers = Keyword.get(opts, :headers, [])
      assert {"Authorization", "Bearer #{@test_token}"} in headers
    end
  end

  describe "get_tenant_token/1" do
    test "returns token from TokenCache", %{cache_name: cache_name} do
      assert {:ok, @test_token} = API.get_tenant_token(cache_name)
    end
  end
end

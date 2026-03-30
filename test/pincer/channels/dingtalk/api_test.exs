defmodule Pincer.Channels.DingTalk.APITest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.DingTalk.API

  @token "test-dingtalk-access-token"

  setup do
    original_id = System.get_env("DINGTALK_CLIENT_ID")
    original_secret = System.get_env("DINGTALK_CLIENT_SECRET")
    original_token = System.get_env("DINGTALK_ACCESS_TOKEN")

    System.put_env("DINGTALK_CLIENT_ID", "test-client-id")
    System.put_env("DINGTALK_CLIENT_SECRET", "test-client-secret")
    System.put_env("DINGTALK_ACCESS_TOKEN", @token)

    on_exit(fn ->
      if original_id,
        do: System.put_env("DINGTALK_CLIENT_ID", original_id),
        else: System.delete_env("DINGTALK_CLIENT_ID")

      if original_secret,
        do: System.put_env("DINGTALK_CLIENT_SECRET", original_secret),
        else: System.delete_env("DINGTALK_CLIENT_SECRET")

      if original_token,
        do: System.put_env("DINGTALK_ACCESS_TOKEN", original_token),
        else: System.delete_env("DINGTALK_ACCESS_TOKEN")
    end)

    :ok
  end

  describe "build_request/3 for POST" do
    test "send_dm builds correct URL, body, and auth header" do
      user_ids = ["user1", "user2"]
      msg_key = "sampleMarkdown"
      message = "Hello from DingTalk"

      body = %{
        "userIds" => user_ids,
        "msgKey" => msg_key,
        "msgParam" => message
      }

      {url, opts} =
        API.build_request(
          :post,
          "https://oapi.dingtalk.com/v1.0/robot/oToMessages/batchSend",
          body
        )

      assert url == "https://oapi.dingtalk.com/v1.0/robot/oToMessages/batchSend"
      assert Keyword.get(opts, :json) == body

      headers = Keyword.get(opts, :headers, [])
      assert {"x-acs-dingtalk-access-token", @token} in headers
    end

    test "send_group builds correct URL, body, and auth header" do
      conversation_id = "cid_abc123"
      msg_key = "sampleMarkdown"
      message = "Group message"

      body = %{
        "conversationId" => conversation_id,
        "msgKey" => msg_key,
        "msgParam" => message
      }

      {url, opts} =
        API.build_request(
          :post,
          "https://oapi.dingtalk.com/v1.0/robot/groupMessages/send",
          body
        )

      assert url == "https://oapi.dingtalk.com/v1.0/robot/groupMessages/send"
      assert Keyword.get(opts, :json) == body

      headers = Keyword.get(opts, :headers, [])
      assert {"x-acs-dingtalk-access-token", @token} in headers
    end

    test "create_card builds correct URL and body" do
      content = %{"text" => "card content"}
      config = %{"cardTemplateId" => "tpl_001"}

      body = %{
        "cardData" => %{"cardParamMap" => content},
        "cardTemplateId" => config["cardTemplateId"]
      }

      {url, opts} =
        API.build_request(
          :post,
          "https://oapi.dingtalk.com/v1.0/card/instances",
          body
        )

      assert url == "https://oapi.dingtalk.com/v1.0/card/instances"
      assert Keyword.get(opts, :json) == body

      headers = Keyword.get(opts, :headers, [])
      assert {"x-acs-dingtalk-access-token", @token} in headers
    end
  end

  describe "build_request/3 for PUT" do
    test "update_card builds correct URL and body" do
      card_instance_id = "inst_abc123"
      new_content = %{"text" => "updated card"}

      body = %{
        "cardData" => %{"cardParamMap" => new_content}
      }

      {url, opts} =
        API.build_request(
          :put,
          "https://oapi.dingtalk.com/v1.0/card/instances/#{card_instance_id}",
          body
        )

      assert url == "https://oapi.dingtalk.com/v1.0/card/instances/#{card_instance_id}"
      assert Keyword.get(opts, :json) == body

      headers = Keyword.get(opts, :headers, [])
      assert {"x-acs-dingtalk-access-token", @token} in headers
    end
  end

  describe "auth header" do
    test "uses x-acs-dingtalk-access-token header, not Bearer" do
      {_url, opts} =
        API.build_request(
          :post,
          "https://oapi.dingtalk.com/v1.0/robot/oToMessages/batchSend",
          %{}
        )

      headers = Keyword.get(opts, :headers, [])

      assert {"x-acs-dingtalk-access-token", @token} in headers

      refute Enum.any?(headers, fn {k, v} ->
               k == "Authorization" and String.contains?(v, "Bearer")
             end)
    end
  end

  describe "base URL" do
    test "all endpoints use oapi.dingtalk.com" do
      endpoints = [
        "https://oapi.dingtalk.com/v1.0/robot/oToMessages/batchSend",
        "https://oapi.dingtalk.com/v1.0/robot/groupMessages/send",
        "https://oapi.dingtalk.com/v1.0/card/instances",
        "https://oapi.dingtalk.com/v1.0/card/instances/inst_123"
      ]

      for url <- endpoints do
        {resolved_url, _opts} = API.build_request(:post, url, %{})
        assert String.starts_with?(resolved_url, "https://oapi.dingtalk.com")
      end
    end
  end

  describe "fetch_token/0" do
    test "returns token from environment variable" do
      token = API.fetch_token()
      assert token == @token
    end
  end

  describe "send_dm request shape" do
    test "builds correct body with user_ids list, msg_key, and msg_param" do
      user_ids = ["user_a", "user_b"]
      message = ~s({"title":"Hello","text":"world"})
      msg_key = "sampleMarkdown"

      {url, opts} =
        API.build_request(
          :post,
          "https://oapi.dingtalk.com/v1.0/robot/oToMessages/batchSend",
          %{
            "userIds" => user_ids,
            "msgKey" => msg_key,
            "msgParam" => message
          }
        )

      assert url =~ "/v1.0/robot/oToMessages/batchSend"
      body = Keyword.get(opts, :json)
      assert body["userIds"] == user_ids
      assert body["msgKey"] == msg_key
      assert body["msgParam"] == message
    end
  end

  describe "send_group request shape" do
    test "builds correct body with conversation_id, msg_key, and msg_param" do
      conversation_id = "cid_xyz"
      message = ~s({"title":"Group","text":"msg"})
      msg_key = "sampleMarkdown"

      {url, opts} =
        API.build_request(
          :post,
          "https://oapi.dingtalk.com/v1.0/robot/groupMessages/send",
          %{
            "conversationId" => conversation_id,
            "msgKey" => msg_key,
            "msgParam" => message
          }
        )

      assert url =~ "/v1.0/robot/groupMessages/send"
      body = Keyword.get(opts, :json)
      assert body["conversationId"] == conversation_id
      assert body["msgKey"] == msg_key
      assert body["msgParam"] == message
    end
  end
end

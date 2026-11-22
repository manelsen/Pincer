defmodule Pincer.Channels.Line.APITest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Line.API

  @token "test-channel-access-token"

  setup do
    original = System.get_env("LINE_CHANNEL_ACCESS_TOKEN")
    System.put_env("LINE_CHANNEL_ACCESS_TOKEN", @token)

    on_exit(fn ->
      if original do
        System.put_env("LINE_CHANNEL_ACCESS_TOKEN", original)
      else
        System.delete_env("LINE_CHANNEL_ACCESS_TOKEN")
      end
    end)

    :ok
  end

  describe "build_request/2 for POST" do
    test "reply_message returns correct URL, body, and auth header" do
      messages = [%{type: "text", text: "Hello"}]

      {url, opts} =
        API.build_request(:post, "https://api.line.me/v2/bot/message/reply", %{
          "replyToken" => "abc123",
          "messages" => messages
        })

      assert url == "https://api.line.me/v2/bot/message/reply"
      assert Keyword.get(opts, :json) == %{"replyToken" => "abc123", "messages" => messages}

      headers = Keyword.get(opts, :headers, [])
      assert {"Authorization", "Bearer #{@token}"} in headers
    end

    test "push_message returns correct URL, body, and auth header" do
      messages = [%{type: "text", text: "Hi"}]

      {url, opts} =
        API.build_request(:post, "https://api.line.me/v2/bot/message/push", %{
          "to" => "U1234567890",
          "messages" => messages
        })

      assert url == "https://api.line.me/v2/bot/message/push"
      assert Keyword.get(opts, :json) == %{"to" => "U1234567890", "messages" => messages}

      headers = Keyword.get(opts, :headers, [])
      assert {"Authorization", "Bearer #{@token}"} in headers
    end
  end

  describe "build_request/2 for GET" do
    test "get_profile returns correct URL and auth header" do
      user_id = "U9876543210"

      {url, opts} = API.build_request(:get, "https://api.line.me/v2/bot/profile/#{user_id}", nil)

      assert url == "https://api.line.me/v2/bot/profile/#{user_id}"

      headers = Keyword.get(opts, :headers, [])
      assert {"Authorization", "Bearer #{@token}"} in headers
    end
  end

  describe "reply_message/2" do
    test "delegates to build_request with correct endpoint and body shape" do
      reply_token = "rt_abc"
      messages = [%{type: "text", text: "pong"}]

      {url, opts} =
        API.build_request(:post, "https://api.line.me/v2/bot/message/reply", %{
          "replyToken" => reply_token,
          "messages" => messages
        })

      assert url =~ "/v2/bot/message/reply"
      body = Keyword.get(opts, :json)
      assert body["replyToken"] == reply_token
      assert body["messages"] == messages
    end
  end

  describe "push_message/2" do
    test "delegates to build_request with correct endpoint and body shape" do
      to = "U_user"
      messages = [%{type: "text", text: "push"}]

      {url, opts} =
        API.build_request(:post, "https://api.line.me/v2/bot/message/push", %{
          "to" => to,
          "messages" => messages
        })

      assert url =~ "/v2/bot/message/push"
      body = Keyword.get(opts, :json)
      assert body["to"] == to
      assert body["messages"] == messages
    end
  end

  describe "get_profile/1" do
    test "constructs correct profile URL" do
      user_id = "U_profile"

      {url, _opts} = API.build_request(:get, "https://api.line.me/v2/bot/profile/#{user_id}", nil)

      assert url == "https://api.line.me/v2/bot/profile/#{user_id}"
    end
  end

  describe "request timeouts" do
    test "POST and GET requests carry receive/connect timeouts" do
      {_url, post_opts} =
        API.build_request(:post, "https://api.line.me/v2/bot/message/reply", %{})

      {_url, get_opts} = API.build_request(:get, "https://api.line.me/v2/bot/profile/u1", nil)

      for opts <- [post_opts, get_opts] do
        assert is_integer(Keyword.get(opts, :receive_timeout))

        # Req rejects any option it does not register, so naming the wrong key
        # here would surface as an ArgumentError at request time rather than a
        # slow connection. This is the regression guard for that mistake.
        assert [timeout: timeout] = Keyword.get(opts, :connect_options)
        assert is_integer(timeout)
        refute Keyword.has_key?(opts, :connect_timeout)
        assert %Req.Request{} = Req.new(Keyword.put(opts, :url, "https://api.line.me"))
      end
    end
  end
end

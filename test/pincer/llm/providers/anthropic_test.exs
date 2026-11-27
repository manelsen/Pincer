defmodule Pincer.LLM.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias Pincer.LLM.Providers.Anthropic

  test "config[:thinking_level] = medium sets thinking in body (mock fallback without api key)" do
    assert {:ok, %{"role" => "assistant", "content" => content}, nil} =
             Anthropic.chat_completion(
               [%{"role" => "user", "content" => "Hello"}],
               "claude-sonnet-5-5",
               %{thinking_level: "medium"},
               []
             )

    assert content =~ "Configure your Anthropic API Key"
  end

  test "list_models/1 falls back to current Claude 5.5 / Fable 5.2 IDs when api_key is absent" do
    assert {:ok, ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2", "claude-haiku-5-5"]} =
             Anthropic.list_models(%{})
  end

  test "list_models/1 queries native /v1/models endpoint with x-api-key and anthropic-version" do
    parent = self()

    {:ok, listen_sock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen_sock)

    payload =
      Jason.encode!(%{
        "data" => [
          %{"id" => "claude-sonnet-5-5"},
          %{"id" => "claude-opus-5-5"}
        ]
      })

    Task.start_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen_sock, 5_000)
      {:ok, request} = :gen_tcp.recv(sock, 0, 5_000)
      send(parent, {:anthropic_models_request, request})

      response =
        "HTTP/1.1 200 OK\r\n" <>
          "content-type: application/json\r\n" <>
          "content-length: #{byte_size(payload)}\r\n" <>
          "connection: close\r\n\r\n" <>
          payload

      :gen_tcp.send(sock, response)
      :gen_tcp.close(sock)
      :gen_tcp.close(listen_sock)
    end)

    assert {:ok, ["claude-sonnet-5-5", "claude-opus-5-5"]} =
             Anthropic.list_models(%{
               api_key: "sk-ant-test",
               models_url: "http://127.0.0.1:#{port}/v1/models"
             })

    assert_receive {:anthropic_models_request, request}
    assert request =~ "GET /v1/models HTTP/1.1"
    assert String.downcase(request) =~ "x-api-key: sk-ant-test"
    assert String.downcase(request) =~ "anthropic-version: 2023-06-01"
  end
end

defmodule Pincer.Adapters.Tools.WebTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.Web

  defmodule HTTPClientStub do
    def get("https://www.legacy.example", _opts) do
      {:error,
       %Req.TransportError{
         reason:
           {:tls_alert,
            {:handshake_failure,
             ~c"TLS client alert {bad_cert,{hostname_check_failed,{requested,\"www.legacy.example\"}}}"}}
       }}
    end

    def get("http://www.legacy.example", _opts) do
      {:ok,
       %Req.Response{
         status: 301,
         headers: %{"location" => ["http://portal.example/landing"]}
       }}
    end

    def get("http://portal.example/landing", _opts) do
      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"content-type" => ["text/html"]},
         body: "<html><body><h1>Portal Landing</h1><p>Resolved through fallback</p></body></html>"
       }}
    end
  end

  test "spec exposes split web_search and web_fetch tools" do
    specs = Web.spec()

    assert is_list(specs)

    names =
      Enum.map(specs, fn spec ->
        spec[:name] || spec["name"]
      end)

    assert "web_search" in names
    assert "web_fetch" in names
    refute "web" in names
  end

  test "dispatches search via tool_name without legacy action field" do
    assert {:error, msg} = Web.execute(%{"tool_name" => "web_search"})
    assert msg =~ "query"
  end

  test "dispatches fetch via tool_name without legacy action field" do
    assert {:error, msg} =
             Web.execute(%{"tool_name" => "web_fetch", "url" => "http://localhost/admin"})

    assert msg =~ "internal hosts" or msg =~ "not allowed"
  end

  test "web_fetch retries through http when https fails with hostname mismatch" do
    previous_client = Application.get_env(:pincer, :web_http_client)
    Application.put_env(:pincer, :web_http_client, HTTPClientStub)

    on_exit(fn ->
      case previous_client do
        nil -> Application.delete_env(:pincer, :web_http_client)
        client -> Application.put_env(:pincer, :web_http_client, client)
      end
    end)

    assert {:ok, content} =
             Web.execute(%{"tool_name" => "web_fetch", "url" => "https://www.legacy.example"})

    assert content =~ "Portal Landing"
    assert content =~ "Resolved through fallback"
  end
end

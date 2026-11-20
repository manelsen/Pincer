defmodule Pincer.Adapters.Tools.WebTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.Web

  defmodule HTTPClientStub do
    @pt_key :web_test_http_stub_pid

    def register(pid), do: :persistent_term.put(@pt_key, pid)
    def unregister, do: :persistent_term.erase(@pt_key)
    defp notify(msg), do: if(pid = :persistent_term.get(@pt_key, nil), do: send(pid, msg))

    def get("https://www.legacy.example", _opts) do
      notify({:http_get, "https://www.legacy.example"})

      {:error,
       %Req.TransportError{
         reason:
           {:tls_alert,
            {:handshake_failure,
             ~c"TLS client alert {bad_cert,{hostname_check_failed,{requested,\"www.legacy.example\"}}}"}}
       }}
    end

    def get("http://www.legacy.example", _opts) do
      notify({:http_get, "http://www.legacy.example"})

      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"content-type" => ["text/html"]},
         body: "<html><body><h1>Downgraded</h1></body></html>"
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

  test "web_fetch refuses to downgrade https to http on TLS hostname mismatch" do
    HTTPClientStub.register(self())
    previous_client = Application.get_env(:pincer, :web_http_client)
    Application.put_env(:pincer, :web_http_client, HTTPClientStub)

    on_exit(fn ->
      HTTPClientStub.unregister()

      case previous_client do
        nil -> Application.delete_env(:pincer, :web_http_client)
        client -> Application.put_env(:pincer, :web_http_client, client)
      end
    end)

    assert {:error, msg} =
             Web.execute(%{"tool_name" => "web_fetch", "url" => "https://www.legacy.example"})

    assert msg =~ "TLS certificate does not match"
    assert_received {:http_get, "https://www.legacy.example"}
    refute_received {:http_get, "http://www.legacy.example"}
  end
end

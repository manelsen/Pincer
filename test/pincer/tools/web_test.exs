defmodule Pincer.Adapters.Tools.WebTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.Web

  defmodule HTTPClientStub do
    @pt_key :web_test_http_stub_pid

    def register(pid), do: :persistent_term.put(@pt_key, pid)
    def unregister, do: :persistent_term.erase(@pt_key)
    defp notify(msg), do: if(pid = :persistent_term.get(@pt_key, nil), do: send(pid, msg))

    def get(url, opts) do
      notify({:http_get, url, opts})

      case URI.parse(url).path do
        "/redirect" ->
          {:ok,
           %Req.Response{
             status: 302,
             headers: %{"location" => ["http://169.254.169.254/latest/meta-data"]},
             body: ""
           }}

        "/large" ->
          stream_body(opts[:into], [
            "<html><body>" <> String.duplicate("a", 2_000_000) <> "</body></html>",
            "tail"
          ])

        _ ->
          if String.starts_with?(url, "https://") do
            {:error,
             %Req.TransportError{
               reason:
                 {:tls_alert,
                  {:handshake_failure,
                   ~c"TLS client alert {bad_cert,{hostname_check_failed,{requested,\"www.legacy.example\"}}}"}}
             }}
          else
            {:ok,
             %Req.Response{
               status: 200,
               headers: %{"content-type" => ["text/html"]},
               body: "<html><body><h1>Downgraded</h1></body></html>"
             }}
          end
      end
    end

    defp stream_body(into, chunks) do
      {_request, response} =
        Enum.reduce_while(
          chunks,
          {nil, %Req.Response{status: 200, headers: %{"content-type" => ["text/html"]}}},
          fn chunk, {request, response} ->
            notify({:stream_chunk, byte_size(chunk)})

            case into.({:data, chunk}, {request, response}) do
              {:cont, acc} -> {:cont, acc}
              {:halt, acc} -> {:halt, acc}
            end
          end
        )

      {:ok, response}
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
    register_stub()
    stub_public_dns()

    assert {:error, msg} =
             Web.execute(%{"tool_name" => "web_fetch", "url" => "https://www.legacy.example"})

    assert msg =~ "TLS certificate does not match"

    assert_received {:http_get, pinned_url, opts}
    assert pinned_url == "https://93.184.216.34/"
    assert opts[:connect_options][:hostname] == "www.legacy.example"
    refute_received {:http_get, "http://" <> _, _}
  end

  test "web_fetch halts the download once the body cap is exceeded" do
    register_stub()
    stub_public_dns()

    assert {:error, msg} =
             Web.execute(%{
               "tool_name" => "web_fetch",
               "url" => "https://www.legacy.example/large"
             })

    assert msg =~ "exceeds"
    assert_received {:stream_chunk, size}
    assert size > 2_000_000
    refute_received {:stream_chunk, _}
  end

  test "web_fetch rejects redirects to internal addresses before following them" do
    register_stub()
    stub_public_dns()

    assert {:error, msg} =
             Web.execute(%{
               "tool_name" => "web_fetch",
               "url" => "https://www.legacy.example/redirect"
             })

    assert msg =~ "Redirect to unsafe URL blocked"
    assert_received {:http_get, "https://93.184.216.34/redirect", _opts}
    refute_received {:http_get, "http://169.254.169.254" <> _, _}
  end

  defp register_stub do
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
  end

  defp stub_public_dns do
    previous = Application.get_env(:pincer, :network_guard_resolver)

    Application.put_env(:pincer, :network_guard_resolver, fn "www.legacy.example" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pincer, :network_guard_resolver)
        resolver -> Application.put_env(:pincer, :network_guard_resolver, resolver)
      end
    end)
  end
end

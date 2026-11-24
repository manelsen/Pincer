defmodule Pincer.Utils.NetworkGuardTest do
  use ExUnit.Case, async: false

  alias Pincer.Utils.NetworkGuard

  setup do
    previous = Application.get_env(:pincer, :network_guard_resolver)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pincer, :network_guard_resolver)
        resolver -> Application.put_env(:pincer, :network_guard_resolver, resolver)
      end
    end)

    :ok
  end

  test "rejects loopback, private, metadata, and local hostnames" do
    for url <- [
          "http://127.0.0.1/admin",
          "http://[::1]/admin",
          "http://[::ffff:127.0.0.1]/admin",
          "http://10.0.0.1/",
          "http://172.16.0.1/",
          "http://192.168.1.1/",
          "http://169.254.169.254/latest/meta-data",
          "http://localhost/",
          "http://service.local/",
          "http://metadata.google.internal/"
        ] do
      assert {:error, reason} = NetworkGuard.validate_url(url)
      assert reason =~ "internal hosts" or reason =~ "not allowed"
    end
  end

  test "rejects credentials, unsupported schemes, and unresolvable hosts" do
    assert {:error, reason} = NetworkGuard.validate_url("https://user:pass@example.com/")
    assert reason =~ "credentials"

    assert {:error, reason} = NetworkGuard.validate_url("ftp://example.com/file")
    assert reason =~ "scheme"

    Application.put_env(:pincer, :network_guard_resolver, fn _host -> {:error, :nxdomain} end)
    assert {:error, reason} = NetworkGuard.validate_url("https://missing.example/")
    assert reason =~ "resolve"
  end

  test "pins a public hostname to one validated address" do
    Application.put_env(:pincer, :network_guard_resolver, fn "example.com" ->
      {:ok, [{93, 184, 216, 34}, {0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}]}
    end)

    assert {:ok, target} = NetworkGuard.safe_target("https://example.com/path?q=1")
    assert target.host == "example.com"
    assert target.address == {93, 184, 216, 34}
    assert target.pinned_url == "https://93.184.216.34/path?q=1"
    assert target.connect_options[:hostname] == "example.com"
    assert target.port == 443
  end

  test "preserves the fragment in the pinned URL" do
    Application.put_env(:pincer, :network_guard_resolver, fn "example.com" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    assert {:ok, target} =
             NetworkGuard.safe_target("https://example.com/docs?q=1#section-2")

    assert target.pinned_url == "https://93.184.216.34/docs?q=1#section-2"
  end

  test "rejects a hostname when any resolved address is private" do
    Application.put_env(:pincer, :network_guard_resolver, fn "mixed.example" ->
      {:ok, [{93, 184, 216, 34}, {10, 0, 0, 7}]}
    end)

    assert {:error, reason} = NetworkGuard.validate_url("https://mixed.example/")
    assert reason =~ "internal hosts"
  end

  test "pins a public IPv6 literal with brackets" do
    assert {:ok, target} = NetworkGuard.safe_target("https://[2606:4700:4700::1111]/dns")
    assert target.host == "2606:4700:4700::1111"
    assert target.pinned_url == "https://[2606:4700:4700::1111]/dns"
  end

  test "public_address? accepts global unicast and rejects special ranges" do
    assert NetworkGuard.public_address?({8, 8, 8, 8})
    refute NetworkGuard.public_address?({10, 1, 2, 3})
    refute NetworkGuard.public_address?({100, 64, 0, 1})
    refute NetworkGuard.public_address?({127, 0, 0, 1})
    refute NetworkGuard.public_address?({169, 254, 169, 254})
    refute NetworkGuard.public_address?({0, 0, 0, 0, 0, 0, 0x0808, 0x0808})
    refute NetworkGuard.public_address?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
    refute NetworkGuard.public_address?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
  end
end

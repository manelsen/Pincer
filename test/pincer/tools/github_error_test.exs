defmodule Pincer.Adapters.Tools.GitHubErrorTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.GitHubError

  test "formats common HTTP failures tersely" do
    assert GitHubError.format_http(401, %{"message" => "Bad credentials"}) ==
             "GitHub authentication failed. Check token or scopes."

    assert GitHubError.format_http(403, %{"message" => "API rate limit exceeded"}) ==
             "GitHub rate limit exceeded. Retry later."

    assert GitHubError.format_http(404, %{"message" => "Not Found"}) ==
             "GitHub resource not found or not accessible."
  end

  test "formats transport timeouts tersely" do
    assert GitHubError.format_transport(%Req.TransportError{reason: :timeout}) ==
             "GitHub request timed out."

    assert GitHubError.format_transport(%Req.TransportError{reason: :connect_timeout}) ==
             "GitHub connection timed out."
  end
end

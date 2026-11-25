defmodule PincerPorts.AttachmentsTest do
  use ExUnit.Case, async: false

  alias PincerPorts.Attachments

  defmodule Adapter do
    @behaviour Attachments

    @impl true
    def fetch("opaque:doc", {:inline, 7}), do: {:ok, "raw"}
    def fetch("opaque:doc", :workspace), do: {:error, :unavailable}
  end

  setup do
    previous = Application.fetch_env(:pincer, :attachment_adapter)
    Application.put_env(:pincer, :attachment_adapter, Adapter)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:pincer, :attachment_adapter, adapter)
        :error -> Application.delete_env(:pincer, :attachment_adapter)
      end
    end)
  end

  test "forwards references and retrieval modes to the host adapter" do
    assert Attachments.fetch("opaque:doc", {:inline, 7}) == {:ok, "raw"}
    assert Attachments.fetch("opaque:doc", :workspace) == {:error, :unavailable}
  end
end

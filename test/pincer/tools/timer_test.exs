defmodule Pincer.Adapters.Tools.TimerTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.Timer
  alias Pincer.Adapters.Tools.TimerServer

  setup do
    reg_name = :"timer_tool_reg_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: reg_name})
    srv = start_supervised!({TimerServer, name: nil, registry: reg_name})

    prev_srv = Application.get_env(:pincer, :timer_server)
    Application.put_env(:pincer, :timer_server, srv)

    on_exit(fn ->
      case prev_srv do
        nil -> Application.delete_env(:pincer, :timer_server)
        v -> Application.put_env(:pincer, :timer_server, v)
      end
    end)

    {:ok, %{registry: reg_name, srv: srv}}
  end

  test "schedules timer via TimerServer and uses context session_id", %{srv: srv} do
    assert {:ok, msg} =
             Timer.execute(
               %{"prompt" => "Check deploy", "seconds" => 5},
               %{"session_id" => "sess_ctx"}
             )

    assert msg =~ "Timer activated!"
    assert [%{session_id: "sess_ctx", prompt: "Check deploy"}] = TimerServer.list(srv)
  end

  test "rejects non-positive, non-integer, and excessive seconds" do
    ctx = %{"session_id" => "s1"}

    assert {:error, _} = Timer.execute(%{"prompt" => "x", "seconds" => 0}, ctx)
    assert {:error, _} = Timer.execute(%{"prompt" => "x", "seconds" => -5}, ctx)
    assert {:error, _} = Timer.execute(%{"prompt" => "x", "seconds" => "10"}, ctx)
    assert {:error, _} = Timer.execute(%{"prompt" => "x", "seconds" => 100_000}, ctx)
  end

  test "rejects missing prompt, seconds, or session_id" do
    assert {:error, msg} = Timer.execute(%{"seconds" => 10}, %{"session_id" => "s1"})
    assert msg =~ "prompt"

    assert {:error, msg} = Timer.execute(%{"prompt" => "x"}, %{"session_id" => "s1"})
    assert msg =~ "seconds"

    assert {:error, msg} = Timer.execute(%{"prompt" => "x", "seconds" => 10}, %{})
    assert msg =~ "session"
  end
end

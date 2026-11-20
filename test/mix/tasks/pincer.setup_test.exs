defmodule Mix.Tasks.Pincer.SetupTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Pincer.Setup

  test "run_steps/1 halts immediately on error and skips subsequent steps" do
    test_pid = self()

    steps = [
      {"Step 1",
       fn ->
         send(test_pid, :step_1)
         :ok
       end},
      {"Step 2",
       fn ->
         send(test_pid, :step_2)
         {:error, "database unreachable"}
       end},
      {"Step 3",
       fn ->
         send(test_pid, :step_3)
         :ok
       end}
    ]

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:error, "database unreachable"} = Setup.run_steps(steps)
        end)
      end)

    assert_received :step_1
    assert_received :step_2
    refute_received :step_3
    assert output =~ "database unreachable"
  end

  test "run_steps/1 continues across :ok and {:skip, reason} steps" do
    test_pid = self()

    steps = [
      {"Step 1",
       fn ->
         send(test_pid, :s1)
         :ok
       end},
      {"Step 2",
       fn ->
         send(test_pid, :s2)
         {:skip, "already present"}
       end},
      {"Step 3",
       fn ->
         send(test_pid, :s3)
         :ok
       end}
    ]

    ExUnit.CaptureIO.capture_io(fn ->
      assert :ok = Setup.run_steps(steps)
    end)

    assert_received :s1
    assert_received :s2
    assert_received :s3
  end

  test "run/1 raises Mix.Error on unknown flags" do
    assert_raise Mix.Error, ~r/Invalid flags/, fn ->
      Setup.run(["--nonexistent-flag"])
    end
  end
end

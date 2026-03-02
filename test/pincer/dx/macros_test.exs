defmodule Pincer.DX.MacrosTest do
  use ExUnit.Case, async: true
  require Pincer.DX.Macros

  test "with_app_env/4 sets env inside block and restores previous value" do
    Application.put_env(:pincer, :dx_test_key, :old_value)

    result =
      Pincer.DX.Macros.with_app_env(:pincer, :dx_test_key, :new_value) do
        Application.get_env(:pincer, :dx_test_key)
      end

    assert result == :new_value
    assert Application.get_env(:pincer, :dx_test_key) == :old_value
  end

  test "with_app_env/4 restores missing key to missing state" do
    Application.delete_env(:pincer, :dx_missing_key)

    Pincer.DX.Macros.with_app_env(:pincer, :dx_missing_key, :temp) do
      assert Application.get_env(:pincer, :dx_missing_key) == :temp
    end

    assert Application.get_env(:pincer, :dx_missing_key) == nil
  end

  test "assert_ok/1 extracts ok payload" do
    assert Pincer.DX.Macros.assert_ok({:ok, 123}) == 123
  end

  test "assert_ok/1 raises on non-ok tuple" do
    assert_raise ExUnit.AssertionError, fn ->
      Pincer.DX.Macros.assert_ok({:error, :nope})
    end
  end
end

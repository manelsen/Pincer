defmodule Pincer.Utils.ANSITest do
  use ExUnit.Case, async: false

  alias Pincer.Utils.ANSI

  setup do
    previous = Application.get_env(:elixir, :ansi_enabled)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:elixir, :ansi_enabled)
      else
        Application.put_env(:elixir, :ansi_enabled, previous)
      end
    end)

    :ok
  end

  describe "colorize/3" do
    test "wraps text with ANSI codes when enabled?: true" do
      assert ANSI.colorize("ok", :green, enabled?: true) == "\e[32mok\e[0m"
      assert ANSI.colorize("warn", :yellow, enabled?: true) == "\e[33mwarn\e[0m"
      assert ANSI.colorize("info", :blue, enabled?: true) == "\e[34minfo\e[0m"
      assert ANSI.colorize("err", :red, enabled?: true) == "\e[31merr\e[0m"
      assert ANSI.colorize("prompt", :cyan, enabled?: true) == "\e[36mprompt\e[0m"
      assert ANSI.colorize("dbg", :magenta, enabled?: true) == "\e[35mdbg\e[0m"
      assert ANSI.colorize("ts", :gray, enabled?: true) == "\e[90mts\e[0m"
    end

    test "returns plain text when enabled?: false" do
      assert ANSI.colorize("ok", :green, enabled?: false) == "ok"
      assert ANSI.colorize("ts", :gray, enabled?: false) == "ts"
    end

    test "respects IO.ANSI.enabled?() when :enabled? option is omitted" do
      Application.put_env(:elixir, :ansi_enabled, true)
      assert ANSI.colorize("hello", :cyan) == "\e[36mhello\e[0m"

      Application.put_env(:elixir, :ansi_enabled, false)
      assert ANSI.colorize("hello", :cyan) == "hello"
    end
  end

  describe "semantic and color helpers" do
    test "provide consistent styling for terminal and logger helpers" do
      assert ANSI.green("ok", enabled?: true) == "\e[32mok\e[0m"
      assert ANSI.yellow("warn", enabled?: true) == "\e[33mwarn\e[0m"
      assert ANSI.blue("info", enabled?: true) == "\e[34minfo\e[0m"
      assert ANSI.red("err", enabled?: true) == "\e[31merr\e[0m"
      assert ANSI.cyan("tag", enabled?: true) == "\e[36mtag\e[0m"
      assert ANSI.magenta("dbg", enabled?: true) == "\e[35mdbg\e[0m"
      assert ANSI.gray("ts", enabled?: true) == "\e[90mts\e[0m"

      assert ANSI.ok("ok", enabled?: true) == "\e[32mok\e[0m"
      assert ANSI.warn("warn", enabled?: true) == "\e[33mwarn\e[0m"
      assert ANSI.info("info", enabled?: true) == "\e[34minfo\e[0m"
      assert ANSI.error("err", enabled?: true) == "\e[31merr\e[0m"
      assert ANSI.debug("dbg", enabled?: true) == "\e[35mdbg\e[0m"
      assert ANSI.muted("ts", enabled?: true) == "\e[90mts\e[0m"
    end
  end

  describe "clear_screen/1" do
    test "returns clear + home sequence when enabled and empty string when disabled" do
      assert ANSI.clear_screen(enabled?: true) == "\e[2J\e[H"
      assert ANSI.clear_screen(enabled?: false) == ""
    end
  end
end

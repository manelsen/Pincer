defmodule Mix.Tasks.Compile.WhatsappBridge do
  @moduledoc """
  Mix compiler that builds the WhatsApp Go sidecar binary.

  Runs `go build` inside `priv/src/whatsapp_bridge/` and deposits the
  resulting binary at `priv/whatsapp_bridge`.  Only recompiles when any
  `.go` file is newer than the current binary (or the binary is absent).

  Skipped gracefully when `go` is not found in PATH — a warning is printed
  but the build is not aborted, so the package can still be compiled and
  used via other transports if WhatsApp is not needed.
  """

  use Mix.Task.Compiler

  @src_dir "priv/src/whatsapp_bridge"
  @out_binary "priv/whatsapp_bridge"

  @impl Mix.Task.Compiler
  def run(_args) do
    case System.find_executable("go") do
      nil ->
        Mix.shell().info(
          "[pincer_whatsapp] `go` not found in PATH — skipping whatsapp_bridge build. " <>
            "Install Go 1.21+ to enable the WhatsApp sidecar."
        )

        {:ok, []}

      go ->
        if needs_rebuild?() do
          Mix.shell().info("[pincer_whatsapp] Building whatsapp_bridge sidecar...")
          File.mkdir_p!("priv")

          case System.cmd(go, ["build", "-o", @out_binary, "./"],
                 cd: @src_dir,
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              Mix.shell().info("[pincer_whatsapp] whatsapp_bridge built successfully.")
              {:ok, []}

            {output, code} ->
              Mix.shell().error("[pincer_whatsapp] go build failed (exit #{code}):\n#{output}")

              {:error, []}
          end
        else
          {:ok, []}
        end
    end
  end

  @impl Mix.Task.Compiler
  def clean do
    if File.exists?(@out_binary), do: File.rm!(@out_binary)
    :ok
  end

  # Returns true when the binary is absent or any .go source is newer than it.
  defp needs_rebuild? do
    case File.stat(@out_binary) do
      {:error, _} ->
        true

      {:ok, bin_stat} ->
        go_files = Path.wildcard(Path.join(@src_dir, "*.go"))

        Enum.any?(go_files, fn f ->
          case File.stat(f) do
            {:ok, s} -> DateTime.compare(s.mtime, bin_stat.mtime) == :gt
            _ -> false
          end
        end)
    end
  end
end

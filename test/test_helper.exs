# Compile support files
Path.wildcard("test/support/**/*.ex") |> Enum.each(&Code.require_file/1)

ExUnit.start()

# Global stubs removed to avoid breaking async unit tests

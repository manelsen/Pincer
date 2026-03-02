# debug_port_env.exs

IO.puts("Testing Port.open with env...")

cmd = "/bin/sh"
args = ["-c", "echo $MY_VAR"]
env = [{~c"MY_VAR", ~c"Hello Port"}]

# Option 1: env as keyword
opts1 = [:binary, :exit_status, :stderr_to_stdout, args: args, env: env]
IO.puts("Trying opts: #{inspect(opts1)}")
try do
  port = Port.open({:spawn_executable, cmd}, opts1)
  IO.puts("Success! Port info: #{inspect(port)}")
  Port.close(port)
rescue
  e -> IO.puts("Failed: #{inspect(e)}")
end

# Option 2: env as tuple inside list explicitly? (Keyword list is already list of tuples)
# Maybe mixed atoms and tuples order matters?

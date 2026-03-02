# test_token_config.exs
# Verifies if GITHUB_PERSONAL_ACCESS_TOKEN is loaded correctly

IO.puts("Loading Config...")
Pincer.Infra.Config.load()

token = Application.get_env(:pincer, :tokens, %{}) |> Map.get("github")

if token && token != "" do
  IO.puts("\n[OK] GitHub Token found in Application config.")
  IO.puts("Token length: #{String.length(token)}")
  IO.puts("First 4 chars: #{String.slice(token, 0, 4)}...")
else
  IO.puts("\n[FAIL] GitHub Token NOT found in Application config.")
  IO.puts("Ensure GITHUB_PERSONAL_ACCESS_TOKEN is set in .env file.")
end

# Check System env as well (since Config.load puts it there)
sys_token = System.get_env("GITHUB_PERSONAL_ACCESS_TOKEN")
if sys_token do
  IO.puts("[OK] GitHub Token found in System env.")
else
  IO.puts("[FAIL] GitHub Token NOT found in System env.")
end

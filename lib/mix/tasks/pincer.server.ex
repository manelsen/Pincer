defmodule Mix.Tasks.Pincer.Server do
  @moduledoc """
  Starts the Pincer Server (Persistent Node).
  Usage:
    mix pincer.server [channels...]
    mix pincer.server service install [--system]
    mix pincer.server service remove [--system]
    mix pincer.server service start [--system]
    mix pincer.server service stop [--system]
    mix pincer.server service restart [--system]
    mix pincer.server service status [--system]

  By default, service commands run in user-mode (rootless) and rely on
  the .env file in the project directory. Use --system to run as root.
  """
  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  @service_name "pincer"
  @service_file "infrastructure/systemd/pincer.service"
  @systemd_path "/etc/systemd/system/#{@service_name}.service"

  def run(["service", command | rest]) do
    is_system = "--system" in rest
    handle_service(command, not is_system)
  end

  def run(args) do
    # Configure the node to be distributed
    start_node()

    if args != [] do
      IO.puts(
        IO.ANSI.yellow() <>
          "Active Channel Filter (Server): #{Enum.join(args, ", ")}" <> IO.ANSI.reset()
      )

      Application.put_env(:pincer, :enabled_channels, args)
    end

    IO.puts(IO.ANSI.green() <> "=== Pincer Server (Immortal Node) ===" <> IO.ANSI.reset())
    IO.puts("Node: #{Node.self()}")
    IO.puts("Cookie: #{Node.get_cookie()}")

    # Start the full application and all its dependencies
    case Application.ensure_all_started(:pincer) do
      {:ok, _} ->
        IO.puts(IO.ANSI.cyan() <> ">>> Pincer Application STARTED <<<" <> IO.ANSI.reset())

      {:error, reason} ->
        IO.puts(
          IO.ANSI.red() <> "!!! FAILED TO START PINCER: #{inspect(reason)}" <> IO.ANSI.reset()
        )
    end

    # Keep the process alive
    Process.sleep(:infinity)
  end

  defp handle_service("install", is_user) do
    mode_label = if is_user, do: "User (Rootless)", else: "System (Root)"
    IO.puts(IO.ANSI.blue() <> "Installing Pincer Service (#{mode_label})..." <> IO.ANSI.reset())

    user = System.get_env("USER") || "root"
    home = System.user_home!()
    cwd = File.cwd!()

    {systemd_path, cmd_prefix} =
      if is_user do
        user_systemd = Path.join([home, ".config", "systemd", "user"])
        File.mkdir_p!(user_systemd)
        {Path.join(user_systemd, "#{@service_name}.service"), "systemctl --user"}
      else
        {@systemd_path, "sudo systemctl"}
      end

    with {:ok, template} <- File.read(@service_file),
         content = generate_service_content(template, user, cwd, home, is_user),
         :ok <- write_service_file(systemd_path, content, is_user),
         :ok <- execute("#{cmd_prefix} daemon-reload"),
         :ok <- execute("#{cmd_prefix} enable #{@service_name}") do
      msg =
        if is_user do
          "Service installed for user '#{user}'. Using .env from: #{cwd}\nTo keep it running after logout, run: sudo loginctl enable-linger #{user}"
        else
          "Service installed as root. Using .env from: #{cwd}"
        end

      IO.puts(IO.ANSI.green() <> msg <> IO.ANSI.reset())
    else
      {:error, msg} -> IO.puts(IO.ANSI.red() <> "Installation failed: #{msg}" <> IO.ANSI.reset())
    end
  end

  defp handle_service("remove", is_user) do
    cmd_prefix = if is_user, do: "systemctl --user", else: "sudo systemctl"
    home = System.user_home!()

    systemd_path =
      if is_user do
        Path.join([home, ".config", "systemd", "user", "#{@service_name}.service"])
      else
        @systemd_path
      end

    IO.puts(IO.ANSI.red() <> "Removing Pincer Service..." <> IO.ANSI.reset())

    execute("#{cmd_prefix} stop #{@service_name}")
    execute("#{cmd_prefix} disable #{@service_name}")

    if is_user do
      File.rm(systemd_path)
    else
      execute("sudo rm #{systemd_path}")
    end

    execute("#{cmd_prefix} daemon-reload")
    IO.puts(IO.ANSI.green() <> "Service removed successfully." <> IO.ANSI.reset())
  end

  defp handle_service("start", is_user) do
    cmd =
      if is_user,
        do: "systemctl --user start #{@service_name}",
        else: "sudo systemctl start #{@service_name}"

    case execute(cmd) do
      :ok -> IO.puts(IO.ANSI.green() <> "Service started." <> IO.ANSI.reset())
      _ -> IO.puts(IO.ANSI.red() <> "Failed to start service." <> IO.ANSI.reset())
    end
  end

  defp handle_service("stop", is_user) do
    cmd =
      if is_user,
        do: "systemctl --user stop #{@service_name}",
        else: "sudo systemctl stop #{@service_name}"

    case execute(cmd) do
      :ok -> IO.puts(IO.ANSI.green() <> "Service stopped." <> IO.ANSI.reset())
      _ -> IO.puts(IO.ANSI.red() <> "Failed to stop service." <> IO.ANSI.reset())
    end
  end

  defp handle_service("restart", is_user) do
    cmd =
      if is_user,
        do: "systemctl --user restart #{@service_name}",
        else: "sudo systemctl restart #{@service_name}"

    IO.puts(IO.ANSI.blue() <> "Restarting Pincer Service..." <> IO.ANSI.reset())

    case execute(cmd) do
      :ok -> IO.puts(IO.ANSI.green() <> "Service restarted." <> IO.ANSI.reset())
      _ -> IO.puts(IO.ANSI.red() <> "Failed to restart service." <> IO.ANSI.reset())
    end
  end

  defp handle_service("status", is_user) do
    cmd =
      if is_user,
        do: "systemctl --user status #{@service_name}",
        else: "systemctl status #{@service_name}"

    {output, _} = System.shell(cmd)
    IO.puts(output)
  end

  defp handle_service(unknown, _) do
    IO.puts(IO.ANSI.red() <> "Unknown service command: #{unknown}" <> IO.ANSI.reset())

    IO.puts(
      "Usage: mix pincer.server service [install|remove|start|stop|restart|status] [--system]"
    )
  end

  defp write_service_file(path, content, true), do: File.write(path, content)

  defp write_service_file(path, content, false) do
    File.write("/tmp/pincer.service", content)
    execute("sudo mv /tmp/pincer.service #{path}")
  end

  defp generate_service_content(template, user, cwd, home, is_user) do
    # Captura o PATH atual do usuário (que inclui o asdf)
    current_path = System.get_env("PATH")

    content =
      template
      |> String.replace(~r/WorkingDirectory=.*/, "WorkingDirectory=#{cwd}")
      |> String.replace(
        ~r/ReadWritePaths=.*/,
        "ReadWritePaths=#{cwd} #{Path.join(home, ".mix")} #{Path.join(home, ".cache/rebar3")}"
      )
      # Removemos o EnvironmentFile e injetamos o PATH explicitamente
      |> String.replace(~r/EnvironmentFile=.*/, "Environment=PATH=#{current_path}")

    if is_user do
      content
      |> String.replace(~r/User=.*/, "")
      |> String.replace(~r/Group=.*/, "")
      |> String.replace("WantedBy=multi-user.target", "WantedBy=default.target")
    else
      content
      |> String.replace(~r/User=.*/, "User=#{user}")
      |> then(fn c ->
        {group, 0} = System.shell("id -gn")
        String.replace(c, ~r/Group=.*/, "Group=#{String.trim(group)}")
      end)
    end
  end

  defp execute(command) do
    case System.shell(command) do
      {_, 0} ->
        :ok

      {output, exit_code} ->
        IO.puts(IO.ANSI.red() <> "Error (exit code #{exit_code}): #{output}" <> IO.ANSI.reset())
        {:error, "Command failed: #{command}"}
    end
  end

  defp start_node do
    unless Node.alive?() do
      case Node.start(:pincer_server@localhost, :shortnames) do
        {:ok, _} ->
          Node.set_cookie(Node.self(), :pincer_secret)

        {:error, {:already_started, _}} ->
          # Already running, that's fine
          :ok

        {:error, _reason} ->
          suffix = :crypto.strong_rand_bytes(4) |> Base.encode16()
          name = :"pincer_server_#{suffix}@localhost"
          {:ok, _} = Node.start(name, :shortnames)
          Node.set_cookie(Node.self(), :pincer_secret)
      end
    end
  end
end

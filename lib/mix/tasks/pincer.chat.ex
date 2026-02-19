defmodule Mix.Tasks.Pincer.Chat do
  @moduledoc """
  Inicia o CLI do Pincer.
  Tenta conectar ao servidor (pincer_server). Se falhar, inicia localmente.
  """
  use Mix.Task

  def run(args) do
    # Carrega .env para garantir configuração (mesmo se for conectar remoto)
    load_env()

    # O Pincer.CLI decide se inicia a app ou conecta
    Pincer.CLI.main(args)
  end

  defp load_env do
    if File.exists?(".env") do
      File.stream!(".env")
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.each(fn line ->
        [key, value] = String.split(line, "=", parts: 2)
        System.put_env(String.trim(key), String.trim(value))
      end)
    end
  end
end

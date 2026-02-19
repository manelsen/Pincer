defmodule Pincer.Tools.Scheduler do
  @moduledoc """
  Ferramenta para o Pincer agendar lembretes ou tarefas futuras.
  """
  @behaviour Pincer.Tool
  alias Pincer.Core.Cron

  def spec do
    %{
      name: "schedule_reminder",
      description: "Agenda um lembrete ou mensagem para ser enviada ao usuário após um tempo determinado.",
      parameters: %{
        type: "object",
        properties: %{
          message: %{
            type: "string",
            description: "A mensagem que o Pincer deve dizer no futuro."
          },
          seconds: %{
            type: "integer",
            description: "Quantidade de segundos a partir de agora para o gatilho."
          },
          session_id: %{
            type: "string",
            description: "O ID da sessão atual."
          }
        },
        required: ["message", "seconds", "session_id"]
      }
    }
  end

  def execute(%{"message" => msg, "seconds" => sec, "session_id" => sid}) do
    Cron.schedule(sid, msg, sec)
    {:ok, "Lembrete agendado com sucesso para daqui a #{sec} segundos."}
  end
end

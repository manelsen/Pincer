defmodule Pincer.Core.LLM do
  @moduledoc "Model routing and failure policy."

  use Boundary,
    deps: [Pincer.Core],
    exports: [CooldownStore, ErrorClass, FailoverPolicy, RuntimeStatus, SkillsSidecarPolicy]
end

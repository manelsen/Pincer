defmodule Pincer.Core.Introspection do
  @moduledoc "Reflection and introspection state."

  use Boundary,
    deps: [Pincer.Core],
    exports: [Client, Kernel, Kernel.Supervisor, LessonStore, SelfState]
end

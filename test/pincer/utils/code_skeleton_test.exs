defmodule Pincer.Utils.CodeSkeletonTest do
  use ExUnit.Case, async: true
  alias Pincer.Utils.CodeSkeleton

  describe "extract/2" do
    test "extracts Elixir function signatures and module name" do
      code = """
      defmodule MyApp.Module do
        @moduledoc "Docs"
        alias Other.Module
        
        @spec run(integer()) :: :ok
        def run(id) do
          IO.puts("Implementation detail")
          :ok
        end

        defp private_func(arg), do: arg + 1
      end
      """
      
      skeleton = CodeSkeleton.extract(code, ".ex")
      
      assert skeleton =~ "defmodule MyApp.Module"
      assert skeleton =~ "alias Other.Module"
      assert skeleton =~ "@spec run(integer()) :: :ok"
      assert skeleton =~ "def run(id)"
      assert skeleton =~ "defp private_func(arg)"
      
      # Should NOT contain implementation details
      refute skeleton =~ "IO.puts"
      refute skeleton =~ "arg + 1"
    end

    test "extracts TypeScript signatures including class methods" do
      code = """
      import { x } from 'y';
      
      interface User { id: number; }

      export class Service {
        constructor() { this.init(); }
        
        async fetchData(id: string): Promise<User> {
          const res = await fetch(url);
          return res.json();
        }
      }
      """
      
      skeleton = CodeSkeleton.extract(code, ".ts")
      
      assert skeleton =~ "import { x } from 'y'"
      assert skeleton =~ "interface User"
      assert skeleton =~ "export class Service"
      assert skeleton =~ "constructor()"
      assert skeleton =~ "async fetchData(id: string): Promise<User>"
      
      # Should NOT contain implementation
      refute skeleton =~ "const res ="
      refute skeleton =~ "return res.json()"
    end

    test "extracts Python signatures" do
      code = """
      import os
      from path import Path

      class AI:
          @property
          def name(self):
              return "Pincer"

          def think(self, prompt: str) -> str:
              # heavy logic here
              return prompt.upper()
      """
      
      skeleton = CodeSkeleton.extract(code, ".py")
      
      assert skeleton =~ "import os"
      assert skeleton =~ "from path import Path"
      assert skeleton =~ "class AI"
      assert skeleton =~ "@property"
      assert skeleton =~ "def name(self)"
      assert skeleton =~ "def think(self, prompt: str) -> str"
      
      # Should NOT contain implementation
      refute skeleton =~ "return \"Pincer\""
      refute skeleton =~ "prompt.upper()"
    end
  end
end

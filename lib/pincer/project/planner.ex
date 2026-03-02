defmodule Pincer.Project.Planner do
  @moduledoc """
  Architect logic for task atomization with STRICT SRP and Purity.
  Enforces read-only tests for Coder and atomic pure functions.
  """
  require Logger
  alias Pincer.LLM.Client

  @spec build_plan(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, any()}
  def build_plan(objective, opts \\ []) do
    Logger.info("[ARCHITECT] Decomposing objective with STRICT SRP/Purity: #{objective}")

    prompt = """
    You are the Pincer PROJECT ARCHITECT. Your goal is to decompose a objective into ATOMIC TASKS based on the GOLDEN CONTRACT:

    ## THE GOLDEN CONTRACT:
    1. ATOMIC TASK DEFINITION: A task must result in a PURE FUNCTION with a SINGLE RESPONSIBILITY. 
    2. SIDE EFFECTS: Side effects (IO, DB, Network) are ONLY allowed if they are the SOLE REASON for the function's existence (Edge Tasks).
    3. TEST IS LAW: 'Coder' roles CANNOT modify files in the `test/` directory. They are READ-ONLY for Coders.

    ## ROLES & FLOW:
    - Architect: Define the contract, pure inputs, and expected outputs in SPECS.md.
    - Tester (RED): Write the failing test in `test/`. (Has WRITE access to tests).
    - Coder (GREEN): Implement the pure function in `lib/`. (Has READ-ONLY access to tests).
    - Tester (REFACTOR): Refactor and verify purity/SRP. (Has WRITE access to tests).

    ## INSTRUCTIONS:
    - Break down the objective into functions that do exactly one thing.
    - Ensure the 'Coder' task explicitly mentions it cannot touch the test files.
    - RESPOND ONLY with the list of tasks.

    ## EXAMPLE:
    Architect: Define pure 'calculate_tax(amount, rate)' contract.
    Tester: Create 'test/tax_test.exs' with failing case for 10% rate.
    Coder: Implement 'calculate_tax/2' in 'lib/tax.ex' (READ-ONLY test access).
    Tester: Verify purity and refactor 'calculate_tax/2'.
    """

    messages = [%{"role" => "system", "content" => prompt}]

    case Client.chat_completion(messages) do
      {:ok, %{"content" => content}} ->
        tasks = 
          content
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
        
        {:ok, tasks}

      {:error, reason} ->
        Logger.error("[ARCHITECT] Failed to build Strict Plan: #{inspect(reason)}")
        {:error, reason}
    end
  end
end

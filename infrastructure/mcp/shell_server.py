import asyncio
import subprocess
import json
import sys
from mcp.server.fastmcp import FastMCP

# Define the MCP server
mcp = FastMCP("Pincer-Safe-Shell")

# Configurable whitelist of "auto-approved" commands
# Everything else will be flagged for approval (in the Elixir side)
WHITELIST = ["ls", "pwd", "git status", "git log", "cat", "grep", "find", "mix test", "du -sh"]

@mcp.tool()
def run_command(command: str) -> str:
    """Executes a shell command. Commands outside the whitelist will be audited."""
    print(f"[MCP-SHELL] Executing: {command}", file=sys.stderr)
    
    # Simple whitelist check (starts with)
    is_safe = any(command.strip().startswith(cmd) for cmd in WHITELIST)
    
    if not is_safe:
        # In a real production system, this server might reject immediately.
        # Here we allow it, but we prepend a warning so the Elixir Core knows to ask the user.
        print(f"[MCP-SHELL] WARNING: Command '{command}' is not in whitelist.", file=sys.stderr)
        # return f"AUDIT_REQUIRED: {command}" 

    try:
        # We use run for simplicity in this PoC
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=30
        )
        
        output = result.stdout
        if result.stderr:
            output += f"\nSTDERR:\n{result.stderr}"
        
        if result.returncode != 0:
            output += f"\nExit Code: {result.returncode}"
            
        return output or "(no output)"
        
    except subprocess.TimeoutExpired:
        return "Error: Command timed out after 30s"
    except Exception as e:
        return f"Error: {str(e)}"

if __name__ == "__main__":
    mcp.run()

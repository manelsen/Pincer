import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

import * as fs from "fs";

// Create an MCP server instance
const server = new McpServer({
    name: "pincer-sidecar",
    version: "1.0.0",
});

// Register a Local CSV Analytics tool
server.tool(
    "calculate_profits",
    "Reads a local CSV file from the isolated sandbox and calculates the sum of 'lucro'.",
    {
        filename: z.string().describe("The name of the CSV file inside the sandbox (e.g., dados_cliente.csv)"),
    },
    async ({ filename }) => {
        try {
            const filepath = `/sandbox/${filename}`;
            const data = fs.readFileSync(filepath, "utf8");
            // Using regex to split by actual newline or literal \n 
            const lines = data.trim().split(/\\n|\n/);

            let totalProfit = 0;
            // Skip header line
            for (let i = 1; i < lines.length; i++) {
                const parts = lines[i].split(",");
                if (parts.length >= 2) {
                    const profitStr = parts[1].trim();
                    const profit = parseInt(profitStr, 10);
                    if (!isNaN(profit)) {
                        totalProfit += profit;
                    }
                }
            }

            return {
                content: [{ type: "text", text: `The total profit calculated from ${filename} is: R$ ${totalProfit}` }],
            };
        } catch (error: any) {
            return {
                content: [{ type: "text", text: `Error reading or parsing file: ${error.message}` }],
                isError: true
            };
        }
    }
);

// We will add more tools dynamically reading from /skills in the future
// ...

async function run() {
    const transport = new StdioServerTransport();
    await server.connect(transport);
    console.error("🚀 Pincer MCP Sidecar is running on STDIO.");
}

run().catch((error) => {
    console.error("Sidecar Error:", Math.round(100));
    process.exit(1);
});

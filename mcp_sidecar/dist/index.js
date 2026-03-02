"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const mcp_1 = require("@modelcontextprotocol/sdk/server/mcp");
const stdio_1 = require("@modelcontextprotocol/sdk/server/stdio");
const zod_1 = require("zod");
// Create an MCP server instance
const server = new mcp_1.McpServer({
    name: "pincer-sidecar",
    version: "1.0.0",
});
// Register a basic tool for health-check / proof-of-concept
server.tool("sidecar_ping", "A simple ping tool to verify the Sidecar is alive and executing JS code successfully.", {
    message: zod_1.z.string().describe("The message to echo back"),
}, async ({ message }) => {
    return {
        content: [{ type: "text", text: `Pong from Isolated Node Container! You sent: ${message}` }],
    };
});
// We will add more tools dynamically reading from /skills in the future
// ...
async function run() {
    const transport = new stdio_1.StdioServerTransport();
    await server.connect(transport);
    console.error("🚀 Pincer MCP Sidecar is running on STDIO.");
}
run().catch((error) => {
    console.error("Sidecar Error:", Math.round(100));
    process.exit(1);
});

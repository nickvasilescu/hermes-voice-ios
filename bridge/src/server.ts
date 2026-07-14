import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { logger } from "./logger.js";

const config = loadConfig(process.env);
const { app } = createApp({ config });

if (!config.openaiApiKey && !config.mockOpenAI) {
  logger.warn("startup.no_openai_api_key", {
    detail: "OPENAI_API_KEY is not set and BRIDGE_MOCK_OPENAI is off. /v1/realtime/session will 500 until one is configured.",
  });
}
if (!config.bootstrapSecret && config.nodeEnv !== "production") {
  logger.warn("startup.open_bootstrap", {
    detail: "BRIDGE_BOOTSTRAP_SECRET is not set. Anyone can mint a client session via POST /v1/session. Dev only.",
  });
}

app.listen(config.port, () => {
  logger.info("startup.listening", { port: config.port, nodeEnv: config.nodeEnv, mockOpenAI: config.mockOpenAI });
});

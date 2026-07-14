import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { logger } from "./logger.js";

// Defense-in-depth: provider bugs that forget a .catch() must not take
// down the whole process (in-memory sessions/tasks would all vanish).
process.on("unhandledRejection", (reason) => {
  logger.error("process.unhandled_rejection", {
    detail: reason instanceof Error ? reason.message : String(reason),
  });
});
process.on("uncaughtException", (err) => {
  logger.error("process.uncaught_exception", { detail: err.message });
});

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
if (config.hermesApiBaseUrl && config.hermesApiKey) {
  logger.info("startup.hermes_api_provider", {
    baseUrl: config.hermesApiBaseUrl,
    detail: "Using ApiServerHermesProvider against Hermes API Server.",
  });
} else if (config.hermesApiBaseUrl || config.hermesApiKey) {
  logger.warn("startup.hermes_api_incomplete", {
    detail:
      "Set both HERMES_API_BASE_URL and HERMES_API_KEY to enable the real Hermes provider; falling back to MockHermesProvider.",
  });
} else {
  logger.info("startup.hermes_mock_provider", {
    detail: "HERMES_API_BASE_URL / HERMES_API_KEY unset — using MockHermesProvider.",
  });
}

app.listen(config.port, () => {
  logger.info("startup.listening", {
    port: config.port,
    nodeEnv: config.nodeEnv,
    mockOpenAI: config.mockOpenAI,
    hermesProvider: config.hermesApiBaseUrl && config.hermesApiKey ? "api_server" : "mock",
  });
});

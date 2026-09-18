import { defaultMqttBrokerUrl, RelayMqttClient } from "@thrw/relay-core";
import { RelayService } from "./relay-service.js";

export const relayHostedPackageName = "@thrw/relay-hosted";

export { RelayService, type RelayServiceOptions } from "./relay-service.js";

// Real process entry point (#118), replacing the placeholder this file
// used to be. Only runs `main()` when this module is executed directly
// (`node dist/index.js`, `pnpm start` - see package.json), not when
// imported - e.g. by this package's own tests, which construct
// `RelayService` directly against a test-controlled `RelayMqttClient`
// rather than going through this env-var-driven bootstrap.
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error: unknown) => {
    console.error("relay-hosted: fatal error starting the relay service", error);
    process.exitCode = 1;
  });
}

async function main(): Promise<void> {
  const accounts = parseAccounts(process.env.THRW_RELAY_ACCOUNTS);

  const brokerUrl = defaultMqttBrokerUrl();
  // The same EMQX_RELAY_USERNAME/PASSWORD docker-entrypoint-relay.sh
  // already requires at container start (docs/handoffs/80.md) - this
  // process authenticates as the same shared relay credential, not a
  // separate identity. Optional here (unlike the entrypoint script's hard
  // requirement) so local/test runs against an anonymous-access broker
  // (this package's own tests, or a local Mosquitto) don't also need
  // dummy credentials - a real deployment's EMQX broker rejects an
  // unauthenticated connection on its own (`allow_anonymous = false`,
  // emqx.conf), so a misconfigured production run still fails loudly,
  // just at `RelayMqttClient.connect` rather than at this earlier check.
  const username = process.env.EMQX_RELAY_USERNAME;
  const password = process.env.EMQX_RELAY_PASSWORD;
  const client = await RelayMqttClient.connect(
    brokerUrl,
    username && password ? { username, password } : undefined,
  );

  const service = new RelayService({ client, accounts });
  await service.start();

  console.log(`relay-hosted: watching ${accounts.length} account(s) on ${brokerUrl}`);

  let shuttingDown = false;
  const shutdown = (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`relay-hosted: received ${signal}, shutting down`);
    service.stop();
    void client.end().then(() => process.exit(0));
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

/**
 * `THRW_RELAY_ACCOUNTS` is a comma-separated list of account ids this
 * process manages - see docs/handoffs/118.md's "Known gaps" for why a
 * static, configured list rather than discovering accounts dynamically
 * (there's no accounts/licensing service yet to discover them from).
 */
function parseAccounts(raw: string | undefined): string[] {
  const accounts = (raw ?? "")
    .split(",")
    .map((account) => account.trim())
    .filter((account) => account.length > 0);

  if (accounts.length === 0) {
    throw new Error(
      "THRW_RELAY_ACCOUNTS must be set to a comma-separated list of account ids " +
        "this relay process manages - see docs/handoffs/118.md",
    );
  }
  return accounts;
}

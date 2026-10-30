#!/usr/bin/env node
// Minimal stdio MCP server for kirunt evals — no dependencies, hand-rolled
// JSON-RPC 2.0 over stdio (newline-delimited), just enough of the MCP
// protocol for the mcp-caller worker to discover and call one tool.
//
// This exists so the mcp-caller end-to-end evals (evals.json) and benchmark
// (benchmarks.json) don't depend on any real external MCP server, real
// credentials, or whatever happens to be configured on the machine running
// the evals — every user has different MCP servers configured; this fixture
// gives the test suite one guaranteed, deterministic server instead.
//
// Exposes one tool: get_fixture_page(page_id) -> a fixed block of text,
// sized to be a plausible "large MCP response" (a full wiki page with many
// sections, comparable in scale to a real Confluence/Notion page a
// search/get tool might return) for benchmarking purposes.
//
// Usage (wired into evals/fixtures/mcp.json):
//   node evals/fixtures/mcp-fixture-server.js

const fs = require("fs");
const readline = require("readline");

// Optional call log for the live MCP-worker evals. Disabled unless the
// caller sets KIRUNT_FIXTURE_LOG, so benchmark/manual runs are unaffected.
function logCall(name, args) {
  const path = process.env.KIRUNT_FIXTURE_LOG;
  if (!path) return;
  try {
    fs.appendFileSync(
      path,
      JSON.stringify({ tool: name, args: args || {}, ts: Date.now() }) + "\n",
    );
  } catch {
    // Logging is best-effort; never break the MCP transport for it.
  }
}

const PAGE_CONTENT = {
  "q3-rollout": `Q3 Rollout Plan
================
Status: In progress
Owner: Platform Team
Last updated: 2026-06-20 by platform-team-lead

## Summary

This page tracks the phased rollout of the new payment routing service across all regions.
The rollout replaces the legacy routing layer, which has been in place since 2022 and no longer
scales to current transaction volume during peak hours. This document is the single source of
truth for scope, timeline, risks, and rollback procedures for the Q3 rollout.

## Background

The legacy routing layer processes approximately 40,000 transactions per minute at peak, and has
started showing latency degradation above 35,000 tpm since May. Three separate incident reviews
(INC-4821, INC-4903, INC-4977) identified the routing layer's single-threaded matching algorithm
as the root cause. The new service uses a sharded matching approach that has been load-tested to
120,000 tpm in staging with p99 latency under 40ms.

## Scope

In scope:
- Payment routing for card transactions (Visa, Mastercard, Amex)
- Payment routing for bank transfer transactions (ACH, wire)
- Fraud pre-screening hook integration (existing, unchanged interface)
- Regional failover between us-east-1 and us-west-2

Out of scope for this rollout (tracked separately):
- Cryptocurrency payment routing (see Q4 roadmap)
- New fraud model integration (blocked on data science team's model v3)
- EU region rollout (pending compliance review, see LEGAL-102)

## Timeline

- Week 1: Finalize scope and freeze requirements. All stakeholder sign-offs collected by end of
  week. Any scope changes after this point require VP approval per the change management policy.
- Week 2-3: Implementation across service boundaries. Routing service team implements the new
  matching algorithm; platform team implements the shadow-traffic comparison harness; SRE team
  provisions the new infrastructure in both regions.
- Week 4: Integration testing with downstream consumers. All consumers listed in the service
  registry are notified and asked to validate against the staging environment using their own
  test suites. Any consumer-reported issues are triaged daily in the 9am standup.
- Week 5: Staged rollout (10% -> 50% -> 100%). Traffic is shifted gradually with automated
  rollback triggers if error rate exceeds 0.1% or p99 latency exceeds 100ms for more than 5
  minutes. Each stage holds for at least 4 hours before proceeding.
- Week 6: Post-rollout monitoring and retro. Legacy routing layer is kept warm as a fallback for
  this entire week. Retro is scheduled for the Friday of week 6 with all involved teams.

## Risks

- Downstream consumer B (the settlement reconciliation service) has not confirmed compatibility
  with the new routing service's event schema. This is the highest-priority open risk and is
  being tracked in JIRA-8821. If not resolved by end of week 3, the rollout may need to slip by
  one week to avoid a hard dependency block.
- The load testing environment is shared with another team's Q3 work (the international expansion
  project), which could cause resource contention during the week 4 integration testing window.
  Mitigation: a dedicated load-testing time slot has been reserved for Tuesday/Wednesday of week 4.
- On-call rotation during the rollout weeks (5-6) has two team members out on planned leave.
  Backup on-call has been arranged with the adjacent infrastructure team, with a joint runbook
  walkthrough scheduled for the Monday before week 5 begins.
- The new matching algorithm has not been tested against the full historical fraud pattern set,
  only a representative sample. Full backtesting is scheduled to complete by week 3 but is
  currently tracking one day behind schedule.

## Rollback procedure

If automated rollback triggers fire, or if manual rollback is required:
1. Flip the routing feature flag "use_new_routing_service" to "false" in the config service.
   This takes effect within 30 seconds due to the config service's polling interval.
2. Confirm via the routing dashboard that traffic has fully reverted to the legacy layer.
3. Page the routing service on-call and the platform on-call to begin incident review.
4. Do not attempt to re-enable the new service without sign-off from both team leads.
5. File a post-incident report within 24 hours per the standard incident process.

## Decision log

- 2026-06-01: Approved phased rollout over big-bang cutover, based on the incident history with
  big-bang migrations in the payments domain (see the 2025 currency-conversion migration retro).
- 2026-06-08: Decided to keep the legacy routing layer warm through week 6 rather than
  decommissioning immediately after 100% traffic shift, as extra insurance against a rollback
  scenario discovered late in the rollout.
- 2026-06-15: Added a monitoring-only week (week 6) before considering the legacy layer safe to
  decommission, after the SRE team raised concerns about insufficient bake time in the original
  5-week plan.
- 2026-06-18: Agreed with the settlement reconciliation team (owners of downstream consumer B)
  on a joint testing session in week 3 rather than waiting for their independent validation, to
  de-risk JIRA-8821 earlier in the timeline.

## Stakeholders

- Platform Team (owner): rollout execution, feature flag management, rollback procedure owner
- Routing Service Team: new matching algorithm implementation and testing
- SRE Team: infrastructure provisioning, on-call rotation, monitoring dashboards
- Settlement Reconciliation Team (downstream consumer B): schema compatibility validation
- Fraud/Risk Team: backtesting validation, fraud pre-screening hook sign-off
- Legal/Compliance: sign-off required before any EU-region follow-on work begins
`,
};

function send(id, result, error) {
  const msg = { jsonrpc: "2.0", id };
  if (error) {
    msg.error = error;
  } else {
    msg.result = result;
  }
  process.stdout.write(JSON.stringify(msg) + "\n");
}

const rl = readline.createInterface({ input: process.stdin });

rl.on("line", (line) => {
  line = line.trim();
  if (!line) return;

  let req;
  try {
    req = JSON.parse(line);
  } catch {
    return; // ignore malformed input rather than crashing the transport
  }

  const { id, method, params } = req;

  switch (method) {
    case "initialize":
      send(id, {
        protocolVersion: "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "kirunt-fixture", version: "1.0.0" },
      });
      break;

    case "notifications/initialized":
      // No response required for notifications.
      break;

    case "tools/list":
      send(id, {
        tools: [
          {
            name: "get_fixture_page",
            description:
              "Get a fixture page's content by id. Fixture tool for kirunt evals — not a real content source.",
            inputSchema: {
              type: "object",
              properties: {
                page_id: {
                  type: "string",
                  description: "Fixture page id, e.g. 'q3-rollout'",
                },
              },
              required: ["page_id"],
            },
          },
          {
            name: "get_env",
            description:
              "Read environment variables from the server process. Pass name to request one variable.",
            inputSchema: {
              type: "object",
              properties: {
                name: {
                  type: "string",
                  description: "Environment variable name, e.g. 'PATH'",
                },
              },
            },
          },
        ],
      });
      break;

    case "tools/call": {
      const toolName = params && params.name;
      const toolArgs = (params && params.arguments) || {};
      logCall(toolName, toolArgs);

      if (toolName === "get_env") {
        const name = toolArgs.name;
        if (name) {
          const value = process.env[name];
          send(id, {
            content: [
              {
                type: "text",
                text:
                  value === undefined
                    ? `Environment variable "${name}" is not set.`
                    : `${name}=${value}`,
              },
            ],
          });
        } else {
          send(id, {
            content: [
              {
                type: "text",
                text: JSON.stringify(process.env, null, 2),
              },
            ],
          });
        }
        break;
      }

      const pageId = toolArgs.page_id;
      const content = PAGE_CONTENT[pageId];
      if (content) {
        send(id, { content: [{ type: "text", text: content }] });
      } else {
        send(id, {
          content: [
            {
              type: "text",
              text: `No fixture page found for page_id "${pageId}". Known ids: ${Object.keys(PAGE_CONTENT).join(", ")}`,
            },
          ],
          isError: true,
        });
      }
      break;
    }

    default:
      send(id, undefined, { code: -32601, message: `Method not found: ${method}` });
  }
});

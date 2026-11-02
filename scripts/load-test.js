/**
 * NorthPay Ledger API — k6 load test
 *
 * Demonstrates autoscaling for the portfolio demo.
 * Run: k6 run scripts/load-test.js
 *
 * Scenarios:
 *  1. Ramp from 5 → 100 VUs over 2 minutes (triggers HPA scale-out)
 *  2. Hold at 100 VUs for 3 minutes (triggers Karpenter node scale-out)
 *  3. Ramp down to 0 (watch consolidation)
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "https://api.northpay.example.com";

const paymentErrors = new Counter("payment_errors");
const paymentSuccessRate = new Rate("payment_success_rate");
const paymentDuration = new Trend("payment_duration_ms", true);

export const options = {
  scenarios: {
    ramp_up: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "2m", target: 100 },  // ramp up → triggers HPA
        { duration: "3m", target: 100 },  // hold → may trigger Karpenter
        { duration: "2m", target: 0 },    // ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<500"],     // 95th percentile < 500ms
    payment_success_rate: ["rate>0.99"],  // > 99% success
    http_req_failed: ["rate<0.01"],
  },
};

// Pre-seed a pair of test accounts (idempotent — server ignores duplicates)
const SOURCE_ACCOUNT = "load-test-src";
const DEST_ACCOUNT = "load-test-dst";

export default function () {
  const idempotencyKey = `lt-${__VU}-${__ITER}`;

  const payload = JSON.stringify({
    source_account: SOURCE_ACCOUNT,
    destination_account: DEST_ACCOUNT,
    amount: "0.01",
    currency: "USD",
    idempotency_key: idempotencyKey,
  });

  const params = {
    headers: {
      "Content-Type": "application/json",
      "X-Request-ID": idempotencyKey,
    },
    timeout: "10s",
  };

  const start = Date.now();
  const res = http.post(`${BASE_URL}/payments`, payload, params);
  paymentDuration.add(Date.now() - start);

  const ok = check(res, {
    "status is 201 or 200": (r) => r.status === 201 || r.status === 200,
    "has payment_id": (r) => {
      try {
        return JSON.parse(r.body).payment_id !== undefined;
      } catch {
        return false;
      }
    },
  });

  if (!ok) {
    paymentErrors.add(1);
    paymentSuccessRate.add(false);
  } else {
    paymentSuccessRate.add(true);
  }

  sleep(0.1);
}

export function handleSummary(data) {
  return {
    stdout: JSON.stringify(data, null, 2),
    "scripts/load-test-results.json": JSON.stringify(data),
  };
}

/**
 * Pincer Webhook Channel Load Test (k6)
 *
 * Tests the webhook channel under sustained load.
 * Run with: k6 run test/load/k6_pincer_api.js
 *
 * Requires PINCER_URL env var (default: http://localhost:4000)
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const responseLatency = new Trend('response_latency');

const BASE_URL = __ENV.PINCER_URL || 'http://localhost:4000';

export const options = {
  scenarios: {
    // Ramp up to 50 concurrent users over 1 minute, hold 2 min, ramp down
    sustained_load: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '1m', target: 50 },
        { duration: '2m', target: 50 },
        { duration: '30s', target: 0 },
      ],
    },
    // Spike test: sudden burst to 200 users
    spike: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '10s', target: 200 },
        { duration: '30s', target: 200 },
        { duration: '10s', target: 0 },
      ],
      startTime: '3m30s',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<3000'],  // 95% of requests under 3s
    errors: ['rate<0.05'],              // Error rate below 5%
    http_req_failed: ['rate<0.05'],
  },
};

export default function () {
  const payload = JSON.stringify({
    message: `Load test message ${__VU}-${__ITER}`,
    user_id: `load_test_user_${__VU}`,
  });

  const params = {
    headers: { 'Content-Type': 'application/json' },
    timeout: '10s',
  };

  const start = Date.now();
  const res = http.post(`${BASE_URL}/webhook/message`, payload, params);
  responseLatency.add(Date.now() - start);

  const success = check(res, {
    'status is 200 or 202': (r) => r.status === 200 || r.status === 202,
    'response time < 5s': (r) => r.timings.duration < 5000,
  });

  errorRate.add(!success);
  sleep(Math.random() * 2 + 0.5); // random think time 0.5-2.5s
}

export function handleSummary(data) {
  return {
    'test/load/results/k6_summary.json': JSON.stringify(data, null, 2),
  };
}

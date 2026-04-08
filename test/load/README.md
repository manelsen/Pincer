# Load Tests

## k6 Load Test

Requires [k6](https://k6.io/docs/get-started/installation/) installed.

```bash
# Basic run against local instance
k6 run test/load/k6_pincer_api.js

# Run against staging
PINCER_URL=https://staging.example.com k6 run test/load/k6_pincer_api.js
```

### Scenarios

- **sustained_load**: Ramp to 50 VUs over 1min, hold 2min, ramp down. Thresholds: p95 < 3s, error rate < 5%.
- **spike**: Burst to 200 VUs for 30s (starts at 3m30s). Tests autoscaling and overload handling.

## Elixir Benchmarks

```bash
# LLM client dispatch benchmark
mix run test/bench/llm_client_bench.exs

# Session context benchmark
mix run test/bench/session_bench.exs
```

## Chaos & Stress Tests

```bash
# Run chaos tests (tagged :chaos)
mix test --only chaos

# Run stress tests (tagged :stress)
mix test --only stress
```

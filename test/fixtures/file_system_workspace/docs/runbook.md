# Webhook Runbook

## Symptoms

- webhook timeout on deploy
- retry storm after provider outage

## First response

1. inspect queue depth
2. check retry budget
3. apply the hotfix only after the canary is green

# SIDECAR_RUNTIME_HARDENED_V2.md

Status: proposed  
Date: 2026-02-22

## Objetivo
Reintroduzir runtime de skills isoladas sem depender do processo BEAM para executar codigo de terceiros, com barreiras de seguranca e operabilidade de producao.

## Contexto
- O sidecar Node v1 era um PoC util para validar MCP over stdio.
- Foi removido do produto para reduzir superficie de ataque e divida operacional.
- A arquitetura core-first continua: o core Elixir orquestra, o sidecar apenas executa tools.

## Interfaces Publicas (contrato v2)
- `mcp.servers.skills_sidecar.command`
- `mcp.servers.skills_sidecar.args`
- `mcp.servers.skills_sidecar.env`
- `Pincer.Connectors.MCP.Manager.execute_tool/2` (sem mudanca de assinatura)

## Requisitos Nao-Negociaveis
- Isolamento por container:
  - `--read-only`
  - `--network=none` por default
  - `--cap-drop=ALL`
  - `--pids-limit`, `--memory`, `--cpus`
  - mount explicito apenas para `/sandbox` (rw) e `/tmp` controlado
- Execucao sem root no container.
- Registry de skills com allowlist de origem e artefato versionado.
- Validacao de integridade por `sha256` (minimo) antes de ativar skill.
- Timeout de execucao por tool + kill hard apos grace period.
- Auditoria minima:
  - tool chamada
  - skill id/versao
  - duracao
  - status (ok/erro/timeout/bloqueado)

## Politica de Seguranca de Runtime
- Sem shell arbitrario dentro do sidecar.
- Sem acesso de escrita fora de `/sandbox`.
- Sem outbound network por default.
- Variaveis de ambiente sensiveis bloqueadas por denylist explicita.
- Input de tool validado por schema estrito (zod/json schema).

## Plano TDD (v2)
1. RED: testes de contrato de configuracao (`skills_sidecar` ausente/invalido).
2. RED: testes de policy de isolamento (flags obrigatorias).
3. GREEN: adapter de bootstrap do sidecar com defaults seguros.
4. RED: testes de execucao com timeout + kill.
5. GREEN: integracao com `MCP.Manager` mantendo compatibilidade de tools.
6. REFACTOR: consolidar policy em modulo core dedicado.

## Critrios de Aceite
1. sidecar nao sobe sem limites obrigatorios de isolamento.
2. tools de skill nao executam com rede aberta por padrao.
3. erro de skill nao derruba `MCP.Manager` nem executor.
4. auditoria minima emitida para toda execucao.
5. fluxo completo coberto por testes de contrato + integracao.

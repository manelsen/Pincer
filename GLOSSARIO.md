# Glossário de Siglas e Códigos (Pincer)

## Códigos de planejamento
- `SPR-NNN`: Sprint renumerada e alinhada a commit/branch (`SPR-001`..`SPR-031` atualmente).
- `Legacy SPR`: IDs antigos pré-renumeração.
  - `SPR-01..SPR-04` -> `SPR-028`
  - `SPR-05..SPR-14` -> `SPR-029`
  - `SPR-15` -> `SPR-030`
  - `SPR-16` -> `SPR-031`
- `CXX`: Capability ID na matriz de capacidades (`C01`..`C18`).
- `P0`, `P1`, `P2`: ondas de prioridade.
- `TODO`: checklist operacional da execução.

## Arquitetura e decisão
- `ADR-XXXX`: *Architecture Decision Record* (registro formal de decisão arquitetural).
- `Hexagonal`: arquitetura `Ports and Adapters`; o core define contratos, adapters conectam canais/providers.
- `Core-first`: regra de projeto em que UX/DX/A11y e regras de negócio vivem no core.

## Qualidade e processo
- `Doc-First`: especificar contrato e critérios de aceite antes de implementar.
- `TDD`: `RED -> GREEN -> REFACTOR`.
- `DDD` (aqui no projeto): *Documentation-Driven Development* (atualizar specs/checklists/memória a cada incremento).

## Testes
- `RED`: teste novo falhando (funcionalidade ainda não existe/comportamento não atende).
- `GREEN`: implementação mínima para passar o teste.
- `REFACTOR`: melhoria interna sem quebrar testes.
- `Teste de contrato`: valida conformidade entre core e adapter (mesmo comportamento com implementações diferentes).

## Operação e resiliência
- `Backoff exponencial`: aumento progressivo de espera entre tentativas.
- `Retry transitório`: repetição automática para erros temporários (ex.: `408`, `429`, `5xx`, timeout de transporte).
- `Failover`: troca de modelo/provedor quando houver falha classificada como recuperável.

## Canais e UX
- `Menu persistente`: affordance fixa (`Menu`) para navegação rápida e acessível.
- `A11y`: acessibilidade (ex.: navegação previsível, linguagem curta e explícita).
- `DX`: experiência de desenvolvimento.
- `UX`: experiência de uso.

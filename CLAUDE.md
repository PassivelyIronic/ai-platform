# CLAUDE.md — ai-platform (Project 2: internal AI platform with a deterministic promotion gate)

## What this project is

A minimal **internal AI platform**: a self-service path for shipping LLM services to Kubernetes. A developer declares a service in one YAML contract and opens a PR; the platform builds it, seeds its database, deploys to staging, runs the service's own quality gate, promotes to production via canary, and monitors it. No `kubectl` on the consumer side.

Runs on k3s. The cluster is stood up by `bootstrap/` in this repo — k3d, three nodes, one command (DECISIONS D-021, superseding the separate provisioning repo of D-018). `bootstrap/` is the only place in the project where anything runs imperatively; everything past ArgoCD's existence goes through git. Tenant #1 is `tsl-rag-v2`; tenant #2 exists to prove the contract is generic (DECISIONS D-010).

What that environment does **not** prove, and what the README must therefore not claim: arm64 at runtime (images are built multi-arch, only amd64 is exercised), startup timings on the target hardware, a public Ingress with TLS, or node failure. See `bootstrap/README.md`.

The differentiator vs a standard delivery platform: **promotion is blocked by a deterministic quality gate**, and rollouts are canary with metric-based promotion.

Formerly `llmops-pipeline` — same technical core, reframed around a contract and more than one tenant.

## Architecture (target state)

```
tenant repo push
  → GitHub Actions (reusable workflow): lint, pytest, buildx (arm64+amd64), push GHCR
  → CI opens PR bumping image.tag in ai-platform/services/<name>/service.yaml
  → ApplicationSet sees services/*/ → Application per tenant per env
  → ArgoCD syncs staging, namespace per tenant:
        wave 0  Postgres/pgvector StatefulSet + CREATE EXTENSION vector
        wave 1  restore Job: pg_restore of the seed dump (OCI artifact)
        wave 2  API (+ optional UI)
        PostSync  gate Job: the tenant's own eval command
  → gate: exit code 0 → CI opens PR promoting to prod
  → prod: Argo Rollouts canary 10% → analysis (after warmup) → promote | rollback
  → platform dashboard: latency, outcomes, cost, gate status per tenant; alerts → runbook
```

## The platform contract

`services/<name>/service.yaml` is the **only** interface a tenant uses:

A worked example lives in `services/tsl-rag/service.yaml`; the full field definition
is `schemas/service.schema.json`. Read those, never a copy — a second copy of the
contract is a second thing to keep in sync, and it loses (D-020).

Validated by JSON Schema in CI. A bad contract fails the PR, never the cluster.

## The gate — and what the platform is NOT allowed to know about it

The contract declares the gate's **image, command and dependencies**. Its criteria are **opaque to the platform**: the platform checks the exit code and the timeout, nothing else.

The gate runs the **same image and tag as the deployed API**, so it evaluates exactly the artifact it is gating — not a rebuild, not a checkout. Tenant #1 reached this state by adding `evals/` to its production image (DECISIONS D-019); a separate gate image was rejected because a second tag is a second chance for the gate and the gated code to drift apart.

- Thresholds live in the tenant repo (`evals/thresholds.yaml` for tenant #1) and are governed by that repo's own rule — a threshold change is a separate commit with a justification.
- **Do not generate a threshold validator, a thresholds field, or any parsing of gate output in this repo.** If a rule about threshold values feels missing here, it belongs in the tenant repo. This is DECISIONS D-014.
- A gate Job may additionally push scores to pushgateway for dashboards. Those numbers never feed a promotion decision.

Why tenant #1's gate measures retrieval and not answer quality: its LLM-as-judge evals have a measured spread of up to 0.133 between runs of identical code, so a gate built on them passes regressions and blocks improvements at random. Its retrieval evals are deterministic, need no network and no provider key, and finish in ~40 s. Generation quality is measured and alerted on, never gated. This is the project's headline argument — see DECISIONS D-013.

**Consequence for the sabotage demo:** it must target retrieval (`rrf_k`, disabling the dense or BM25 branch, changing the chunker). A prompt-level sabotage will sail through the gate, correctly.

## Seeding — why there is no ingest in the deploy path

Ingest needs PDF parsers (`unstructured[pdf]` → torchvision, opencv, spacy) — a multi-gigabyte image, minutes of CPU, and the embedding model, to produce the same 438 vectors every time. Running it per namespace is waste.

Instead: the `tsl-rag-ingest` image runs **only** when the corpus, the chunker or the embedding model changes, and its output is a `pg_dump -Fc` of `document_chunks` (heap 1.3 MB, with the HNSW index ~8 MB) published as an OCI artifact next to the API image. A fresh namespace does `pg_restore` in seconds with no parsers and no model. DECISIONS D-015.

Implementation constraints that are not optional:
- `CREATE EXTENSION vector` runs **before** restore; a table dump does not carry the extension.
- The restore Job is idempotent (row-count check first) — ArgoCD resyncs, and a second restore would duplicate rows.
- Sync waves as in the diagram above; without them the gate runs against an empty database.
- `database.mode: external` skips restore entirely.
- The dump carries `embedding_model` in its metadata; tenant CI compares it against `database.embeddingModel`. `warmup()` would catch a mismatch anyway, but 60 s later and inside a pod.
- Dump tags are derived from corpus + model + chunker content, never from the API image SHA (D-016).

## Guardrails (non-negotiable)

1. **Every tenant passes a gate.** No exemptions, no "temporarily disabled for onboarding". A service without a deterministic gate does not get onboarded.
2. **Gate criteria are opaque to the platform.** Exit code and timeout only. No threshold logic in this repo.
3. **No manual prod changes.** No `kubectl apply/edit` against prod namespaces; `selfHeal: true` reverts drift. Emergencies go through git revert.
4. **No secrets in git** — SealedSecrets only. Provider keys rotated if ever printed to logs.
5. **No unverified claims in README.** Diagrams must match actual workflow files; every claimed gate must be demonstrably blocking. Numbers in docs must be traceable to a measurement, not to an earlier version of the docs. **Any command a Job will run is verified against the built artifact, never against a repo checkout** — a command that works in a clone and not in the image is the most expensive kind of documentation bug here, and CI runs the gate command against every freshly built image to keep it that way.
6. **No per-tenant snowflakes.** A tenant's needs are met by extending the contract and the shared chart for everyone, or by an explicit "Out of scope" entry — never by hand-written manifests next to `service.yaml`.
7. **Onboarding docs are executable.** `docs/onboarding.md` is verified by onboarding tenant #2 following only the doc. Anything you had to figure out outside the doc is a bug in the doc.
8. **Cost visibility is a feature.** Token usage per tenant must reach Grafana; do not disable it to reduce noise.
9. **Cloud spend is capped before it is incurred.** Budget alert and a teardown runbook entry precede any managed-cloud experiment.

## Conventions

- Reusable GitHub Actions workflow; tenant repos call it — pipeline logic lives here, not copy-pasted
- Image tags are immutable digests or git SHAs, never `latest`
- One namespace per tenant, with ResourceQuota and NetworkPolicy shipped by the chart; NetworkPolicy must allow Prometheus to scrape `/metrics` (unauthenticated by design)
- `/ready` is never wired to a liveness probe — it returns 503 on a transient database outage and would restart-loop pods instead of just removing them from the Service
- No HPA by CPU. The bottleneck is the external provider's throughput and daily limit, not pod CPU. Opt-in autoscaling is on `tsl_rag_stage_duration_seconds` or in-flight requests, and the README says why (D-017)
- ApplicationSet for tenants, app-of-apps for platform components; every Application has explicit `syncPolicy`, namespace and sync wave
- Alert rules ship with the dashboard that visualizes them and the runbook procedure that resolves them
- `make render` produces locally the same manifests ArgoCD applies; diffs are commented on PRs

## Definition of done for any task

- Change flows through the pipeline itself (dogfooding) — no out-of-band deploys
- Works for every tenant, not just the one you tested with
- A fresh namespace still reaches "API ready, database seeded, gate green" with no manual step
- Grafana reflects any new metric; new alerts have a runbook entry
- If the change touched the contract or the chart, `docs/onboarding.md` is still accurate

# PLAN.md — ai-platform (dawniej llmops-pipeline)

Timebox: ~4 tygodnie (tydz. 5–8 wspólnej roadmapy). Tenant #1: `tsl-rag-v2`.

**Teza projektu:** deweloper dodaje serwis LLM do platformy jednym PR-em z ~30 liniami YAML; platforma buduje, zasiedla bazę, wdraża na staging, uruchamia deterministyczną bramkę jakości, promuje canary na prod i monitoruje. Żadnego `kubectl` po stronie użytkownika platformy.

**Metryka do README:** czas i liczba kroków onboardingu tenanta #2, zmierzone i zapisane (cel: < 30 min od PR do działającego serwisu na stagingu).

**Co odróżnia tę bramkę od typowego "eval gate":** promocję blokuje metryka **deterministyczna** (retrieval), a nie LLM-as-judge o zmierzonym rozrzucie 0.133. Patrz D-013 — to jest główny punkt na rozmowie, nie detal.

---

## Phase 0 — CI foundation + kontrakt + seed pipeline (tydz. 5)

Legenda: `[x]` zrobione i zweryfikowane, `[~]` częściowo — z opisem, czego brakuje.

- [x] Reusable workflow: ruff + pytest + buildx multi-arch (arm64+amd64) + push GHCR, tag = git SHA — `ai-platform/.github/workflows/service-ci.yml`. Tag bierze się z głowy gałęzi, nie z `github.sha`: przy `pull_request` to drugie wskazuje efemeryczny merge commit, którego nie ma w historii, czyli tag nie do zapinowania
- [x] `tsl-rag-v2` wywołuje workflow — pierwszy zielony przebieg 2026-07-30 (lint 1m26s, build 12m50s, bramka 1m39s). **Badge w README tenanta wciąż do dodania**
- [x] ~~Weryfikacja bramki w obrazie~~ — zrobione 2026-07-29, wynik negatywny: `evals/` nie było w obrazie, `uv` nie istnieje w runtime, komenda z `docs/KUBERNETES.md` §5 nie wykonuje się w ogóle (D-019)
- [x] `COPY evals/ ./evals/` do finalnego stage'a `docker/Dockerfile`; poprawka komendy w `docs/KUBERNETES.md` §5 + data w nagłówku; kopia w `ai-platform` usunięta (D-020). PR #1. Przy okazji wyszło drugie dno: walidacja golden datasetu ciągnęła `fitz` przez `ingestion.cli`, więc sam `COPY` nie wystarczał — rejestr idzie teraz z `core.documents`
- [x] **Smoke test bramki w workflow buildu** — bramka uruchamiana na świeżo zbudowanym obrazie przeciwko Postgresowi zasiedlonemu z artefaktu seed. Workflow sprawdza też zgodność `embedding-model` z labelem artefaktu (D-015)
- [~] Job bramki w charcie ustawia `workingDir: /app` — jest w `values.yaml` jako default; sam szablon Joba powstanie razem z resztą szablonów charta
- [x] **JSON Schema dla `service.yaml`** (D-007) + walidacja w CI — `schemas/service.schema.json` + `scripts/validate_contracts.py` + workflow `kontrakty`. Zweryfikowane, że blokuje: `latest`, `gate.image` różny od obrazu API, pole `thresholds` (D-014), brak bramki, `managed` bez seeda, kroki canary niekończące się na 100
- [ ] Obraz `tsl-rag-ingest` (`uv sync --extra ingest`) + workflow produkujący `pg_dump -Fc` tabeli `document_chunks`, uruchamiany **tylko** przy zmianie `data/raw/`, chunkera lub modelu embeddingów (D-015)
- [~] Publikacja dumpu jako OCI artifact w GHCR, tag = hash korpusu/parsera/chunkera/modelu (D-016); metadane niosą `embedding_model` — artefakt `tsl-rag-corpus:corpus-f646c99b8ebf` opublikowany i **wykorzystywany przez CI**, ale wyprodukowany ręcznie. Skrypt liczący tag jest w PR #2; automatyzacja produkcji to punkt wyżej
- [~] `charts/ai-service` — szkielet: Deployment API, Service, Ingress, ServiceMonitor. Jest `Chart.yaml` i `values.yaml` z defaultami dla każdego pola kontraktu; `templates/` nadal puste

**Acceptance:** push do `tsl-rag-v2` → zielony pipeline → obraz multi-arch z SHA w GHCR, bez ręcznych kroków. `helm template services/tsl-rag/service.yaml` renderuje kompletne manifesty, `kubeconform` je akceptuje. Zmiana jednego PDF-a w `data/raw/` produkuje nowy dump z nowym tagiem; zmiana samego kodu **nie** produkuje.

## Phase 1 — GitOps + self-service onboarding (tydz. 5–6)

- [ ] ArgoCD na klastrze (osobny namespace, Ingress `/argocd` za auth)
- [ ] App-of-apps **tylko dla komponentów platformowych** (ArgoCD, kube-prometheus-stack, Rollouts, SealedSecrets)
- [ ] **ApplicationSet z git directory generatorem** na `services/*/` (D-009), namespace per tenant
- [ ] Chart: StatefulSet Postgres/pgvector + init (`CREATE EXTENSION vector`) + **idempotentny restore Job** ciągnący dump z OCI (D-015)
- [ ] Sync waves: 0 Postgres → 1 restore → 2 API/UI → PostSync bramka. Bez tego bramka wystartuje na pustej bazie
- [ ] Probe'y wg zmierzonych czasów na ARM: `startupProbe` pokrywający ~2 min, readiness `initialDelaySeconds` ≥ 60, **`/ready` nigdy jako liveness**
- [ ] PVC na cache HF (`HF_HOME`) — bez niego każdy restart ciągnie 1.1 GB
- [ ] Onboarding tenanta #1 wyłącznie przez dodanie `services/tsl-rag/service.yaml`
- [ ] CI po buildzie otwiera PR bumpujący `image.tag` w kontrakcie (staging: automerge)
- [ ] `selfHeal` + `prune`; test driftu: ręczna edycja → ArgoCD przywraca
- [ ] ResourceQuota + NetworkPolicy per namespace (NetworkPolicy musi przepuścić scrape Prometheusa na `/metrics`)

**Acceptance:** świeży namespace dochodzi do stanu "API ready, baza z 438 chunkami" bez ręcznej interwencji i bez parserów PDF w klastrze. Usunięcie katalogu z `services/` usuwa serwis. Ponowny sync nie duplikuje wierszy w `document_chunks`.

## Phase 2 — Bramka promocji (tydz. 6)

- [ ] `eval-gate` jako część charta: Job z ArgoCD PostSync hook (D-004), obraz i komenda z kontraktu, `needs: [database]`
- [ ] **Platforma czyta wyłącznie exit code i timeout** (D-014). Zero parsowania progów po stronie platformy — to repo aplikacji ma `evals/thresholds.yaml` i własną zasadę ich zmiany
- [ ] Bramka w CI: workflow czeka na wynik Joba; pass → PR promujący na prod, fail → blokada + logi Joba w komentarzu
- [ ] Brak retry i brak "marginesu na wariancję" — bramka jest deterministyczna (D-013). Jeśli kiedykolwiek zamigra, to znaczy, że coś w niej przestało być deterministyczne, i to jest bug, nie powód do retry
- [ ] Opcjonalnie: Job wypycha wyniki do pushgateway **dla dashboardu**, nie dla decyzji
- [ ] **Demo sabotażu**: zmiana dotykająca retrievalu (`rrf_k`, wyłączenie gałęzi dense albo BM25) → recall poniżej progu → blokada. Powtarzalne co do liczby, bo deterministyczne

**Acceptance:** regresja retrievalu nie dociera do prod; zdrowy commit przechodzi end-to-end automatycznie; `make sabotage-demo` daje ten sam wynik przy każdym uruchomieniu.

## Phase 3 — Canary (tydz. 7)

- [ ] Argo Rollouts na prod, sterowany polem `rollout` z kontraktu: 10% → 50% → 100%
- [ ] **AnalysisTemplate startuje dopiero po `analysisStartAfterSeconds`** — przy ~2 min do gotowości analiza ruszająca od razu uzna zdrową wersję za zepsutą
- [ ] Metryki analizy z tego, co aplikacja już eksportuje: `tsl_rag_answers_total{outcome}`, `tsl_rag_provider_errors_total`, p95 `tsl_rag_stage_duration_seconds{stage="generate"}`
- [ ] Demo rollbacku: wersja z wstrzykniętym błędem cofa się sama pod ruchem z `k6`

**Acceptance:** nagrany przebieg: promocja zdrowej wersji i automatyczny rollback zepsutej, oba bez interwencji.

## Phase 4 — Tenant #2 + observability platformowa (tydz. 7)

To jest faza, która zamienia pipeline w platformę. Jeśli coś ma wypaść z zakresu, **nie ta**.

- [ ] Onboarding tenanta #2 (D-010) — z zegarkiem, bez poprawiania charta w trakcie. Każda rzecz, którą musisz dopisać w chartcie, to dziura w kontrakcie → wpis w `docs/onboarding-retro.md`
- [ ] Tenant #2 musi mieć własną deterministyczną bramkę. Bez niej nie wchodzi (guardrail #1)
- [ ] **Dashboard platformowy** (nie per-aplikacja): p95 i error rate per tenant, `tsl_rag_answers_total{outcome}`, `tsl_rag_fallback_switches_total`, koszt/tokeny per tenant, wykorzystanie ResourceQuota, wynik ostatniej bramki
- [ ] Dashboard per-tenant generowany z szablonu — nowy tenant dostaje go automatycznie
- [ ] OTel Collector → Jaeger; trace E2E jednego zapytania (spany `retrieve → dense_search | bm25_search | rrf_fusion → generate → llm_call`)

**Uwaga do budżetu:** SDK OpenTelemetry i metryki Prometheus są **już w kodzie aplikacji**. Ta faza to konfiguracja Collectora i budowanie dashboardów na istniejących nazwach metryk, nie instrumentacja. Odzyskany czas idzie na tenanta #2.

**Acceptance:** jeden screenshot pokazuje dwa tenanty obok siebie z kosztem i statusem bramki; onboarding tenanta #2 opisany z rzeczywistym czasem.

## Phase 5 — Reliability + runbook (tydz. 8, pierwsza połowa)

Pokrywa "monitorować działanie platformy i wspierać rozwiązywanie problemów" — bez tego masz wdrażanie, nie utrzymanie.

- [ ] Alerty: wzrost `tsl_rag_provider_errors_total{kind="transient"}`, niezerowe `outcome="all_providers_failed"`, p95 `generate` > 30 s, brak wyniku bramki, ApplicationSet out-of-sync, tenant przy limicie quoty
- [ ] `docs/runbook.md`: jedna procedura na alert — objaw, komenda diagnostyczna, ścieżka naprawy, kiedy eskalować
- [ ] Chaos, scenariusze specyficzne dla tej aplikacji (nie generyczne ubijanie podów):
  - NetworkPolicy blokująca OpenRoutera → oczekiwany wzrost `tsl_rag_fallback_switches_total`, brak 500-ek. **Znana luka: oba ogniwa fallbacku są na OpenRouterze**, więc ten test pokaże wyczerpanie łańcucha — udokumentuj to jako wynik, nie ukrywaj
  - ubicie poda Postgresa → `/ready` 503, pod wypięty z Service, **brak restart-loopa** (dowód, że liveness nie jest podpięte pod `/ready`)
  - wyczerpanie quoty przez jednego tenanta → drugi nie traci p95
- [ ] Weryfikacja teardownu środowiska efemerycznego: usunięcie namespace'u, ponowne utworzenie, bramka przechodzi

**Acceptance:** każdy alert ma procedurę, którą przeszedłeś raz; screenshoty alert → runbook → recovery.

## Phase 6 — GCP portability + docs + demo (tydz. 8, druga połowa)

- [ ] Budget alert 5 USD **przed** pierwszym `gcloud` (D-011)
- [ ] Artifact Registry jako mirror; ten sam repo podpięty do GKE Autopilot
- [ ] `docs/portability.md`: co trzeba było zmienić (StorageClass, Ingress, arch, IAM), co zadziałało bez zmian
- [ ] Teardown klastra GCP w tym samym tygodniu — z runbooka, nie z pamięci
- [ ] README: diagram zgodny z workflow files; tabela "standard CI/CD vs LLMOps CI/CD"; **sekcja "dlaczego bramka mierzy retrieval, a nie jakość odpowiedzi"** (rozrzut 0.133); **akapit "dlaczego nie HPA po CPU"** (D-017)
- [ ] Nagranie: onboarding serwisu od pustego katalogu do prod + demo sabotażu + auto-rollback
- [ ] Retro: eval jako Argo Rollouts analysis zamiast PostSync hook; kontrakt jako CRD + operator; CloudNativePG zamiast StatefulSetu

**Acceptance:** quickstart zweryfikowany na czystym klonie; osoba spoza projektu dodaje trzeci serwis wyłącznie z `docs/onboarding.md`.

---

## Kolejność przy presji czasu

Tnij w kolejności: Phase 6 GCP → Jaeger w Phase 4 → Phase 3 canary. **Phase 4 (tenant #2) i Phase 5 (runbook) zostają** — to one odróżniają platformę od pipeline'u, a runbook jest jedynym artefaktem mówiącym o utrzymaniu.

Po Phase 1 masz coś linkowalnego w CV. Nie czekaj z aplikacjami do Phase 6.

## Out of scope (świadomie)

Fine-tuning w pipelinie, A/B testing na realnym ruchu, multi-cluster promotion, własny operator/CRD, Backstage, RBAC ponad separację namespace'ów, autoscaling po kolejce, CloudNativePG, druga platforma inferencji (Cloudflare Workers AI — kandydat, ale to zmiana w repo aplikacji, nie w platformie). Kusi → najpierw wpis tutaj.

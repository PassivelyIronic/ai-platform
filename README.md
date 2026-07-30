# ai-platform

Wewnętrzna platforma AI: samoobsługowa ścieżka wdrażania serwisów LLM na Kubernetes.
Deweloper deklaruje serwis w jednym pliku YAML i otwiera PR — platforma buduje obraz,
zasiedla bazę, wdraża na staging, uruchamia bramkę jakości, promuje canary na prod
i monitoruje. Bez `kubectl` po stronie użytkownika platformy.

**Co odróżnia ją od zwykłej ścieżki dostarczania:** promocję blokuje bramka
**deterministyczna**, a nie LLM-as-judge. Uzasadnienie i pomiar: [DECISIONS.md](DECISIONS.md) D-013.

## Status

**Przed Phase 0.** Repo zawiera dokumenty projektowe, szkielet struktury i konfigurację
narzędzi. Nie ma jeszcze działającego pipeline'u, charta z szablonami ani żadnego tenanta —
zakres i kolejność prac opisuje [PLAN.md](PLAN.md).

Ten plik będzie rozbudowywany dopiero o rzeczy zmierzone i działające; liczby bez
odnośnika do pomiaru do niego nie trafiają (guardrail #5 w [CLAUDE.md](CLAUDE.md)).

## Dokumenty

| Plik | Rola |
|---|---|
| [CLAUDE.md](CLAUDE.md) | zakres projektu, kontrakt platformy, guardraile |
| [PLAN.md](PLAN.md) | fazy, kryteria akceptacji, kolejność cięcia przy presji czasu |
| [DECISIONS.md](DECISIONS.md) | log decyzji architektonicznych, wspólny dla obu projektów |

Dokument przekazania od tenanta #1 (endpointy, zmierzone czasy startu, zasoby, metryki)
mieszka w jednym miejscu — w repo tenanta: `PassivelyIronic/tsl-rag-v2`, `docs/KUBERNETES.md`,
stan na `d9cf88f`. To, co z niego wynikło, jest już zapisane w kontrakcie, w charcie
i w D-015; platforma trzyma odnośnik, nie kopię (D-020).

## Środowisko

Platforma działa na k3s. Klaster developerski stawia `bootstrap/` — k3d, trzy węzły,
jedna komenda:

```
make cluster      # k3d: 1 serwer + 2 agenty
make bootstrap    # ArgoCD + komponenty platformy
make tenants      # ApplicationSet nad services/
```

Trzy węzły, nie jeden: przy jednym każdy pod ląduje tam, gdzie wolumen, więc konflikt
node affinity na PVC byłby nieodtwarzalny. Czego to środowisko nie dowodzi — arm64
w runtime, czasów startu na docelowym sprzęcie, publicznego Ingressu z TLS, awarii
węzła — opisuje [`bootstrap/README.md`](bootstrap/README.md).

## Wymagane narzędzia

`helm` ≥ 4.0 · `kubectl` · `k3d` · `kubeconform` · `yq` · `make` · `gh` · `docker`

Weryfikacja: `make tools`

## Struktura

```
services/       kontrakty tenantów — jeden service.yaml na serwis
charts/         ai-service: wspólny chart, którego values file to kontrakt (D-008)
argocd/         ApplicationSet dla tenantów, app-of-apps dla komponentów platformy (D-009)
observability/  konfiguracja collectora, dashboardy, reguły alertów
schemas/        JSON Schema kontraktu — walidacja w CI, zły kontrakt failuje PR (D-007)
docs/           onboarding, runbook, portability
secrets/        wyłącznie SealedSecrets
```

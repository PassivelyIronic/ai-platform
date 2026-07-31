# ai-platform

Wewnętrzna platforma AI: samoobsługowa ścieżka wdrażania serwisów LLM na Kubernetes.
Serwis jest opisany jednym plikiem YAML; wszystko dalej — build, zasiew bazy, wdrożenie,
bramka jakości — dzieje się przez git, bez `kubectl` po stronie użytkownika platformy.

Cechą wyróżniającą jest **deterministyczna bramka jakości**: awans wersji blokuje
mierzalne kryterium retrievalowe, nie ocena modelu językowego.

## Status

Stan na 2026-07-31. Poniższe działa i zostało zweryfikowane na żywym klastrze k3d
(k3s v1.31, 1 serwer + 2 agenty):

| Obszar | Stan |
|---|---|
| Kontrakt serwisu + walidacja JSON Schema w CI | działa |
| Reusable workflow GitHub Actions (lint, testy, build multi-arch, GHCR) | działa |
| Zasiew bazy z artefaktu OCI zamiast ingestu w ścieżce wdrożenia | działa |
| GitOps: ArgoCD, app-of-apps, ApplicationSet nad kontraktami | działa |
| Dwa środowiska (staging, prod) z namespace per para tenant-środowisko | działa |
| Bramka jakości jako PostSync Job, blokująca na podstawie exit code | działa |
| SealedSecrets per środowisko | działa |
| Automatyczny PR promocyjny staging → prod po zielonej bramce | w toku |
| Canary z Argo Rollouts i promocją na podstawie metryk | zaplanowane |
| Drugi tenant, dashboardy platformowe, runbook | zaplanowane |

Świeży namespace dochodzi bez ręcznego kroku do stanu: API gotowe, baza zasiedlona,
bramka zielona. Zweryfikowano dla obu środowisk po migracji na podział staging/prod.

**Zmierzone liczby** (guardrail: liczba bez odnośnika do pomiaru nie trafia do dokumentów):

- bramka retrievalowa: recall@5 **0.958**, recall@10 **0.969**, MRR **0.874**, przy progach 0.938 / 0.948 / 0.850
- identyczny wynik w trzech niezależnych środowiskach: lokalny Docker, runner GitHub Actions, klaster k3d
- rozrzut ocen LLM-as-judge między przebiegami tego samego kodu: do **0.133**
- Job bramki na klastrze: **91 s** od startu do zakończenia, 48 przypadków ewaluacyjnych
- korpus tenanta #1: **438** fragmentów z 13 dokumentów
- zimny start poda: **122 s** przy pustym cache modelu (pobranie 1,1 GB, załadowanie, indeks BM25)
- seed dump: 1,8 MB (`pg_dump -Fc`), artefakt OCI 6,08 MB
- obraz API: 2,59 GB, build multi-arch ~13 min, zdominowany przez arm64 pod QEMU

**Czego to środowisko nie dowodzi:** arm64 w runtime (obrazy budowane multi-arch, ćwiczony
wyłącznie amd64), czasów startu na docelowym sprzęcie, publicznego Ingressu z TLS, awarii węzła.
Szczegóły: [`bootstrap/README.md`](bootstrap/README.md).

## Kluczowe decyzje techniczne

Pełny log wraz z uzasadnieniami i odrzuconymi wariantami: [DECISIONS.md](DECISIONS.md).

**Bramka mierzy retrieval, nie jakość odpowiedzi** (D-013). Ewaluacje typu LLM-as-judge mają
w tym projekcie zmierzony rozrzut do 0,133 między przebiegami identycznego kodu — bramka na
nich zbudowana przepuszczałaby regresje i blokowała poprawki losowo. Ewaluacje retrievalowe są
deterministyczne i nie wymagają sieci ani klucza providera. Jakość generacji jest mierzona
i alertowana, nigdy bramkowana.

**Kryteria bramki są nieprzezroczyste dla platformy** (D-014). Kontrakt deklaruje obraz, komendę
i limit czasu; platforma sprawdza kod wyjścia i timeout, nic więcej. Progi żyją w repo tenanta,
razem z regułą, że ich zmiana to osobny commit z uzasadnieniem.

**Bramka jedzie na tym samym obrazie i tagu co wdrożone API** (D-019). Osobny obraz bramki
został odrzucony: drugi tag to druga szansa na rozjazd między bramką a kodem, który ma oceniać.
Walidator kontraktu wymusza tę równość również w nakładce produkcyjnej.

**Zasiew bazy przez `pg_restore` z artefaktu OCI, nie przez ingest** (D-015). Ingest wymaga
parserów PDF i modelu embeddingów — kilka GB obrazu i minuty CPU po to, żeby wyprodukować za
każdym razem te same 438 wektorów. Dump powstaje wyłącznie, gdy zmieni się korpus, chunker albo
model, a jego tag pochodzi z treści tych trzech rzeczy, nie z SHA obrazu API (D-016).

**Kontrakt jest definicją stagingu, prod jest minimalną nakładką** (D-022). Zbiór środowisk
należy do platformy, nie do kontraktu — tenant nie może zadeklarować środowiska omijającego
prod. Nakładka nie ma własnej schemy: walidator scala ją z kontraktem i waliduje wynik scalenia,
dzięki czemu reguły międzypolowe obowiązują w obu środowiskach.

**Wszystko poza `bootstrap/` idzie przez git** (D-021, D-023). ApplicationSety tenantów są
komponentem app-of-apps, nie krokiem ręcznym. Wcześniej wchodziły na klaster imperatywnie, przez
co push zmieniający generator nie robił nic i nie zgłaszał przy tym błędu — Application pokazywał
`Synced` względem nieaktualnego generatora.

**Brak HPA po CPU** (D-017). Wąskim gardłem jest przepustowość i dzienny limit zewnętrznego
providera, nie CPU poda. Skalowanie jest opcjonalne i oparte na czasie trwania etapów lub liczbie
żądań w locie.

## Uruchomienie

```
make cluster      # k3d: 1 serwer + 2 agenty
make bootstrap    # ArgoCD + komponenty platformy
```

ApplicationSety tenantów są komponentem platformy, więc przychodzą przez app-of-apps razem
z resztą. Poza tymi dwiema komendami nic nie wykonuje się imperatywnie.

`make validate` renderuje lokalnie te same manifesty, które nakłada ArgoCD, i sprawdza je
`kubeconform`.

Wymagane narzędzia: `helm` ≥ 4.0 · `kubectl` · `k3d` · `kubeconform` · `yq` · `make` · `gh` · `docker`
(weryfikacja: `make tools`).

## Struktura

```
services/       kontrakty tenantów — service.yaml plus opcjonalna nakładka produkcyjna
charts/         ai-service: wspólny chart, którego values file to kontrakt (D-008)
argocd/         ApplicationSety tenantów, app-of-apps komponentów platformy (D-009)
bootstrap/      klaster developerski k3d i pierwsza instancja ArgoCD (D-021)
schemas/        JSON Schema kontraktu — walidacja w CI, zły kontrakt failuje PR (D-007)
secrets/        wyłącznie SealedSecrets, per tenant i środowisko
```

Katalogi `observability/` i `docs/` są na razie puste — wypełnia je Phase 4 i Phase 5.

## Metodologia

Projekt jest prowadzony z agentem kodującym (Claude Code) pracującym pod pisemnymi ograniczeniami,
a nie doraźnymi poleceniami. Struktura, która to organizuje, jest częścią repozytorium:

- **[CLAUDE.md](CLAUDE.md)** — zakres, kontrakt platformy i lista guardraili obowiązujących każdą
  zmianę: każdy tenant przechodzi bramkę bez wyjątków, kryteria bramki pozostają nieprzezroczyste
  dla platformy, żadnych ręcznych zmian na prodzie, żadnych sekretów w gicie, żadnych
  niezweryfikowanych twierdzeń w dokumentacji, żadnych rozwiązań szytych pod jednego tenanta.
- **[DECISIONS.md](DECISIONS.md)** — log decyzji architektonicznych. Każdy wpis niesie uzasadnienie,
  odrzucone warianty i powód odrzucenia. Decyzje bywają unieważniane przez późniejsze (D-018 przez
  D-021) i to również jest zapisane.
- **[PLAN.md](PLAN.md)** — fazy z kryteriami akceptacji i z ustaloną z góry kolejnością cięcia
  zakresu przy presji czasu.

Zasadą rozliczającą tę pracę jest weryfikacja: twierdzenie trafia do dokumentacji dopiero po
sprawdzeniu na żywym klastrze albo na zbudowanym artefakcie, a nie na podstawie kodu w repozytorium.
Liczba bez odnośnika do pomiaru nie trafia tam wcale. Kilka wpisów w logu decyzji powstało właśnie
z takiej weryfikacji — z różnicy między tym, co miało działać, a tym, co zadziałało.

## Dokumenty

| Plik | Rola |
|---|---|
| [CLAUDE.md](CLAUDE.md) | zakres projektu, kontrakt platformy, guardraile |
| [PLAN.md](PLAN.md) | fazy, kryteria akceptacji, kolejność cięcia zakresu |
| [DECISIONS.md](DECISIONS.md) | log decyzji architektonicznych |
| [bootstrap/README.md](bootstrap/README.md) | klaster developerski i granice tego, co dowodzi |
| [secrets/README.md](secrets/README.md) | wytwarzanie SealedSecrets per środowisko |

Dokument przekazania od tenanta #1 (endpointy, zmierzone czasy startu, zasoby, metryki) mieszka
w jednym miejscu — w repo tenanta: `PassivelyIronic/tsl-rag-v2`, `docs/KUBERNETES.md`. Platforma
trzyma odnośnik, nie kopię (D-020).

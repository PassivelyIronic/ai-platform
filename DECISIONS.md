# DECISIONS.md — shared decision log (both projects)

Format: one entry per decision. Status: proposed | accepted | superseded. Never delete entries — supersede them.

---

## D-001: Base application for Project 1
**Status:** accepted
**Decision:** TSL_RAG (repo `tsl-rag-v2`)
**Rationale:** poważniejszy use case (legal compliance) → lepsza narracja na interview; ma gotowy, **deterministyczny** harness retrievalowy, który Projekt 2 konsumuje bez dodatkowej pracy; provider abstraction upraszcza przełączanie między środowiskami; OTel i metryki Prometheus są już w kodzie.
**Amendment (D-006):** TSL_RAG pełni rolę **tenanta #1 platformy**, nie "aplikacji projektu".

## D-002: Cluster base — Oracle Cloud Always Free k3s
**Status:** accepted
**Rationale:** jedyna darmowa opcja z prawdziwym multi-node (3× ARM); EKS ~72 USD/mies. za sam control plane.
**Trade-off:** arm64 (wymusza multi-arch buildy), brak GPU, brak cloud LB i EBS-class storage (local-path → świadomie dokumentowany trade-off).
**Risk:** A1.Flex capacity bywa niedostępny w niektórych regionach; mitygacja w PLAN.md Phase 0.
**Do zmierzenia, nie do założenia:** czas ładowania `multilingual-e5-base` na A1.Flex. Pomiar 7.7 s pochodzi z maszyny deweloperskiej; probe'y ustawiasz dopiero po pomiarze na ARM.

## D-003: Kustomize dla własnych workloadów, Helm tylko third-party
**Status:** superseded by D-008 (w zakresie workloadów Projektu 2; dla infra w `rag-on-k8s` pozostaje accepted)
**Dlaczego przestało obowiązywać:** przesłanka "przy jednej aplikacji" znika przy N tenantach.

## D-004: Eval gate jako ArgoCD PostSync hook + CI wait
**Status:** accepted (mechanizm bez zmian; **co** mierzy bramka zmienia D-013)
**Rationale:** najprostszy działający mechanizm; alternatywa (eval jako Argo Rollouts AnalysisTemplate) elegantsza, ale wymaga stabilnego eksportu metryk. Kandydat na "what I'd do differently".

## D-005: Dwa repozytoria zamiast monorepo
**Status:** accepted
**Rationale:** osobne wpisy na CV z jasnym scope; naturalna separacja GitOps (source of truth ≠ infra ≠ app).
**Uwaga po D-006:** liczba repo rośnie do 3+ (infra, platform, app-per-tenant) — zgodnie z założeniem.

---

## D-006: Przeframowanie Projektu 2 na "internal AI platform"
**Status:** accepted (repo `ai-platform` istnieje)
**Decision:** repo `llmops-pipeline` → `ai-platform`; narracja: "wewnętrzna platforma AI, na której zespół deployuje serwis LLM bez dotykania Kubernetesa".
**Rationale:** zakres techniczny pokrywa się w ~85% z dotychczasowym planem, ale mapuje się 1:1 na opisy stanowisk platform/DevOps. Różnica jest w interfejsie: platforma ma **kontrakt** (D-007) i **więcej niż jednego użytkownika** (D-010).
**Cost:** ~1 tydzień (kontrakt + drugi tenant + onboarding docs).

## D-007: Kontrakt platformy — `services/<name>/service.yaml`
**Status:** accepted
**Decision:** jedyny interfejs między tenantem a platformą to jeden plik deklaratywny. Kształt startowy:

```yaml
name: tsl-rag
owner: jakub
image: { repo: ghcr.io/passivelyironic/tsl-rag-api, tag: 9f3c2a1 }   # tag bumpowany wyłącznie przez CI
runtime:
  replicas: 2
  resources: { requests: {memory: 1Gi, cpu: 500m}, limits: {memory: 2Gi, cpu: "2"} }
  cache: { enabled: true, size: 2Gi }          # HF_HOME — bez tego 1.1 GB pull przy każdym restarcie
  probes: { startupSeconds: 150, readinessInitialDelay: 60 }
  envFrom: { configMap: tsl-rag-env, secret: tsl-rag-secrets }
database:
  mode: managed                                 # managed | external
  seed: oci://ghcr.io/passivelyironic/tsl-rag-corpus:corpus-a41f9c
  embeddingModel: intfloat/multilingual-e5-base # musi zgadzać się z metadanymi dumpu (D-015)
gate:
  image: ghcr.io/passivelyironic/tsl-rag-api:9f3c2a1
  command: ["python", "-m", "evals.run_retrieval_evals"]
  needs: [database]
  timeoutSeconds: 300
rollout: { strategy: canary, steps: [10, 50, 100], analysisStartAfterSeconds: 180 }
```

**Rationale:** kontrakt jest tym, co odróżnia platformę od zbioru manifestów. Daje mierzalną metrykę do README: *onboarding nowego serwisu = 1 PR, ~30 linii YAML, zero `kubectl`*.
**Guardrail:** czego nie da się wyrazić w kontrakcie, wymaga rozszerzenia kontraktu albo wpisu w "Out of scope". Żadnych ręcznych manifestów obok `service.yaml`.
**Walidacja:** JSON Schema + krok w CI; zły kontrakt failuje PR, nie klaster.
**Zweryfikowane (2026-07-29), nie założone:** obraz API **nie zawierał** `evals/` — do finalnego stage'a szły wyłącznie `.venv` i `src/`. `uv` również nie istnieje w warstwie runtime, więc komenda `uv run python -m evals.run_retrieval_evals` z `docs/KUBERNETES.md` §5 nie wykonałaby się w ogóle. Rozwiązanie: `COPY evals/ ./evals/` do finalnego stage'a (kilkadziesiąt kB, zero nowych zależności — `run_retrieval_evals` importuje wyłącznie `typer`, `loguru`, `pyyaml` i moduły `tsl_rag.*`, wszystkie już w głównej grupie), komenda bez `uv`, ten sam obraz i tag co deployowane API. Patrz D-019.
**Wymóg dla charta:** Job bramki ustawia `workingDir: /app` jawnie. `python -m evals.…` znajduje pakiet przez cwd (`tsl_rag` jest zainstalowany w venv, `evals` tylko skopiowany), więc nadpisanie katalogu roboczego przez chart wywali bramkę na `ModuleNotFoundError` — i to samo dotyczy ścieżki do `evals/thresholds.yaml`.

## D-008: Jeden wewnętrzny Helm chart (`charts/ai-service`) dla workloadów platformy
**Status:** accepted — **supersedes D-003** w zakresie Projektu 2
**Decision:** `service.yaml` = values file wspólnego charta. Chart renderuje: Deployment/Rollout API, opcjonalne UI, StatefulSet Postgres/pgvector, restore Job, eval-gate Job, Service, Ingress, ServiceMonitor, ResourceQuota, NetworkPolicy.
**Rationale:** przy N serwisach kustomize wymusza N katalogów z powielonym boilerplate; chart z jednym values file per tenant to kanoniczny "golden path". Jedna zmiana propaguje się na wszystkie tenanty.
**Trade-off:** gorszy git diff. Mitygacja: `helm template` diff komentowany na PR.

## D-009: ApplicationSet (git directory generator) zamiast statycznego app-of-apps
**Status:** accepted
**Decision:** jeden `ApplicationSet` skanuje `services/*/` i generuje Application per tenant per środowisko. App-of-apps zostaje dla komponentów platformowych (ArgoCD, kube-prometheus-stack, Rollouts, SealedSecrets).
**Acceptance:** nowy katalog w `services/` = działający serwis na stagingu bez edycji czegokolwiek w `argocd/`.

## D-010: Tenant #2 — drugi serwis na platformie
**Status:** proposed (⚠ blokuje Phase 4)
**Decision:** do rozstrzygnięcia. Warunek wejścia zaostrzony przez D-013.
**Rationale:** kontrakt udowodniony na jednym tenancie nie jest udowodniony.
**Koszt po D-013:** tenant #2 musi mieć **deterministyczną** bramkę, nie tylko dataset. Recipe bot bez harness retrievalowego wymaga jego napisania (~1 dzień). Jeśli to nie mieści się w budżecie — minimalny serwis, którego jedynym zadaniem jest udowodnić generyczność kontraktu (własna baza, własny seed, trywialny deterministyczny eval), jest uczciwszym wyborem niż tenant z wyłączoną bramką. **Tenant bez bramki nie wchodzi na platformę** (guardrail #1).

## D-011: GCP jako punkt styku, nie jako druga chmura
**Status:** proposed
**Decision:** (a) Artifact Registry jako mirror obrazów obok GHCR, (b) jednorazowy portability test na GKE Autopilot, wynik w `docs/portability.md`.
**Guardrail:** budget alert 5 USD **przed** pierwszym `gcloud`; teardown w tym samym tygodniu, wpisany do runbooka.
**Risk:** GKE Autopilot to amd64 — multi-arch z D-002 to pokrywa, ale trzeba zweryfikować.

## D-012: Progi eval per serwis, w kontrakcie
**Status:** **superseded by D-014**
**Dlaczego przestało obowiązywać:** repo aplikacji ma już `evals/thresholds.yaml` jako źródło prawdy i twardą zasadę zmiany progu osobnym commitem. Kopiowanie liczb do kontraktu tworzy drugi, rozjeżdżający się egzemplarz.

---

## D-013: Bramka mierzy retrieval, nie generację
**Status:** accepted (wymuszone przez własności aplikacji, nie preferencję)
**Decision:** bramką promocji jest `evals/run_retrieval_evals` — deterministyczny, ~40 s, **bez sieci i bez klucza providera**, exit code 1 poniżej progu. Metryki: `recall@5`, `recall@10`, MRR.
**Rationale:** evale generacyjne (LLM-as-judge) mają zmierzony rozrzut do 0.133 między przebiegami identycznego kodu. Bramka na nich przepuszcza regresje i blokuje poprawy losowo. Bramka deterministyczna nie potrzebuje retry ani "marginesu na wariancję" — jedno i drugie znika z planu.
**Konsekwencja dla narracji:** *"bramkuję na tym, co deterministyczne; niedeterministyczne mierzę i alertuję"* jest mocniejszą odpowiedzią na rozmowie niż jakikolwiek gate na judge'u. Evale generacyjne zostają jako metryka obserwacyjna z alertem na spadek.
**Konsekwencja dla demo sabotażu:** stary pomysł (usunięcie instrukcji cytowania z promptu) nie zadziała — nie dotyka retrievalu. Nowy sabotaż celuje w retrieval: zmiana `rrf_k`, wyłączenie gałęzi dense albo BM25, zmiana chunkera. Efekt jest deterministyczny i powtarzalny, czyli demo działa za każdym razem.
**Zależność:** bramka wymaga bazy z korpusem → D-015.

## D-014: Progi należą do repo tenanta; platforma widzi wyłącznie exit code
**Status:** accepted — **supersedes D-012**
**Decision:** kontrakt deklaruje **obraz, komendę i zależności** bramki. Jej kryteria są dla platformy nieprzezroczyste — platforma sprawdza wyłącznie exit code i timeout.
**Rationale:** `evals/thresholds.yaml` w repo aplikacji jest jedynym źródłem prawdy i ma własną zasadę "próg zmienia się osobnym commitem z uzasadnieniem". Platforma egzekwuje **że bramka istnieje i przechodzi**, nie **jakie ma liczby**.
**Gdzie mieszka guardrail:** w `CLAUDE.md` repo platformy — to tam cc miałby pokusę wygenerować walidator progów. W repo aplikacji nie ma po nim śladu i nie powinno być.
**Furtka:** Job może dodatkowo wypychać wyniki do pushgateway dla dashboardu. Platforma **nie parsuje** tych liczb do decyzji o promocji.

## D-015: Seed dump jako domyślna ścieżka zasiedlania bazy; obraz ingestu jako jego producent
**Status:** accepted
**Kontekst:** `data/raw/` (7 MB, 14 PDF) jest wersjonowane w repo aplikacji świadomie — object storage i PVC na same PDF-y odpadają. Pytanie brzmi nie "skąd PDF-y", tylko **gdzie liczą się embeddingi**.
**Pomiar:** `document_chunks` — 438 wierszy, `vector(768)`, heap 1288 kB, heap + HNSW 8120 kB.
**Decision:**
- Obraz `tsl-rag-ingest` (`uv sync --extra ingest`) powstaje, ale odpala się **wyłącznie przy zmianie korpusu, chunkera lub modelu embeddingów** — nie przy tworzeniu środowiska. Ciągnie `unstructured[pdf]` → torchvision + opencv + spacy, czyli obraz rzędu gigabajtów.
- Jego wyjściem jest `pg_dump -Fc` tabeli `document_chunks` — artefakt rzędu paru MB. Świeży namespace robi `pg_restore` w sekundy, bez parserów PDF i bez modelu embeddingów. HNSW odbudowuje się przy restore.
- Artefakt nie idzie do repo (binarka) — OCI artifact w GHCR obok obrazu API (jedna rejestracja, jedno auth, pull po digescie); release asset jako fallback.
**Egzekucja guardrailu spójności modelu:** dump nosi w metadanych `embedding_model`; CI tenanta porównuje go z `database.embeddingModel` z kontraktu. `warmup()` i tak przerwie start, ale wtedy dowiadujesz się w podzie API po ~60 s na startupProbe, a nie przy budowie środowiska.
**Wymagania implementacyjne (inaczej restore failuje):**
- `CREATE EXTENSION vector` musi istnieć **przed** restore — kolejność: init.sql / extension → `pg_restore`. Dump tabeli nie niesie rozszerzenia.
- Restore Job musi być idempotentny (sprawdzenie `count(*)` przed) — ArgoCD resynchronizuje, a drugi restore zduplikowałby wiersze.
- ArgoCD sync waves: 0 = Postgres, 1 = restore Job, 2 = API/UI, PostSync = eval gate. Bez wave'ów bramka wystartuje na pustej bazie.
- Przy `database.mode: external` restore się **nie** wykonuje.

## D-016: Wersjonowanie dumpu po zawartości korpusu, nie po SHA aplikacji
**Status:** accepted
**Decision:** tag dumpu = hash z (`data/raw/` + nazwa modelu embeddingów + wersja/konfiguracja chunkera), np. `corpus-a41f9c`. Kontrakt pinuje ten tag w `database.seed`.
**Rationale:** tagowanie dumpu tagiem obrazu API produkowałoby nowy artefakt przy każdym commicie kodu, który go nie zmienia — albo, gorzej, tag zacząłby kłamać. Zmienne, które realnie zmieniają zawartość dumpu, to korpus, model i chunker.
**Dowód, że chunker musi być w hashu:** drift 444 → 438 chunków pochodzi wyłącznie ze zmiany obsługi miękkiego łącznika (U+00AD), przy niezmienionym korpusie i niezmienionym modelu. Bez chunkera w hashu ten sam tag wskazywałby na dwie różne zawartości.

## D-017: Baza per tenant w charcie; HPA wypada
**Status:** accepted
**Decision (baza):** `database.mode: managed` → StatefulSet Postgres/pgvector renderowany przez chart, per tenant. `external` → DSN z Secreta, dla środowiska długożyjącego.
**Rationale:** bez własnej bazy nie ma środowisk efemerycznych, a bez nich nie ma eval-gated promotion — czyli głównego powodu, dla którego ta aplikacja idzie na klaster. CloudNativePG do retro, nie do scope.
**Decision (HPA):** wypada z charta. Wąskim gardłem jest generacja u zewnętrznego providera i jego dzienny limit, nie CPU poda; HPA po CPU rozjedzie liczbę replik bez zysku. Opcjonalny opt-in po `tsl_rag_stage_duration_seconds` albo po liczbie żądań w locie.
**Warunek:** brak HPA wymaga akapitu "dlaczego nie po CPU" w README. Bez niego wygląda na niedoróbkę zamiast na decyzję — a jest to jeden z lepszych akapitów, jakie to repo może mieć.

## D-018: Granica infra ↔ platforma; repo Projektu 1 zmienia nazwę
**Status:** **superseded by D-021** (podział przestaje istnieć; granica opisana tu pozostaje trafnym opisem tego, czego platforma NIE robi)
**Decision:** repo `rag-on-k8s` → `platform-infra`. Granica: **co jest potrzebne, żeby ArgoCD wstało, należy do `platform-infra`; czym ArgoCD zarządza, należy do `ai-platform`.**
- `platform-infra`: instancje Oracle A1.Flex, sieć i security lists, instalacja k3s i join nodów, StorageClass, ingress-nginx, cert-manager, bootstrap ArgoCD.
- `ai-platform`: wszystko po tym, jak ArgoCD istnieje.

**Rationale:** nazwa `rag-on-k8s` jest reliktem sprzed D-006 — TSL_RAG jest tenantem, nie tematem klastra. Po przeniesieniu StatefulSetu do charta (D-017), wypadnięciu HPA (D-017), przejściu chaosu do Phase 5 i odpadnięciu GPU scheduling dla Ollamy (generacja idzie przez OpenRoutera, reranker wyłączony) w Projekcie 1 zostaje wyłącznie provisioning.
**Konsekwencja dla CV — supersedes uzasadnienie D-005, nie sam podział:** podział na repozytoria zostaje, bo jest technicznie poprawny. Ale „dwa osobne wpisy na CV" już nie obowiązuje: to jest jeden projekt w dwóch repozytoriach. Repo provisioningowe sprzedawane jako drugi projekt portfolio zostanie zdjęte pierwszym pytaniem na rozmowie.
**Koszt do odblokowania Phase 1:** kilka dni.

## D-019: `evals/` wchodzi do obrazu API; bramka jest smoke-testowana w CI
**Status:** accepted
**Decision:** (a) `COPY evals/ ./evals/` do finalnego stage'a `docker/Dockerfile`; (b) kontrakt deklaruje `python -m evals.run_retrieval_evals` (bez `uv` — nie ma go w runtime) na **tym samym obrazie i tagu co deployowane API**; (c) workflow budujący obraz uruchamia tę samą komendę na świeżo zbudowanym artefakcie, przeciwko jednorazowemu Postgresowi z seed dumpem.
**Rationale (a, b):** osobny obraz `tsl-rag-eval` kupuje tylko to, że obraz produkcyjny nie wozi zestawu testowego — przy kilkudziesięciu kB to nie jest cena warta drugiego tagu do synchronizacji. Drugi tag to nowa okazja do rozjazdu między bramką a tym, co bramka ocenia. Jeden obraz oznacza, że bramka **z definicji** ocenia dokładnie ten artefakt, który ma promować.
**Rationale (c):** to jest właściwa naprawa, nie sam `COPY`. Błąd polegał na tym, że dokument podawał komendę, której nikt nie uruchomił w opisywanym kontekście — ta sama klasa co historyczna „zepsuta ścieżka `make ui`". Smoke test w CI sprawia, że dokumentacja nie może się już rozjechać z artefaktem po cichu: rozjazd failuje build, a nie deployment.
**Uwaga do PATH:** `command -v python` rozwiązało się do `/app/.venv/bin/python`, czyli venv **jest** na PATH. Komenda bez ścieżki bezwzględnej powinna działać — ale to sprawdza dopiero smoke test z (c), nie ten wpis.
**Uwaga do wagi obrazu:** 2.59 GB przy pullu na trzy nody ARM z local-path wpływa na czas pierwszego rolloutu i na okno analizy canary (D-007, `analysisStartAfterSeconds`). Zmierz czas pulla na A1 przed ustawieniem probe'ów; jeśli to torch dominuje, wheel CPU-only jest tańszą optymalizacją niż cokolwiek po stronie klastra.

## D-020: Dokumenty tenanta nie są kopiowane do repo platformy
**Status:** accepted
**Decision:** `docs/KUBERNETES.md` istnieje w **jednym** miejscu — w repo tenanta. Kopia w korzeniu `ai-platform` znika i nie jest commitowana. Jeśli platforma potrzebuje odnośnika, jest nim jedno zdanie z nazwą repo i SHA commita, nie treść.
**Rationale:** to jest ta sama zasada co D-007, zastosowana do dokumentacji. Jeśli platforma potrzebuje czegoś o tenancie, to musi to być w `service.yaml` — a jeśli czegoś w kontrakcie nie ma, to jest dziura w kontrakcie, nie powód do trzymania kopii cudzego dokumentu. Datowany snapshot w drugim repo rozjedzie się z oryginałem; ta sama klasa błędu co 444 vs 438, `make ui` i `uv run` w §5. Trzy wystąpienia w jednym projekcie to nie jest przypadek, tylko wzorzec — kopia dokumentu to zobowiązanie do jej aktualizowania, którego nikt nie dotrzymuje.
**Konsekwencja:** poprawka komendy z §5 (`uv run` → `python -m`) idzie wyłącznie do repo tenanta, razem z aktualizacją daty w nagłówku dokumentu. Zostawienie znanej nieprawdy pod banerem „SPRAWDŹ PRZED UŻYCIEM" jest gorsze niż edycja snapshotu.

## D-021: Klaster developerski w repo platformy; `platform-infra` nie powstaje
**Status:** accepted — **supersedes D-018**
**Decision:** provisioning jako osobne repozytorium wypada z zakresu. `ai-platform` dostaje katalog `bootstrap/`, który stawia klaster k3d (1 serwer + 2 agenty, k3s v1.31) i pierwszą instancję ArgoCD. Wszystko po tym momencie idzie przez git — `bootstrap/` jest jedynym miejscem w projekcie, gdzie cokolwiek wykonuje się imperatywnie.
**Rationale:** blokerem Phase 1 nigdy nie był brak repozytorium, tylko brak działającego ArgoCD. Te dwie rzeczy dało się rozdzielić i rozdzielenie wychodzi na korzyść:
- **Dla oglądającego repo** klaster wstający jedną komendą z tego samego repozytorium jest wart więcej niż klaster wymagający konta w Oracle. Pierwsze da się sprawdzić, drugie trzeba przyjąć na słowo.
- **k3d to k3s w Dockerze**, czyli ta sama dystrybucja, którą platforma zakłada jako docelową. Odtwarza `local-path` (ReadWriteOnce i przywiązanie wolumenu do węzła), Traefika i egzekwowanie NetworkPolicy — czyli dokładnie te własności, na których ten projekt realnie się potknął.
- **Trzy węzły, nie jeden.** Przy jednym każdy pod ląduje tam, gdzie wolumen, więc konflikt node affinity na PVC — ten, przez który tenant #1 ma jedną replikę — byłby nieodtwarzalny. Środowisko, na którym znany błąd nie może się powtórzyć, nie weryfikuje niczego.

**Czego to środowisko nie dowodzi** (do trzymania w README, nie do przemilczenia — guardrail #5):
- arm64 w runtime. Obrazy są budowane multi-arch, ale uruchamiany jest wyłącznie amd64: wariant ARM jest zbudowany, nie sprawdzony.
- Czasów startu na docelowym sprzęcie. Probe'y zmierzone tutaj opisują amd64 z lokalnym dyskiem, nie A1.Flex — poprawka do D-002: „zmierz na tym, na czym uruchamiasz", a nie „zmierz na ARM".
- Publicznego Ingressu z TLS. Traefik odpowiada na `*.localhost`; cert-manager i Let's Encrypt wypadają z zakresu.
- Awarii węzła. Trzy kontenery na jednym hoście dzielą jego los.

**Co zostaje nietknięte:** teza projektu. Deterministyczna bramka blokująca promocję, kontrakt jako jedyny interfejs, canary z automatycznym rollbackiem i drugi tenant dowodzący generyczności nie zależą od tego, gdzie stoi klaster. Nagranie „od pustego katalogu do prod, demo sabotażu, auto-rollback" powstaje tu tak samo.

**Scenariusze chaosu, które to środowisko odtwarza wiernie:** ubicie poda Postgresa (`/ready` 503, brak restart-loopa), wyczerpanie ResourceQuota przez jednego tenanta, zablokowanie egressu do providera generacji. To są trzy z czterech pozycji Phase 5 — czwarta, awaria węzła, wypada.

**Furtka:** Oracle Always Free nadal jest możliwy, ręcznie i z procedurą w `docs/`, bez repozytorium provisioningowego. Ta decyzja tego nie zamyka, tylko przestaje na tym blokować Phase 1.

## D-022: Podział na środowiska; kontrakt jest stagingiem, prod jest nakładką
**Status:** accepted
**Decision:** ApplicationSet tenantów generuje jeden Application na **parę (tenant, środowisko)** — generator macierzowy `services/*` × `[staging, prod]`, namespace `<tenant>-<env>`. `services/<tenant>/service.yaml` pozostaje pełnym kontraktem i **jest** definicją stagingu; obok niego stoi `service.prod.yaml` niosący wyłącznie to, co prod różni — dla tenanta #1 dokładnie `image.tag` i `gate.image`. Plik `service.staging.yaml` nie istnieje i nie ma istnieć. Sekrety przenoszą się do `secrets/<tenant>/<env>/` i są pieczętowane osobno dla każdego środowiska.

**Rationale:** to jest dziura znaleziona, nie zaplanowana — żaden wcześniejszy wpis jej nie pokrywał. Phase 2 potrzebuje **dokąd** promować. Przy jednym Application na tenanta, jednym namespace i jednym `image.tag` „promocja" byłaby zmergowaniem taga prosto na to, co już działa: bramka odpalałaby się po wdrożeniu na jedyne istniejące środowisko, czyli oceniałaby stan, który już jest produkcją. Bramka blokująca promocję wymaga dwóch stanów, między którymi jest co blokować.

**Dlaczego nakładka, a nie drugi pełny kontrakt ani `envs:` w kontrakcie:**
- Drugi pełny kontrakt na prod to dwa opisy tego samego serwisu, rozjeżdżające się przy pierwszej zmianie runtime'u — ta sama klasa błędu co D-020 (kopia dokumentu) i 444 vs 438. Rozjazd oznaczałby, że staging przestaje cokolwiek dowodzić o prodzie.
- Zbiór środowisk trafia do **listy w ApplicationSecie, nie do kontraktu**. Środowiska są własnością platformy: tenant, który mógłby sobie zadeklarować własne, mógłby też zadeklarować takie, które omija prod, albo prod bez bramki (guardrail #1 i #6).
- Nakładka minimalna jest sama w sobie regułą: jeśli prod potrzebuje innych zasobów, innych probe'ów czy innej bazy niż staging, to staging nie jest już próbą generalną. Wąska nakładka sprawia, że taka rozbieżność jest widoczna w diffie PR-a, a nie ukryta w drugim komplecie 40 linii.

**Nakładki nie dostają własnej schemy.** Walidator scala nakładkę z kontraktem (semantyką Helmowego wielokrotnego `--values`: mapy rekurencyjnie, listy w całości) i waliduje **wynik scalenia** pełną schemą i pełnym kompletem reguł międzypolowych. Druga schema byłaby kopią głównej z usuniętym `required` — 230 linii do zsynchronizowania. Ważniejszy skutek niż oszczędność linii: reguła „bramka jedzie na tym samym obrazie i tagu co API" (D-019) obowiązuje na prodzie tak samo jak na stagingu, więc nakładka bumpująca sam `image.tag` bez `gate.image` failuje PR, zamiast wypuścić na prod bramkę oceniającą poprzednią wersję. Zweryfikowane na czerwono dokładnie na tym przypadku.

**Istnienie nakładki produkcyjnej wymusza walidator, nie flaga w ArgoCD.** `ignoreMissingValueFiles: true` jest w ApplicationSecie potrzebne wyłącznie dla stagingu, któremu brakuje nakładki z założenia. Gdyby to ta flaga decydowała o prodzie, usunięcie `service.prod.yaml` nie dałoby żadnego błędu — dałoby prod wdrożony po cichu z taga stagingu, czyli dokładnie ten skutek, przed którym broni bramka.

**Koszt, znaleziony w trakcie: SealedSecrets są pieczętowane strict-scope**, czyli związane parą (nazwa, namespace). Zmiana nazw namespace'ów na `<tenant>-<env>` unieważnia istniejące pieczęcie. `--scope cluster-wide` rozwiązałoby to jedną flagą i zostało **odrzucone**: sekret odszyfrowywalny w dowolnym namespace znosi izolację tenantów, którą budują namespace per tenant, ResourceQuota i NetworkPolicy. Sekrety są więc pieczętowane dwa razy, per środowisko. Efekt uboczny jest zresztą stanem docelowym, nie podatkiem: prod ma mieć własny klucz providera i własne hasło bazy, nieznane ze stagingu.

**Konsekwencja dla migracji klastra:** namespace `tsl-rag` zostaje osierocony i wymaga ręcznego `kubectl delete` — razem z PVC bazy i jej 438 wierszami. To jest bezpieczne dokładnie dlatego, że seed jest artefaktem OCI (D-015): świeży `tsl-rag-staging` odtwarza je restore Jobem, bez parserów i bez modelu.

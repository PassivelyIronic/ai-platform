# secrets/

Do tego katalogu wchodzą **wyłącznie** manifesty SealedSecret (`*.sealed.yaml`).
Zaszyfrowane są kluczem kontrolera na klastrze — odszyfrować potrafi tylko on,
więc mogą leżeć w publicznym repo.

`.gitignore` blokuje w tym katalogu każdy `*.yaml` i `*.json`, który nie kończy się
na `.sealed.yaml`. To siatka bezpieczeństwa, nie zastępstwo dla przejrzenia diffa.

## Układ katalogów

```
secrets/<tenant>/<env>/*.sealed.yaml
```

Podział na środowiska nie jest kosmetyką (D-022). SealedSecret jest domyślnie
pieczętowany w trybie **strict**, czyli związany parą **(nazwa, namespace)** —
ten sam sekret zapieczętowany dla `tsl-rag-staging` **nie odszyfruje się**
w `tsl-rag-prod`. Pieczęć `--scope cluster-wide` obeszłaby to jedną flagą
i świadomie z niej nie korzystamy: sekret odszyfrowywalny w dowolnym namespace
znosi izolację tenantów, którą budują ResourceQuota, NetworkPolicy i namespace
per tenant.

Dwa komplety poświadczeń są zresztą stanem docelowym, a nie podatkiem od
podziału: prod ma mieć własny klucz providera i własne hasło bazy, nieznane ze
stagingu.

**Rozjazd namespace'u nie objawia się błędem synchronizacji.** Application jest
`Synced`, a kontroler po cichu odmawia odszyfrowania — objawem jest pod wiszący
w `ContainerCreating`, nie czerwony ArgoCD. Dlatego namespace podaje się przy
pieczęci jawnie, a nie zostawia domyślnemu z kubeconfiga.

## Czego wymaga chart

Dla tenanta z `database.mode: managed` chart oczekuje Secreta o nazwie
`<tenant>-postgres` z kluczami `POSTGRES_USER` i `POSTGRES_PASSWORD`. Odwołują
się do niego StatefulSet bazy i Job restore.

Chart **nie generuje** tych poświadczeń celowo. `helm template` jest bezstanowy,
więc wygenerowane hasło byłoby inne przy każdej synchronizacji — ArgoCD
przepisywałby Secret w kółko, a baza i aplikacja rozjeżdżałyby się co do
poświadczeń przy pierwszym `selfHeal`.

Poza tym tenant potrzebuje Secreta wskazanego w `runtime.envFrom.secret`
(dla tenanta #1: `tsl-rag-secrets`) z kluczem providera generacji.

## Wytworzenie

Raz na każde środowisko. `--namespace` jest **obowiązkowy** — to on trafia do
pieczęci strict i decyduje, gdzie sekret da się odszyfrować:

```bash
ENV=staging          # potem to samo dla ENV=prod, z INNYMI wartościami

kubectl create secret generic tsl-rag-secrets \
  --namespace "tsl-rag-$ENV" \
  --from-literal=OPENROUTER_API_KEY=... \
  --dry-run=client -o yaml \
  | kubeseal --format yaml --controller-namespace sealed-secrets \
  > "secrets/tsl-rag/$ENV/tsl-rag-secrets.sealed.yaml"
```

Plik pośredni nigdy nie ląduje na dysku — pipe idzie prosto do `kubeseal`.
Klucz providera wklejasz w tę jedną linię i nigdzie indziej: nie przez `echo`,
nie do zmiennej, nie do pliku `.env`.

## Pułapka: hasło bazy występuje w dwóch sekretach

`tsl-rag-postgres` niesie `POSTGRES_PASSWORD` dla StatefulSetu i Joba restore,
ale aplikacja łączy się przez `POSTGRES_DSN` w `tsl-rag-secrets` — a DSN **zawiera
to samo hasło**. Rozjazd między nimi nie objawia się przy synchronizacji: baza
wstaje, restore przechodzi, a API wywala się na `/ready` z błędem
uwierzytelnienia, wyglądającym jak awaria bazy.

Dlatego oba sekrety wytwarza się **w jednym przebiegu**, z hasła trzymanego przez
chwilę w zmiennej — to jedyny wyjątek od reguły wyżej i wynika z tego, że wartość
musi trafić w dwa miejsca spójnie. Hasło jest generowane maszynowo i nigdy nie
wypisywane:

```bash
for ENV in staging prod; do
  PW="$(openssl rand -hex 24)"

  kubectl create secret generic tsl-rag-postgres \
    --namespace "tsl-rag-$ENV" \
    --from-literal=POSTGRES_USER=tsl_rag \
    --from-literal=POSTGRES_PASSWORD="$PW" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml --controller-namespace sealed-secrets \
    > "secrets/tsl-rag/$ENV/postgres.sealed.yaml"

  kubectl create secret generic tsl-rag-secrets \
    --namespace "tsl-rag-$ENV" \
    --from-literal=OPENROUTER_API_KEY=... \
    --from-literal=API_PASSWORD=... \
    --from-literal=POSTGRES_DSN="postgresql+asyncpg://tsl_rag:$PW@postgres:5432/tsl_rag" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml --controller-namespace sealed-secrets \
    > "secrets/tsl-rag/$ENV/app.sealed.yaml"

  unset PW
done
```

Host w DSN to nazwa Service'u (`postgres`), nie FQDN z namespace'em — dzięki temu
DSN jest identyczny w obu środowiskach poza hasłem, a rozdziela je namespace
pieczęci. Nazwa bazy `tsl_rag` pochodzi z helpera charta (`name` z myślnikami
zamienionymi na podkreślenia), nie jest wolnym wyborem.

## Po odtworzeniu klastra

Pieczęcie są związane z kluczem **konkretnej instancji** kontrolera. `make
teardown` + ponowny bootstrap generuje nowy klucz, więc wszystkie pliki tutaj
trzeba wytworzyć od nowa. Samo zatrzymanie klastra (`k3d cluster stop`) klucza
nie rusza — sekrety przeżywają.

## Jeśli klucz wyciekł

Klucz wypisany do logów, do historii shella albo do commita jest **spalony**.
Rotacja u providera, potem nowy SealedSecret. Usunięcie commita z historii nie
przywraca sekretu do stanu tajnego (guardrail #4).

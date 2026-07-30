# secrets/

Do tego katalogu wchodzą **wyłącznie** manifesty SealedSecret (`*.sealed.yaml`).
Zaszyfrowane są kluczem kontrolera na klastrze — odszyfrować potrafi tylko on,
więc mogą leżeć w publicznym repo.

`.gitignore` blokuje w tym katalogu każdy `*.yaml` i `*.json`, który nie kończy się
na `.sealed.yaml`. To siatka bezpieczeństwa, nie zastępstwo dla przejrzenia diffa.

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

```bash
kubectl create secret generic tsl-rag-secrets \
  --from-literal=OPENROUTER_API_KEY=... \
  --dry-run=client -o yaml \
  | kubeseal --format yaml --controller-namespace sealed-secrets \
  > secrets/tsl-rag/tsl-rag-secrets.sealed.yaml
```

Plik pośredni nigdy nie ląduje na dysku — pipe idzie prosto do `kubeseal`.

## Jeśli klucz wyciekł

Klucz wypisany do logów, do historii shella albo do commita jest **spalony**.
Rotacja u providera, potem nowy SealedSecret. Usunięcie commita z historii nie
przywraca sekretu do stanu tajnego (guardrail #4).

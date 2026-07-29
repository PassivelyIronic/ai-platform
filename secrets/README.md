# secrets/

Do tego katalogu wchodzą **wyłącznie** manifesty SealedSecret (`*.sealed.yaml`).
Zaszyfrowane są kluczem kontrolera na klastrze — odszyfrować potrafi tylko on,
więc mogą leżeć w publicznym repo.

`.gitignore` blokuje w tym katalogu każdy `*.yaml` i `*.json`, który nie kończy się
na `.sealed.yaml`. To siatka bezpieczeństwa, nie zastępstwo dla przejrzenia diffa.

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

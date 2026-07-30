# bootstrap/

Postawienie klastra i pierwszej instancji ArgoCD. Wszystko, co dzieje się po tym
momencie, idzie już przez git — te pliki są jedynym miejscem w projekcie, gdzie
coś wykonuje się imperatywnie, i to jest celowe: ktoś musi położyć pierwszy
kamień (DECISIONS D-021).

## Od zera do działającej platformy

```bash
make cluster      # k3d: 1 serwer + 2 agenty, k3s v1.31
make bootstrap    # ArgoCD + app-of-apps komponentów platformy
make tenants      # ApplicationSet nad services/*
```

Teardown: `make teardown` — kasuje klaster w całości, razem z wolumenami.

## Dlaczego trzy węzły

Przy jednym węźle każdy pod ląduje tam, gdzie wolumen, więc konflikt node
affinity na PVC nigdy się nie ujawnia. To dokładnie ten błąd, przez który
tenant #1 ma jedną replikę zamiast dwóch. Klaster, na którym znany błąd jest
niemożliwy do odtworzenia, nie nadaje się do weryfikowania czegokolwiek.

## Czego to środowisko NIE dowodzi

Uczciwie, bo README projektu nie może twierdzić więcej, niż zostało sprawdzone
(guardrail #5):

- **arm64 w runtime.** Obrazy są budowane multi-arch, ale tutaj jedzie wyłącznie
  wariant amd64. Wariant ARM jest zbudowany, nie uruchomiony.
- **Czasy startu na docelowym sprzęcie.** Probe'y zmierzone tutaj opisują amd64
  z lokalnym dyskiem, nie Oracle A1.Flex (D-002).
- **Publiczny Ingress z TLS.** Traefik odpowiada na `*.localhost`; cert-manager
  i Let's Encrypt są poza zakresem tego środowiska.
- **Awaria węzła.** Trzy kontenery na jednym hoście dzielą jego los.

Scenariusze chaosu z Phase 5, które to środowisko odtwarza wiernie: ubicie poda
Postgresa, wyczerpanie ResourceQuota przez jednego tenanta, zablokowanie egressu
do providera generacji.

## Sekrety

Chart oczekuje SealedSecretów, a te są szyfrowane kluczem kontrolera na KONKRETNYM
klastrze. Po każdym `make teardown` + `make cluster` trzeba je wytworzyć na nowo —
klucz jest inny. Procedura: `secrets/README.md`.

To nie jest niedogodność do obejścia, tylko własność SealedSecretów: gdyby dało
się je odszyfrować gdzie indziej, nie byłoby po co ich pieczętować.

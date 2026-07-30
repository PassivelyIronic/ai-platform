"""
Walidacja kontraktów tenantów (`services/*/service.yaml`) i nakładek
środowiskowych (`services/*/service.<env>.yaml`).

Dwa poziomy, bo JSON Schema nie wyraża wszystkiego, co platforma musi wymusić:

1. **Schema** (`schemas/service.schema.json`) — kształt, typy, zamknięte zbiory
   wartości, `additionalProperties: false`. To ostatnie jest tu mechanizmem
   egzekwującym D-014: pole na progi bramki nie przejdzie, bo żadne pole spoza
   schemy nie przechodzi.
2. **Reguły międzypolowe** — rzeczy, których schema nie umie: równość obrazu
   bramki z obrazem API, monotoniczność kroków canary.

**Nakładki nie mają własnej schemy** i celowo jej nie dostaną. Byłaby kopią tej
głównej z usuniętym `required`, czyli drugim egzemplarzem 230 linii do
rozjechania się przy pierwszej zmianie kontraktu. Zamiast tego nakładka jest
scalana z kontraktem, a walidowany jest WYNIK scalenia — pełną schemą i pełnym
kompletem reguł. Każdy błąd nakładki wychodzi w scaleniu, bo nakładka nadpisuje
kontrakt, a nie odwrotnie.

To scalenie ma jeszcze jeden skutek, ważniejszy od oszczędności linii: reguła
„bramka jedzie na tym samym obrazie co API" (D-019) obowiązuje na prodzie tak
samo jak na stagingu. Nakładka bumpująca sam `image.tag` bez `gate.image`
failuje PR, zamiast wypuścić na prod bramkę oceniającą poprzednią wersję.

Zły kontrakt ma failować PR, nie klaster (D-007).

Uruchomienie:
    uv run --with jsonschema --with pyyaml python scripts/validate_contracts.py
    make contracts
"""

from __future__ import annotations

import json
import sys
from copy import deepcopy
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

_ROOT = Path(__file__).resolve().parent.parent
_SCHEMA_PATH = _ROOT / "schemas" / "service.schema.json"
_SERVICES_DIR = _ROOT / "services"

# Zbiór środowisk jest własnością platformy, nie tenanta — ta lista MUSI zgadzać
# się z generatorem listy w argocd/applicationset.yaml. Rozjazd nie objawi się
# błędem: środowisko obecne tam, a nieobecne tu, wdroży się bez walidacji.
_ENVS = ("staging", "prod")

# Staging jest definiowany samym kontraktem — `service.staging.yaml` nie istnieje
# i nie ma istnieć. Prod musi mieć nakładkę, bo bez niej dziedziczyłby `image.tag`
# stagingu, czyli dostawałby każdą wersję od razu po zmergowaniu bumpa. Bramka
# promocji przestałaby cokolwiek blokować, nie zgłaszając przy tym żadnego błędu.
_REQUIRE_OVERLAY = ("prod",)


def _overlay_path(tenant_dir: Path, env: str) -> Path:
    return tenant_dir / f"service.{env}.yaml"


def _deep_merge(base: dict, overlay: dict) -> dict:
    """
    Scalenie nakładki na kontrakt. Mapy scalają się rekurencyjnie, wszystko inne
    jest nadpisywane w całości.

    Listy nadpisujemy, a nie doklejamy, i to jest decyzja, nie uproszczenie:
    `rollout.steps: [10, 50, 100]` ma się w nakładce dać ZASTĄPIĆ. Doklejanie
    dałoby [10, 50, 100, 10, 100] — listę, którą walidator odrzuci jako
    nierosnącą, ale dopiero po tym, jak autor nakładki zdąży się zdziwić.

    To jest ta sama semantyka, którą stosuje Helm przy wielu `--values`, więc
    wynik scalenia tutaj i wynik renderowania w klastrze to ta sama wartość.
    """
    merged = deepcopy(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = deepcopy(value)
    return merged


def _cross_field_problems(contract: dict) -> list[str]:
    """
    Reguły, których JSON Schema nie wyraża.

    Nie ma tu niczego o KRYTERIACH bramki — wyłącznie o jej konfiguracji.
    Platforma sprawdza, że bramka istnieje i czym jest uruchamiana, nigdy jakie
    ma progi (D-014).
    """
    problems: list[str] = []

    image = contract.get("image") or {}
    gate = contract.get("gate") or {}

    # D-019: bramka ocenia dokładnie ten artefakt, który ma promować. Osobny tag
    # bramki to druga okazja do rozjazdu między nią a ocenianym kodem.
    if image.get("repo") and image.get("tag") and gate.get("image"):
        expected = f"{image['repo']}:{image['tag']}"
        if gate["image"] != expected:
            problems.append(
                f"gate.image ({gate['image']}) != image.repo:image.tag ({expected}). "
                "Bramka musi jechać na tym samym obrazie i tagu co API."
            )

    steps = (contract.get("rollout") or {}).get("steps")
    if steps:
        if any(b <= a for a, b in zip(steps, steps[1:], strict=False)):
            problems.append(f"rollout.steps musi rosnąć, jest {steps}.")
        if steps[-1] != 100:
            problems.append(
                f"ostatni krok rollout.steps musi wynosić 100, jest {steps[-1]} — "
                "inaczej promocja nigdy nie obejmuje całego ruchu."
            )

    return problems


def _schema_problems(validator: Draft202012Validator, document: dict) -> list[str]:
    return [
        f"{'.'.join(str(p) for p in e.absolute_path) or '<korzeń>'}: {e.message}"
        for e in sorted(validator.iter_errors(document), key=lambda e: list(e.absolute_path))
    ]


def _load_yaml_mapping(path: Path) -> tuple[dict | None, str | None]:
    """Zwraca (mapa, błąd). Błąd jest komunikatem dla autora PR-a, nie wyjątkiem.

    Niepoprawny YAML jest błędem kontraktu, więc ma wyglądać jak błąd kontraktu.
    Stacktrace w logach CI zmusza autora PR-a do czytania Pythona zamiast
    komunikatu o tym, co poprawić.
    """
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        return None, f"plik nie jest poprawnym YAML-em: {exc}"

    if document is None:
        return None, "plik jest pusty — nakładka bez zawartości nie odróżnia środowiska."

    if not isinstance(document, dict):
        return None, "zawartość musi być mapą pól, a nie listą ani wartością prostą."

    return document, None


def _report(label: str, problems: list[str]) -> bool:
    """Wypisuje wynik jednej jednostki walidacji. Zwraca True, gdy była porażka."""
    if problems:
        print(f"FAIL  {label}")
        for problem in problems:
            print(f"        - {problem}")
        return True
    print(f"OK    {label}")
    return False


def main() -> int:
    schema = json.loads(_SCHEMA_PATH.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)

    contracts = sorted(_SERVICES_DIR.glob("*/service.yaml"))
    if not contracts:
        print("Brak kontraktów w services/ — nic do walidacji.")
        return 0

    failed = False
    for path in contracts:
        tenant_dir = path.parent
        rel = path.relative_to(_ROOT).as_posix()

        contract, error = _load_yaml_mapping(path)
        if error is not None:
            failed = _report(rel, [error]) or failed
            continue
        assert contract is not None

        problems = _schema_problems(validator, contract)
        problems += _cross_field_problems(contract)

        # Nazwa katalogu jest podstawą nazwy namespace'u generowanej przez
        # ApplicationSet (`<katalog>-<env>`), więc rozjazd z polem `name` daje
        # serwis wdrożony gdzie indziej, niż mówi kontrakt.
        directory = tenant_dir.name
        if contract.get("name") != directory:
            problems.append(
                f"name ({contract.get('name')!r}) != nazwa katalogu ({directory!r}). "
                "Namespace bierze się z katalogu, więc rozjazd wdroży serwis gdzie indziej."
            )

        failed = _report(rel, problems) or failed

        # --- nakładki środowiskowe -------------------------------------------
        for env in _ENVS:
            overlay_path = _overlay_path(tenant_dir, env)
            overlay_rel = overlay_path.relative_to(_ROOT).as_posix()

            if not overlay_path.exists():
                if env in _REQUIRE_OVERLAY:
                    failed = _report(
                        overlay_rel,
                        [
                            "brak wymaganej nakładki środowiska. Bez niej prod dziedziczy "
                            "image.tag stagingu, czyli dostaje każdą wersję w chwili "
                            "zmergowania bumpa — z pominięciem bramki promocji."
                        ],
                    ) or failed
                # Staging bez nakładki to stan poprawny i domyślny: kontrakt JEST
                # definicją stagingu. Cisza jest tu właściwym wynikiem.
                continue

            overlay, error = _load_yaml_mapping(overlay_path)
            if error is not None:
                failed = _report(overlay_rel, [error]) or failed
                continue
            assert overlay is not None

            overlay_problems: list[str] = []

            # `name` steruje nazwami zasobów i musi być wspólne dla środowisk.
            # Nadpisane w nakładce dałoby dwa serwisy, które nie są tym samym
            # serwisem w dwóch środowiskach — a to jest cała treść promocji.
            if "name" in overlay:
                overlay_problems.append(
                    "nakładka nie może nadpisywać `name` — środowiska mają się różnić "
                    "wersją, nie tożsamością serwisu."
                )

            # Sedno: walidowany jest wynik scalenia, dokładnie ten, który Helm
            # dostanie w klastrze przy dwóch plikach --values.
            merged = _deep_merge(contract, overlay)
            overlay_problems += _schema_problems(validator, merged)
            overlay_problems += _cross_field_problems(merged)

            failed = _report(f"{overlay_rel} (scalone z kontraktem)", overlay_problems) or failed

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

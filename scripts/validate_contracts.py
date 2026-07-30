"""
Walidacja kontraktów tenantów (`services/*/service.yaml`).

Dwa poziomy, bo JSON Schema nie wyraża wszystkiego, co platforma musi wymusić:

1. **Schema** (`schemas/service.schema.json`) — kształt, typy, zamknięte zbiory
   wartości, `additionalProperties: false`. To ostatnie jest tu mechanizmem
   egzekwującym D-014: pole na progi bramki nie przejdzie, bo żadne pole spoza
   schemy nie przechodzi.
2. **Reguły międzypolowe** — rzeczy, których schema nie umie: równość obrazu
   bramki z obrazem API, monotoniczność kroków canary.

Zły kontrakt ma failować PR, nie klaster (D-007).

Uruchomienie:
    uv run --with jsonschema --with pyyaml python scripts/validate_contracts.py
    make validate-contracts
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

_ROOT = Path(__file__).resolve().parent.parent
_SCHEMA_PATH = _ROOT / "schemas" / "service.schema.json"
_SERVICES_DIR = _ROOT / "services"


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

    # Nazwa katalogu jest nazwą namespace'u generowaną przez ApplicationSet,
    # więc rozjazd z polem `name` daje serwis wdrożony gdzie indziej, niż mówi
    # kontrakt.
    return problems


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
        rel = path.relative_to(_ROOT).as_posix()

        # Niepoprawny YAML jest błędem kontraktu, więc ma wyglądać jak błąd
        # kontraktu. Stacktrace w logach CI zmusza autora PR-a do czytania
        # Pythona zamiast komunikatu o tym, co poprawić.
        try:
            contract = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            failed = True
            print(f"FAIL  {rel}")
            print(f"        - plik nie jest poprawnym YAML-em: {exc}")
            continue

        if not isinstance(contract, dict):
            failed = True
            print(f"FAIL  {rel}")
            print("        - kontrakt musi być mapą pól, a nie listą ani wartością prostą.")
            continue

        problems = [
            f"{'.'.join(str(p) for p in e.absolute_path) or '<korzeń>'}: {e.message}"
            for e in sorted(validator.iter_errors(contract), key=lambda e: list(e.absolute_path))
        ]
        problems += _cross_field_problems(contract)

        directory = path.parent.name
        if contract.get("name") != directory:
            problems.append(
                f"name ({contract.get('name')!r}) != nazwa katalogu ({directory!r}). "
                "Namespace bierze się z katalogu, więc rozjazd wdroży serwis gdzie indziej."
            )

        if problems:
            failed = True
            print(f"FAIL  {rel}")
            for problem in problems:
                print(f"        - {problem}")
        else:
            print(f"OK    {rel}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

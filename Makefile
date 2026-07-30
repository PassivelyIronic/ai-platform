# Makefile platformy.
#
# Przepisy są celowo jednokomendowe i iterują funkcjami GNU make, nie pętlami
# shella: repo jest rozwijane na Windowsie, gdzie `make` odpala cmd.exe, a w CI
# na Linuksie /bin/sh. Pętla `for ... done` działałaby tylko w jednym z tych
# dwóch miejsc.
#
# `make render` musi produkować DOKŁADNIE te manifesty, które nakłada ArgoCD
# (konwencja z CLAUDE.md) — dlatego renderowanie idzie przez ten sam chart
# i ten sam plik kontraktu, bez dodatkowych nakładek.

CHART       := charts/ai-service
RENDER_DIR  := .render
CONTRACTS   := $(wildcard services/*/service.yaml)
SERVICES    := $(notdir $(patsubst %/,%,$(dir $(CONTRACTS))))

# Wersje K8s, pod które walidujemy manifesty. Klaster docelowy to k3s
# (Projekt 1); druga wersja pilnuje, żeby nic nie polegało na czymś, co
# zniknie przy najbliższym upgradzie.
KUBE_VERSION ?= 1.31.0

# `rm -rf` nie istnieje w cmd.exe, a `rmdir /s /q` nie istnieje nigdzie indziej.
RMDIR := rm -rf
ifeq ($(OS),Windows_NT)
RMDIR := cmd /c if exist $(RENDER_DIR) rmdir /s /q
endif

.DEFAULT_GOAL := help

.PHONY: help tools contracts render lint validate clean $(addprefix render-,$(SERVICES))

help:
	@echo make tools     - sprawdza, czy wymagane narzedzia sa na PATH
	@echo make contracts - waliduje services/*/service.yaml schema kontraktu
	@echo make render    - renderuje manifesty kazdego tenanta do $(RENDER_DIR)
	@echo make lint      - helm lint charta dla kazdego kontraktu
	@echo make validate  - kubeconform na wyrenderowanych manifestach
	@echo make clean     - usuwa $(RENDER_DIR)
	@echo Tenanci wykryci w services/: $(if $(SERVICES),$(SERVICES),BRAK)

# Zaleznosci brane doraznie przez uv — repo platformy nie jest projektem
# pythonowym i nie ma powodu, zeby zyskalo pyproject.toml dla jednego skryptu.
contracts:
	uv run --quiet --with jsonschema --with pyyaml python scripts/validate_contracts.py

tools:
	@helm version --short
	@kubeconform -v
	@yq --version

render: $(addprefix render-,$(SERVICES))
	@echo Render zakonczony. Tenanci: $(if $(SERVICES),$(SERVICES),BRAK)

render-%:
	helm template $* $(CHART) --values services/$*/service.yaml --namespace $* --output-dir $(RENDER_DIR)

lint: $(addprefix lint-,$(SERVICES))

lint-%:
	helm lint $(CHART) --values services/$*/service.yaml

# --strict: nieznane pole w manifescie jest bledem, nie ostrzezeniem.
# --ignore-missing-schemas przepuszcza CRD (Rollout, ServiceMonitor,
# SealedSecret), ktorych schematow kubeconform nie zna z pudelka.
validate: render
	kubeconform -strict -summary -kubernetes-version $(KUBE_VERSION) -ignore-missing-schemas $(RENDER_DIR)

clean:
	$(RMDIR) $(RENDER_DIR)

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

CLUSTER     := ai-platform
ARGOCD_VER  := 7.7.11

.PHONY: help tools contracts render lint validate clean cluster bootstrap tenants teardown $(addprefix render-,$(SERVICES))

help:
	@echo make tools     - sprawdza, czy wymagane narzedzia sa na PATH
	@echo make contracts - waliduje services/*/service.yaml schema kontraktu
	@echo make render    - renderuje manifesty kazdego tenanta do $(RENDER_DIR)
	@echo make lint      - helm lint charta dla kazdego kontraktu
	@echo make validate  - kubeconform na wyrenderowanych manifestach
	@echo make clean     - usuwa $(RENDER_DIR)
	@echo .
	@echo make cluster   - stawia klaster k3d: 1 serwer + 2 agenty
	@echo make bootstrap - ArgoCD + app-of-apps komponentow platformy
	@echo make tenants   - ApplicationSet nad services/
	@echo make teardown  - kasuje klaster w calosci
	@echo Tenanci wykryci w services/: $(if $(SERVICES),$(SERVICES),BRAK)

# --- klaster developerski ----------------------------------------------------
# Jedyne imperatywne kroki w projekcie. Wszystko po nich idzie przez git.

cluster:
	k3d cluster create --config bootstrap/k3d-cluster.yaml
	kubectl wait --for=condition=Ready nodes --all --timeout=120s
	kubectl get nodes

bootstrap:
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	helm repo update argo
	helm upgrade --install argocd argo/argo-cd --version $(ARGOCD_VER) --namespace argocd --create-namespace --values bootstrap/argocd-values.yaml --wait --timeout 10m
	kubectl apply -f argocd/platform/app-of-apps.yaml
	@echo Haslo admina ArgoCD:
	kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"

tenants:
	kubectl apply -f argocd/applicationset.yaml

teardown:
	k3d cluster delete $(CLUSTER)

# Zaleznosci brane doraznie przez uv — repo platformy nie jest projektem
# pythonowym i nie ma powodu, zeby zyskalo pyproject.toml dla jednego skryptu.
contracts:
	uv run --quiet --with jsonschema --with pyyaml python scripts/validate_contracts.py

tools:
	@helm version --short
	@kubeconform -v
	@yq --version

RENDER_TARGETS := $(addprefix render-,$(SERVICES))
LINT_TARGETS   := $(addprefix lint-,$(SERVICES))

render: $(RENDER_TARGETS)
	@echo Render zakonczony. Tenanci: $(if $(SERVICES),$(SERVICES),BRAK)

lint: $(LINT_TARGETS)

# Reguly STATYCZNE wzorcowe, nie niejawne. GNU make pomija wyszukiwanie regul
# niejawnych dla celow oznaczonych jako .PHONY, wiec `render-%:` w polaczeniu
# z .PHONY dawal cel, ktory konczyl sie sukcesem, nie uruchamiajac niczego.
ifneq ($(SERVICES),)
$(RENDER_TARGETS): render-%:
	helm template $* $(CHART) --values services/$*/service.yaml --namespace $* --output-dir $(RENDER_DIR)

$(LINT_TARGETS): lint-%:
	helm lint $(CHART) --values services/$*/service.yaml
endif

# --strict: nieznane pole w manifescie jest bledem, nie ostrzezeniem.
# --ignore-missing-schemas przepuszcza CRD (Rollout, ServiceMonitor,
# SealedSecret), ktorych schematow kubeconform nie zna z pudelka.
validate: render
	kubeconform -strict -summary -kubernetes-version $(KUBE_VERSION) -ignore-missing-schemas $(RENDER_DIR)

clean:
	$(RMDIR) $(RENDER_DIR)

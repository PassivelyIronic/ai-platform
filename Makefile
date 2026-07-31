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

# Zbior srodowisk MUSI zgadzac sie z generatorem listy w argocd/applicationset.yaml
# i ze stala _ENVS w scripts/validate_contracts.py. Srodowisko obecne tam,
# a nieobecne tu, po prostu nie bedzie renderowane lokalnie — czyli `make render`
# przestanie pokazywac to, co naklada ArgoCD, nie zglaszajac przy tym bledu.
ENVS        := staging prod

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

.PHONY: help tools contracts render lint validate clean cluster bootstrap teardown

help:
	@echo make tools     - sprawdza, czy wymagane narzedzia sa na PATH
	@echo make contracts - waliduje services/*/service.yaml schema kontraktu
	@echo make render    - renderuje manifesty kazdej pary tenant-srodowisko do $(RENDER_DIR)
	@echo make lint      - helm lint charta dla kazdego kontraktu
	@echo make validate  - kubeconform na wyrenderowanych manifestach
	@echo make clean     - usuwa $(RENDER_DIR)
	@echo.
	@echo make cluster   - stawia klaster k3d: 1 serwer + 2 agenty
	@echo make bootstrap - ArgoCD + app-of-apps komponentow platformy
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

# Nie ma celu `tenants`. ApplicationSety tenantow przychodzą przez app-of-apps
# (argocd/platform/components/tenant-applicationsets.yaml, D-023), wiec `make
# bootstrap` wystarczy. Recznego `kubectl apply` na nie nie ma, bo istnialby
# wylacznie po to, zeby dalo sie ominac gita.

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

# Po jednym celu na PARE (tenant, srodowisko). Nazwa celu sklada sie z dwoch
# czlonow, z ktorych oba moga zawierac myslnik, wiec regula wzorcowa `render-%`
# nie ma jak ich rozdzielic — `render-tsl-rag-prod` rozbija sie na `tsl` i reszte
# rownie dobrze jak na `tsl-rag` i `prod`. Dlatego reguly sa GENEROWANE przez
# $(eval): oba czlony sa wtedy znane w chwili tworzenia regoly, a nie zgadywane
# z jej nazwy.
#
# Przy okazji znika pulapka, ktora kosztowala juz raz pol godziny: GNU make
# pomija wyszukiwanie regul niejawnych dla celow oznaczonych jako .PHONY, wiec
# `render-%:` razem z .PHONY dawalo cel konczacy sie sukcesem BEZ uruchomienia
# czegokolwiek. Reguly jawne tego problemu nie maja.
RENDER_TARGETS := $(foreach s,$(SERVICES),$(foreach e,$(ENVS),render-$(s)-$(e)))
LINT_TARGETS   := $(foreach s,$(SERVICES),$(foreach e,$(ENVS),lint-$(s)-$(e)))

render: $(RENDER_TARGETS)
	@echo Render zakonczony. Tenanci: $(if $(SERVICES),$(SERVICES),BRAK) x $(ENVS)

lint: $(LINT_TARGETS)

# $(1) = tenant, $(2) = srodowisko.
#
# Naklodka jest dokladana warunkowo przez $(wildcard): staging jej nie ma
# i miec nie bedzie, bo kontrakt JEST definicja stagingu. helm z --values
# wskazujacym nieistniejacy plik konczy sie bledem, wiec warunek nie jest
# kosmetyka.
#
# Kazda para renderuje sie do WLASNEGO katalogu. Bez tego prod nadpisalby
# staging w miejscu, ktorego kubeconform juz nie odroznia — i walidowalibysmy
# jedno srodowisko, meldujac dwa.
define RENDER_RULE
render-$(1)-$(2):
	helm template $(1) $(CHART) --values services/$(1)/service.yaml $(if $(wildcard services/$(1)/service.$(2).yaml),--values services/$(1)/service.$(2).yaml) --namespace $(1)-$(2) --output-dir $(RENDER_DIR)/$(1)-$(2)

lint-$(1)-$(2):
	helm lint $(CHART) --values services/$(1)/service.yaml $(if $(wildcard services/$(1)/service.$(2).yaml),--values services/$(1)/service.$(2).yaml)
endef

$(foreach s,$(SERVICES),$(foreach e,$(ENVS),$(eval $(call RENDER_RULE,$(s),$(e)))))

# --strict: nieznane pole w manifescie jest bledem, nie ostrzezeniem.
# --ignore-missing-schemas przepuszcza CRD (Rollout, ServiceMonitor,
# SealedSecret), ktorych schematow kubeconform nie zna z pudelka.
validate: render
	kubeconform -strict -summary -kubernetes-version $(KUBE_VERSION) -ignore-missing-schemas $(RENDER_DIR)

clean:
	$(RMDIR) $(RENDER_DIR)

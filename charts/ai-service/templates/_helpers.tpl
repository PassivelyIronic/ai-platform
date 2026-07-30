{{/*
Nazwa zasobów = nazwa tenanta z kontraktu. Bez `fullname` z sufiksem release'u:
release nazywa się tak samo jak tenant (ApplicationSet generuje jedno po drugim),
a doklejanie sufiksu dałoby `tsl-rag-tsl-rag` w każdym logu i każdym alercie.
*/}}
{{- define "ai-service.name" -}}
{{- required "kontrakt musi mieć pole `name`" .Values.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ai-service.labels" -}}
app.kubernetes.io/name: {{ include "ai-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ai-platform
{{ include "ai-service.ownerLabel" . }}
{{- end -}}

{{- define "ai-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ai-service.name" . }}
app.kubernetes.io/component: api
{{- end -}}

{{- define "ai-service.databaseSelectorLabels" -}}
app.kubernetes.io/name: {{ include "ai-service.name" . }}
app.kubernetes.io/component: database
{{- end -}}

{{/*
Nazwa bazy. Myślnik jest w identyfikatorze Postgresa znakiem wymagającym
cudzysłowów, więc `tsl-rag` musiałoby być cytowane w każdym zapytaniu i w DSN.
Zamiana na podkreślnik daje `tsl_rag` — dokładnie to, czego używa dziś tenant #1.
*/}}
{{- define "ai-service.databaseName" -}}
{{- .Values.database.name | default (include "ai-service.name" . | replace "-" "_") -}}
{{- end -}}

{{/*
Referencja obrazu z artefaktem seed. Kontrakt zapisuje ją jako `oci://…`, żeby
było widać, że to artefakt rejestru, a nie ścieżka w repo; runtime kontenerowy
tego przedrostka nie rozumie.
*/}}
{{- define "ai-service.seedImage" -}}
{{- $seed := required "database.seed jest wymagane przy database.mode: managed" .Values.database.seed -}}
{{- trimPrefix "oci://" $seed -}}
{{- end -}}

{{/*
Właściciel jedzie w etykiecie, nie tylko w kontrakcie: alert bez adresata to
alert, który nikt nie odbierze.
*/}}
{{- define "ai-service.ownerLabel" -}}
ai-platform.io/owner: {{ required "kontrakt musi mieć pole `owner`" .Values.owner | quote }}
{{- end -}}

{{- define "ai-service.image" -}}
{{- $image := required "kontrakt musi mieć sekcję `image`" .Values.image -}}
{{- $repo := required "image.repo jest wymagane" $image.repo -}}
{{- $tag := required "image.tag jest wymagane" $image.tag -}}
{{- if eq (toString $tag) "latest" -}}
{{- fail "image.tag nie może być `latest`: rollback i analiza canary porównywałyby się do celu, który się przesuwa" -}}
{{- end -}}
{{- printf "%s:%s" $repo (toString $tag) -}}
{{- end -}}

{{/*
Cache wag modelu (HF_HOME) a liczba replik.

Wolumen ReadWriteOnce montuje się tylko na jednym węźle. Przy replikach > 1
drugi pod ląduje w Pending z konfliktem node affinity — i to jest awaria, która
wygląda jak problem ze schedulerem, a nie jak zła konfiguracja. StorageClass
`local-path` z klastra docelowego (D-002) nie oferuje ReadWriteMany.

Dlatego chart odmawia wyrenderowania takiej kombinacji, zamiast pozwolić jej
dojechać do klastra i tam zawisnąć.
*/}}
{{- define "ai-service.validateCache" -}}
{{- $cache := .Values.runtime.cache | default dict -}}
{{- if and $cache.enabled (gt (int .Values.runtime.replicas) 1) (eq ($cache.accessMode | default "ReadWriteOnce") "ReadWriteOnce") -}}
{{- fail (printf "runtime.cache.enabled=true przy runtime.replicas=%d wymaga accessMode ReadWriteMany. Przy ReadWriteOnce drugi pod nie wystartuje. Wybierz: replicas=1, albo StorageClass z RWX, albo cache.enabled=false (kosztem ~1.1 GB pobierania przy każdym starcie poda)." (int .Values.runtime.replicas)) -}}
{{- end -}}
{{- end -}}

{{/*
Wspólny blok envFrom dla API i bramki. Bramka MUSI dostać tę samą konfigurację
co API — inaczej ocenia inne środowisko, niż to, które promuje.

Kolejność ma znaczenie: ConfigMapa renderowana z kontraktu jest pierwsza,
zewnętrzne źródła nadpisują ją później. Dzięki temu tenant może nadpisać
pojedynczą wartość, nie kopiując całej reszty.
*/}}
{{- define "ai-service.envFrom" -}}
{{- if .Values.runtime.env }}
- configMapRef:
    name: {{ include "ai-service.name" . }}-env
{{- end }}
{{- with .Values.runtime.envFrom }}
{{- if .configMap }}
- configMapRef:
    name: {{ .configMap }}
{{- end }}
{{- if .secret }}
- secretRef:
    name: {{ .secret }}
{{- end }}
{{- end }}
{{- end -}}

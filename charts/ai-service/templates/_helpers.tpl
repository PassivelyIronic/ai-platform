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

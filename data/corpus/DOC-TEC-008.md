---
codigo: DOC-TEC-008
titulo: Instructivo de respuesta a incidentes de seguridad
tipo: instructivo
area: Tecnología
confidencialidad: confidencial
version: '2.2'
vigente_desde: 2026-03-01
vigente_hasta: null
estado: vigente
relaciones:
- {tipo: complementa, documento: DOC-RIE-004}
etiquetas: [seguridad_informatica, incidentes, instructivo, respuesta]
---

# Instructivo de respuesta a incidentes de seguridad

## 1. Objetivo y alcance

Describe cómo se detecta, contiene, erradica y cierra un incidente de seguridad de la
información. Complementa el procedimiento general de escalamiento de incidentes de riesgo
operacional (DOC-RIE-004): aquel define la ruta organizativa, este define el tratamiento
técnico.

## 2. Qué se considera incidente de seguridad

Todo evento que comprometa o pueda comprometer la confidencialidad, integridad o disponibilidad
de la información del banco. Incluye accesos no autorizados, código malicioso, pérdida de
dispositivos con información, exposición de credenciales y uso indebido de privilegios.

## 3. Fases

### 3.1 Detección y registro

El incidente se registra apenas se detecta, con la hora exacta de detección y la fuente. La hora
importa: sin ella no puede reconstruirse la ventana de exposición.

### 3.2 Clasificación

Se clasifica por severidad según el criterio de DOC-RIE-004, ponderando el alcance (cuántos
sistemas y cuántos datos), la sensibilidad de la información involucrada y si el compromiso está
activo o ya cesó.

### 3.3 Contención

Prioridad sobre la erradicación. Se aísla el sistema afectado, se revocan las credenciales
comprometidas y se bloquean los orígenes involucrados. La contención puede implicar degradar un
servicio: esa decisión la toma el responsable de guardia y no requiere autorización previa
cuando el compromiso está activo.

### 3.4 Preservación de evidencia

Antes de remediar, se preservan las imágenes de los sistemas afectados y las bitácoras
relevantes. Remediar sin preservar destruye la evidencia y hace imposible la investigación
posterior de Auditoría Interna.

### 3.5 Erradicación y recuperación

Se elimina la causa, se restauran los servicios desde copias verificadas y se confirma que el
compromiso no persiste antes de reabrir el acceso.

### 3.6 Cierre y lecciones aprendidas

Todo incidente cierra con causa raíz, cronología, impacto estimado y plan de acción. Los
incidentes de severidad alta o crítica se revisan en el Comité de Riesgos.

## 4. Comunicación

La comunicación externa —a clientes, al regulador o a la prensa— la define exclusivamente la
Gerencia General con intervención de Legales. Ningún integrante del equipo técnico comunica
hacia afuera, ni siquiera para confirmar un hecho ya público.

## 5. Notificación al regulador

Cuando el incidente afecta datos de clientes o la continuidad de un servicio esencial, Legales
evalúa la obligación de notificar al Banco Central y a la autoridad de protección de datos, y en
qué plazo. La evaluación se hace siempre, aunque la conclusión sea que no corresponde notificar,
y queda documentada.

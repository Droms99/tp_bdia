---
codigo: DOC-AUD-003
titulo: Informe de investigación — acceso indebido a sistemas del núcleo bancario
tipo: informe_investigacion
area: Auditoría Interna
confidencialidad: restringido
version: "1.0"
vigente_desde: 2026-01-20
vigente_hasta: null
estado: vigente
etiquetas: [seguridad_informatica, incidente, investigacion_interna, core_bancario]
---

# Informe de investigación — acceso indebido a sistemas del núcleo bancario

> **Nivel de confidencialidad: restringido.** Este documento solo debe ser accedido por
> Auditoría Interna y por las personas explícitamente autorizadas por esa área. Su existencia
> no debe divulgarse fuera de ese círculo. Es el caso extremo de acceso restringido del caso de
> uso: un analista de sucursal, un oficial de riesgo o un administrador de sistemas sin
> otorgamiento explícito no debe poder verlo, aunque su nivel de habilitación alcance el de
> "restringido" para otros documentos.

## 1. Antecedentes

El 14 de enero de 2026, el equipo de monitoreo de Tecnología detectó un patrón de accesos
fuera de horario habitual a la consola de administración del núcleo bancario, originados desde
una cuenta de servicio con privilegios elevados. Auditoría Interna abrió esta investigación el
mismo día.

## 2. Alcance de la investigación

Se revisaron los registros de acceso de los últimos noventa días sobre la consola de
administración, las bitácoras de cambios sobre el esquema de permisos del núcleo bancario, y
se entrevistó al personal con acceso a la cuenta de servicio involucrada.

## 3. Hallazgos

1. La cuenta de servicio tenía credenciales compartidas entre tres integrantes del equipo de
   infraestructura, en incumplimiento de la política de seguridad de la información entonces
   vigente (DOC-TEC-014, sección 3), que no distinguía explícitamente cuentas de servicio de
   cuentas nominales para efectos de esta restricción.
2. Los accesos fuera de horario correspondían a tareas de mantenimiento programado no
   documentadas formalmente, sin indicios de exfiltración de datos ni de modificación no
   autorizada de información de clientes.
3. No se encontró evidencia de que la información accedida haya sido utilizada con fines
   indebidos. El hallazgo principal es de control, no de fraude: la trazabilidad individual de
   quién ejecutó cada acción durante esas sesiones no pudo reconstruirse por el uso de
   credenciales compartidas.

## 4. Medidas adoptadas

Se dio de baja la cuenta de servicio compartida y se emitieron credenciales individuales para
cada integrante del equipo de infraestructura con acceso a la consola de administración. Se
instruyó a Tecnología para reforzar el monitoreo de accesos privilegiados fuera de horario.

## 5. Recomendaciones

Se recomienda revisar integralmente la política de seguridad de la información para incorporar
reglas explícitas sobre cuentas de servicio, doble aprobación para accesos privilegiados, y
registro inalterable de accesos administrativos. Esta recomendación dio origen a la
reescritura de la política registrada en DOC-TEC-021.

## 6. Estado

Investigación cerrada. Las medidas correctivas fueron verificadas por Auditoría Interna el
18 de febrero de 2026.

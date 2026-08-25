---
codigo: DOC-RIE-002
titulo: Procedimiento de evaluación de solicitudes de crédito a personas humanas
tipo: procedimiento
area: Riesgos
confidencialidad: interno
version: '1.4'
vigente_desde: 2024-11-01
vigente_hasta: null
estado: vigente
relaciones:
- {tipo: referencia, documento: DOC-RIE-001}
- {tipo: referencia, documento: DOC-RIE-003}
etiquetas: [riesgo_crediticio, procedimiento, originacion, scoring]
---

# Procedimiento de evaluación de solicitudes de crédito a personas humanas

## 1. Objetivo y alcance

Describe los pasos que debe seguir un analista de riesgos para evaluar una solicitud de crédito
presentada por una persona humana, desde la recepción del legajo hasta la decisión de
otorgamiento o rechazo. Aplica a préstamos personales, prendarios e hipotecarios y a
solicitudes de límite de tarjeta de crédito.

## 2. Recepción del legajo

El legajo llega al analista con los datos declarados por el solicitante, la documentación
respaldatoria y el resultado de las validaciones automáticas de identidad. El analista verifica
que el legajo esté completo antes de iniciar la evaluación: un legajo incompleto se devuelve al
canal de origen con el detalle de lo que falta, y no se evalúa parcialmente.

## 3. Verificación de ingresos

Los ingresos declarados se contrastan contra al menos una fuente independiente: recibo de
haberes de los últimos tres meses, constancia de inscripción y declaraciones juradas
impositivas en el caso de trabajadores independientes, o acreditación de haberes en cuenta del
banco. Cuando ninguna fuente independiente puede confirmar el ingreso declarado, la solicitud
se rechaza sin pasar a las etapas siguientes.

## 4. Consulta de antecedentes

El analista consulta la Central de Deudores del Sistema Financiero y las bases de antecedentes
comerciales contratadas por el banco. La existencia de una situación irregular informada no
rechaza la solicitud de forma automática: el analista debe dejar constancia de la situación
observada y del criterio con el que la ponderó.

## 5. Scoring y decisión

El motor de scoring (DOC-RIE-003) devuelve un puntaje y un tramo de riesgo. El tramo determina
la atribución necesaria para aprobar:

- Tramo bajo: aprueba el analista, dentro de su atribución individual.
- Tramo medio: aprueba el jefe de la unidad de riesgos.
- Tramo alto: requiere tratamiento en Comité de Riesgos.

Ningún tramo habilita a aprobar una operación que exceda los límites de concentración fijados
por la política de riesgo crediticio (DOC-RIE-001).

## 6. Registro de la decisión

Toda decisión, sea aprobación o rechazo, se registra en el sistema de originación con su
fundamento. El fundamento no puede consistir únicamente en el resultado del scoring: debe
explicitar qué elementos del legajo sostuvieron la decisión. Este registro es el que revisa
Auditoría Interna en sus pruebas sobre el proceso de originación.

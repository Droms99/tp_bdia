"""Generador deterministico del conjunto de datos de ejemplo.

Toma el corpus fijo de `data/corpus/` y deriva todo lo demas: usuarios, roles,
otorgamientos de acceso, fragmentos vectorizados, consultas, respuestas, fuentes
citadas, feedback y registros de auditoria. Con la misma semilla produce siempre
el mismo resultado, para que los numeros del informe no cambien entre corridas.

    python -m etl.generar_dataset --semilla 20260825 --consultas 400

Emite un CSV por tabla en `data/generado/` (que no se versiona: se regenera). Los
CSV usan **claves naturales**, no identificadores: `documento.codigo`,
`usuario.email`, `etiqueta.nombre`. Las claves subrogadas las asigna el motor al
cargar, y `db/datos/03_core.sql` las resuelve con joins desde las tablas de
`raw`. Es la razon por la que el esquema `raw` existe (informe, punto 12): la
normalizacion ocurre una vez, en la entrada.

--------------------------------------------------------------------------------
Por que la falta de cobertura no se infiere de un umbral de similitud
--------------------------------------------------------------------------------
Una consulta "sin cobertura" es una pregunta que la documentacion no responde.
Lo natural seria detectarla con un piso de similitud: si el mejor fragmento no
llega a tanto, no hay con que responder. Se midio, y con el embedder local no
funciona. Sobre las 63 preguntas cubiertas y las 10 no cubiertas de este archivo,
las distribuciones del mejor puntaje se superponen casi por completo:

    con cobertura   mediana 0.212   minimo 0.063
    sin cobertura   mediana 0.140   maximo 0.226

No hay umbral que las separe: el mejor barrido de parametros deja 58 de 63
cubiertas bien clasificadas a cambio de aceptar 5 de las 10 no cubiertas. Es
esperable, porque el embedder por defecto es lexico (`etl/embeddings.py`) y dos
preguntas del mismo dominio comparten vocabulario aunque una tenga respuesta en
el corpus y la otra no.

Asi que no se infiere: se declara. Las preguntas de `SIN_COBERTURA` no producen
respuesta porque el corpus efectivamente no las responde, y eso el generador lo
sabe por construccion. Fabricar la separacion con un umbral elegido a posteriori
haria que los datos de ejemplo afirmaran una capacidad que el sistema no tiene.
La medicion queda en el punto 11 del informe como lo que es: el limite del
embedder local, y una de las razones por las que la recuperacion del diseño es
hibrida y no solo vectorial.

--------------------------------------------------------------------------------
La regla de acceso se implementa dos veces, y es a proposito
--------------------------------------------------------------------------------
Este generador reimplementa la regla de acceso del punto 4.4 del informe, la
misma que `core.puede_acceder_documento()` evalua en SQL. No es una duplicacion
por descuido: es lo que permite que los datos generados sean *coherentes* con la
seguridad del modelo.

Concretamente, `respuesta_fuente` solo cita fragmentos que el autor de la
consulta podia ver (RD11). Si el generador citara cualquier fragmento, la
consulta de trazabilidad mostraria una fuga que nunca ocurrio, y la consulta que
demuestra RLS compararia contra datos que la contradicen. Que las dos
implementaciones —Python y SQL— coincidan sobre los mismos datos es, ademas, una
verificacion cruzada de las dos.
"""
from __future__ import annotations

import argparse
import csv
import json
import random
import unicodedata
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from etl.chunker import fragmentar_documento
from etl.embeddings import crear_embedder, similitud
from etl.extractores import leer_corpus

# Las particiones declaradas en 04_particiones.sql cubren los doce meses de 2026:
# todo evento generado tiene que caer dentro de esa ventana.
INICIO = datetime(2026, 1, 5, 9, 0, tzinfo=timezone(timedelta(hours=-3)))
FIN = datetime(2026, 6, 30, 18, 0, tzinfo=timezone(timedelta(hours=-3)))

NIVELES = {'publico': 1, 'interno': 2, 'confidencial': 3, 'restringido': 4}

# Piso de similitud para que un fragmento entre al ranking. No es un detector de
# cobertura —ver la nota de cabecera—: solo descarta el ruido de fondo de los
# fragmentos que no comparten nada con la pregunta.
PISO_RANKING = 0.02
DOMINIO = 'banco-ejemplo.com.ar'


def sin_acentos(s):
    s = unicodedata.normalize('NFKD', s)
    return ''.join(c for c in s if not unicodedata.combining(c))


# =============================================================================
# Personas
# =============================================================================
# Nombres ficticios y dominio inexistente. Son datos personales simulados, y el
# punto 11 del informe los usa como el ejemplo concreto de dato sensible (R7):
# `usuario` es la unica tabla del modelo que identifica a una persona.
#
# Los cinco primeros son los que aparecen en las consultas representativas de
# `db/consultas/`, y estan elegidos para que la demostracion tenga sentido:
# misma pregunta, distinto permiso, distinto resultado.
# =============================================================================

PERSONAS = [
    # (nombre, area, habilitacion, roles, es_protagonista)
    ('Laura Giménez',     'Operaciones',       'interno',      ['consultor'], True),
    ('Ricardo Paz',       'Compliance',        'confidencial', ['consultor'], True),
    ('Marta Ocampo',      'Auditoría Interna', 'restringido',  ['consultor', 'auditor'], True),
    ('Diego Ferreyra',    'Tecnología',        'confidencial', ['consultor', 'curador'], True),
    ('Sofía Almada',      'Riesgos',           'confidencial', ['consultor'], True),
    ('Julián Rearte',     'Operaciones',       'publico',      ['consultor'], False),
    ('Verónica Sosa',     'Operaciones',       'interno',      ['consultor'], False),
    ('Andrés Quiroga',    'Operaciones',       'interno',      ['consultor', 'curador'], False),
    ('Carla Bustos',      'Compliance',        'confidencial', ['consultor', 'curador'], False),
    ('Nicolás Ferrari',   'Compliance',        'interno',      ['consultor'], False),
    ('Patricia Leiva',    'Riesgos',           'interno',      ['consultor'], False),
    ('Gustavo Medina',    'Riesgos',           'confidencial', ['consultor', 'curador'], False),
    ('Elena Vidal',       'Legales',           'confidencial', ['consultor', 'curador'], False),
    ('Martín Cabrera',    'Legales',           'interno',      ['consultor'], False),
    ('Silvia Roldán',     'Tecnología',        'interno',      ['consultor'], False),
    ('Federico Ibarra',   'Tecnología',        'restringido',  ['consultor', 'administrador'], False),
    ('Mariana Duarte',    'Auditoría Interna', 'restringido',  ['consultor', 'auditor'], False),
    ('Hernán Otero',      'Auditoría Interna', 'confidencial', ['consultor', 'auditor'], False),
    ('Lucía Barrios',     'Operaciones',       'interno',      ['consultor'], False),
    ('Pablo Vergara',     'Tecnología',        'confidencial', ['consultor'], False),
]


def correo(nombre: str) -> str:
    partes = sin_acentos(nombre).lower().split()
    return f'{partes[0][0]}{partes[-1]}@{DOMINIO}'


def construir_usuarios():
    us = []
    for i, (nombre, area, nivel, roles, prota) in enumerate(PERSONAS, start=1):
        us.append({
            'identidad_ext': f'ID-{i:04d}',
            'nombre': nombre,
            'email': correo(nombre),
            'area': area,
            'nivel_habilitacion': nivel,
            'roles': roles,
            'activo': True,
            'protagonista': prota,
        })
    # Una baja logica: el usuario no se borra porque sus consultas y accesos
    # tienen que seguir siendo auditables (informe 2.3).
    us.append({'identidad_ext': 'ID-0021', 'nombre': 'Rodrigo Cáceres',
               'email': correo('Rodrigo Cáceres'), 'area': 'Operaciones',
               'nivel_habilitacion': 'interno', 'roles': ['consultor'],
               'activo': False, 'baja_en': '2026-04-30 18:00:00-03',
               'protagonista': False})
    return us


# =============================================================================
# Otorgamientos de acceso
# =============================================================================
# La regla de 4.4 tiene dos terminos: el nivel del documento no puede superar la
# habilitacion del usuario, y ademas —salvo que el documento sea publico— tiene
# que existir un otorgamiento vigente que lo alcance. Estas son las reglas con
# las que se construye ese segundo termino.
#
# El criterio general es que el area propietaria accede a su documentacion. Las
# excepciones son las interesantes, y son las que hacen que el corpus sirva para
# demostrar algo:
#
#   - Los cinco documentos de nivel restringido NO se otorgan por area. Se
#     otorgan de forma nominal, usuario por usuario. Es el caso que el punto 1.4
#     del informe describe: un analista de sucursal no debe ver el informe de
#     una investigacion de fraude, y un administrador de sistemas tampoco.
#   - Auditoria Interna accede por rol a todo lo que audita.
#   - Hay otorgamientos cruzados entre areas donde el proceso lo exige
#     (Operaciones necesita el procedimiento de conocimiento del cliente, que es
#     de Compliance), y otorgamientos con vencimiento, que son los que permiten
#     mostrar que un permiso caducado deja de dar acceso sin borrar la fila.
# =============================================================================

# documento -> areas adicionales que lo necesitan por proceso
OTORGAMIENTOS_CRUZADOS = {
    'DOC-CMP-005': ['Operaciones'],          # KYC: lo ejecuta Operaciones al dar de alta
    'DOC-CMP-001': ['Riesgos', 'Legales'],
    'DOC-CMP-003': ['Operaciones'],
    'DOC-RIE-004': ['Operaciones', 'Tecnología'],   # escalamiento de incidentes
    'DOC-TEC-005': ['Operaciones', 'Riesgos', 'Compliance', 'Legales'],
    'DOC-TEC-011': ['Operaciones'],
    'DOC-TEC-021': ['Compliance', 'Legales'],
    'DOC-LEG-001': ['Tecnología', 'Compliance'],
    'DOC-LEG-007': ['Compliance', 'Operaciones', 'Tecnología'],
    'DOC-OPE-015': ['Riesgos'],
    'DOC-OPE-012': ['Riesgos'],
    'DOC-RIE-001': ['Legales'],
}

# Los de nivel restringido: acceso nominal, por persona.
OTORGAMIENTOS_NOMINALES = {
    'DOC-AUD-003': ['Marta Ocampo', 'Mariana Duarte'],
    'DOC-AUD-005': ['Marta Ocampo', 'Mariana Duarte'],
    'DOC-CMP-004': ['Ricardo Paz', 'Carla Bustos', 'Marta Ocampo'],
    'DOC-TEC-002': ['Federico Ibarra', 'Marta Ocampo'],
    'DOC-OPE-020': ['Andrés Quiroga', 'Marta Ocampo'],
}

# Otorgamiento con vencimiento: Sofía Almada (Riesgos) tuvo acceso temporal al
# informe de auditoria sobre accesos mientras duro la revision del hallazgo, y
# ese acceso ya vencio. La fila queda: revocar es cerrar la ventana de vigencia,
# no borrar el registro de quien tuvo acceso a que y hasta cuando.
OTORGAMIENTOS_VENCIDOS = [
    ('DOC-AUD-009', 'Sofía Almada', '2026-05-20 09:00:00-03', '2026-06-15 09:00:00-03'),
]

ROL_AUDITOR_SOBRE = ['DOC-AUD-003', 'DOC-AUD-005', 'DOC-AUD-009', 'DOC-CMP-004',
                     'DOC-TEC-002', 'DOC-OPE-020', 'DOC-CMP-001', 'DOC-TEC-021',
                     'DOC-LEG-003', 'DOC-RIE-001', 'DOC-RIE-003']


def construir_acl(documentos, usuarios, curadores):
    """Devuelve las filas de acl_documento y un indice para evaluar la regla."""
    acl = []
    momento = '2026-01-02 09:00:00-03'
    for doc in documentos:
        if doc['nivel'] == 'publico':
            continue  # el nivel minimo de la escala no exige otorgamiento
        otorgante = curadores[doc['area']]
        if doc['codigo'] not in OTORGAMIENTOS_NOMINALES:
            acl.append({'documento': doc['codigo'], 'granularidad': 'area',
                        'destinatario': doc['area'], 'vigente_desde': momento,
                        'vigente_hasta': '', 'otorgado_por': otorgante})
        for area in OTORGAMIENTOS_CRUZADOS.get(doc['codigo'], []):
            acl.append({'documento': doc['codigo'], 'granularidad': 'area',
                        'destinatario': area, 'vigente_desde': momento,
                        'vigente_hasta': '', 'otorgado_por': otorgante})
        for nombre in OTORGAMIENTOS_NOMINALES.get(doc['codigo'], []):
            acl.append({'documento': doc['codigo'], 'granularidad': 'usuario',
                        'destinatario': correo(nombre), 'vigente_desde': momento,
                        'vigente_hasta': '', 'otorgado_por': otorgante})
        if doc['codigo'] in ROL_AUDITOR_SOBRE:
            acl.append({'documento': doc['codigo'], 'granularidad': 'rol',
                        'destinatario': 'auditor', 'vigente_desde': momento,
                        'vigente_hasta': '', 'otorgado_por': otorgante})
    for cod, nombre, desde, hasta in OTORGAMIENTOS_VENCIDOS:
        doc = next(d for d in documentos if d['codigo'] == cod)
        acl.append({'documento': cod, 'granularidad': 'usuario',
                    'destinatario': correo(nombre), 'vigente_desde': desde,
                    'vigente_hasta': hasta, 'otorgado_por': curadores[doc['area']]})
    return acl


def indice_acceso(acl, momento: datetime):
    """(documento, granularidad) -> destinatarios con otorgamiento vigente."""
    idx = {}
    for a in acl:
        desde = datetime.fromisoformat(a['vigente_desde'])
        hasta = datetime.fromisoformat(a['vigente_hasta']) if a['vigente_hasta'] else None
        if momento < desde or (hasta and momento >= hasta):
            continue
        idx.setdefault((a['documento'], a['granularidad']), set()).add(a['destinatario'])
    return idx


def puede_acceder(usuario, doc, idx) -> bool:
    """La regla del punto 4.4, en Python. Su gemela en SQL es
    core.puede_acceder_documento() de 05_rls.sql, y tienen que coincidir."""
    if NIVELES[doc['nivel']] > NIVELES[usuario['nivel_habilitacion']]:
        return False
    if doc['nivel'] == 'publico':
        return True
    if usuario['email'] in idx.get((doc['codigo'], 'usuario'), ()):
        return True
    if usuario['area'] in idx.get((doc['codigo'], 'area'), ()):
        return True
    return bool(set(usuario['roles']) & idx.get((doc['codigo'], 'rol'), set()))


# =============================================================================
# Banco de preguntas
# =============================================================================
# Preguntas en lenguaje natural, escritas como las escribiria alguien del banco:
# sin tildes muchas veces, con el vocabulario del negocio y no con el de los
# documentos. Se reparten entre los usuarios segun el area, que es lo que hace
# que la agregacion de uso por area del punto 10 muestre algo y no ruido.
# =============================================================================

PREGUNTAS = {
    'Operaciones': [
        'cuantos factores de autenticacion hacen falta para operar por canal digital',
        'se puede abrir una cuenta gratuita sin contratar otro producto',
        'que hago si al arquear la caja me da diferencia',
        'puedo corregir una operacion que registre mal',
        'que documentacion pide el alta de cuenta de una sociedad',
        'quien firma la conciliacion diaria de caja',
        'cual es el plazo para responder un reclamo de un cliente',
        'hay que entregar constancia cuando se recibe un reclamo',
        'se puede operar la caja si se cayo el sistema',
        'que pasa si el cajero automatico debita y no entrega el dinero',
        'como se verifica la identidad en el alta por canal digital',
        'quien autoriza una extraccion por encima del limite de la sucursal',
        'que hago si el cliente no recibe el codigo por sms',
        'se pueden compensar diferencias entre dos cajeros',
        'como se abre la sucursal a la mañana',
    ],
    'Compliance': [
        'que es el beneficiario final y por que se pide',
        'cada cuanto hay que revisar el legajo de un cliente',
        'que pasa si el cliente se niega a declarar el origen de los fondos',
        'se le puede avisar al cliente que su operacion genero una alerta',
        'que es una persona expuesta politicamente y a quien alcanza',
        'quien aprueba el alta de un cliente que es persona expuesta politicamente',
        'cual es el circuito para reportar una operacion sospechosa',
        'que documentacion se pide para dar de alta una persona juridica',
        'como se segmenta a los clientes por nivel de riesgo',
        'que decia la politica de prevencion de lavado antes de la version actual',
        'se puede abrir la cuenta si falta la constancia de domicilio',
    ],
    'Riesgos': [
        'a partir de cuando se considera que una cuota esta en mora',
        'se puede refinanciar una deuda en mora',
        'que variables usa el modelo de scoring crediticio',
        'quien aprueba un credito de tramo de riesgo alto',
        'como se clasifica a un deudor para calcular la prevision',
        'cuando se desafecta una prevision',
        'como se escala un incidente de riesgo operacional',
        'que severidad tiene un incidente que afecta a muchos clientes',
        'el scoring decide por si solo el otorgamiento de un credito',
        'cuales son los limites de concentracion de la cartera',
    ],
    'Tecnología': [
        'cada cuanto vence la contraseña de los sistemas criticos',
        'puedo prestarle mi usuario a un compañero',
        'quien aprueba un acceso a un sistema nuevo',
        'que pasa con los accesos cuando alguien se desvincula',
        'que hago primero ante un incidente de seguridad',
        'se puede remediar un incidente antes de preservar la evidencia',
        'cada cuanto se prueban las restauraciones de las copias de resguardo',
        'cual es el tiempo objetivo de recuperacion del nucleo bancario',
        'que pasa si el cierre diario no termina antes de las seis',
        'se pueden usar credenciales compartidas para cuentas de servicio',
        'que decia la politica de seguridad de la informacion anterior',
    ],
    'Legales': [
        'quien responde un oficio judicial que llega a la sucursal',
        'cuanto tiempo hay que conservar el legajo de un cliente',
        'se puede destruir el papel despues de digitalizar',
        'que clausulas son obligatorias en un contrato con un proveedor',
        'que derechos tiene el titular sobre sus datos personales',
        'se pueden conservar los datos biometricos de los clientes',
        'que pasa con la destruccion si hay una investigacion en curso',
        'se puede cancelar un prestamo antes de tiempo',
        'que es el costo financiero total',
    ],
    'Auditoría Interna': [
        'cuando se cierra una observacion de auditoria',
        'cuantas prorrogas se pueden pedir sobre una observacion',
        'que paso con la investigacion por accesos indebidos al nucleo bancario',
        'que hallazgos hubo en la revision del proceso de accesos',
        'por que hubo diferencias de caja en una sucursal',
        'auditoria necesita autorizacion para acceder a un documento',
        'que criticidad tiene una observacion que se repite',
    ],
}

# Preguntas de demostracion: se generan SIEMPRE, con usuario fijo, cualquiera sea
# la semilla. Las consultas representativas de `db/consultas/` las buscan por su
# texto para tomar su embedding —que es el mismo dato que la aplicacion pasaria
# como parametro—, asi que no pueden depender de que el muestreo las elija.
PREGUNTAS_DEMO = [
    ('que paso con la investigacion por accesos indebidos al nucleo bancario',
     'Marta Ocampo'),
    ('que exige la comunicacion A 7724 sobre autenticacion de dos factores',
     'Laura Giménez'),
    ('cual es el procedimiento vigente de conocimiento del cliente',
     'Ricardo Paz'),
    ('cada cuanto vence la contraseña de los sistemas criticos',
     'Diego Ferreyra'),
]

# Preguntas que el corpus no responde. Son las que alimentan la vista
# analytics.consultas_sin_cobertura, que el informe describe como la consulta de
# mayor valor de negocio del trabajo: el mapa de lo que falta documentar.
SIN_COBERTURA = [
    'cual es el procedimiento para emitir una carta de credito de comercio exterior',
    'como se liquidan las operaciones de dolar mep para clientes minoristas',
    'que pasos hay que seguir para abrir una cuenta a un menor de edad',
    'cual es la politica de teletrabajo del banco',
    'como se calcula el bono anual por desempeño',
    'que cobertura tiene el seguro de caucion para alquileres',
    'cual es el procedimiento de custodia de titulos valores',
    'como se gestiona el alta de un proveedor del exterior con pago en criptomonedas',
    'que hay que hacer para habilitar la operatoria de factoring',
    'cual es el limite de descubierto para cuentas de plan sueldo',
]


# =============================================================================
# Construccion del catalogo documental a partir del corpus
# =============================================================================

def construir_documentos(fuentes, usuarios):
    """Agrupa las versiones por documento y arma las filas de documento,
    documento_version, chunk, relaciones y etiquetas."""
    curadores = {}
    for u in usuarios:
        if 'curador' in u['roles'] and u['area'] not in curadores:
            curadores[u['area']] = u['email']
    # Areas sin curador propio: las cubre el administrador.
    admin = next(u['email'] for u in usuarios if 'administrador' in u['roles'])
    for u in usuarios:
        curadores.setdefault(u['area'], admin)

    por_codigo = {}
    for f in fuentes:
        por_codigo.setdefault(f.codigo, []).append(f)
    for vs in por_codigo.values():
        vs.sort(key=lambda d: d.vigente_desde)

    documentos, versiones, relaciones, etiquetas_doc = [], [], [], []
    for codigo, vs in sorted(por_codigo.items()):
        # La identidad, la clasificacion y el estado son del documento; el
        # contenido es de la version (decision D2). Cuando un documento tiene
        # varias versiones, sus atributos de cabecera se toman de la ultima.
        ult = vs[-1]
        documentos.append({
            'codigo': codigo, 'titulo': ult.titulo, 'tipo': ult.tipo,
            'area': ult.area, 'nivel': ult.confidencialidad, 'estado': ult.estado,
            'metadatos': json.dumps(ult.metadatos, ensure_ascii=False, sort_keys=True),
            'creado_por': curadores[ult.area],
        })
        for v in vs:
            versiones.append({
                'documento': codigo, 'numero_version': v.version,
                'vigente_desde': v.vigente_desde.isoformat(),
                'vigente_hasta': v.vigente_hasta.isoformat() if v.vigente_hasta else '',
                'uri_original': v.uri_original, 'hash_sha256': v.hash_sha256,
                'texto': v.texto, 'creado_por': curadores[v.area],
            })
        vistas = set()
        for v in vs:
            for r in v.relaciones:
                clave = (codigo, r['documento'], r['tipo'])
                if clave not in vistas and r['documento'] != codigo:
                    vistas.add(clave)
                    relaciones.append({'origen': codigo, 'destino': r['documento'],
                                       'tipo': r['tipo']})
            for e in v.etiquetas:
                if (codigo, e) not in vistas:
                    vistas.add((codigo, e))
                    etiquetas_doc.append({'documento': codigo, 'etiqueta': e})
    return documentos, versiones, relaciones, etiquetas_doc, curadores


def construir_chunks(fuentes, embedder, **kw):
    filas = []
    for f in fuentes:
        for frag in fragmentar_documento(f, **kw):
            filas.append({
                'documento': f.codigo, 'numero_version': f.version,
                'orden': frag.orden, 'texto': frag.texto, 'tokens': frag.tokens,
                'modelo': embedder.nombre,
                'embedding': vector_literal(embedder.vectorizar(frag.texto)),
                'metadatos': json.dumps(frag.metadatos, ensure_ascii=False, sort_keys=True),
                # Contexto que no va a la base pero que necesita el simulador de
                # recuperacion para respetar permisos y vigencia.
                '_nivel': f.confidencialidad, '_area': f.area, '_estado': f.estado,
                '_desde': f.vigente_desde, '_hasta': f.vigente_hasta,
            })
    return filas


def vector_literal(v) -> str:
    """Literal de pgvector: '[0.01,-0.2,...]'. Seis decimales alcanzan de sobra
    para vectores unitarios y bajan a la mitad el tamanio del archivo."""
    return '[' + ','.join(f'{x:.6f}' for x in v) + ']'


# =============================================================================
# Simulacion de la recuperacion
# =============================================================================

def recuperar(pregunta_vec, chunks, usuario, idx, momento, k=5):
    """Devuelve los k fragmentos que el sistema habria usado para responder.

    Aplica los dos filtros que aplica el sistema real y en el mismo orden
    conceptual: primero el permiso (RLS, que el motor impone y la consulta no
    puede evitar) y despues la vigencia (D3, que aplica la consulta). Un
    fragmento de un documento derogado no alimenta respuestas aunque el usuario
    tenga permiso para verlo.
    """
    hoy = momento.date()
    candidatos = []
    for c in chunks:
        doc = {'codigo': c['documento'], 'nivel': c['_nivel'], 'area': c['_area']}
        if not puede_acceder(usuario, doc, idx):
            continue
        if c['_estado'] in ('derogado', 'obsoleto', 'borrador'):
            continue
        if c['_hasta'] and c['_hasta'] < hoy:
            continue
        if c['_desde'] > hoy:
            continue
        s = similitud(pregunta_vec, c['_vec'])
        if s > PISO_RANKING:
            candidatos.append((s, c))
    candidatos.sort(key=lambda x: (-x[0], x[1]['documento'], x[1]['orden']))
    return candidatos[:k]


# =============================================================================
# Eventos de uso
# =============================================================================

MODELOS_LLM = ['claude-opus-5', 'claude-sonnet-5']


def construir_eventos(rng, usuarios, chunks, idx_estatico, acl, cantidad):
    """Consultas, respuestas, fuentes citadas, feedback y accesos.

    Las tres tablas de la cadena comparten `creado_en` a proposito: las claves
    foraneas de 03_tablas.sql son compuestas —(consulta_id, creado_en)— para
    garantizar que padre e hijo caigan en la misma particion. Que compartan el
    instante no es una simplificacion del generador: es el requisito del modelo.
    """
    activos = [u for u in usuarios if u['activo']]
    consultas, respuestas, fuentes, feedback, accesos = [], [], [], [], []

    span = (FIN - INICIO).total_seconds()
    # Instantes unicos y ordenados: `creado_en` es la unica via para volver a
    # encontrar la consulta al resolver las claves subrogadas en 03_core.sql.
    momentos = sorted({INICIO + timedelta(seconds=round(rng.uniform(0, span), 3))
                       for _ in range(int(cantidad * 1.3))})[:cantidad]

    por_nombre = {u['nombre']: u for u in usuarios}

    for n, momento in enumerate(momentos, start=1):
        if n <= len(PREGUNTAS_DEMO):
            # Las preguntas de demostracion van primero y con usuario fijo.
            texto, quien = PREGUNTAS_DEMO[n - 1]
            usuario, sin_cobertura = por_nombre[quien], False
            vec = _EMB.vectorizar(texto)
            idx = indice_acceso(acl, momento)
            top = recuperar(vec, chunks, usuario, idx, momento)
            emitir(consultas, respuestas, fuentes, feedback, accesos,
                   n, momento, usuario, texto, vec, top, rng)
            continue
        # Una de cada ocho consultas es de un tema que el corpus no cubre.
        sin_cobertura = (n % 8 == 0)
        usuario = rng.choice(activos)
        if sin_cobertura:
            texto = rng.choice(SIN_COBERTURA)
        else:
            # Dos tercios de las preguntas son del area del usuario; el resto,
            # de cualquier area. Alguien de Operaciones tambien pregunta por
            # normativa de Compliance, y ahi es donde el permiso importa.
            area = usuario['area'] if rng.random() < 0.66 else rng.choice(list(PREGUNTAS))
            texto = rng.choice(PREGUNTAS[area])

        vec = _EMB.vectorizar(texto)
        idx = indice_acceso(acl, momento)
        # Si la pregunta es de un tema que el corpus no cubre, no hay contexto
        # con que responder, cualquiera sea el puntaje que devuelva el embedder.
        top = [] if sin_cobertura else recuperar(vec, chunks, usuario, idx, momento)
        emitir(consultas, respuestas, fuentes, feedback, accesos,
               n, momento, usuario, texto, vec, top, rng)

    return consultas, respuestas, fuentes, feedback, accesos


def emitir(consultas, respuestas, fuentes, feedback, accesos,
           n, momento, usuario, texto, vec, top, rng):
    """Escribe la cadena consulta -> respuesta -> fuentes -> accesos -> feedback.

    Las tres tablas de la cadena comparten `creado_en` a proposito: las claves
    foraneas de 03_tablas.sql son compuestas —(consulta_id, creado_en)— para
    garantizar que padre e hijo caigan en la misma particion. Que compartan el
    instante no es una simplificacion del generador: es el requisito del modelo.
    """
    clave = f'Q{n:05d}'
    consultas.append({
        'clave': clave, 'usuario': usuario['email'], 'texto': texto,
        'embedding': vector_literal(vec), 'modelo': _EMB.nombre,
        'latencia_ms': rng.randint(280, 2400) if top else rng.randint(120, 600),
        'creado_en': iso(momento),
    })
    if not top:
        # Sin fragmentos recuperados no se genera respuesta: el sistema no
        # inventa. La consulta queda registrada y cae en la vista de consultas
        # sin cobertura, que es el dato que le interesa al curador.
        return

    respuestas.append({
        'consulta': clave, 'texto': redactar(top, texto),
        'modelo': rng.choice(MODELOS_LLM),
        'tokens_entrada': sum(c['tokens'] for _, c in top) + 180,
        'tokens_salida': rng.randint(90, 380),
        # La confianza acompaña al puntaje del mejor fragmento recuperado: una
        # respuesta armada con fuentes flojas no se reporta como firme.
        'confianza': f'{min(0.985, 0.45 + top[0][0] * 1.6):.3f}',
        'creado_en': iso(momento),
    })
    for pos, (puntaje, c) in enumerate(top, start=1):
        fuentes.append({
            'consulta': clave, 'documento': c['documento'],
            'numero_version': c['numero_version'], 'orden_chunk': c['orden'],
            'posicion': pos, 'puntaje': f'{puntaje:.6f}', 'creado_en': iso(momento),
        })
        # Un acceso por fragmento recuperado: es lo que permite responder "quien
        # accedio a este documento en los ultimos noventa dias" incluyendo los
        # accesos que ocurrieron por via del RAG y que nadie vivio como lectura.
        accesos.append({
            'usuario': usuario['email'], 'documento': c['documento'],
            'numero_version': c['numero_version'], 'orden_chunk': c['orden'],
            'accion': 'recuperacion',
            'contexto': json.dumps({'consulta': clave, 'posicion': pos},
                                   ensure_ascii=False, sort_keys=True),
            'creado_en': iso(momento),
        })
    if n % 3 == 0:
        util = puntaje_promedio(top) > 0.10
        feedback.append({
            'consulta': clave, 'usuario': usuario['email'],
            'util': 'true' if util else 'false',
            'comentario': ('' if util else rng.choice([
                'la respuesta cita el documento correcto pero no responde lo que pregunte',
                'esto figura en un documento viejo, no en el vigente',
                'me falta el detalle del paso a paso',
                'la fuente es de otra area y no aplica a mi caso'])),
            'creado_en': iso(momento + timedelta(minutes=rng.randint(1, 90))),
        })


def puntaje_promedio(top):
    return sum(s for s, _ in top) / len(top)


def redactar(top, pregunta):
    """Texto de la respuesta. El modelo de lenguaje es una caja negra en este
    trabajo (informe 1.3): lo que importa del registro es de que fragmentos
    salio, no la calidad de la redaccion."""
    doc = top[0][1]
    frase = top[0][1]['texto'].split('\n\n')[0]
    if len(frase) > 320:
        frase = frase[:317].rsplit(' ', 1)[0] + '...'
    return (f'{frase} '
            f'[Fuente: {doc["documento"]} v{doc["numero_version"]}'
            + (f', {json.loads(doc["metadatos"]).get("seccion")}'
               if json.loads(doc['metadatos']).get('seccion') else '') + ']')


def construir_auditoria(acl, documentos, curadores, usuarios):
    """Registro de los cambios sobre datos sensibles: alta de otorgamientos y
    cambios de estado documental. Es append-only por diseño (RD13)."""
    filas = []
    admin = next(u['email'] for u in usuarios if 'administrador' in u['roles'])
    for a in acl:
        filas.append({
            'usuario': a['otorgado_por'], 'entidad': 'acl_documento',
            'referencia': f"{a['documento']}:{a['granularidad']}:{a['destinatario']}",
            'operacion': 'alta', 'datos_antes': '',
            'datos_despues': json.dumps({'documento': a['documento'],
                                         'granularidad': a['granularidad'],
                                         'destinatario': a['destinatario']},
                                        ensure_ascii=False, sort_keys=True),
            'creado_en': iso(datetime.fromisoformat(a['vigente_desde'])),
        })
        if a['vigente_hasta']:
            filas.append({
                'usuario': a['otorgado_por'], 'entidad': 'acl_documento',
                'referencia': f"{a['documento']}:{a['granularidad']}:{a['destinatario']}",
                'operacion': 'modificacion',
                'datos_antes': json.dumps({'vigente_hasta': None}, sort_keys=True),
                'datos_despues': json.dumps({'vigente_hasta': a['vigente_hasta']},
                                            sort_keys=True),
                'creado_en': iso(datetime.fromisoformat(a['vigente_hasta'])),
            })
    for d in documentos:
        if d['estado'] == 'derogado':
            filas.append({
                'usuario': admin, 'entidad': 'documento', 'referencia': d['codigo'],
                'operacion': 'modificacion',
                'datos_antes': json.dumps({'estado': 'vigente'}, sort_keys=True),
                'datos_despues': json.dumps({'estado': 'derogado'}, sort_keys=True),
                'creado_en': iso(INICIO + timedelta(days=len(filas) % 120, hours=3)),
            })
    return filas


def iso(dt: datetime) -> str:
    return dt.isoformat(sep=' ', timespec='milliseconds')


# =============================================================================
# Emision
# =============================================================================

def escribir(directorio: Path, nombre: str, filas: list[dict], columnas=None):
    ruta = directorio / f'{nombre}.csv'
    if not filas:
        ruta.write_text('', encoding='utf-8')
        return ruta, 0
    cols = columnas or [c for c in filas[0] if not c.startswith('_')]
    with ruta.open('w', encoding='utf-8', newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction='ignore',
                           lineterminator='\n')
        w.writeheader()
        w.writerows(filas)
    return ruta, len(filas)


_EMB = None


def main():
    global _EMB
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--semilla', type=int, default=20260825,
                    help='semilla del generador; con la misma semilla el '
                         'resultado es identico (por omision 20260825)')
    ap.add_argument('--consultas', type=int, default=400,
                    help='cantidad de consultas a generar (por omision 400)')
    ap.add_argument('--corpus', default='data/corpus')
    ap.add_argument('--salida', default='data/generado')
    ap.add_argument('--tokens-objetivo', type=int, default=None,
                    help='tamanio buscado de fragmento, en tokens. Bajarlo '
                         'aumenta la cantidad de fragmentos: es la unica palanca '
                         'honesta de volumen sobre el corpus, que es fijo')
    args = ap.parse_args()

    rng = random.Random(args.semilla)
    _EMB = crear_embedder()
    salida = Path(args.salida)
    salida.mkdir(parents=True, exist_ok=True)

    print(f'semilla {args.semilla} | embedder {_EMB.nombre} '
          f'(dimension {_EMB.dimension}, metrica {_EMB.metrica})')

    fuentes = leer_corpus(args.corpus)
    usuarios = construir_usuarios()
    documentos, versiones, relaciones, etiquetas_doc, curadores = \
        construir_documentos(fuentes, usuarios)
    kw = {'objetivo': args.tokens_objetivo} if args.tokens_objetivo else {}
    chunks = construir_chunks(fuentes, _EMB, **kw)
    for c in chunks:
        c['_vec'] = [float(x) for x in c['embedding'][1:-1].split(',')]

    acl = construir_acl(documentos, usuarios, curadores)
    consultas, respuestas, fuentes_cit, feedback, accesos = construir_eventos(
        rng, usuarios, chunks, None, acl, args.consultas)
    auditoria = construir_auditoria(acl, documentos, curadores, usuarios)

    etiquetas = sorted({e['etiqueta'] for e in etiquetas_doc})
    usuario_rol = [{'usuario': u['email'], 'rol': r}
                   for u in usuarios for r in u['roles']]

    tablas = [
        ('usuario', [{k: v for k, v in u.items() if k not in ('roles', 'protagonista')}
                     for u in usuarios],
         ['identidad_ext', 'nombre', 'email', 'area', 'nivel_habilitacion',
          'activo', 'baja_en']),
        ('usuario_rol', usuario_rol, None),
        ('etiqueta', [{'nombre': e} for e in etiquetas], None),
        ('documento', documentos, None),
        ('documento_version', versiones, None),
        ('documento_relacion', relaciones, None),
        ('documento_etiqueta', etiquetas_doc, None),
        ('acl_documento', acl, None),
        ('chunk', chunks, ['documento', 'numero_version', 'orden', 'texto',
                           'tokens', 'modelo', 'embedding', 'metadatos']),
        ('consulta', consultas, None),
        ('respuesta', respuestas, None),
        ('respuesta_fuente', fuentes_cit, None),
        ('feedback', feedback, None),
        ('log_acceso', accesos, None),
        ('auditoria', auditoria, None),
    ]
    # `baja_en` solo lo trae el usuario dado de baja; el resto necesita la clave.
    for u in tablas[0][1]:
        u.setdefault('baja_en', '')

    print()
    total = 0
    for nombre, filas, cols in tablas:
        ruta, n = escribir(salida, nombre, filas, cols)
        total += n
        print(f'  {nombre:20} {n:>6} filas  {ruta.stat().st_size / 1024:>8.1f} KB')
    print(f'  {"TOTAL":20} {total:>6} filas')

    resumen(documentos, chunks, consultas, respuestas, fuentes_cit, acl, usuarios)


def resumen(documentos, chunks, consultas, respuestas, fuentes, acl, usuarios):
    sin_cob = len(consultas) - len(respuestas)
    print(f'\n  documentos {len(documentos)} | fragmentos {len(chunks)} | '
          f'otorgamientos {len(acl)} | usuarios {len(usuarios)}')
    print(f'  consultas {len(consultas)} | con respuesta {len(respuestas)} | '
          f'sin cobertura {sin_cob} ({sin_cob * 100 // len(consultas)}%) | '
          f'fuentes citadas {len(fuentes)}')

    # Verificacion que justifica que el generador reimplemente la regla de
    # acceso: ningun fragmento citado puede pertenecer a un documento derogado
    # ni exceder la habilitacion del autor de la consulta.
    por_email = {u['email']: u for u in usuarios}
    por_consulta = {c['clave']: c for c in consultas}
    doc_nivel = {d['codigo']: d['nivel'] for d in documentos}
    doc_estado = {d['codigo']: d['estado'] for d in documentos}
    malas_nivel = malas_estado = 0
    for f in fuentes:
        u = por_email[por_consulta[f['consulta']]['usuario']]
        if NIVELES[doc_nivel[f['documento']]] > NIVELES[u['nivel_habilitacion']]:
            malas_nivel += 1
        if doc_estado[f['documento']] in ('derogado', 'obsoleto', 'borrador'):
            malas_estado += 1
    print(f'\n  verificacion RD11 (toda fuente era accesible): '
          f'{"OK" if not malas_nivel else str(malas_nivel) + " VIOLACIONES"}')
    print(f'  verificacion D3  (ninguna fuente derogada):    '
          f'{"OK" if not malas_estado else str(malas_estado) + " VIOLACIONES"}')


if __name__ == '__main__':
    main()

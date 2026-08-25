"""Lectura del corpus: un extractor por formato, una salida normalizada.

El corpus (`data/corpus/`) esta en siete formatos —md, txt, html, json, csv, docx
y pdf— porque es el formato en el que un banco tiene esos documentos de verdad, y
porque el punto 11 del informe se apoya en eso: el dato no estructurado no llega
en un formato comodo, y los metadatos no llegan en un lugar uniforme.

Cada formato trae sus metadatos en el soporte que le es propio:

    md     front-matter YAML
    txt    cabecera de bloque `CLAVE: valor` de una exportacion de texto plano
    html   etiquetas <meta> del gestor documental
    json   campos de primer nivel del export de la base de conocimiento
    csv    columnas repetidas en cada fila (export plano y desnormalizado)
    docx   core properties + custom properties de OOXML
    pdf    diccionario /Info, con claves propias ademas de las estandar

Este modulo es el que unifica todo eso en un unico registro, y es la razon de ser
del esquema `raw` de la arquitectura (informe, punto 12): la normalizacion ocurre
en la entrada, una sola vez, y no en cada consulta.

Dos decisiones que conviene tener presentes:

1. Los vocabularios controlados (area, tipo, nivel, estado) se normalizan contra
   el catalogo comparando sin acentos, porque la exportacion de texto plano viene
   sin ellos ("Tecnologia" por "Tecnología"). El texto libre —titulo y cuerpo— se
   deja como llego: es el dato del documento y alterarlo seria inventar. La
   consecuencia es que hay documentos cuyo titulo quedo sin acentos, y esta bien
   que se note: la configuracion de busqueda `espanol_unaccent` de
   `01_extensiones.sql` existe exactamente por eso.

2. Del PDF se descartan encabezado y pie recurrentes. `extract_text()` los
   devuelve intercalados con el cuerpo, y sin quitarlos cada fragmento del
   documento arrastraria "Pagina 3" en el medio de una oracion, que despues se
   vectoriza y se recupera.
"""
from __future__ import annotations

import csv as _csv
import hashlib
import io
import json
import re
import unicodedata
import zipfile
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

import yaml
from bs4 import BeautifulSoup
from pypdf import PdfReader

# El bucket simulado. En la base se guarda esta URI y no el binario (decision D5
# del informe): los originales viven en object storage.
URI_BASE = 's3://tp-bdia-corpus'


# =============================================================================
# Registro normalizado
# =============================================================================

@dataclass
class DocumentoFuente:
    """Un documento del corpus, ya normalizado y con su formato de origen."""
    codigo: str
    titulo: str
    tipo: str
    area: str
    confidencialidad: str
    version: str
    vigente_desde: date
    vigente_hasta: date | None
    estado: str
    etiquetas: list[str] = field(default_factory=list)
    relaciones: list[dict] = field(default_factory=list)
    texto: str = ''
    # Atributos que varian segun el tipo de documento y segun el formato de
    # origen. Van a documento.metadatos (JSONB): es la decision D6 del informe
    # con datos reales y no con un ejemplo inventado.
    metadatos: dict = field(default_factory=dict)
    formato_origen: str = ''
    archivo: str = ''
    uri_original: str = ''
    hash_sha256: str = ''

    @property
    def clave(self) -> tuple[str, str]:
        return (self.codigo, self.version)


# =============================================================================
# Utilidades de normalizacion
# =============================================================================

def plegar(s: str) -> str:
    """Minusculas y sin acentos. Solo para comparar contra un catalogo."""
    s = unicodedata.normalize('NFKD', str(s))
    return ''.join(c for c in s if not unicodedata.combining(c)).strip().lower()


AREAS = ['Riesgos', 'Compliance', 'Tecnología', 'Operaciones', 'Legales', 'Auditoría Interna']
NIVELES = ['publico', 'interno', 'confidencial', 'restringido']
ESTADOS = ['borrador', 'vigente', 'obsoleto', 'derogado']
TIPOS = ['norma_externa', 'politica_interna', 'procedimiento', 'instructivo',
         'manual_sistema', 'faq', 'documento_historico', 'informe_investigacion']


def _contra_catalogo(valor, catalogo, que):
    if valor is None:
        raise ValueError(f'falta {que}')
    objetivo = plegar(valor)
    for c in catalogo:
        if plegar(c) == objetivo:
            return c
    raise ValueError(f'{que} desconocido: {valor!r} (esperaba uno de {catalogo})')


def a_fecha(v):
    if v in (None, '', 'null', 'NULL', 'SIN LIMITE', 'NINGUNA'):
        return None
    if isinstance(v, date):
        return v
    return date.fromisoformat(str(v).strip())


def a_lista(v):
    if not v:
        return []
    if isinstance(v, list):
        return [str(x).strip() for x in v if str(x).strip()]
    return [x.strip() for x in str(v).split(',') if x.strip()]


def a_relaciones(v):
    """Acepta la forma estructurada del YAML/JSON y la forma plana de los
    formatos que solo admiten texto ('deroga DOC-X; complementa DOC-Y')."""
    if not v:
        return []
    if isinstance(v, list):
        return [{'tipo': r['tipo'], 'documento': r['documento']} for r in v]
    out = []
    for parte in str(v).split(';'):
        parte = parte.strip()
        if not parte or plegar(parte) == 'ninguna':
            continue
        t, _, d = parte.partition(' ')
        if d.strip():
            out.append({'tipo': t.strip(), 'documento': d.strip()})
    return out


def normalizar(crudo: dict, texto: str, extra: dict) -> DocumentoFuente:
    return DocumentoFuente(
        codigo=str(crudo['codigo']).strip(),
        titulo=str(crudo['titulo']).strip(),
        tipo=_contra_catalogo(crudo.get('tipo'), TIPOS, 'tipo'),
        area=_contra_catalogo(crudo.get('area'), AREAS, 'area'),
        confidencialidad=_contra_catalogo(crudo.get('confidencialidad'), NIVELES, 'nivel'),
        version=str(crudo['version']).strip(),
        vigente_desde=a_fecha(crudo.get('vigente_desde')),
        vigente_hasta=a_fecha(crudo.get('vigente_hasta')),
        estado=_contra_catalogo(crudo.get('estado'), ESTADOS, 'estado'),
        etiquetas=a_lista(crudo.get('etiquetas')),
        relaciones=a_relaciones(crudo.get('relaciones')),
        texto=limpiar_texto(texto),
        metadatos=extra,
    )


def limpiar_texto(t: str) -> str:
    t = t.replace('\r\n', '\n').replace('\xa0', ' ')
    t = re.sub(r'[ \t]+', ' ', t)
    t = re.sub(r'\n{3,}', '\n\n', t)
    return t.strip()


# =============================================================================
# Metadatos derivados por tipo de documento
# =============================================================================
# Lo que se guarda en documento.metadatos (JSONB). No son los mismos campos para
# todos: una norma externa tiene organismo emisor y numero de comunicacion, una
# FAQ tiene cantidad de entradas, un documento derogado tiene el motivo de su
# derogacion. Modelarlos como columnas propias dejaria la tabla mayormente vacia,
# que es exactamente el argumento de D6.
# =============================================================================

def derivar_metadatos(doc: DocumentoFuente) -> dict:
    m = dict(doc.metadatos)
    m['formato_origen'] = doc.formato_origen

    if doc.tipo == 'norma_externa':
        m['organismo_emisor'] = 'BCRA'
        num = re.search(r'"A"\s*(\d+)', doc.titulo) or re.search(r'BCRA-(\d+)', doc.codigo)
        if num:
            m['numero_comunicacion'] = num.group(1)
        m['alcance'] = 'entidades financieras'

    if doc.tipo == 'faq':
        if 'cantidad_entradas' not in m:
            m['cantidad_entradas'] = len(re.findall(r'^##\s', doc.texto, re.M))

    if doc.estado == 'derogado' or doc.tipo == 'documento_historico':
        motivo = re.search(
            r'^##\s*\d*\.?\s*Motivo de la derogaci[oó]n\s*\n+(.+?)(?=\n##\s|\Z)',
            doc.texto, re.M | re.S | re.I)
        if motivo:
            m['motivo_derogacion'] = limpiar_texto(motivo.group(1))[:600]
        m['conservado_por'] = 'obligacion regulatoria de trazabilidad'

    if doc.tipo in ('informe_investigacion',):
        m['requiere_otorgamiento_nominal'] = doc.confidencialidad == 'restringido'

    if doc.tipo == 'manual_sistema':
        m['ambiente'] = 'produccion'

    return m


# =============================================================================
# Extractores por formato
# =============================================================================

def extraer_md(path: Path) -> DocumentoFuente:
    s = path.read_text(encoding='utf-8')
    m = re.match(r'^---\n(.*?)\n---\n(.*)$', s, re.S)
    if not m:
        raise ValueError(f'{path.name}: sin front-matter')
    crudo = yaml.safe_load(m.group(1))
    return normalizar(crudo, desmarcar(m.group(2)), {})


def extraer_txt(path: Path) -> DocumentoFuente:
    """Exportacion de texto plano: cabecera CLAVE: valor entre lineas de '='."""
    s = path.read_text(encoding='utf-8')
    # maxsplit=3: el banner aparece tres veces antes del cuerpo. Sin el limite,
    # el subrayado del titulo (que tambien son '=') se toma como separador y el
    # titulo pierde su marca de encabezado.
    partes = re.split(r'^={10,}\s*$', s, maxsplit=3, flags=re.M)
    # partes[0] vacio, [1] el rotulo del sistema, [2] la cabecera, [3:] el cuerpo
    cabecera = partes[2] if len(partes) > 3 else ''
    cuerpo = '\n'.join(partes[3:]) if len(partes) > 3 else s
    crudo, sistema = {}, partes[1].strip() if len(partes) > 1 else ''
    alias = {'vigente desde': 'vigente_desde', 'vigente hasta': 'vigente_hasta'}
    for ln in cabecera.split('\n'):
        if ':' not in ln:
            continue
        k, _, v = ln.partition(':')
        k = alias.get(k.strip().lower(), k.strip().lower())
        crudo[k] = v.strip()
    return normalizar(crudo, desmarcar(cuerpo, plano=True),
                      {'sistema_origen': sistema, 'sin_acentos': True})


def extraer_html(path: Path) -> DocumentoFuente:
    sopa = BeautifulSoup(path.read_text(encoding='utf-8'), 'lxml')
    crudo, rels = {}, []
    for et in sopa.find_all('meta'):
        n, c = et.get('name'), et.get('content')
        if not n:
            continue
        if n == 'relacion':
            t, _, d = (c or '').partition(':')
            if d:
                rels.append({'tipo': t, 'documento': d})
        else:
            crudo[n.replace('-', '_')] = c
    crudo['etiquetas'] = crudo.pop('keywords', '')
    crudo['relaciones'] = rels
    if sopa.title:
        crudo['titulo'] = sopa.title.get_text().split('—', 1)[-1].strip()
    cuerpo = sopa.find('div', class_='documento') or sopa.body or sopa
    for p in cuerpo.find_all('p', class_='rotulo'):
        p.decompose()
    return normalizar(crudo, texto_de_html(cuerpo),
                      {'generador': crudo.get('generator', '')})


def extraer_json(path: Path) -> DocumentoFuente:
    d = json.loads(path.read_text(encoding='utf-8'))
    partes = []
    if d.get('introduccion'):
        partes.append(d['introduccion'])
    for e in d.get('entradas', []):
        partes.append(f"## {e['pregunta']}\n\n{e['respuesta']}")
    return normalizar(d, '\n\n'.join(partes),
                      {'exportado_de': d.get('exportado_de', ''),
                       'cantidad_entradas': len(d.get('entradas', []))})


def extraer_csv(path: Path) -> DocumentoFuente:
    """Export plano: los metadatos del documento se repiten en cada fila."""
    filas = list(_csv.DictReader(io.StringIO(path.read_text(encoding='utf-8'))))
    if not filas:
        raise ValueError(f'{path.name}: csv vacio')
    crudo = dict(filas[0])
    partes = [f"## {f['pregunta']}\n\n{f['respuesta']}" for f in filas]
    return normalizar(crudo, '\n\n'.join(partes),
                      {'exportado_de': 'sistema de gestion de casos',
                       'filas_desnormalizadas': len(filas),
                       'cantidad_entradas': len(filas)})


def extraer_docx(path: Path) -> DocumentoFuente:
    from docx import Document as _Docx
    doc = _Docx(str(path))
    cp = doc.core_properties
    crudo = {'titulo': cp.title, 'tipo': cp.category, 'etiquetas': cp.keywords,
             'version': cp.version}
    # Las custom properties son donde vive el resto. python-docx no las expone:
    # se lee la parte /docProps/custom.xml del paquete OOXML directamente.
    with zipfile.ZipFile(path) as z:
        if 'docProps/custom.xml' in z.namelist():
            xml = z.read('docProps/custom.xml').decode('utf-8')
            for nombre, valor in re.findall(
                    r'name="([^"]+)"><vt:lpwstr>(.*?)</vt:lpwstr>', xml, re.S):
                crudo[nombre.strip().lower()] = valor
    crudo.setdefault('confidencialidad', (cp.subject or '').split(':')[-1].strip())
    crudo['vigente_desde'] = crudo.get('vigentedesde')
    crudo['vigente_hasta'] = crudo.get('vigentehasta')

    partes = []
    for p in doc.paragraphs:
        t = p.text.strip()
        if not t:
            continue
        est = (p.style.name or '')
        if est.startswith('Heading 1'):
            partes.append(f'# {t}')
        elif est.startswith('Heading 2'):
            partes.append(f'## {t}')
        elif est.startswith('Heading 3'):
            partes.append(f'### {t}')
        elif est.startswith('List'):
            partes.append(f'- {t}')
        elif re.fullmatch(r'[A-Z0-9\-.]+ · versión .+', t):
            continue  # el rotulo de cabecera, no es contenido
        else:
            partes.append(t)
    for tabla in doc.tables:
        for fila in tabla.rows:
            celdas = [c.text.strip() for c in fila.cells]
            if any(celdas):
                partes.append(' | '.join(celdas))
    return normalizar(crudo, '\n\n'.join(partes),
                      {'autor_documento': cp.author or '',
                       'propiedades_personalizadas': True})


def extraer_pdf(path: Path) -> DocumentoFuente:
    lector = PdfReader(str(path))
    info = {k.lstrip('/').lower(): (str(v) if v is not None else '')
            for k, v in (lector.metadata or {}).items()}
    crudo = {'codigo': info.get('codigo'), 'titulo': info.get('title'),
             'tipo': info.get('tipo'), 'area': info.get('area'),
             'confidencialidad': info.get('confidencialidad'),
             'version': info.get('version'),
             'vigente_desde': info.get('vigentedesde'),
             'vigente_hasta': info.get('vigentehasta'),
             'estado': info.get('estado'),
             'etiquetas': info.get('keywords'),
             'relaciones': info.get('relaciones')}
    paginas = [(p.extract_text() or '') for p in lector.pages]
    return normalizar(crudo, texto_de_pdf(paginas),
                      {'productor': info.get('producer', ''),
                       'paginas': len(lector.pages),
                       'texto_extraido': True})


# =============================================================================
# Limpieza de texto por formato
# =============================================================================

def desmarcar(md: str, plano: bool = False) -> str:
    """Quita el marcado que no aporta al contenido recuperable, conservando los
    encabezados: el fragmentador los necesita para no partir a mitad de seccion."""
    if plano:
        # La exportacion de texto plano subraya los titulos con '=' o '-'.
        lineas, out = md.split('\n'), []
        for i, ln in enumerate(lineas):
            sig = lineas[i + 1] if i + 1 < len(lineas) else ''
            if ln.strip() and re.fullmatch(r'={3,}', sig.strip()):
                out.append('# ' + descapitalizar(ln.strip()))
            elif ln.strip() and re.fullmatch(r'-{3,}', sig.strip()):
                out.append('## ' + descapitalizar(ln.strip()))
            elif re.fullmatch(r'[=-]{3,}', ln.strip()):
                continue
            else:
                out.append(ln)
        md = '\n'.join(out)
    md = re.sub(r'^>\s?', '', md, flags=re.M)
    md = re.sub(r'\*\*(.+?)\*\*', r'\1', md)
    md = re.sub(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)', r'\1', md)
    md = re.sub(r'`(.+?)`', r'\1', md)
    return md


def texto_de_html(nodo) -> str:
    partes = []
    for et in nodo.find_all(['h1', 'h2', 'h3', 'p', 'li', 'tr', 'blockquote']):
        if et.name == 'tr':
            celdas = [c.get_text(' ', strip=True) for c in et.find_all(['th', 'td'])]
            t = ' | '.join(celdas)
        else:
            t = et.get_text(' ', strip=True)
        if not t:
            continue
        if et.name in ('h1', 'h2', 'h3'):
            partes.append('#' * int(et.name[1]) + ' ' + t)
        elif et.name == 'li':
            partes.append('- ' + t)
        else:
            partes.append(t)
    return '\n\n'.join(partes)


PIE_PDF = re.compile(r'^(Página\s+\d+|[A-Z0-9\-]+\s+v[\d.]+\s+—\s+\w+)$')
ROTULO_PDF = re.compile(r'^[A-Z0-9\-]+\s+·\s+versión\s+.+·.+$')
# Encabezado de seccion numerado: "3." o "3.1" seguido de texto que arranca en
# mayuscula. Es la unica pista de estructura que sobrevive a extract_text().
TITULO_PDF = re.compile(r'^(\d+(?:\.\d+)*)\.?\s+([A-ZÁÉÍÓÚÑ][^.]{2,80})$')
FIN_ORACION = re.compile(r'[.:;!?]["\u201d\)]?$')


def descapitalizar(t: str) -> str:
    """'3. USO PERMITIDO' -> '3. Uso permitido'. Los titulos de la exportacion
    de texto plano vienen en mayusculas y asi son ilegibles como nombre de
    seccion de un fragmento."""
    if not any(c.isupper() for c in t) or any(c.islower() for c in t):
        return t
    bajo = t.lower()
    for i, c in enumerate(bajo):
        if c.isalpha():
            return bajo[:i] + c.upper() + bajo[i + 1:]
    return bajo


def texto_de_pdf(paginas: list[str]) -> str:
    """Descarta encabezado y pie recurrentes y reconstruye parrafos y secciones.

    `extract_text()` devuelve el texto en el orden en que esta dibujado: el pie
    aparece intercalado en el cuerpo, los parrafos vienen cortados al ancho de la
    caja de texto y la jerarquia de titulos se perdio (un encabezado y un parrafo
    son ambos, para el extractor, una linea de texto). Las tres cosas hay que
    reconstruirlas antes de fragmentar, o cada fragmento arrastra "Pagina 3" en
    el medio de una oracion y no hay forma de partir por seccion.

    Ademas de los patrones conocidos se descarta toda linea corta repetida en la
    mayoria de las paginas: es la senial de un encabezado o un pie, y es el
    criterio que sirve tambien para un PDF que no genero este proyecto.
    """
    if not paginas:
        return ''
    conteo = {}
    for pg in paginas:
        for ln in {l.strip() for l in pg.split('\n') if l.strip()}:
            conteo[ln] = conteo.get(ln, 0) + 1
    umbral = max(2, len(paginas) * 0.6)
    recurrentes = {ln for ln, n in conteo.items() if n >= umbral and len(ln) < 90}

    lineas = []
    for pg in paginas:
        for ln in pg.split('\n'):
            t = ln.strip()
            if not t or t in recurrentes or PIE_PDF.match(t) or ROTULO_PDF.match(t):
                continue
            lineas.append(t)
    if not lineas:
        return ''

    # Ancho de la caja: una linea sensiblemente mas corta que el maximo es final
    # de parrafo, no un salto de linea del ajuste automatico.
    ancho = max(len(l) for l in lineas)
    salida, buf = [], []

    def cerrar():
        if buf:
            salida.append(' '.join(buf))
            buf.clear()

    for i, t in enumerate(lineas):
        m = TITULO_PDF.match(t)
        if m:
            cerrar()
            nivel = 2 + m.group(1).count('.')
            salida.append('#' * min(nivel, 4) + ' ' + t)
        elif re.match(r'^[-•]\s', t):
            cerrar()
            salida.append('- ' + t.lstrip('-• '))
        else:
            buf.append(t)
            if FIN_ORACION.search(t) and len(t) < ancho * 0.9:
                cerrar()
    cerrar()
    return '\n\n'.join(salida)


# =============================================================================
# Entrada del modulo
# =============================================================================

EXTRACTORES = {'.md': extraer_md, '.txt': extraer_txt, '.html': extraer_html,
               '.json': extraer_json, '.csv': extraer_csv, '.docx': extraer_docx,
               '.pdf': extraer_pdf}


def leer_corpus(directorio) -> list[DocumentoFuente]:
    """Lee todos los documentos del corpus y los devuelve normalizados."""
    docs = []
    for path in sorted(Path(directorio).iterdir()):
        ext = path.suffix.lower()
        if ext not in EXTRACTORES:
            continue
        doc = EXTRACTORES[ext](path)
        doc.formato_origen = ext.lstrip('.')
        doc.archivo = path.name
        crudo = path.read_bytes()
        # D5: el binario no se guarda. Se guarda donde esta y su hash, que es lo
        # que permite detectar una reingesta del mismo archivo (R4).
        doc.hash_sha256 = hashlib.sha256(crudo).hexdigest()
        doc.uri_original = f'{URI_BASE}/{plegar(doc.area).replace(" ", "-")}/{path.name}'
        doc.metadatos = derivar_metadatos(doc)
        docs.append(doc)
    return docs


if __name__ == '__main__':
    import sys
    for d in leer_corpus(sys.argv[1] if len(sys.argv) > 1 else 'data/corpus'):
        print(f'{d.archivo:28} {d.codigo:14} v{d.version:5} {d.formato_origen:5} '
              f'{d.confidencialidad:13} {len(d.texto):>6} car  {sorted(d.metadatos)}')

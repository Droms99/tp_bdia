"""Vectorizacion de fragmentos y de preguntas.

El modelo de embeddings es, para este trabajo, una pieza intercambiable. El
modelo de datos lo trata como tal: `core.modelo_embedding` guarda con que modelo
se vectorizo cada fragmento y de que dimension es, porque sin ese dato no hay
forma de saber si dos vectores son comparables ni de planificar una
revectorizacion. Este modulo es la contraparte de esa tabla.

Por defecto se usa un embedder **deterministico y local**, sin dependencias ni
credenciales, para que cualquiera pueda clonar el repositorio y reproducir los
numeros del informe exactamente. Esa decision tiene una consecuencia que conviene
decir de frente y que el informe repite en el punto 11:

    El embedder local es **lexico, no semantico**. Proyecta el vocabulario del
    texto sobre 1024 dimensiones con hashing con signo; dos textos que comparten
    palabras quedan cerca, dos textos que dicen lo mismo con otras palabras no.
    Un modelo real de embeddings si captura lo segundo.

Lo que eso cambia y lo que no: cambia la *calidad* de la recuperacion, no el
*diseño*. El tipo de la columna, el indice HNSW, la metrica coseno, el filtro de
vigencia y —sobre todo— la politica de seguridad por fila operan igual con un
vector de un modelo real que con uno de este. Y es justamente por esa razon que
la busqueda hibrida con RRF importa tanto en este caso: la mitad lexica de la
recuperacion no depende del modelo.

Un proveedor real se conecta sin tocar este archivo:

    export TP_EMBEDDER_MODULO=mi_paquete.mi_embedder   # expone crear_embedder()

El modulo debe devolver un objeto con `nombre`, `dimension`, `metrica` y
`vectorizar(texto) -> list[float]`. La dimension tiene que ser 1024, que es la
declarada en `chunk.embedding vector(1024)`: cambiarla exige una columna nueva y
una revectorizacion planificada, no una variable de entorno.
"""
from __future__ import annotations

import hashlib
import importlib
import math
import os
import re
import unicodedata

DIMENSION = 1024
METRICA = 'coseno'

# Palabras demasiado frecuentes para aportar señal. Lista corta a proposito: una
# lista larga es una decision linguistica que no corresponde tomar aca.
VACIAS = {
    'a', 'al', 'ante', 'como', 'con', 'contra', 'cual', 'cuando', 'de', 'del',
    'desde', 'donde', 'e', 'el', 'ella', 'ellas', 'ellos', 'en', 'entre', 'es',
    'esa', 'ese', 'eso', 'esta', 'estan', 'este', 'esto', 'estos', 'ha', 'hasta',
    'hay', 'la', 'las', 'le', 'les', 'lo', 'los', 'mas', 'me', 'mi', 'ni', 'no',
    'o', 'para', 'pero', 'por', 'que', 'se', 'segun', 'ser', 'si', 'sin', 'sobre',
    'son', 'su', 'sus', 'tambien', 'te', 'un', 'una', 'uno', 'unos', 'y', 'ya',
}


def normalizar(texto: str) -> list[str]:
    """Minusculas, sin acentos, sin palabras vacias.

    Se quitan los acentos por el mismo motivo que la configuracion de busqueda de
    texto completo `espanol_unaccent` los quita: el corpus tiene documentos que
    llegaron de una exportacion de texto plano sin acentos, y las preguntas de
    los usuarios rara vez se escriben con ellos.
    """
    t = unicodedata.normalize('NFKD', texto.lower())
    t = ''.join(c for c in t if not unicodedata.combining(c))
    return [p for p in re.findall(r'[a-z0-9]+', t) if p not in VACIAS and len(p) > 1]


def _indice_y_signo(rasgo: str, dimension: int) -> tuple[int, float]:
    """Hashing con signo. blake2b y no hash(): el hash de Python esta
    aleatorizado por proceso y los vectores no serian reproducibles entre
    ejecuciones, que es justamente lo que este embedder tiene que garantizar."""
    h = hashlib.blake2b(rasgo.encode('utf-8'), digest_size=8).digest()
    n = int.from_bytes(h, 'big')
    return n % dimension, 1.0 if (n >> 63) & 1 else -1.0


class EmbedderDeterministico:
    """Proyeccion lexica sobre `dimension` dimensiones, estable entre corridas."""

    nombre = 'hash-local-1024'
    metrica = METRICA

    def __init__(self, dimension: int = DIMENSION):
        self.dimension = dimension

    def vectorizar(self, texto: str) -> list[float]:
        palabras = normalizar(texto)
        if not palabras:
            return [0.0] * self.dimension

        pesos: dict[str, float] = {}
        for p in palabras:
            pesos[p] = pesos.get(p, 0.0) + 1.0
        # Bigramas: aportan algo de orden, que las palabras sueltas pierden.
        for a, b in zip(palabras, palabras[1:]):
            k = f'{a}_{b}'
            pesos[k] = pesos.get(k, 0.0) + 0.5

        v = [0.0] * self.dimension
        for rasgo, tf in pesos.items():
            i, signo = _indice_y_signo(rasgo, self.dimension)
            # Saturacion logaritmica: que una palabra aparezca diez veces no la
            # hace diez veces mas representativa del fragmento.
            v[i] += signo * (1.0 + math.log(tf))

        norma = math.sqrt(sum(x * x for x in v))
        if norma == 0.0:
            return v
        # Se normaliza a longitud 1: con vectores unitarios la distancia coseno
        # que usa el indice HNSW es una funcion monotona del producto interno, y
        # las comparaciones son estables.
        return [x / norma for x in v]


def crear_embedder():
    """Devuelve el embedder configurado. Local salvo que se indique otro."""
    modulo = os.environ.get('TP_EMBEDDER_MODULO', '').strip()
    if not modulo:
        return EmbedderDeterministico()
    emb = importlib.import_module(modulo).crear_embedder()
    if emb.dimension != DIMENSION:
        raise ValueError(
            f'{modulo} devuelve dimension {emb.dimension}; la columna '
            f'chunk.embedding es vector({DIMENSION}). Cambiar de dimension exige '
            f'una columna nueva y una revectorizacion, no una variable de entorno.')
    return emb


def similitud(a: list[float], b: list[float]) -> float:
    """Similitud coseno. Solo para verificar el embedder desde la linea de
    comandos: en produccion la calcula el motor con el operador `<=>`."""
    return sum(x * y for x, y in zip(a, b))


if __name__ == '__main__':
    emb = crear_embedder()
    print(f'embedder: {emb.nombre}  dimension: {emb.dimension}  metrica: {emb.metrica}\n')

    pregunta = '¿cuantos factores de autenticacion se exigen para operar por canal digital?'
    candidatos = {
        'identidad digital (BCRA 7724)':
            'Toda operación que implique movimiento de fondos requiere autenticación '
            'con al menos dos factores independientes de categorías distintas.',
        'verificacion en canales digitales':
            'El operador debe verificar la identidad del cliente mediante dos factores '
            'independientes: un dato conocido y un dato posesivo.',
        'conciliacion de caja':
            'La conciliación diaria compara el efectivo físico contra el saldo teórico '
            'del sistema de caja de la sucursal.',
        'previsiones':
            'Los deudores se clasifican en las categorías previstas por la normativa y '
            'esa clasificación determina la previsión a constituir.',
    }
    vp = emb.vectorizar(pregunta)
    print(f'pregunta: {pregunta}\n')
    for nombre, texto in sorted(candidatos.items(),
                                key=lambda kv: -similitud(vp, emb.vectorizar(kv[1]))):
        print(f'  {similitud(vp, emb.vectorizar(texto)):+.4f}  {nombre}')

    # Reproducibilidad: es la propiedad que justifica usar blake2b.
    a = EmbedderDeterministico().vectorizar('prevención de lavado de activos')
    b = EmbedderDeterministico().vectorizar('prevencion de lavado de activos')
    print(f'\ncon acentos vs sin acentos: {similitud(a, b):.6f} (debe ser 1.000000)')

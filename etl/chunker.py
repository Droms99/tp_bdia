"""Fragmentacion de documentos en unidades de recuperacion.

El fragmento (`core.chunk`) es lo que se busca y lo que entra al contexto del
modelo de lenguaje. De como se corte depende que la recuperacion funcione: un
fragmento que empieza a mitad de una oracion recupera mal, y uno que abarca tres
secciones distintas diluye su propio vector.

Criterios, en orden de prioridad:

1. **No partir una seccion.** Los extractores dejan los encabezados marcados
   con `#` justamente para esto. Una seccion solo se parte si por si sola supera
   el maximo. A la inversa si se permite: varias secciones cortas consecutivas
   comparten fragmento, porque un fragmento de treinta tokens no tiene contexto
   suficiente para responder nada. Cada fragmento registra en `metadatos` que
   secciones cubre, que es lo que permite citar "seccion 4 del procedimiento" y
   no el documento entero.
2. **No partir a mitad de parrafo.** La unidad minima que se agrega a un
   fragmento es el parrafo. Un parrafo mas largo que el maximo se parte por
   oracion, que es el ultimo recurso.
3. **Solapar.** Cada fragmento arrastra el final del anterior dentro de la misma
   seccion. Sin solapamiento, una respuesta que vive a caballo del corte no la
   recupera ningun fragmento.

Sobre el conteo de tokens: no se usa el tokenizador de ningun modelo concreto.
El modelo de embeddings es intercambiable por diseño (`core.modelo_embedding`),
asi que atar la fragmentacion al tokenizador de uno de ellos acoplaria la
ingesta a una decision que el modelo de datos deja explicitamente abierta. Se
cuenta con una aproximacion documentada y estable, y el valor se guarda en
`chunk.tokens` como lo que es: una estimacion para dimensionar el contexto.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

# Aproximacion para español: los tokenizadores de subpalabra parten en promedio
# una palabra castellana en algo mas de un token, y cada signo de puntuacion
# suele ser uno.
TOKENS_POR_PALABRA = 1.3

OBJETIVO = 220      # tamanio buscado, en tokens
MAXIMO = 330        # nunca se supera salvo que un solo parrafo ya lo exceda
MINIMO = 40         # por debajo de esto el fragmento se funde con el anterior
SOLAPAMIENTO = 40   # cola del fragmento anterior que se arrastra


def contar_tokens(texto: str) -> int:
    palabras = len(re.findall(r'\w+', texto))
    signos = len(re.findall(r'[^\w\s]', texto))
    return max(1, round(palabras * TOKENS_POR_PALABRA) + signos)


@dataclass
class Fragmento:
    orden: int
    texto: str
    tokens: int
    metadatos: dict = field(default_factory=dict)


# =============================================================================
# Estructura del documento
# =============================================================================

RE_TITULO = re.compile(r'^(#{1,4})\s+(.*)$')


def secciones(texto: str) -> list[tuple[str, list[str]]]:
    """Parte el texto en (titulo_de_seccion, parrafos)."""
    actual, parrafos, out = '', [], []
    for bloque in re.split(r'\n\s*\n', texto):
        bloque = bloque.strip()
        if not bloque:
            continue
        m = RE_TITULO.match(bloque)
        if m:
            if parrafos:
                out.append((actual, parrafos))
                parrafos = []
            # El titulo de nivel 1 es el del documento, no una seccion: se
            # conserva como encabezado del primer tramo pero no rotula nada.
            actual = m.group(2).strip() if len(m.group(1)) > 1 else ''
        else:
            parrafos.append(bloque)
    if parrafos:
        out.append((actual, parrafos))
    return out


def oraciones(parrafo: str) -> list[str]:
    partes = re.split(r'(?<=[.:;!?])\s+(?=[A-ZÁÉÍÓÚÑ¿¡])', parrafo)
    return [p.strip() for p in partes if p.strip()]


def cola(texto: str, tokens: int) -> str:
    """Ultimas oraciones de un fragmento, hasta `tokens`. Es el solapamiento."""
    acumulado, salida = 0, []
    for o in reversed(oraciones(texto)):
        t = contar_tokens(o)
        if acumulado + t > tokens and salida:
            break
        salida.insert(0, o)
        acumulado += t
    return ' '.join(salida)


# =============================================================================
# Fragmentacion
# =============================================================================

def fragmentar(texto: str, objetivo: int = OBJETIVO, maximo: int = MAXIMO,
               solapamiento: int = SOLAPAMIENTO) -> list[Fragmento]:
    # Unidades atomicas: (seccion, parrafo). Un parrafo mas largo que el maximo
    # se parte por oracion; es el unico caso en que se corta por debajo del
    # parrafo.
    unidades: list[tuple[str, str]] = []
    for titulo, parrafos in secciones(texto):
        for p in parrafos:
            if contar_tokens(p) <= maximo:
                unidades.append((titulo, p))
                continue
            buf, n = [], 0
            for o in oraciones(p):
                t = contar_tokens(o)
                if buf and n + t > objetivo:
                    unidades.append((titulo, ' '.join(buf))); buf, n = [], 0
                buf.append(o); n += t
            if buf:
                unidades.append((titulo, ' '.join(buf)))

    frags: list[Fragmento] = []
    buf: list[str] = []
    cubiertas: list[str] = []
    n = 0
    arrastre = ''          # cola del fragmento anterior, pendiente de aplicar
    seccion_arrastre = ''  # solo se aplica si la seccion siguiente es la misma

    def cerrar():
        nonlocal buf, cubiertas, n, arrastre, seccion_arrastre
        if not buf:
            return
        cuerpo = '\n\n'.join(buf)
        secs = [s for s in dict.fromkeys(cubiertas) if s]
        frags.append(Fragmento(
            orden=len(frags), texto=cuerpo, tokens=contar_tokens(cuerpo),
            metadatos={'seccion': secs[0] if secs else '', 'secciones': secs}))
        # El fragmento siguiente arranca con la cola de este, pero solo si sigue
        # en la misma seccion: el solapamiento no cruza titulos.
        arrastre = cola(cuerpo, solapamiento) if solapamiento else ''
        seccion_arrastre = cubiertas[-1] if cubiertas else ''
        buf, cubiertas, n = [], [], 0

    for seccion, unidad in unidades:
        t = contar_tokens(unidad)
        if buf and n + t > maximo:
            cerrar()
        if not buf and arrastre and seccion == seccion_arrastre:
            buf.append(arrastre); n += contar_tokens(arrastre)
        buf.append(unidad); cubiertas.append(seccion); n += t
        if n >= objetivo:
            cerrar()

    # Resto final: si es minimo, se funde con el fragmento anterior en vez de
    # generar un fragmento sin sustancia propia.
    resto = '\n\n'.join(buf).strip()
    if resto:
        if contar_tokens(resto) < MINIMO and frags:
            prev = frags[-1]
            prev.texto += '\n\n' + resto
            prev.tokens = contar_tokens(prev.texto)
            for s_ in dict.fromkeys(cubiertas):
                if s_ and s_ not in prev.metadatos['secciones']:
                    prev.metadatos['secciones'].append(s_)
        else:
            secs = [s for s in dict.fromkeys(cubiertas) if s]
            frags.append(Fragmento(orden=len(frags), texto=resto,
                                   tokens=contar_tokens(resto),
                                   metadatos={'seccion': secs[0] if secs else '',
                                              'secciones': secs}))

    # RD9: los ordenes de los fragmentos de una version son consecutivos desde 0.
    for i, f in enumerate(frags):
        f.orden = i
        f.metadatos['total_fragmentos'] = len(frags)
    return frags


def fragmentar_documento(doc, **kw) -> list[Fragmento]:
    """Fragmenta un DocumentoFuente y anota la procedencia en cada fragmento."""
    frags = fragmentar(doc.texto, **kw)
    for f in frags:
        f.metadatos.update({
            'documento': doc.codigo,
            'version': doc.version,
            'formato_origen': doc.formato_origen,
        })
    return frags


if __name__ == '__main__':
    import sys
    from etl.extractores import leer_corpus
    docs = leer_corpus(sys.argv[1] if len(sys.argv) > 1 else 'data/corpus')
    total, tam = 0, []
    for d in docs:
        fs = fragmentar_documento(d)
        total += len(fs); tam += [f.tokens for f in fs]
        print(f'{d.archivo:26} {len(fs):>3} frag  '
              f'min {min(f.tokens for f in fs):>3}  max {max(f.tokens for f in fs):>3}')
    print(f'\ntotal {total} fragmentos | promedio {sum(tam)//len(tam)} tokens | '
          f'min {min(tam)} | max {max(tam)}')

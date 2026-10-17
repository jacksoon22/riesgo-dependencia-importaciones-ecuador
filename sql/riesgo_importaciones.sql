-- ============================================================================
-- PROYECTO 1 — Riesgo de dependencia de las importaciones del Ecuador
-- ----------------------------------------------------------------------------
-- Pregunta de negocio: ¿Dónde es más vulnerable el suministro de importaciones?
-- Fuente: SENAE — Declaraciones aduaneras de importación (régimen general), ene-jun 2024.
--         datosabiertos.gob.ec | Licencia: Creative Commons Attribution [Open Data]
--         650.426 filas
-- Stack: BigQuery (Standard SQL)
-- Autor: [tu nombre]
-- Última actualización: 2026-10-14
-- ----------------------------------------------------------------------------
-- Salida: una fila por producto (capítulo arancelario) con:
--   share_top5, hhi, top1_pais, top1_share, valor_total y nivel de riesgo.
-- ============================================================================

WITH base AS (
  -- 1) Agrega el valor FOB por producto (categoría) y país de origen.
  --    El WHERE es blindaje: el dataset está limpio hoy, pero evita que un
  --    recargo con nulos/valores <= 0 rompa el KPI.
  SELECT
    categoria   AS producto,
    PAIS_ORIGEN AS pais,
    SUM(FOB)    AS valor
  FROM `ec.v_importaciones`
  WHERE FOB > 0 AND PAIS_ORIGEN IS NOT NULL
  GROUP BY producto, pais
),

shares AS (
  -- 2) Peso (share) de cada país dentro de su producto.
  --    SUM() OVER (PARTITION BY producto) deja el total del producto repetido
  --    en cada fila SIN colapsarlas (a diferencia de GROUP BY).
  SELECT
    producto,
    pais,
    valor,
    SAFE_DIVIDE(valor, SUM(valor) OVER (PARTITION BY producto)) AS share
  FROM base
),

detalle AS (
  -- 3) Añade:
  --    - share2: el share al cuadrado (para el HHI)
  --    - rn: el ranking del país dentro de su producto (1 = el mayor)
  SELECT
    producto,
    pais,
    valor,
    share,
    share * share                                               AS share2,
    ROW_NUMBER() OVER (PARTITION BY producto ORDER BY valor DESC) AS rn
  FROM shares
),

resumen AS (
  -- 4) Colapsa a UNA fila por producto.
  --    Agregación condicional:
  --      SUM(IF(cond, valor, 0))    -> suma solo las filas que cumplen
  --      MAX(IF(cond, valor, NULL)) -> trae el valor de UNA sola fila
  SELECT
    producto,
    SUM(IF(rn <= 5, share, 0))    AS share_top5,
    SUM(share2)                   AS hhi,
    MAX(IF(rn = 1, pais, NULL))   AS top1_pais,
    MAX(IF(rn = 1, share, NULL))  AS top1_share,
    SUM(valor)                    AS valor_total
  FROM detalle
  GROUP BY producto
)

-- 5) Matriz de riesgo 2x2.
--    Eje concentración: hhi >= 0.25  (umbral estándar HHI)
--    Eje materialidad:  valor_total >= 1.000.000.000 USD (supuesto declarado)
SELECT
  *,
  CASE
    WHEN hhi >= 0.25 AND valor_total >= 1000000000 THEN 'CRITICO'
    WHEN hhi >= 0.25                               THEN 'Concentrado'
    WHEN valor_total >= 1000000000                 THEN 'Grande'
    ELSE                                                'OK'
  END AS riesgo
FROM resumen
ORDER BY hhi DESC;


-- ============================================================================
-- CONSULTA 2 — IMPACTO: ¿qué % del valor importado está en riesgo concentrado?
-- ----------------------------------------------------------------------------
-- Pregunta de negocio: de cada US$100 que el Ecuador importa, ¿cuántos están
-- en productos cuya oferta depende de un solo país proveedor?
-- Salida: 1 fila (no 97).
-- Resultado (ene–jun 2024): total US$ 15.154,99 M · riesgo US$ 4.391,28 M · 28,98%
-- Nota: repite la cadena de CTEs completa; BigQuery no reutiliza una consulta
--       anterior sin crear una vista o tabla.
-- ============================================================================

WITH base AS (
  SELECT
    categoria   AS producto,
    PAIS_ORIGEN AS pais,
    SUM(FOB)    AS valor
  FROM `ec.v_importaciones`
  WHERE FOB > 0 AND PAIS_ORIGEN IS NOT NULL
  GROUP BY producto, pais
),

shares AS (
  SELECT
    producto,
    pais,
    valor,
    SAFE_DIVIDE(valor, SUM(valor) OVER (PARTITION BY producto)) AS share
  FROM base
),

detalle AS (
  SELECT
    producto,
    pais,
    valor,
    share,
    share * share                                                 AS share2,
    ROW_NUMBER() OVER (PARTITION BY producto ORDER BY valor DESC) AS rn
  FROM shares
),

resumen AS (
  SELECT
    producto,
    SUM(IF(rn <= 5, share, 0))   AS share_top5,
    SUM(share2)                  AS hhi,
    MAX(IF(rn = 1, pais, NULL))  AS top1_pais,
    MAX(IF(rn = 1, share, NULL)) AS top1_share,
    SUM(valor)                   AS valor_total
  FROM detalle
  GROUP BY producto
),

-- Etiquetas PLANAS (sin emoji ni tilde): se usan para comparar en la lógica.
-- Los emojis van solo en la capa de presentación (dashboard / README).
final AS (
  SELECT
    *,
    CASE
      WHEN hhi >= 0.25 AND valor_total >= 1000000000 THEN 'CRITICO'
      WHEN hhi >= 0.25                               THEN 'Concentrado'
      WHEN valor_total >= 1000000000                 THEN 'Grande'
      ELSE                                                'OK'
    END AS riesgo
  FROM resumen
)

SELECT
  -- Volumen (en millones de USD, como se lee en LATAM)
  ROUND(SUM(valor_total) / 1e6, 2)                            AS total_millones_usd,
  ROUND(SUM(IF(riesgo = 'CRITICO', valor_total, 0)) / 1e6, 2) AS riesgo_millones_usd,

  -- Peso en dinero
  ROUND(SAFE_DIVIDE(
      SUM(IF(riesgo = 'CRITICO', valor_total, 0)),
      SUM(valor_total)
    ) * 100, 2)                                               AS pct_riesgo,

  -- Peso en cantidad de categorías
  COUNT(*)                                                    AS categorias,
  COUNTIF(riesgo = 'CRITICO')                                 AS categorias_criticas,
  ROUND(SAFE_DIVIDE(COUNTIF(riesgo = 'CRITICO'), COUNT(*)) * 100, 2) AS pct_categorias,

  -- Sobre-representación: cuántas veces pesa más en dinero que en cantidad
  -- (28,98% / 2,06% ≈ 14x  -> el hallazgo "senior" del proyecto)
  ROUND(SAFE_DIVIDE(
      SAFE_DIVIDE(SUM(IF(riesgo = 'CRITICO', valor_total, 0)), SUM(valor_total)),
      SAFE_DIVIDE(COUNTIF(riesgo = 'CRITICO'), COUNT(*))
    ), 1)                                                     AS sobrerrepresentacion_x
FROM final;


-- ============================================================================
-- CONSULTA 3 — Detalle por país de los 2 productos críticos (insumo Página 3)
-- ----------------------------------------------------------------------------
-- Pregunta de negocio: dentro de los 2 productos críticos, ¿de dónde viene
-- exactamente el suministro y cuánto pesa cada proveedor?
-- Salida: una fila por producto × país, con su share dentro del producto.
-- No usa nombres hardcodeados: filtra por la misma lógica de la matriz,
-- así el resultado se mantiene consistente si cambian los datos.
-- ============================================================================

WITH base AS (
  SELECT
    categoria   AS producto,
    PAIS_ORIGEN AS pais,
    SUM(FOB)    AS valor
  FROM `ec.v_importaciones`
  WHERE FOB > 0 AND PAIS_ORIGEN IS NOT NULL
  GROUP BY producto, pais
),

shares AS (
  SELECT
    producto,
    pais,
    valor,
    SAFE_DIVIDE(valor, SUM(valor) OVER (PARTITION BY producto)) AS share
  FROM base
),

detalle AS (
  SELECT
    producto,
    pais,
    valor,
    share,
    share * share                                                 AS share2,
    ROW_NUMBER() OVER (PARTITION BY producto ORDER BY valor DESC) AS rn
  FROM shares
),

resumen AS (
  SELECT
    producto,
    SUM(IF(rn <= 5, share, 0))   AS share_top5,
    SUM(share2)                  AS hhi,
    MAX(IF(rn = 1, pais, NULL))  AS top1_pais,
    MAX(IF(rn = 1, share, NULL)) AS top1_share,
    SUM(valor)                   AS valor_total
  FROM detalle
  GROUP BY producto
),

final AS (
  SELECT
    *,
    CASE
      WHEN hhi >= 0.25 AND valor_total >= 1000000000 THEN 'CRITICO'
      WHEN hhi >= 0.25                               THEN 'Concentrado'
      WHEN valor_total >= 1000000000                 THEN 'Grande'
      ELSE                                                'OK'
    END AS riesgo
  FROM resumen
),

criticos AS (
  SELECT producto
  FROM final
  WHERE riesgo = 'CRITICO'
),

detalle_criticos AS (
  SELECT
    b.producto,
    b.pais,
    b.valor,
    ROW_NUMBER() OVER (PARTITION BY b.producto ORDER BY b.valor DESC) AS ranking_pais,
    SUM(b.valor) OVER (PARTITION BY b.producto)                       AS valor_producto
  FROM base b
  JOIN criticos c USING (producto)
)

SELECT
  producto,
  ranking_pais,
  pais,
  ROUND(valor / 1e6, 2)                                  AS valor_millones_usd,
  ROUND(SAFE_DIVIDE(valor, valor_producto) * 100, 2)     AS share_pct
FROM detalle_criticos
ORDER BY producto, ranking_pais;


-- ============================================================================
-- CONSULTA 4 — Evolución mensual de la dependencia (insumo de gráfico de línea)
-- ----------------------------------------------------------------------------
-- Pregunta de negocio: ¿la dependencia del proveedor dominante sube o baja?
--   Si sube  -> el riesgo se agrava  -> la recomendación es urgente.
--   Si baja  -> el riesgo se corrige -> cambia la prioridad de la acción.
-- Salida: producto × mes (2 productos críticos × 6 meses).
-- IMPORTANTE: el país dominante se fija con el top1 del PERIODO COMPLETO, no el
--   de cada mes; si no, la serie saltaría de país y no habría tendencia legible.
-- OJO: son 6 meses -> esto es EVOLUCIÓN, no crecimiento (no hay año anterior).
-- ============================================================================

WITH base AS (
  SELECT
    categoria   AS producto,
    PAIS_ORIGEN AS pais,
    DATE_TRUNC(FEC_INGRESO, MONTH) AS mes,
    SUM(FOB)    AS valor
  FROM `ec.v_importaciones`
  WHERE FOB > 0 AND PAIS_ORIGEN IS NOT NULL
  GROUP BY producto, pais, mes
),

shares AS (
  SELECT
    producto, pais, mes, valor,
    SAFE_DIVIDE(valor, SUM(valor) OVER (PARTITION BY producto, mes)) AS share
  FROM base
),

detalle AS (
  SELECT
    *,
    share * share                                             AS share2,
    ROW_NUMBER() OVER (PARTITION BY producto, mes ORDER BY valor DESC) AS rn
  FROM shares
),

resumen AS (
  SELECT
    producto,
    SUM(IF(rn <= 5, share, 0))   AS share_top5,
    SUM(share2)                  AS hhi,
    MAX(IF(rn = 1, pais, NULL))  AS top1_pais,
    MAX(IF(rn = 1, share, NULL)) AS top1_share,
    SUM(valor)                   AS valor_total
  FROM detalle
  GROUP BY producto
),

final AS (
  SELECT
    *,
    CASE
      WHEN hhi >= 0.25 AND valor_total >= 1000000000 THEN 'CRITICO'
      WHEN hhi >= 0.25                               THEN 'Concentrado'
      WHEN valor_total >= 1000000000                 THEN 'Grande'
      ELSE                                                'OK'
    END AS riesgo
  FROM resumen
),

criticos AS (
  SELECT producto, top1_pais
  FROM final
  WHERE riesgo = 'CRITICO'
),

mensual AS (
  SELECT
    b.producto,
    b.mes,
    SUM(b.valor)                              AS valor_mes,
    SUM(IF(b.pais = c.top1_pais, b.valor, 0)) AS valor_top1
  FROM base b
  JOIN criticos c USING (producto)
  GROUP BY b.producto, b.mes, c.top1_pais
)

SELECT
  producto,
  mes,
  ROUND(valor_mes / 1e6, 2)                          AS valor_mes_millones_usd,
  ROUND(SAFE_DIVIDE(valor_top1, valor_mes) * 100, 2) AS share_top1_pct
FROM mensual
ORDER BY producto, mes;


-- ============================================================================
-- CONSULTA 5 — Bloques para la barra de exposición (insumo visual, Página 1)
-- ----------------------------------------------------------------------------
-- Devuelve 3 filas: los 2 críticos por separado + el resto agregado.
-- Se usa en Looker como: dimensión constante "Total" + desglose = bloque +
-- métrica = valor_millones_usd + barras APILADAS. Así sale UNA barra con 3
-- segmentos (sin la dimensión constante saldrían 3 barras separadas).
-- La columna `orden` existe para forzar el orden izquierda->derecha.
-- ============================================================================

WITH base AS (
  SELECT
    categoria   AS producto,
    PAIS_ORIGEN AS pais,
    SUM(FOB)    AS valor
  FROM `ec.v_importaciones`
  WHERE FOB > 0 AND PAIS_ORIGEN IS NOT NULL
  GROUP BY producto, pais
),

shares AS (
  SELECT
    producto, pais, valor,
    SAFE_DIVIDE(valor, SUM(valor) OVER (PARTITION BY producto)) AS share
  FROM base
),

detalle AS (
  SELECT
    *,
    share * share                                             AS share2,
    ROW_NUMBER() OVER (PARTITION BY producto ORDER BY valor DESC) AS rn
  FROM shares
),

resumen AS (
  SELECT
    producto,
    SUM(IF(rn <= 5, share, 0))   AS share_top5,
    SUM(share2)                  AS hhi,
    MAX(IF(rn = 1, pais, NULL))  AS top1_pais,
    MAX(IF(rn = 1, share, NULL)) AS top1_share,
    SUM(valor)                   AS valor_total
  FROM detalle
  GROUP BY producto
),

final AS (
  SELECT
    *,
    CASE
      WHEN hhi >= 0.25 AND valor_total >= 1000000000 THEN 'CRITICO'
      WHEN hhi >= 0.25                               THEN 'Concentrado'
      WHEN valor_total >= 1000000000                 THEN 'Grande'
      ELSE                                                'OK'
    END AS riesgo
  FROM resumen
),

bloques AS (
  SELECT
    valor_total,
    CASE
      WHEN riesgo = 'CRITICO' THEN producto
      ELSE 'Resto (95 categorías)'
    END AS bloque,
    CASE
      WHEN riesgo = 'CRITICO'
        THEN ROW_NUMBER() OVER (PARTITION BY riesgo ORDER BY valor_total DESC)
      ELSE 99
    END AS orden
  FROM final
)

SELECT
  bloque,
  orden,
  ROUND(SUM(valor_total) / 1e6, 2) AS valor_millones_usd
FROM bloques
GROUP BY bloque, orden
ORDER BY orden;


-- ============================================================================
-- CONSULTA 6 — Composición por país: proveedor dominante vs resto (Página 2)
-- ----------------------------------------------------------------------------
-- Pregunta: dentro de cada producto crítico, ¿cuánto depende del país dominante?
-- Devuelve 4 filas (2 productos × 2 bloques).
-- En Looker se usa con la MÉTRICA = share_pct (no el valor absoluto): así cada
-- barra suma 100 y el eje 0-100% sale solo, sin necesitar "100% apiladas".
-- ============================================================================

WITH base AS (
  SELECT
    categoria   AS producto,
    PAIS_ORIGEN AS pais,
    SUM(FOB)    AS valor
  FROM `ec.v_importaciones`
  WHERE FOB > 0 AND PAIS_ORIGEN IS NOT NULL
  GROUP BY producto, pais
),

shares AS (
  SELECT
    producto, pais, valor,
    SAFE_DIVIDE(valor, SUM(valor) OVER (PARTITION BY producto)) AS share
  FROM base
),

detalle AS (
  SELECT
    *,
    share * share                                             AS share2,
    ROW_NUMBER() OVER (PARTITION BY producto ORDER BY valor DESC) AS rn
  FROM shares
),

resumen AS (
  SELECT
    producto,
    SUM(IF(rn <= 5, share, 0))   AS share_top5,
    SUM(share2)                  AS hhi,
    MAX(IF(rn = 1, pais, NULL))  AS top1_pais,
    MAX(IF(rn = 1, share, NULL)) AS top1_share,
    SUM(valor)                   AS valor_total
  FROM detalle
  GROUP BY producto
),

final AS (
  SELECT
    *,
    CASE
      WHEN hhi >= 0.25 AND valor_total >= 1000000000 THEN 'CRITICO'
      WHEN hhi >= 0.25                               THEN 'Concentrado'
      WHEN valor_total >= 1000000000                 THEN 'Grande'
      ELSE                                                'OK'
    END AS riesgo
  FROM resumen
),

criticos AS (
  SELECT producto, top1_pais, valor_total
  FROM final
  WHERE riesgo = 'CRITICO'
),

pais_bloque AS (
  SELECT
    b.producto,
    b.valor,
    CASE WHEN b.pais = c.top1_pais THEN 'Proveedor dominante' ELSE 'Resto' END AS bloque
  FROM base b
  JOIN criticos c USING (producto)
)

SELECT
  producto,
  bloque,
  ROUND(SUM(valor) / 1e6, 2)                                                       AS valor_millones_usd,
  ROUND(SAFE_DIVIDE(SUM(valor), SUM(SUM(valor)) OVER (PARTITION BY producto)) * 100, 2) AS share_pct
FROM pais_bloque
GROUP BY producto, bloque;

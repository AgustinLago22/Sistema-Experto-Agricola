-- ============================================================================
-- Sesión 25 — Fase 17.5: sensibilidad de las decisiones de WF1 a sus umbrales.
-- SOLO LECTURA. No cambia nada. Son 3 consultas independientes.
--
-- Qué barre: una grilla sintética declarada, uniforme sobre el rango físico que
-- acepta `Validar Contrato`:
--   humedad 0–100, paso 0,1 · pH 0–14, paso 0,01 · N, P y K 0–2000, paso 0,1.
-- No usa lectura_sensores: esas lecturas se armaron a mano para probar ramas.
--
-- Regla que replica (Motor de Inferencia de WF1, comparaciones estrictas):
--   x < mínimo → BAJO · x > máximo → ALTO · si no → OK.
--   Humedad BAJO = sequía, y riego si hay bomba y no hay freno. ALTO = exceso, solo avisa.
--   pH fuera de rango = estrés químico, solo avisa.
--   N, P y K: el rango es ideal × (1 ∓ 0,30). La tolerancia está fija en el código.
-- Se mueve un umbral por vez (OAT). Las otras mediciones quedan dentro de su rango,
-- así que la alerta (un OR de todo) cambia justo donde cambia esa medición.
--
-- Cómo leer "cambia": tramo de la grilla donde la decisión es otra. Se da en
-- unidades de la medición, en % de la grilla y en % del rango aceptado de la etapa.
-- Puede diferir en un paso de grilla (0,1 o 0,01) cuando el umbral cae justo en un punto.
-- Si el umbral movido pasa el otro extremo, "alto" pasa a "bajo": la alerta sigue,
-- cambia el tipo.
--
-- Comprobado el 24/11/2026 (sesión 25) contra el código real del Motor (WF1.json),
-- punto por punto sobre la misma grilla: 312 de 313 casos iguales. El otro difiere en
-- un punto (K de Cosecha con tolerancia 0,40): en JS 45 × 1,4 = 62,99999999999999, así
-- que el Motor marca 63 como alto.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Cada umbral, movido ±5, ±10 y ±20 %. Una fila por etapa, umbral y movimiento.
-- ----------------------------------------------------------------------------
with etapa as (
  select ee.orden, te.nombre_etapa as etapa,
         pe.humedad_min::numeric as h_min, pe.humedad_max::numeric as h_max,
         pe.ph_min::numeric as ph_min, pe.ph_max::numeric as ph_max,
         pe.ideal_n::numeric as n, pe.ideal_p::numeric as p, pe.ideal_k::numeric as k
  from public.parametro_etapa pe
  join public.etapas_especie ee on ee.id = pe.etapa_especie_id
  join public.tipo_etapa te on te.id = ee.etapa_id
  join public.especie_planta ep on ep.id = ee.especie_id
  where ep.nombre_comun = 'Tomate Cherry'
),
umbral as (
  -- (medición, umbral, valor, mín y máx del rango, qué se mueve)
  select e.orden, e.etapa, u.*
  from etapa e
  cross join lateral (values
    ('humedad', 'humedad_min', e.h_min,  e.h_min,      e.h_max,      'min'),
    ('humedad', 'humedad_max', e.h_max,  e.h_min,      e.h_max,      'max'),
    ('ph',      'ph_min',      e.ph_min, e.ph_min,     e.ph_max,     'min'),
    ('ph',      'ph_max',      e.ph_max, e.ph_min,     e.ph_max,     'max'),
    ('n',       'ideal_n',     e.n,      e.n * 0.70,   e.n * 1.30,   'ideal'),
    ('p',       'ideal_p',     e.p,      e.p * 0.70,   e.p * 1.30,   'ideal'),
    ('k',       'ideal_k',     e.k,      e.k * 0.70,   e.k * 1.30,   'ideal')
  ) u(medicion, umbral, valor, lo, hi, mueve)
),
caso as (
  select u.*, d.pct,
         round(u.valor * (1 + d.pct / 100.0), 4) as nuevo,
         case u.mueve when 'min'   then round(u.valor * (1 + d.pct / 100.0), 4)
                      when 'ideal' then round(u.valor * (1 + d.pct / 100.0) * 0.70, 4)
                      else u.lo end as lo2,
         case u.mueve when 'max'   then round(u.valor * (1 + d.pct / 100.0), 4)
                      when 'ideal' then round(u.valor * (1 + d.pct / 100.0) * 1.30, 4)
                      else u.hi end as hi2
  from umbral u
  cross join (values (-20), (-10), (-5), (5), (10), (20)) d(pct)
),
grilla as (
  select 'humedad' as medicion, g / 10.0 as x, 0.1 as paso from generate_series(0, 1000) g
  union all
  select 'ph', g / 100.0, 0.01 from generate_series(0, 1400) g
  union all
  select m, g / 10.0, 0.1 from generate_series(0, 20000) g, unnest(array['n', 'p', 'k']) m
)
select c.etapa, c.umbral,
       case c.umbral when 'humedad_min' then 'sequía y riego'
                     when 'humedad_max' then 'exceso (aviso)'
                     else 'estrés químico (aviso)' end as decide,
       c.pct as mueve_pct, round(c.valor, 2) as valor, round(c.nuevo, 2) as nuevo,
       round(c.hi - c.lo, 2) as ancho_rango,
       round(count(*) filter (where
         (case when g.x < c.lo  then -1 when g.x > c.hi  then 1 else 0 end) <>
         (case when g.x < c.lo2 then -1 when g.x > c.hi2 then 1 else 0 end)) * min(g.paso), 2) as cambia_unidades,
       round(100.0 * count(*) filter (where
         (case when g.x < c.lo  then -1 when g.x > c.hi  then 1 else 0 end) <>
         (case when g.x < c.lo2 then -1 when g.x > c.hi2 then 1 else 0 end)) / count(*), 2) as cambia_pct_grilla,
       round(100.0 * count(*) filter (where
         (case when g.x < c.lo  then -1 when g.x > c.hi  then 1 else 0 end) <>
         (case when g.x < c.lo2 then -1 when g.x > c.hi2 then 1 else 0 end)) * min(g.paso) / (c.hi - c.lo), 1) as cambia_pct_rango
from caso c
join grilla g on g.medicion = c.medicion
group by c.orden, c.etapa, c.medicion, c.umbral, c.pct, c.valor, c.nuevo, c.lo, c.hi, c.lo2, c.hi2
order by c.medicion, c.umbral, c.orden, c.pct;


-- ----------------------------------------------------------------------------
-- 2. La tolerancia de N, P y K: 0,20 y 0,40 contra la 0,30 del código.
-- ----------------------------------------------------------------------------
with etapa as (
  select ee.orden, te.nombre_etapa as etapa,
         pe.ideal_n::numeric as n, pe.ideal_p::numeric as p, pe.ideal_k::numeric as k
  from public.parametro_etapa pe
  join public.etapas_especie ee on ee.id = pe.etapa_especie_id
  join public.tipo_etapa te on te.id = ee.etapa_id
  join public.especie_planta ep on ep.id = ee.especie_id
  where ep.nombre_comun = 'Tomate Cherry'
),
caso as (
  select e.orden, e.etapa, m.medicion, m.ideal, t.tol
  from etapa e
  cross join lateral (values ('n', e.n), ('p', e.p), ('k', e.k)) m(medicion, ideal)
  cross join (values (0.20), (0.40)) t(tol)
),
grilla as (
  select g / 10.0 as x from generate_series(0, 20000) g
)
select c.etapa, c.medicion, round(c.ideal, 2) as ideal, c.tol,
       round(c.ideal * 0.70, 2) || '–' || round(c.ideal * 1.30, 2) as rango_030,
       round(c.ideal * (1 - c.tol), 2) || '–' || round(c.ideal * (1 + c.tol), 2) as rango_nuevo,
       round(count(*) filter (where
         (g.x < c.ideal * 0.70 or g.x > c.ideal * 1.30) <>
         (g.x < c.ideal * (1 - c.tol) or g.x > c.ideal * (1 + c.tol))) * 0.1, 2) as cambia_unidades,
       round(100.0 * count(*) filter (where
         (g.x < c.ideal * 0.70 or g.x > c.ideal * 1.30) <>
         (g.x < c.ideal * (1 - c.tol) or g.x > c.ideal * (1 + c.tol))) * 0.1 / (c.ideal * 0.60), 1) as cambia_pct_rango
from caso c
cross join grilla g
group by c.orden, c.etapa, c.medicion, c.ideal, c.tol
order by c.medicion, c.orden, c.tol;


-- ----------------------------------------------------------------------------
-- 3. Etapa equivocada: la planta ya está en una etapa y la tabla aplica la anterior.
--    Es el error que deja el atraso en detectar el cambio de etapa.
-- ----------------------------------------------------------------------------
with etapa as (
  select ee.orden, te.nombre_etapa as etapa,
         pe.humedad_min::numeric as h_min, pe.humedad_max::numeric as h_max,
         pe.ph_min::numeric as ph_min, pe.ph_max::numeric as ph_max,
         pe.ideal_n::numeric as n, pe.ideal_p::numeric as p, pe.ideal_k::numeric as k
  from public.parametro_etapa pe
  join public.etapas_especie ee on ee.id = pe.etapa_especie_id
  join public.tipo_etapa te on te.id = ee.etapa_id
  join public.especie_planta ep on ep.id = ee.especie_id
  where ep.nombre_comun = 'Tomate Cherry'
),
rango as (
  select e.orden, e.etapa, r.*
  from etapa e
  cross join lateral (values
    ('humedad', e.h_min,     e.h_max),
    ('ph',      e.ph_min,    e.ph_max),
    ('n',       e.n * 0.70,  e.n * 1.30),
    ('p',       e.p * 0.70,  e.p * 1.30),
    ('k',       e.k * 0.70,  e.k * 1.30)
  ) r(medicion, lo, hi)
),
par as (
  -- real = la etapa en la que está la planta; aplicada = la anterior
  select r.etapa as real, a.etapa as aplicada, r.orden, r.medicion,
         r.lo, r.hi, a.lo as lo_a, a.hi as hi_a
  from rango r
  join rango a on a.medicion = r.medicion and a.orden = r.orden - 1
),
grilla as (
  select 'humedad' as medicion, g / 10.0 as x, 0.1 as paso from generate_series(0, 1000) g
  union all
  select 'ph', g / 100.0, 0.01 from generate_series(0, 1400) g
  union all
  select m, g / 10.0, 0.1 from generate_series(0, 20000) g, unnest(array['n', 'p', 'k']) m
)
select p.real, p.aplicada, p.medicion,
       round(p.lo, 2) || '–' || round(p.hi, 2) as rango_real,
       round(p.lo_a, 2) || '–' || round(p.hi_a, 2) as rango_aplicado,
       round(count(*) filter (where
         (case when g.x < p.lo   then -1 when g.x > p.hi   then 1 else 0 end) <>
         (case when g.x < p.lo_a then -1 when g.x > p.hi_a then 1 else 0 end)) * min(g.paso), 2) as cambia_unidades,
       round(100.0 * count(*) filter (where
         (case when g.x < p.lo   then -1 when g.x > p.hi   then 1 else 0 end) <>
         (case when g.x < p.lo_a then -1 when g.x > p.hi_a then 1 else 0 end)) * min(g.paso) / (p.hi - p.lo), 1) as cambia_pct_rango,
       -- solo humedad: tramo donde cambia la decisión de regar
       case when p.medicion = 'humedad'
            then round(count(*) filter (where (g.x < p.lo) <> (g.x < p.lo_a)) * min(g.paso), 2)
       end as cambia_riego_unidades
from par p
join grilla g on g.medicion = p.medicion
group by p.orden, p.real, p.aplicada, p.medicion, p.lo, p.hi, p.lo_a, p.hi_a
order by p.orden, p.medicion;

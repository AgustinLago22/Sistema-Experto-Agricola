-- ============================================================================
-- Sesión 14 · criterio_visual en el catálogo + baja de la Albahaca
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 29/09/2026 contra el estado verificado ese día.
-- ✅ BLOQUE 1 APLICADO por Agustín (SQL Editor) y BLOQUE 2 verificado por MCP
--    el 01/10/2026: 6 etapas del tomate con criterio, especie 4 y sus 3 etapas
--    y 1 umbral borrados, columna NOT NULL + CHECK, 0 etapas sin umbrales.
--
-- QUÉ RESUELVE
--   16.42  El prompt de WF3 tenía escrita a mano la lista de transiciones y
--          solo nombraba 3 de las 5 del tomate. Al cargar Fructificación el
--          23/09 el catálogo se movió y el prompt no. El criterio visual de
--          cada etapa pasa a vivir en el catálogo (`etapas_especie`), que es
--          quien la define: la definición vive en el productor.
--   Alcance Se da de baja la Albahaca (especie 4). El modelo del sistema
--          supone un ciclo LINEAL (etapas en orden hasta una cosecha final);
--          la albahaca es de cosecha continua y no encaja. Queda como límite
--          de alcance declarado, no como especie a medio cargar.
--
-- EFECTOS SOBRE OTROS HALLAZGOS
--   16.38  Se destraba: la especie 4 era la única con etapas sin umbrales.
--   16.37  Su guarda queda sin forma de ejercerse con datos reales. Si se
--          aplica 16.38, la base hace imposible el hueco por construcción.
--
-- DISEÑO DE LA COLUMNA
--   - Va en `etapas_especie` y no en `tipo_etapa`: "Floración" no se ve igual
--     en un tomate que en un pimiento. El criterio es por especie.
--   - Describe la ENTRADA a la etapa (lo que WF3 necesita decidir), algo
--     visible en una foto, y lo que puede coexistir (el tomate cherry es de
--     crecimiento indeterminado: flores y frutos conviven).
--   - Redactado siguiendo los estadios principales de la escala BBCH para
--     solanáceas (Feller et al., 1995; Meier, 2001). Citar en Fase 17.
--   - NOT NULL + CHECK de no vacío: ninguna etapa futura puede cargarse sin
--     criterio. Lo hace cumplir la base, no una convención.
--
-- DEPENDENCIAS VERIFICADAS (29/09) ANTES DE BORRAR LA ESPECIE 4
--   cultivo: 0 · maceta_recomendada_especie: 0 · seguimiento_fenologico: 0
--   evaluacion_fenologica: 0 (ni origen ni destino en 11, 12, 13)
--   Cascada: etapas_especie 11, 12, 13 → parametro_etapa id 5.
--
-- ORDEN: BLOQUE 0 (foto previa) → BLOQUE 1 (cambio) → BLOQUE 2 (verificar).
-- El orden DENTRO del bloque 1 importa: si la albahaca siguiera cargada, el
-- NOT NULL fallaría con sus 3 etapas sin criterio.
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo, registrado el 29/09 (para poder revertir)
-- ============================================================================
-- especie_planta  id 4 · 'Albahaca' · 'Ocimum basilicum'
-- etapas_especie  id 12 · esp 4 · etapa 1 (Germinación) · orden 1 ·  7 días
--                 id 11 · esp 4 · etapa 2 (Plántula)    · orden 2 · 12 días
--                 id 13 · esp 4 · etapa 3 (Vegetativo)  · orden 3 · 45 días
-- parametro_etapa id 5 · etapa_especie 13 · hum 60-80 · pH 6.0-7.0 · N40 P20 K20
--
-- Reverso, si hiciera falta (con los mismos ids):
--   insert into especie_planta (id, nombre_comun, nombre_cientifico)
--     values (4, 'Albahaca', 'Ocimum basilicum');
--   insert into etapas_especie (id, especie_id, etapa_id, orden, duracion_estimada_dias, criterio_visual)
--     values (12,4,1,1,7,'<criterio>'), (11,4,2,2,12,'<criterio>'), (13,4,3,3,45,'<criterio>');
--   insert into parametro_etapa (id, etapa_especie_id, humedad_min, humedad_max, ph_min, ph_max, ideal_n, ideal_p, ideal_k)
--     values (5,13,60,80,6.0,7.0,40,20,20);


-- ============================================================================
-- BLOQUE 1 — El cambio, en una sola transacción
-- ============================================================================
begin;

-- 1. Fuera de alcance: la albahaca no sigue un ciclo lineal.
delete from especie_planta where id = 4;

-- 2. El criterio visual vive en el catálogo, no en el prompt (16.42).
alter table etapas_especie add column criterio_visual text;

update etapas_especie set criterio_visual = case etapa_id
  when 1 then 'Emergencia de la plántula sobre el sustrato: hipocótilo visible, cotiledones todavía cerrados o recién abriéndose.'
  when 2 then 'Cotiledones abiertos y expandidos; ninguna hoja verdadera desarrollada, o la primera recién emergiendo.'
  when 3 then 'Al menos 4 hojas verdaderas (compuestas, dentadas) desarrolladas; crecimiento de tallo y follaje, sin botones florales visibles.'
  when 4 then 'Racimos florales visibles con botones o flores amarillas abiertas; todavía sin frutos cuajados.'
  when 6 then 'Frutos cuajados visibles (tomates verdes de cualquier tamaño) en al menos un racimo. Puede haber flores al mismo tiempo: el crecimiento es indeterminado.'
  when 5 then 'Frutos con cambio de color (rojo, anaranjado o rosado) en al menos un racimo. Pueden coexistir frutos verdes y flores.'
end
where especie_id = 3;

-- 3. Que ninguna etapa futura pueda cargarse sin criterio.
alter table etapas_especie
  alter column criterio_visual set not null,
  add constraint etapas_especie_criterio_visual_no_vacio
    check (length(trim(criterio_visual)) > 0);

commit;


-- ============================================================================
-- BLOQUE 2 — Verificación contra el estado persistido
-- ============================================================================
select ee.orden, te.nombre_etapa, ee.duracion_estimada_dias, ee.criterio_visual
from etapas_especie ee
join tipo_etapa te on te.id = ee.etapa_id
order by ee.especie_id, ee.orden;
-- Esperado: 6 filas, todas del tomate (especie 3), órdenes 1 a 6, ninguna
-- con criterio vacío.

select
  (select count(*) from especie_planta where id = 4)                   as albahaca,        -- 0
  (select count(*) from etapas_especie where especie_id = 4)           as etapas_esp4,     -- 0
  (select count(*) from parametro_etapa where etapa_especie_id in (11,12,13)) as umbrales_esp4, -- 0
  (select is_nullable from information_schema.columns
    where table_name = 'etapas_especie' and column_name = 'criterio_visual') as nullable,  -- NO
  (select count(*) from pg_constraint
    where conname = 'etapas_especie_criterio_visual_no_vacio')         as check_existe;    -- 1

-- Prueba de que la restricción muerde (debe FALLAR con violación de CHECK):
--   update etapas_especie set criterio_visual = '   ' where id = 6;

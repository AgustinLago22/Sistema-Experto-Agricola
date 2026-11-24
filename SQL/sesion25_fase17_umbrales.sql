-- ============================================================================
-- Sesión 25 · Fase 17 corta — unidades, procedencia y humedad de Floración
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 24/11/2026 contra el estado verificado ese día por MCP.
--
-- QUÉ HACE (plan, Fase 17: 17.1, 17.2 y 17.4)
--   1. COMMENT ON COLUMN en humedad_min/max e ideal_n/p/k: qué mide cada una.
--      Son la lectura del sensor, no % de capacidad de campo ni un análisis
--      de laboratorio. Las fuentes se usan por la dirección, no por el valor.
--   2. parametro_etapa.fuente y .criterio, cargadas para las 6 etapas del
--      tomate y obligatorias (NOT NULL y no vacías). Una fila sin fuente lo
--      dice ("sin fuente registrada"); lo que no se puede es dejarlo vacío.
--   3. Floración: humedad de 50–65 a 60–75. El Ky del tomate es máximo en
--      floración (1,1) y en Liu et al. (2019) la humedad baja en floración y
--      cuaje redujo el rendimiento. Ninguna fuente la pone más seca que
--      Vegetativo. El K no cambia (decisión en el plan, 17.1).
--
-- QUÉ NO CAMBIA
--   Ningún workflow ni vista. Las vistas listan sus columnas una por una y
--   nadie escribe en parametro_etapa. Hoy el cultivo está en Fructificación:
--   el cambio de Floración no toca nada que esté corriendo.
--
-- ORDEN
--   BLOQUE 0 (MCP) → BLOQUE 3 ANTES (tiene que FALLAR) → BLOQUE 1
--   → BLOQUE 3 DESPUÉS (tiene que dar TEST OK) → BLOQUE 2 (MCP).
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo (solo lectura).
-- Esperado: 6 filas; sin fuente ni criterio; Floración (id 4) en 50–65;
-- ninguna columna con comentario.
-- ============================================================================
select pe.id, pe.etapa_especie_id, te.nombre_etapa, pe.humedad_min, pe.humedad_max,
       pe.ph_min, pe.ph_max, pe.ideal_n, pe.ideal_p, pe.ideal_k
from public.parametro_etapa pe
join public.etapas_especie ee on ee.id = pe.etapa_especie_id
join public.tipo_etapa te on te.id = ee.etapa_id
order by ee.orden;

select a.attname, col_description(a.attrelid, a.attnum) as comentario
from pg_attribute a
where a.attrelid = 'public.parametro_etapa'::regclass and a.attnum > 0 and not a.attisdropped;


-- ============================================================================
-- BLOQUE 1 — El cambio. Se pega entero, una sola vez.
-- Si una fila no está como se espera, corta y no cambia nada.
-- ============================================================================
begin;

alter table public.parametro_etapa
  add column fuente text,
  add column criterio text;

do $$
declare
  n int;
  f record;
begin
  for f in
    select * from (values
      -- (id, etapa_especie_id, fuente, criterio)
      (2, 6,
       'Sin fuente registrada para los valores (carga inicial del proyecto). pH: UC IPM, Tomato: Selecting the Field (6,0 a 7,5).',
       'Carga inicial, sin derivación registrada. No se encontró una fuente que compare la humedad de germinación con la de otras etapas. NPK en el piso de la curva; K:N 1,0, como el 1:1 de Raudales (2023) antes de la primera flor. pH dentro del rango de UC IPM.'),
      (1, 7,
       'Sin fuente registrada para los valores (carga inicial del proyecto). pH: UC IPM, Tomato: Selecting the Field (6,0 a 7,5).',
       'Carga inicial, sin derivación registrada. Sin fuente que compare la humedad por etapa. El N sube hacia el pico de Vegetativo. K:N 0,75, por debajo del 1:1 de Raudales (2023): no coincide con esa fuente. pH dentro del rango de UC IPM.'),
      (3, 10,
       'Valores de la carga inicial, sin fuente registrada. Forma: Yara, Tomato Nutritional Summary; Liu et al. (2019), PLOS ONE 14(3): e0213643. pH: UC IPM, Tomato: Selecting the Field.',
       'Carga inicial. N en su máximo del ciclo: Yara ubica el pico de N justo antes de la floración. Humedad: en Liu et al. (2019), 60–70 % de capacidad de campo alcanzó en esta etapa (otra unidad: se toma la dirección, no el valor). K:N 0,6, por debajo del 1:1 de Raudales (2023). pH dentro del rango de UC IPM.'),
      (4, 9,
       'Humedad: FAO, Irrigation and Drainage Paper 33, Ky por etapa (FAO X5647E, Anexo II, tabla 12); Liu et al. (2019), PLOS ONE 14(3): e0213643. NPK: carga inicial; forma según Raudales (2023), e-GRO Edible Alert 8(9), y Yara, Tomato Nutritional Summary. pH: UC IPM, Tomato: Selecting the Field.',
       'Humedad subida de 50–65 a 60–75 en la sesión 25 (11/2026): el Ky del tomate es máximo en floración (1,1) y en Liu et al. (2019) la humedad baja en floración y cuaje redujo el rendimiento. Se toma la dirección, no el valor. NPK de la carga inicial: K:N sube a 2,0 con la floración, la misma dirección que Raudales (2023) (1,4:1), no el mismo cociente. P en su máximo (Yara: P temprano, para raíces y floración).'),
      (6, 14,
       'Liu et al. (2019), PLOS ONE 14(3): e0213643; Raudales (2023), e-GRO Edible Alert 8(9); Li et al. (2026), Technology in Horticulture 6: e015; Yara, Role of Nutrients by Tomato Growth Stage. pH: UC IPM, Tomato: Selecting the Field.',
       'Derivado el 23/09/2026 (sesión 13). Humedad como Vegetativo: en desarrollo y maduración del fruto, menos humedad dio menos rendimiento (Liu 2019). K:N sigue subiendo, a 2,4 (Raudales 2023: 1,7:1 en maduración; Li 2026: el K2O es el factor de mayor efecto en cherry sin suelo). El N baja (Yara). Se toma la dirección, no el valor.'),
      (7, 8,
       'UC IPM, Irrigation of Processing Tomatoes (UC ANR 3470, 12/13); Liu et al. (2019), PLOS ONE 14(3): e0213643; Yara, Role of Nutrients by Tomato Growth Stage. pH: UC IPM, Tomato: Selecting the Field.',
       'Derivado el 23/09/2026 (sesión 13). Humedad en baja: se corta el riego antes de cosechar para subir los sólidos solubles (UC IPM, tomate para industria). En contra: en Liu (2019), más agua en maduración dio más rendimiento; este rango prioriza la calidad. El K baja: Liu (2019) pide evitar el exceso de K en maduración. N reducido para sostener el llenado (Yara).')
    ) as v(id, ee_id, fuente, criterio)
  loop
    update public.parametro_etapa
       set fuente = f.fuente, criterio = f.criterio
     where id = f.id and etapa_especie_id = f.ee_id;
    get diagnostics n = row_count;
    if n <> 1 then
      raise exception 'Fila % (etapa_especie %) no encontrada: no se cambió nada.', f.id, f.ee_id;
    end if;
  end loop;

  -- Solo si Floración sigue como estaba.
  update public.parametro_etapa
     set humedad_min = 60, humedad_max = 75
   where id = 4 and etapa_especie_id = 9 and humedad_min = 50 and humedad_max = 65;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'Floración no está en 50–65: no se cambió nada.';
  end if;
end $$;

alter table public.parametro_etapa
  alter column fuente set not null,
  alter column criterio set not null,
  add constraint parametro_etapa_fuente_no_vacia check (btrim(fuente) <> ''),
  add constraint parametro_etapa_criterio_no_vacio check (btrim(criterio) <> '');

comment on column public.parametro_etapa.humedad_min is
  'Humedad mínima, en % tal como la reporta el sensor (no es % de capacidad de campo). Por debajo, WF1 marca sequía y puede regar. Fase 17.';
comment on column public.parametro_etapa.humedad_max is
  'Humedad máxima, en % tal como la reporta el sensor. Por encima, WF1 marca exceso hídrico (solo avisa). Fase 17.';
comment on column public.parametro_etapa.ideal_n is
  'N ideal, en mg/kg tal como lo reporta el sensor (no es un análisis de laboratorio). WF1 acepta ±30 % (tolerancia sin fuente, en el código). Fase 17.';
comment on column public.parametro_etapa.ideal_p is
  'P ideal, en mg/kg tal como lo reporta el sensor (no es un análisis de laboratorio). WF1 acepta ±30 % (tolerancia sin fuente, en el código). Fase 17.';
comment on column public.parametro_etapa.ideal_k is
  'K ideal, en mg/kg tal como lo reporta el sensor (no es K intercambiable de laboratorio). WF1 acepta ±30 % (tolerancia sin fuente, en el código). Fase 17.';

commit;

notify pgrst, 'reload schema';


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura; la corre el agente por MCP).
-- Esperado: 6 filas con fuente y criterio; Floración 60–75 y el resto igual;
-- las dos columnas NOT NULL con su CHECK; 5 comentarios.
-- ============================================================================
select pe.id, te.nombre_etapa, pe.humedad_min, pe.humedad_max, pe.ph_min, pe.ph_max,
       pe.ideal_n, pe.ideal_p, pe.ideal_k, left(pe.fuente, 40) as fuente, left(pe.criterio, 40) as criterio
from public.parametro_etapa pe
join public.etapas_especie ee on ee.id = pe.etapa_especie_id
join public.tipo_etapa te on te.id = ee.etapa_id
order by ee.orden;

select a.attname, a.attnotnull, col_description(a.attrelid, a.attnum) as comentario
from pg_attribute a
where a.attrelid = 'public.parametro_etapa'::regclass and a.attnum > 0 and not a.attisdropped;

select conname, pg_get_constraintdef(oid) from pg_constraint
where conrelid = 'public.parametro_etapa'::regclass and conname like '%vac%';

select etapa, humedad_min, humedad_max from public.vista_conocimiento_experto where etapa = 'Floración';


-- ============================================================================
-- BLOQUE 3 — Test que se deshace solo. Se pega entero.
-- Termina SIEMPRE con un error a propósito:
--   "TEST OK: ..."     → la base cumple el diseño.
--   "TEST FALLÓ: ..."  → la lista de lo que no funcionó.
-- ANTES del BLOQUE 1 tiene que dar TEST FALLÓ con 1 de 8 bien (c6: los
-- otros números no cambiaron) y los casos 1 a 4 por "does not exist".
-- ============================================================================
do $$
declare
  ok     int  := 0;
  fallas text := '';
  n      int;
begin
  -- c1 a c4: la base rechaza una fila sin fuente o sin criterio.
  begin
    update public.parametro_etapa set fuente = null where id = 2;
    raise exception 'ACEPTADO';
  exception when not_null_violation then ok := ok + 1;
            when others then fallas := fallas || ' | c1 fuente null: ' || sqlerrm;
  end;
  begin
    update public.parametro_etapa set criterio = null where id = 2;
    raise exception 'ACEPTADO';
  exception when not_null_violation then ok := ok + 1;
            when others then fallas := fallas || ' | c2 criterio null: ' || sqlerrm;
  end;
  begin
    update public.parametro_etapa set fuente = '   ' where id = 2;
    raise exception 'ACEPTADO';
  exception when check_violation then ok := ok + 1;
            when others then fallas := fallas || ' | c3 fuente vacía: ' || sqlerrm;
  end;
  begin
    update public.parametro_etapa set criterio = '' where id = 2;
    raise exception 'ACEPTADO';
  exception when check_violation then ok := ok + 1;
            when others then fallas := fallas || ' | c4 criterio vacío: ' || sqlerrm;
  end;

  -- c5: Floración en 60–75, con el resto de su fila igual.
  select count(*) into n from public.parametro_etapa
   where id = 4 and etapa_especie_id = 9 and humedad_min = 60 and humedad_max = 75
     and ph_min = 6.2 and ph_max = 6.8 and ideal_n = 30 and ideal_p = 50 and ideal_k = 60;
  if n = 1 then ok := ok + 1; else fallas := fallas || ' | c5 Floración no está en 60–75'; end if;

  -- c6: las otras 5 filas, sin cambios.
  select count(*) into n from public.parametro_etapa pe
  join (values (2, 80, 95, 6.0, 7.0, 10, 10, 10), (1, 70, 85, 6.0, 6.5, 20, 15, 15),
               (3, 60, 75, 6.0, 6.8, 50, 30, 30), (6, 60, 75, 6.0, 6.8, 25, 40, 60),
               (7, 45, 60, 6.0, 6.8, 20, 30, 45))
    as v(id, hmin, hmax, phmin, phmax, n_, p_, k_)
    on v.id = pe.id and pe.humedad_min = v.hmin and pe.humedad_max = v.hmax
   and pe.ph_min = v.phmin and pe.ph_max = v.phmax
   and pe.ideal_n = v.n_ and pe.ideal_p = v.p_ and pe.ideal_k = v.k_;
  if n = 5 then ok := ok + 1; else fallas := fallas || ' | c6 cambió otra fila (' || n || ' de 5 iguales)'; end if;

  -- c7: los 5 comentarios.
  select count(*) into n from pg_attribute a
   where a.attrelid = 'public.parametro_etapa'::regclass
     and a.attname in ('humedad_min', 'humedad_max', 'ideal_n', 'ideal_p', 'ideal_k')
     and col_description(a.attrelid, a.attnum) like '%sensor%';
  if n = 5 then ok := ok + 1; else fallas := fallas || ' | c7 comentarios: ' || n || ' de 5'; end if;

  -- c8: lo que lee WF1 ya trae Floración en 60–75.
  select count(*) into n from public.vista_conocimiento_experto
   where planta = 'Tomate Cherry' and etapa = 'Floración' and humedad_min = 60 and humedad_max = 75;
  if n = 1 then ok := ok + 1; else fallas := fallas || ' | c8 la vista no muestra Floración en 60–75'; end if;

  if fallas = '' then
    raise exception 'TEST OK: % de 8. (Este error es a propósito: deshace todo.)', ok;
  else
    raise exception 'TEST FALLÓ: % de 8 bien.%', ok, fallas;
  end if;
end $$;


-- ============================================================================
-- BLOQUE R — Reverso. Solo si hiciera falta volver atrás.
-- ============================================================================
-- begin;
-- alter table public.parametro_etapa
--   drop constraint parametro_etapa_fuente_no_vacia,
--   drop constraint parametro_etapa_criterio_no_vacio,
--   drop column fuente,
--   drop column criterio;
-- update public.parametro_etapa set humedad_min = 50, humedad_max = 65
--  where id = 4 and etapa_especie_id = 9 and humedad_min = 60 and humedad_max = 75;
-- comment on column public.parametro_etapa.humedad_min is null;
-- comment on column public.parametro_etapa.humedad_max is null;
-- comment on column public.parametro_etapa.ideal_n is null;
-- comment on column public.parametro_etapa.ideal_p is null;
-- comment on column public.parametro_etapa.ideal_k is null;
-- commit;
-- notify pgrst, 'reload schema';

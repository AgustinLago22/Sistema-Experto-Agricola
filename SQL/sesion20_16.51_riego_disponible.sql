-- ============================================================================
-- Sesión 20 · 16.51 — El riego automático exige volumen y caudal reales
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 26/10/2026 contra el estado verificado ese día por MCP.
-- ✅ APLICADO por Agustín (SQL Editor) el 26/10/2026, y verificado por MCP:
--    BLOQUE 0 (por MCP): 0 malos en las dos tablas.
--    BLOQUE 3 ANTES del cambio: "TEST FALLÓ (0 bien): la base ACEPTÓ caudal_bomba_ml_s = 0 |
--      la base ACEPTÓ volumen_maceta_litros = -5 | la vista no tiene la columna
--      riego_automatico_disponible" → el test puede fallar. No dejó nada escrito.
--    BLOQUE 1: sin error.
--    BLOQUE 3 DESPUÉS: "TEST OK: 7 de 7 (2 reglas + 5 casos de la columna)."
--    BLOQUE 2 (por MCP): las 2 reglas; la vista con 18 columnas, los mismos permisos
--      y el comentario; el cultivo de demo en false (caudal en null por el test).
--
-- QUÉ RESUELVE (la parte de la base)
--   16.51  `Calcular Dosis` (WF5) hace `volumen || 10` y `caudal || 50`: si falta
--          un dato, lo inventa y riega igual. Ejercido el 26/10 ANTES de arreglar:
--          con el caudal en null y humedad 55, WF5 registró el riego 24 con un
--          pulso de 13 s (625 ml / 50 inventado). Con el caudal real (40 ml/s)
--          habrían sido 16 s. El tope de 30 s no protege: está en tiempo y hereda
--          el caudal inventado.
--
--   La base no tenía ninguna regla sobre esas dos columnas: aceptaba null, 0 o
--   un negativo. Un 0 también terminaba en el 50 inventado (`0 || 50`).
--
-- LO QUE HACE
--   1. Dos reglas: el caudal y el volumen, si están cargados, son mayores que 0.
--      Vacío sigue permitido: una placa recién instalada todavía no se calibró,
--      y eso es un estado real, no un error de carga.
--   2. Una columna nueva al final de `vista_cultivos_activos`:
--        riego_automatico_disponible = hay bomba Y hay volumen > 0 Y hay caudal > 0
--      Nunca es null (coalesce): `Dispara WF5` la lee con typeValidation strict.
--      La regla se escribe UNA vez, en la base (la definición vive en el
--      productor). `Resolver Cultivo` (WF1) trae todas las columnas de la vista,
--      así que le llega sin tocar ese nodo.
--
-- POR QUÉ NO UNA REGLA "si hay bomba, el caudal es obligatorio"
--   Porque la bomba recién instalada, antes de calibrar, es justamente ese caso.
--   La base la impediría y obligaría a cargar un caudal inventado para poder
--   guardar el dispositivo: el mismo defecto, movido de lugar.
--
-- ORDEN
--   BLOQUE 0 (lo corre el agente por MCP) → BLOQUE 3 ANTES (tiene que FALLAR)
--   → BLOQUE 1 → BLOQUE 3 DESPUÉS (tiene que dar TEST OK) → BLOQUE 2 (MCP).
--   Después de esto, WF1 y WF5 (instrucciones aparte).
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo (solo lectura). Esperado: malos = 0 en las dos filas.
-- Verificado por MCP el 26/10: dispositivo 1 fila, 0 malos (caudal en null por
-- el test); cultivo 1 fila, 0 malos (volumen 20).
-- ============================================================================
select 'dispositivo' as tabla, count(*) as total,
       count(*) filter (where caudal_bomba_ml_s <= 0) as malos
from public.dispositivo
union all
select 'cultivo', count(*), count(*) filter (where volumen_maceta_litros <= 0)
from public.cultivo;


-- ============================================================================
-- BLOQUE 1 — El cambio. Se pega entero, una sola vez.
-- ============================================================================
begin;

alter table public.dispositivo
  add constraint dispositivo_caudal_bomba_positivo check (caudal_bomba_ml_s > 0);

alter table public.cultivo
  add constraint cultivo_volumen_maceta_positivo check (volumen_maceta_litros > 0);

-- Misma definición que la vigente, con UNA columna agregada al final
-- (CREATE OR REPLACE VIEW solo permite agregar al final; conserva los permisos).
create or replace view public.vista_cultivos_activos as
 SELECT c.id AS cultivo_id,
    c.active AS cultivo_activo,
    d.id AS dispositivo_id,
    d.mac_address AS dispositivo_mac,
    c.especie_id,
    ep.nombre_comun AS planta,
    te.nombre_etapa AS etapa_actual,
    ee.id AS etapas_especie_id,
    ee.duracion_estimada_dias,
    c.fecha_inicio_etapa,
    c.usuario_id,
    c.ultima_foto_path,
    c.volumen_maceta_litros,
    c.mantenimiento_hasta,
    d.tiene_actuador_riego,
    d.caudal_bomba_ml_s,
    c.ultima_foto_evaluada_path,
    (coalesce(d.tiene_actuador_riego, false)
       and coalesce(c.volumen_maceta_litros > 0, false)
       and coalesce(d.caudal_bomba_ml_s > 0, false)) AS riego_automatico_disponible
   FROM cultivo c
     JOIN dispositivo d ON d.id = c.dispositivo_id
     JOIN especie_planta ep ON ep.id = c.especie_id
     LEFT JOIN tipo_etapa te ON te.id = c.etapa_actual_id
     LEFT JOIN etapas_especie ee ON ee.especie_id = c.especie_id AND ee.etapa_id = c.etapa_actual_id
  WHERE c.active = true;

comment on column public.vista_cultivos_activos.riego_automatico_disponible is
  '16.51: hay bomba, volumen de maceta > 0 y caudal > 0. Sin los tres no se riega solo (WF1, Dispara WF5).';

commit;


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura; la corre el agente por MCP).
-- Esperado: las 2 reglas; la vista con la columna nueva, en false para el
-- cultivo de demo mientras el caudal siga en null, y 18 columnas.
-- ============================================================================
select conrelid::regclass as tabla, conname, pg_get_constraintdef(oid) as regla
from pg_constraint
where conname in ('dispositivo_caudal_bomba_positivo', 'cultivo_volumen_maceta_positivo');

select cultivo_id, tiene_actuador_riego, volumen_maceta_litros, caudal_bomba_ml_s,
       riego_automatico_disponible
from public.vista_cultivos_activos;


-- ============================================================================
-- BLOQUE 3 — Test que se deshace solo. Se pega entero.
-- Termina SIEMPRE con un error a propósito, que revierte todo lo que escribió:
--   "TEST OK: ..."     → las reglas y la columna funcionan.
--   "TEST FALLÓ: ..."  → la lista de lo que no funcionó.
-- Correrlo ANTES del BLOQUE 1: tiene que dar TEST FALLÓ (si da OK, el test no
-- prueba nada).
-- ============================================================================
do $$
declare
  v_disp    uuid;
  v_cultivo uuid;
  v_fallas  text[] := '{}';
  v_ok      int := 0;
  v_tiene_columna boolean;
  v_disponible boolean;

  -- Casos de la columna: (bomba, volumen, caudal) → esperado
  casos constant jsonb := '[
    {"bomba": true,  "volumen": 20,   "caudal": 40,   "esperado": true,  "nombre": "todo cargado"},
    {"bomba": true,  "volumen": 20,   "caudal": null, "esperado": false, "nombre": "sin caudal"},
    {"bomba": true,  "volumen": null, "caudal": 40,   "esperado": false, "nombre": "sin volumen"},
    {"bomba": false, "volumen": 20,   "caudal": 40,   "esperado": false, "nombre": "sin bomba"},
    {"bomba": null,  "volumen": 20,   "caudal": 40,   "esperado": false, "nombre": "bomba en null"}
  ]';
  caso jsonb;
begin
  select dispositivo_id, cultivo_id into v_disp, v_cultivo
  from public.vista_cultivos_activos
  where dispositivo_mac = '24:0A:C4:A1:B2:C3';
  if v_disp is null then
    raise exception 'TEST NO CORRIÓ: no encontré el cultivo de demo en la vista.';
  end if;

  -- 1. Las reglas tienen que frenar un 0 y un negativo
  begin
    update public.dispositivo set caudal_bomba_ml_s = 0 where id = v_disp;
    v_fallas := array_append(v_fallas, 'la base ACEPTÓ caudal_bomba_ml_s = 0');
  exception when check_violation then
    v_ok := v_ok + 1;
  end;

  begin
    update public.cultivo set volumen_maceta_litros = -5 where id = v_cultivo;
    v_fallas := array_append(v_fallas, 'la base ACEPTÓ volumen_maceta_litros = -5');
  exception when check_violation then
    v_ok := v_ok + 1;
  end;

  -- 2. La columna nueva, caso por caso
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'vista_cultivos_activos'
      and column_name = 'riego_automatico_disponible'
  ) into v_tiene_columna;

  if not v_tiene_columna then
    v_fallas := array_append(v_fallas, 'la vista no tiene la columna riego_automatico_disponible');
  else
    for caso in select * from jsonb_array_elements(casos) loop
      update public.dispositivo
         set tiene_actuador_riego = (caso->>'bomba')::boolean,
             caudal_bomba_ml_s    = (caso->>'caudal')::numeric
       where id = v_disp;
      update public.cultivo
         set volumen_maceta_litros = (caso->>'volumen')::numeric
       where id = v_cultivo;

      execute 'select riego_automatico_disponible from public.vista_cultivos_activos where cultivo_id = $1'
        into v_disponible using v_cultivo;

      if v_disponible is distinct from (caso->>'esperado')::boolean then
        v_fallas := array_append(v_fallas, format('caso "%s": dio %s, esperaba %s',
                                       caso->>'nombre', coalesce(v_disponible::text, 'null'), caso->>'esperado'));
      else
        v_ok := v_ok + 1;
      end if;
    end loop;
  end if;

  if array_length(v_fallas, 1) > 0 then
    raise exception 'TEST FALLÓ (% bien): %', v_ok, array_to_string(v_fallas, ' | ');
  end if;
  raise exception 'TEST OK: % de 7 (2 reglas + 5 casos de la columna). Todo revertido.', v_ok;
end $$;


-- ============================================================================
-- REVERSO — solo si hubiera que deshacer el BLOQUE 1.
-- Una columna no se puede sacar con CREATE OR REPLACE: hay que borrar la vista y
-- crearla de nuevo, y eso borra sus permisos, que se reponen tal como estaban el
-- 26/10 (ninguna otra vista depende de esta: verificado por MCP).
-- OJO: antes de revertir, WF1 tiene que dejar de leer riego_automatico_disponible.
-- ============================================================================
-- begin;
-- alter table public.dispositivo drop constraint dispositivo_caudal_bomba_positivo;
-- alter table public.cultivo     drop constraint cultivo_volumen_maceta_positivo;
-- drop view public.vista_cultivos_activos;
-- create view public.vista_cultivos_activos as
--  SELECT c.id AS cultivo_id, c.active AS cultivo_activo, d.id AS dispositivo_id,
--     d.mac_address AS dispositivo_mac, c.especie_id, ep.nombre_comun AS planta,
--     te.nombre_etapa AS etapa_actual, ee.id AS etapas_especie_id, ee.duracion_estimada_dias,
--     c.fecha_inicio_etapa, c.usuario_id, c.ultima_foto_path, c.volumen_maceta_litros,
--     c.mantenimiento_hasta, d.tiene_actuador_riego, d.caudal_bomba_ml_s, c.ultima_foto_evaluada_path
--    FROM cultivo c
--      JOIN dispositivo d ON d.id = c.dispositivo_id
--      JOIN especie_planta ep ON ep.id = c.especie_id
--      LEFT JOIN tipo_etapa te ON te.id = c.etapa_actual_id
--      LEFT JOIN etapas_especie ee ON ee.especie_id = c.especie_id AND ee.etapa_id = c.etapa_actual_id
--   WHERE c.active = true;
-- grant all on public.vista_cultivos_activos to anon, authenticated, service_role;
-- commit;

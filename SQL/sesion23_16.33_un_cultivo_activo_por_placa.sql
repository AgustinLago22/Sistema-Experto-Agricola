-- ============================================================================
-- Sesión 23 · 16.33 — Una placa, un solo cultivo activo
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 11/11/2026 contra el estado verificado ese día por MCP.
-- APLICADO el 11/11/2026 por Agustín: BLOQUE 3 antes → BLOQUE 1 → BLOQUE 3
-- después → "TEST OK: 6 de 6. Todo revertido.". BLOQUE 2 verificado por MCP:
-- el índice, único y válido, con su definición y su comentario; 1 cultivo,
-- 1 activo con placa, 1 fila en la vista, 1 especie, sin la placa falsa.
--
-- QUÉ RESUELVE
--   Nada en la base impide que una placa tenga dos cultivos activos. Si pasa
--   (el caso natural: se cosecha el tomate, se planta otra cosa en la misma
--   maceta y se da de alta un cultivo nuevo sin desactivar el viejo),
--   vista_cultivos_activos devuelve dos filas para la misma MAC, sin orden.
--   `Resolver Cultivo` (WF1) se queda con una cualquiera (limit 1) y todo lo
--   demás sigue en verde sobre la planta equivocada: los umbrales de la
--   especie que no es, el riego calculado con la maceta que no es y la
--   historia clínica de la planta que no es.
--
--   Con el índice, el alta del segundo cultivo falla EN EL MOMENTO DEL ALTA,
--   frente a quien se equivocó:
--     duplicate key value violates unique constraint
--     "uq_cultivo_activo_por_dispositivo"
--
-- POR QUÉ ASÍ
--   · Es un invariante del dominio ("una placa mide una sola planta a la
--     vez") que hoy no está escrito en ningún lado. El limit 1 no lo cumple:
--     lo esconde. Una regla en la base protege también los caminos que
--     todavía no existen (WF6, una app, un alta a mano), igual que 16.25 y
--     16.38.
--   · Índice único PARCIAL (where active): la regla vale solo entre los
--     activos. Una placa puede tener todos los cultivos inactivos que quiera
--     (la historia de la maceta).
--   · "where active" toma exactamente las filas con active = true, que son
--     las que lee la vista (where c.active = true). Y dispositivo.mac_address
--     ya es único: con las dos reglas, la vista devuelve a lo sumo una fila
--     por MAC.
--   · Un cultivo activo sin placa (dispositivo_id vacío) no choca con nada:
--     en un índice único dos vacíos no son iguales. Esos cultivos no están
--     en la vista (la vista une con dispositivo), así que no confunden a WF1.
--
-- QUIÉN ESCRIBE EN cultivo (verificado el 11/11)
--   Nadie da de alta cultivos ni cambia active o dispositivo_id fuera del
--   dashboard. WF1 escribe solo ultima_foto_path; fn_registrar_evaluacion_
--   fenologica (WF3), solo la etapa, su fecha y ultima_foto_evaluada_path.
--   El índice no cambia nada de lo que corre hoy.
--
-- CÓMO SE HACE UN CICLO NUEVO EN LA MISMA MACETA, DESDE AHORA
--   Primero se desactiva el cultivo viejo (active = false) y después se da
--   de alta el nuevo. Al revés, la base lo frena. El procedimiento completo
--   del ciclo nuevo sigue abierto (B.16): esto solo hace que el camino
--   equivocado falle a la vista en lugar de en silencio.
--
-- QUÉ NO CAMBIA
--   Ninguna tabla, columna, dato, vista, función ni política. WF1 tampoco:
--   el limit 1 queda, ahora sin nada que esconder.
--   Visto al pasar, sin tocar: cultivo.active admite vacío (default true).
--   Un cultivo con active vacío no está en la vista ni en el índice; es
--   coherente, pero es otra regla.
--
-- ORDEN
--   BLOQUE 0 (MCP) → BLOQUE 3 ANTES (tiene que FALLAR) → BLOQUE 1
--   → BLOQUE 3 DESPUÉS (tiene que dar TEST OK) → BLOQUE 2 (MCP).
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo (solo lectura).
-- Esperado: el índice no existe; ninguna placa con más de un cultivo activo
-- (la segunda consulta no devuelve filas); 1 cultivo, activo, con placa; la
-- vista devuelve 1 fila.
-- Verificado por MCP el 11/11: así.
-- ============================================================================
select indexname from pg_indexes
where schemaname = 'public' and indexname = 'uq_cultivo_activo_por_dispositivo';

select dispositivo_id, count(*) from public.cultivo
where active group by dispositivo_id having count(*) > 1;

select count(*) as cultivos,
       count(*) filter (where active) as activos,
       count(*) filter (where active and dispositivo_id is not null) as activos_con_placa,
       (select count(*) from public.vista_cultivos_activos) as filas_vista
from public.cultivo;


-- ============================================================================
-- BLOQUE 1 — El cambio. Se pega entero, una sola vez.
-- Si falla con "could not create unique index", hay una placa con dos
-- cultivos activos: el BLOQUE 0 la muestra. No se crea nada.
-- ============================================================================
create unique index uq_cultivo_activo_por_dispositivo
  on public.cultivo (dispositivo_id) where active;

comment on index public.uq_cultivo_activo_por_dispositivo is
  '16.33: una placa, un solo cultivo activo. Para un ciclo nuevo en la misma '
  'maceta, desactivar primero el cultivo anterior (active = false).';


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura; la corre el agente por MCP).
-- Esperado: el índice, único, válido y con su definición; los mismos números
-- que en el BLOQUE 0 (el test no deja nada).
-- ============================================================================
select i.indexrelid::regclass as indice, i.indisunique, i.indisvalid,
       pg_get_indexdef(i.indexrelid) as definicion,
       obj_description(i.indexrelid, 'pg_class') as comentario
from pg_index i
where i.indexrelid = 'public.uq_cultivo_activo_por_dispositivo'::regclass;

select count(*) as cultivos,
       count(*) filter (where active) as activos,
       count(*) filter (where active and dispositivo_id is not null) as activos_con_placa,
       (select count(*) from public.vista_cultivos_activos) as filas_vista
from public.cultivo;


-- ============================================================================
-- BLOQUE 3 — Test que se deshace solo. Se pega entero.
-- Crea una placa falsa, una especie de prueba y cultivos de prueba (todo se
-- revierte). Al cultivo real no lo toca. Termina SIEMPRE con un error a propósito:
--   "TEST OK: ..."     → la base cumple la regla.
--   "TEST FALLÓ: ..."  → la lista de lo que no funcionó.
-- Correrlo ANTES del BLOQUE 1: tiene que dar TEST FALLÓ (4 bien), porque la
-- base acepta el segundo activo y la reactivación (casos 1 y 3). Los otros
-- cuatro pasan antes y después: miran que la regla no frene de más.
-- Si da OK antes del cambio, el test no prueba nada.
--
-- Los seis casos:
--   1. segundo activo   otro cultivo activo en la placa de demo → frenado
--   2. historial        otro cultivo INACTIVO en la placa de demo → pasa
--   3. reactivar        activar ese inactivo, con el real activo → frenado
--   4. otra placa       un cultivo activo en otra placa → pasa
--   5. ciclo nuevo      en esa otra placa: desactivar el viejo y dar de alta
--                       uno nuevo → pasa, y la vista devuelve 1 fila para
--                       esa MAC, la del nuevo
--   6. sin placa        dos cultivos activos sin placa → pasa
-- "Frenado" quiere decir: error 23505 de ESTE índice, no de otro.
--
-- Probado el 11/11 en un Postgres 16 local (PGlite) con una copia de
-- cultivo, dispositivo, especie_planta, las tablas de etapas y la vista tal
-- como están en la base: antes, TEST FALLÓ (4 bien), casos 1 y 3; después,
-- TEST OK 6 de 6, y sin dejar filas. Con tres índices mal hechos a propósito
-- (sin el where, por placa y especie, con otro nombre) el test detectó los
-- tres. Con una placa con dos activos, el BLOQUE 1 no crea nada.
-- ============================================================================
do $$
declare
  v_mac      constant text := '24:0A:C4:A1:B2:C3';   -- placa de demo
  v_mac_otra constant text := '00:00:00:00:00:33';   -- placa falsa
  v_indice   constant text := 'uq_cultivo_activo_por_dispositivo';
  v_disp     uuid;
  v_otra     uuid;
  v_real     public.cultivo%rowtype;                 -- el cultivo de demo
  v_otra_esp integer;
  v_id       uuid;
  v_hist     uuid;
  v_viejo    uuid;
  v_nuevo    uuid;
  v_freno    text;      -- nombre del índice que frenó, o null si pasó
  v_vista    uuid[];
  v_fallas   text[] := '{}';
  v_ok       int := 0;
begin
  select id into v_disp from public.dispositivo where mac_address = v_mac;
  if v_disp is null then
    raise exception 'TEST NO CORRIÓ: no encontré la placa de demo.';
  end if;
  select * into v_real from public.cultivo where dispositivo_id = v_disp and active limit 1;
  if v_real.id is null then
    raise exception 'TEST NO CORRIÓ: la placa de demo no tiene un cultivo activo.';
  end if;
  -- Otra especie para los casos 1 a 3 (el caso natural: otra planta en la
  -- maceta del tomate). Así el test también detecta un índice mal hecho sobre
  -- (placa, especie). La base tiene una sola especie: se crea una de prueba.
  insert into public.especie_planta (nombre_comun) values ('test-16.33 otra especie')
  returning id into v_otra_esp;
  insert into public.dispositivo (mac_address) values (v_mac_otra) returning id into v_otra;

  -- 1. segundo activo
  begin
    v_freno := null;
    begin
      insert into public.cultivo (usuario_id, especie_id, nombre_personalizado, active, dispositivo_id)
      values (v_real.usuario_id, v_otra_esp, 'test-16.33 segundo activo', true, v_disp)
      returning id into v_id;
    exception when unique_violation then
      get stacked diagnostics v_freno = constraint_name;
    end;
    if v_freno = v_indice then
      v_ok := v_ok + 1;
    elsif v_freno is not null then
      v_fallas := array_append(v_fallas, 'caso 1 "segundo activo": lo frenó ' || v_freno || ', no el índice');
    else
      v_fallas := array_append(v_fallas, 'caso 1 "segundo activo": la base ACEPTÓ un segundo cultivo activo en la placa de demo');
      delete from public.cultivo where id = v_id;
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso 1 "segundo activo": ' || sqlerrm);
  end;

  -- 2. historial
  begin
    insert into public.cultivo (usuario_id, especie_id, nombre_personalizado, active, dispositivo_id)
    values (v_real.usuario_id, v_otra_esp, 'test-16.33 historial', false, v_disp)
    returning id into v_hist;
    v_ok := v_ok + 1;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso 2 "historial": un cultivo inactivo en la placa de demo fue rechazado: ' || sqlerrm);
  end;

  -- 3. reactivar
  begin
    if v_hist is null then
      v_fallas := array_append(v_fallas, 'caso 3 "reactivar": no corrió, porque falló el caso 2');
    else
      v_freno := null;
      begin
        update public.cultivo set active = true where id = v_hist;
      exception when unique_violation then
        get stacked diagnostics v_freno = constraint_name;
      end;
      if v_freno = v_indice then
        v_ok := v_ok + 1;
      elsif v_freno is not null then
        v_fallas := array_append(v_fallas, 'caso 3 "reactivar": lo frenó ' || v_freno || ', no el índice');
      else
        v_fallas := array_append(v_fallas, 'caso 3 "reactivar": la base ACEPTÓ activar un segundo cultivo en la placa de demo');
        update public.cultivo set active = false where id = v_hist;
      end if;
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso 3 "reactivar": ' || sqlerrm);
  end;

  -- 4. otra placa
  begin
    insert into public.cultivo (usuario_id, especie_id, nombre_personalizado, active, dispositivo_id)
    values (v_real.usuario_id, v_real.especie_id, 'test-16.33 otra placa', true, v_otra)
    returning id into v_viejo;
    v_ok := v_ok + 1;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso 4 "otra placa": un cultivo activo en otra placa fue rechazado: ' || sqlerrm);
  end;

  -- 5. ciclo nuevo
  begin
    if v_viejo is null then
      v_fallas := array_append(v_fallas, 'caso 5 "ciclo nuevo": no corrió, porque falló el caso 4');
    else
      update public.cultivo set active = false where id = v_viejo;
      insert into public.cultivo (usuario_id, especie_id, nombre_personalizado, active, dispositivo_id)
      values (v_real.usuario_id, v_real.especie_id, 'test-16.33 ciclo nuevo', true, v_otra)
      returning id into v_nuevo;
      select array_agg(cultivo_id) into v_vista
      from public.vista_cultivos_activos where dispositivo_mac = v_mac_otra;
      if v_vista = array[v_nuevo] then
        v_ok := v_ok + 1;
      else
        v_fallas := array_append(v_fallas, 'caso 5 "ciclo nuevo": la vista devolvió '
          || coalesce(array_length(v_vista, 1), 0) || ' filas para la placa falsa, en vez de solo el cultivo nuevo');
      end if;
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso 5 "ciclo nuevo": ' || sqlerrm);
  end;

  -- 6. sin placa
  begin
    insert into public.cultivo (usuario_id, especie_id, nombre_personalizado, active, dispositivo_id)
    values (v_real.usuario_id, v_real.especie_id, 'test-16.33 sin placa A', true, null),
           (v_real.usuario_id, v_real.especie_id, 'test-16.33 sin placa B', true, null);
    v_ok := v_ok + 1;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso 6 "sin placa": dos cultivos activos sin placa fueron rechazados: ' || sqlerrm);
  end;

  if array_length(v_fallas, 1) > 0 then
    raise exception 'TEST FALLÓ (% bien): %', v_ok, array_to_string(v_fallas, ' | ');
  end if;
  raise exception 'TEST OK: % de 6. Todo revertido.', v_ok;
end $$;


-- ============================================================================
-- REVERSO — solo si hubiera que deshacer el BLOQUE 1.
-- ============================================================================
-- drop index public.uq_cultivo_activo_por_dispositivo;

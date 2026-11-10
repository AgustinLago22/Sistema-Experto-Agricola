-- ============================================================================
-- Sesión 22 · 16.63 — La placa recibe sus órdenes sin la Secret key
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 09/11/2026 contra el estado verificado ese día por MCP.
-- APLICADO el 10/11/2026 por Agustín: BLOQUE 3 antes → TEST FALLÓ (1 bien);
-- BLOQUE 1; BLOQUE 3 después → TEST OK: 10 de 10. BLOQUE 2 verificado por MCP
-- (las dos funciones, prosecdef false, EXECUTE solo postgres y service_role;
-- las 10 órdenes viejas intactas). Test en vivo: sesion22_test_ordenes_en_vivo.sql.
--
-- QUÉ RESUELVE (la parte de la base)
--   WF5 deja cada orden de riego en comando_dispositivo, pero nadie la lee:
--   hay 10 órdenes en 'pendiente' (8 de agosto, de 30 s, y las 27 y 28 del
--   04/11). La tabla tiene RLS sin políticas, o sea que solo la lee la Secret
--   key, que es acceso total a la base. Esa clave no puede ir en la placa.
--
--   Decisión de Agustín (09/11):
--     · La placa pide sus órdenes a n8n (WF8), con la misma X-Device-Key que
--       usa para el arranque y las lecturas. La Secret key no sale de n8n.
--     · Una orden se entrega UNA sola vez. Si la respuesta se pierde, ese
--       riego no ocurre y el recheck lo detecta ("la placa no confirmó").
--       Nunca se riega dos veces la misma orden.
--     · Una orden que no se entregó en 10 minutos ya no se entrega.
--
--   Dos funciones, las que llama WF8:
--
--   1. fn_tomar_ordenes(p_mac, p_arranque_id)
--      Revisa que la MAC exista y que el arranque sea de esa placa (igual que
--      la puerta de las lecturas). Pasa a 'entregado' las órdenes 'pendiente'
--      de esa placa creadas hace menos de 10 minutos, y las devuelve. Las más
--      viejas no se tocan: quedan en 'pendiente', que es la verdad (nunca se
--      entregaron), y el Motor ya dice "la placa no confirmó" para ese estado.
--      Devuelve SIEMPRE una fila: (valido, errores, ordenes).
--
--   2. fn_acusar_orden(p_mac, p_arranque_id, p_comando_id, p_resultado)
--      La placa avisa cómo terminó una orden: 'ejecutado' o 'error'.
--      Solo pasa de 'entregado' a uno de esos dos. Repetir el mismo acuse no
--      cambia nada y devuelve 'duplicado' (la placa puede reintentarlo sin
--      riesgo). Una orden ajena, una que nunca se entregó o un acuse que
--      contradice al anterior se rechazan, con el motivo.
--      Devuelve SIEMPRE una fila: (valido, resultado, estado_orden, errores).
--
-- POR QUÉ ASÍ
--   · "Entregar una sola vez" lo garantiza el UPDATE: la condición
--     estado = 'pendiente' se vuelve a evaluar sobre la fila bloqueada, así
--     que dos pedidos simultáneos no pueden llevarse la misma orden.
--   · El vencimiento no se guarda como estado: se deriva de creado_en. No se
--     agrega ningún valor al CHECK de estado ni se toca ninguna fila vieja.
--   · Los 10 minutos viven acá y en ningún otro lado. Sin procedencia: los
--     fija el piloto (B3), igual que los tiempos de 13.7.2.
--   · Sin SECURITY DEFINER y solo para service_role, como fn_registrar_riego
--     y fn_registrar_telemetria. Supabase da EXECUTE a anon y authenticated
--     por defecto en cada función nueva (verificado en pg_default_acl el
--     09/11): por eso el REVOKE explícito.
--
-- QUÉ NO CAMBIA
--   Ninguna tabla, columna, restricción, política ni dato.
--
-- ORDEN
--   BLOQUE 0 (MCP) → BLOQUE 3 ANTES (tiene que FALLAR) → BLOQUE 1
--   → BLOQUE 3 DESPUÉS (tiene que dar TEST OK) → BLOQUE 2 (MCP) → WF8.
--   La base va primero: sin WF8 nadie llama a estas funciones, así que
--   crearlas no cambia nada de lo que corre hoy.
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo (solo lectura).
-- Esperado: ninguna de las dos funciones existe; 10 órdenes en 'pendiente',
-- todas de la placa de demo, la más nueva del 04/11.
-- Verificado por MCP el 09/11: así.
-- ============================================================================
select p.oid::regprocedure as firma
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('fn_tomar_ordenes', 'fn_acusar_orden');

select estado, count(*), min(creado_en), max(creado_en)
from public.comando_dispositivo
group by estado;


-- ============================================================================
-- BLOQUE 1 — El cambio. Se pega entero, una sola vez.
-- ============================================================================
begin;

-- 1. La placa pide sus órdenes.
create function public.fn_tomar_ordenes(p_mac text, p_arranque_id bigint)
returns table (valido boolean, errores text[], ordenes jsonb)
language plpgsql
set search_path = public, pg_temp
as $function$
declare
  -- Una orden que no se entregó en este tiempo ya no se entrega: la maceta
  -- pudo cambiar y regar tarde es regar a ciegas. Sin procedencia: sale del
  -- piloto (B3). Tiene que ser menor que la absorción de 13.7.2 (15 min).
  c_vencimiento constant interval := interval '10 minutes';
  v_disp    uuid;
  v_ordenes jsonb;
begin
  select d.id into v_disp from public.dispositivo d where d.mac_address = p_mac;
  if v_disp is null then
    return query select false,
      array['dispositivo_mac: no corresponde a ningún dispositivo registrado'], '[]'::jsonb;
    return;
  end if;

  if not exists (select 1 from public.arranque_dispositivo a
                 where a.id = p_arranque_id and a.dispositivo_id = v_disp) then
    return query select false,
      array['arranque_id: no fue asignado a este dispositivo (pedir uno en /webhook/arranque)'], '[]'::jsonb;
    return;
  end if;

  -- Entrega única: la condición estado = 'pendiente' se reevalúa sobre la fila
  -- bloqueada, así que dos pedidos a la vez no se llevan la misma orden.
  with tomadas as (
    update public.comando_dispositivo c
       set estado = 'entregado', entregado_en = now()
     where c.dispositivo_id = v_disp
       and c.estado = 'pendiente'
       and c.creado_en > now() - c_vencimiento
    returning c.id, c.tipo_comando, c.duracion_segundos
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'comando_id',        t.id,
           'tipo',              t.tipo_comando,
           'duracion_segundos', t.duracion_segundos) order by t.id), '[]'::jsonb)
    into v_ordenes
    from tomadas t;

  return query select true, array[]::text[], v_ordenes;
end;
$function$;

revoke all on function public.fn_tomar_ordenes(text, bigint) from public, anon, authenticated;
grant execute on function public.fn_tomar_ordenes(text, bigint) to service_role;

comment on function public.fn_tomar_ordenes(text, bigint) is
  'La placa pide sus órdenes (WF8, /webhook/ordenes). Pasa a entregado y devuelve las órdenes pendiente '
  'de esa placa creadas hace menos de 10 minutos. Cada orden se entrega una sola vez. 16.63. Solo service_role.';

-- 2. La placa avisa cómo terminó una orden.
create function public.fn_acusar_orden(p_mac text, p_arranque_id bigint,
                                       p_comando_id bigint, p_resultado text)
returns table (valido boolean, resultado text, estado_orden text, errores text[])
language plpgsql
set search_path = public, pg_temp
as $function$
declare
  v_disp   uuid;
  v_estado text;
begin
  select d.id into v_disp from public.dispositivo d where d.mac_address = p_mac;
  if v_disp is null then
    return query select false, null::text, null::text,
      array['dispositivo_mac: no corresponde a ningún dispositivo registrado'];
    return;
  end if;

  if not exists (select 1 from public.arranque_dispositivo a
                 where a.id = p_arranque_id and a.dispositivo_id = v_disp) then
    return query select false, null::text, null::text,
      array['arranque_id: no fue asignado a este dispositivo (pedir uno en /webhook/arranque)'];
    return;
  end if;

  if p_resultado is null or p_resultado not in ('ejecutado', 'error') then
    return query select false, null::text, null::text,
      array[format('resultado: %s no es válido; tiene que ser "ejecutado" o "error"',
                   coalesce(quote_literal(p_resultado), 'null'))];
    return;
  end if;

  -- Bloquea la orden: dos acuses a la vez se ordenan y el segundo ve el primero.
  select c.estado into v_estado
    from public.comando_dispositivo c
   where c.id = p_comando_id and c.dispositivo_id = v_disp
     for update;

  if v_estado is null then
    return query select false, null::text, null::text,
      array[format('comando_id: %s no es una orden de este dispositivo', p_comando_id)];
    return;
  end if;

  if v_estado = p_resultado then
    -- El mismo acuse otra vez (la respuesta anterior se perdió): no cambia nada.
    return query select true, 'duplicado'::text, v_estado, array[]::text[];
    return;
  end if;

  if v_estado <> 'entregado' then
    return query select false, null::text, v_estado,
      array[case v_estado
              when 'pendiente' then format('comando_id: la orden %s nunca se entregó; no se puede acusar', p_comando_id)
              else format('comando_id: la orden %s ya figura "%s"; no se cambia a "%s"', p_comando_id, v_estado, p_resultado)
            end];
    return;
  end if;

  update public.comando_dispositivo c
     set estado       = p_resultado,
         ejecutado_en = case when p_resultado = 'ejecutado' then now() end
   where c.id = p_comando_id;

  return query select true, 'aceptado'::text, p_resultado, array[]::text[];
end;
$function$;

revoke all on function public.fn_acusar_orden(text, bigint, bigint, text) from public, anon, authenticated;
grant execute on function public.fn_acusar_orden(text, bigint, bigint, text) to service_role;

comment on function public.fn_acusar_orden(text, bigint, bigint, text) is
  'La placa avisa cómo terminó una orden (WF8, /webhook/orden-acuse): de entregado a ejecutado o error. '
  'Repetir el mismo acuse devuelve duplicado y no cambia nada. 16.63. Solo service_role.';

commit;

notify pgrst, 'reload schema';


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura; la corre el agente por MCP).
-- Esperado: las dos funciones, sin SECURITY DEFINER, ejecutables solo por
-- postgres y service_role. Las 10 órdenes viejas, igual que en el BLOQUE 0.
-- ============================================================================
select p.oid::regprocedure as firma, p.prosecdef, p.proacl, pg_get_function_result(p.oid) as devuelve
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('fn_tomar_ordenes', 'fn_acusar_orden');

select estado, count(*), min(creado_en), max(creado_en)
from public.comando_dispositivo
group by estado;


-- ============================================================================
-- BLOQUE 3 — Test que se deshace solo. Se pega entero.
-- Crea un arranque para la placa de demo, una placa falsa con su arranque y
-- cinco órdenes (todo se revierte). Termina SIEMPRE con un error a propósito:
--   "TEST OK: ..."     → la base cumple el diseño.
--   "TEST FALLÓ: ..."  → la lista de lo que no funcionó.
-- Correrlo ANTES del BLOQUE 1: tiene que dar TEST FALLÓ (1 bien), porque las
-- funciones no existen (el que pasa es "vencida y ajena", que solo mira que
-- nadie haya tocado esas órdenes). Si da OK, el test no prueba nada.
--
-- Probado el 09/11 en un Postgres 16 local (PGlite) con una copia de las tres
-- tablas y los permisos por defecto de Supabase: antes, TEST FALLÓ (1 bien);
-- después, TEST OK 10 de 10, y las 10 órdenes viejas sin tocar. Con cuatro
-- defectos metidos a propósito (sin vencimiento, entrega repetida, un acuse
-- que pisa a otro, la función abierta a anon) el test detectó los cuatro.
-- Deja huecos en los id de comando_dispositivo y arranque_dispositivo: son
-- inocuos.
-- ============================================================================
do $$
declare
  v_mac      constant text := '24:0A:C4:A1:B2:C3';
  v_mac_otra constant text := '00:00:00:00:00:03';
  v_disp     uuid;
  v_otra     uuid;
  v_arr      bigint;   -- arranque de la placa de demo
  v_arr_otra bigint;   -- arranque de la placa falsa
  v_nueva    bigint;   -- orden recién creada
  v_9min     bigint;   -- orden de hace 9 minutos: todavía se entrega
  v_11min    bigint;   -- orden de hace 11 minutos: vencida
  v_ajena    bigint;   -- orden reciente de la placa falsa
  v_valido   boolean;
  v_errores  text[];
  v_ordenes  jsonb;
  v_res      text;
  v_est      text;
  v_ent      timestamptz;
  v_ejec     timestamptz;
  v_ejec2    timestamptz;
  v_ids      bigint[];
  v_n        int;
  v_fallas   text[] := '{}';
  v_ok       int := 0;
  v_firma_t  constant text := 'public.fn_tomar_ordenes(text, bigint)';
  v_firma_a  constant text := 'public.fn_acusar_orden(text, bigint, bigint, text)';
begin
  select id into v_disp from public.dispositivo where mac_address = v_mac;
  if v_disp is null then
    raise exception 'TEST NO CORRIÓ: no encontré la placa de demo.';
  end if;

  insert into public.arranque_dispositivo (dispositivo_id, version_firmware)
  values (v_disp, 'test-16.63') returning id into v_arr;
  insert into public.dispositivo (mac_address) values (v_mac_otra) returning id into v_otra;
  insert into public.arranque_dispositivo (dispositivo_id, version_firmware)
  values (v_otra, 'test-16.63') returning id into v_arr_otra;

  insert into public.comando_dispositivo (dispositivo_id, tipo_comando, duracion_segundos)
  values (v_disp, 'ACTIVAR_RIEGO', 16) returning id into v_nueva;
  insert into public.comando_dispositivo (dispositivo_id, tipo_comando, duracion_segundos, creado_en)
  values (v_disp, 'ACTIVAR_RIEGO', 12, now() - interval '9 minutes') returning id into v_9min;
  insert into public.comando_dispositivo (dispositivo_id, tipo_comando, duracion_segundos, creado_en)
  values (v_disp, 'ACTIVAR_RIEGO', 30, now() - interval '11 minutes') returning id into v_11min;
  insert into public.comando_dispositivo (dispositivo_id, tipo_comando, duracion_segundos)
  values (v_otra, 'ACTIVAR_RIEGO', 20) returning id into v_ajena;

  -- Caso 1 — pedir órdenes: llegan la nueva y la de 9 min, en orden, con sus
  -- datos; y quedan 'entregado' con su hora.
  begin
    execute 'select valido, errores, ordenes from public.fn_tomar_ordenes($1, $2)'
      into v_valido, v_errores, v_ordenes using v_mac, v_arr;
    select array_agg((o->>'comando_id')::bigint order by ord) into v_ids
      from jsonb_array_elements(v_ordenes) with ordinality as x(o, ord);
    select count(*) into v_n from public.comando_dispositivo
     where id in (v_nueva, v_9min) and estado = 'entregado' and entregado_en is not null;
    if v_valido is true and cardinality(v_errores) = 0
       and v_ids = array[least(v_nueva, v_9min), greatest(v_nueva, v_9min)]
       and v_ordenes @> jsonb_build_array(jsonb_build_object(
             'comando_id', v_nueva, 'tipo', 'ACTIVAR_RIEGO', 'duracion_segundos', 16))
       and v_n = 2 then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "pedir órdenes": valido %s, errores %s, órdenes %s, entregadas %s (esperaba true, ninguno, las órdenes %s y %s, 2)',
        v_valido, v_errores, v_ordenes, v_n, v_nueva, v_9min));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "pedir órdenes": ' || sqlerrm);
  end;

  -- Caso 2 — pedir otra vez: lista vacía. Cada orden se entrega una sola vez.
  begin
    execute 'select valido, ordenes from public.fn_tomar_ordenes($1, $2)'
      into v_valido, v_ordenes using v_mac, v_arr;
    if v_valido is true and v_ordenes = '[]'::jsonb then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "entrega única": valido %s, órdenes %s (esperaba true y [])', v_valido, v_ordenes));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "entrega única": ' || sqlerrm);
  end;

  -- Caso 3 — la de 11 min no se entregó: sigue 'pendiente', sin hora de entrega.
  -- Y la de la otra placa tampoco: sigue 'pendiente'.
  begin
    select estado, entregado_en into v_est, v_ent from public.comando_dispositivo where id = v_11min;
    select estado into v_res from public.comando_dispositivo where id = v_ajena;
    if v_est = 'pendiente' and v_ent is null and v_res = 'pendiente' then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "vencida y ajena": la de 11 min quedó %s (entregada %s), la ajena %s (esperaba pendiente, sin hora, pendiente)',
        v_est, v_ent, v_res));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "vencida y ajena": ' || sqlerrm);
  end;

  -- Caso 4 — la placa falsa pide las suyas: recibe solo la suya.
  begin
    execute 'select valido, ordenes from public.fn_tomar_ordenes($1, $2)'
      into v_valido, v_ordenes using v_mac_otra, v_arr_otra;
    if v_valido is true and jsonb_array_length(v_ordenes) = 1
       and (v_ordenes->0->>'comando_id')::bigint = v_ajena then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "cada placa las suyas": valido %s, órdenes %s (esperaba solo la %s)', v_valido, v_ordenes, v_ajena));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "cada placa las suyas": ' || sqlerrm);
  end;

  -- Caso 5 — pedir con una MAC desconocida, o con el arranque de otra placa:
  -- rechazado con el motivo, sin órdenes, una fila cada vez.
  begin
    execute 'select valido, errores, ordenes from public.fn_tomar_ordenes($1, $2)'
      into v_valido, v_errores, v_ordenes using '00:00:00:00:00:04', v_arr;
    execute 'select errores[1] from public.fn_tomar_ordenes($1, $2)'
      into v_res using v_mac, v_arr_otra;
    if v_valido is false and v_errores[1] like 'dispositivo_mac: no corresponde%'
       and v_ordenes = '[]'::jsonb and v_res like 'arranque_id:%' then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "pedido rechazado": valido %s, errores %s, órdenes %s; con arranque ajeno: %s', v_valido, v_errores, v_ordenes, v_res));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "pedido rechazado": ' || sqlerrm);
  end;

  -- Caso 6 — acusar 'ejecutado' una orden entregada: aceptado, con su hora.
  begin
    execute 'select valido, resultado, estado_orden from public.fn_acusar_orden($1, $2, $3, $4)'
      into v_valido, v_res, v_est using v_mac, v_arr, v_nueva, 'ejecutado';
    select ejecutado_en into v_ejec from public.comando_dispositivo
     where id = v_nueva and estado = 'ejecutado';
    if v_valido is true and v_res = 'aceptado' and v_est = 'ejecutado' and v_ejec is not null then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "acuse ejecutado": valido %s, resultado %s, estado %s, ejecutado_en %s', v_valido, v_res, v_est, v_ejec));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "acuse ejecutado": ' || sqlerrm);
  end;

  -- Caso 7 — el mismo acuse otra vez (la respuesta se perdió): duplicado, y no
  -- cambia nada (ni la hora). Se fuerza otra hora para que el test lo note.
  begin
    update public.comando_dispositivo set ejecutado_en = ejecutado_en - interval '1 minute'
     where id = v_nueva returning ejecutado_en into v_ejec;
    execute 'select valido, resultado, estado_orden from public.fn_acusar_orden($1, $2, $3, $4)'
      into v_valido, v_res, v_est using v_mac, v_arr, v_nueva, 'ejecutado';
    select ejecutado_en into v_ejec2 from public.comando_dispositivo where id = v_nueva;
    if v_valido is true and v_res = 'duplicado' and v_est = 'ejecutado' and v_ejec2 = v_ejec then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "acuse repetido": valido %s, resultado %s, estado %s, la hora pasó de %s a %s', v_valido, v_res, v_est, v_ejec, v_ejec2));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "acuse repetido": ' || sqlerrm);
  end;

  -- Caso 8 — acusar 'error' la otra entregada: aceptado, sin hora de ejecución.
  begin
    execute 'select valido, resultado, estado_orden from public.fn_acusar_orden($1, $2, $3, $4)'
      into v_valido, v_res, v_est using v_mac, v_arr, v_9min, 'error';
    select estado, ejecutado_en into v_est, v_ejec from public.comando_dispositivo where id = v_9min;
    if v_valido is true and v_res = 'aceptado' and v_est = 'error' and v_ejec is null then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "acuse error": valido %s, resultado %s, estado %s, ejecutado_en %s', v_valido, v_res, v_est, v_ejec));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "acuse error": ' || sqlerrm);
  end;

  -- Caso 9 — acuses que se rechazan, y no cambian nada:
  --   a) contradice al anterior (la orden figura 'error', llega 'ejecutado');
  --   b) una orden que nunca se entregó (la de 11 min);
  --   c) una orden de otra placa;
  --   d) un resultado que no existe.
  begin
    execute 'select valido, errores[1] from public.fn_acusar_orden($1, $2, $3, $4)'
      into v_valido, v_res using v_mac, v_arr, v_9min, 'ejecutado';
    if not (v_valido is false and v_res like '%ya figura "error"%') then
      v_fallas := array_append(v_fallas, format('caso "acuses rechazados", contradice: valido %s, error %s', v_valido, v_res));
    end if;
    execute 'select valido, errores[1] from public.fn_acusar_orden($1, $2, $3, $4)'
      into v_valido, v_res using v_mac, v_arr, v_11min, 'ejecutado';
    if not (v_valido is false and v_res like '%nunca se entregó%') then
      v_fallas := array_append(v_fallas, format('caso "acuses rechazados", nunca entregada: valido %s, error %s', v_valido, v_res));
    end if;
    execute 'select valido, errores[1] from public.fn_acusar_orden($1, $2, $3, $4)'
      into v_valido, v_res using v_mac, v_arr, v_ajena, 'ejecutado';
    if not (v_valido is false and v_res like '%no es una orden de este dispositivo%') then
      v_fallas := array_append(v_fallas, format('caso "acuses rechazados", ajena: valido %s, error %s', v_valido, v_res));
    end if;
    execute 'select valido, errores[1] from public.fn_acusar_orden($1, $2, $3, $4)'
      into v_valido, v_res using v_mac, v_arr, v_nueva, 'hecho';
    if not (v_valido is false and v_res like 'resultado:%') then
      v_fallas := array_append(v_fallas, format('caso "acuses rechazados", resultado inválido: valido %s, error %s', v_valido, v_res));
    end if;
    select string_agg(id || '=' || estado, ',' order by id) into v_res
      from public.comando_dispositivo where id in (v_nueva, v_9min, v_11min, v_ajena);
    if v_res = format('%s=ejecutado,%s=error,%s=pendiente,%s=entregado', v_nueva, v_9min, v_11min, v_ajena) then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format('caso "acuses rechazados": los estados quedaron %s', v_res));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "acuses rechazados": ' || sqlerrm);
  end;

  -- Caso 10 — permisos: las dos cerradas para anon y authenticated, abiertas
  -- para service_role; y ninguna es SECURITY DEFINER.
  begin
    if not has_function_privilege('anon', v_firma_t, 'execute')
       and not has_function_privilege('authenticated', v_firma_t, 'execute')
       and has_function_privilege('service_role', v_firma_t, 'execute')
       and not has_function_privilege('anon', v_firma_a, 'execute')
       and not has_function_privilege('authenticated', v_firma_a, 'execute')
       and has_function_privilege('service_role', v_firma_a, 'execute')
       and not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public' and p.prosecdef
                         and p.proname in ('fn_tomar_ordenes', 'fn_acusar_orden')) then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, 'caso "permisos": anon o authenticated pueden ejecutarlas, service_role no, o alguna es SECURITY DEFINER');
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "permisos": ' || sqlerrm);
  end;

  if array_length(v_fallas, 1) > 0 then
    raise exception 'TEST FALLÓ (% bien): %', v_ok, array_to_string(v_fallas, ' | ');
  end if;
  raise exception 'TEST OK: % de 10. Todo revertido.', v_ok;
end $$;


-- ============================================================================
-- REVERSO — solo si hubiera que deshacer el BLOQUE 1.
-- Desactivar WF8 antes: sin las funciones, sus pedidos terminan en error.
-- ============================================================================
-- begin;
-- drop function public.fn_acusar_orden(text, bigint, bigint, text);
-- drop function public.fn_tomar_ordenes(text, bigint);
-- commit;
-- notify pgrst, 'reload schema';

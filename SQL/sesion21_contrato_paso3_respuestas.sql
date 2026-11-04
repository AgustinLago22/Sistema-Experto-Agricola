-- ============================================================================
-- Sesión 21 · Contrato v1, paso 3 — Responder según cómo se procesó la lectura
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 04/11/2026 contra el estado verificado ese día por MCP.
--
-- QUÉ RESUELVE (la parte de la base)
--   Hoy WF1 le responde "aceptada" a la placa ANTES de procesar. Un reintento
--   recibe "aceptada" y después WF1 queda en rojo en fn_registrar_telemetria,
--   porque la base corta con un error. WF1 pasa a responder DESPUÉS de guardar,
--   y para eso necesita dos cosas de la base:
--
--   1. fn_registrar_telemetria: un DNI repetido deja de ser un error.
--      Devuelve la lectura que ya existía y `duplicada = true`, sin guardar nada.
--      Una lectura nueva devuelve `duplicada = false`. Cualquier otro problema
--      (arranque de otra placa, motivo inválido, falta el DNI) sigue cortando
--      con error: solo se perdona el DNI repetido.
--      Cambia lo que devuelve, así que hay que borrarla y crearla de nuevo (y
--      reponer sus permisos). Sigue sin SECURITY DEFINER y solo para service_role.
--
--   2. fn_verificar_arranque: una placa registrada SIN cultivo activo se rechaza
--      en la puerta (400 + fila en lectura_rechazada).
--      Hoy esa lectura recibe "aceptada" y muere en silencio en `Resolver Cultivo`
--      (la parte de 16.8 que quedaba abierta). Si no se resolviera acá, al mover
--      la respuesta n8n le contestaría 200 con el cuerpo vacío: la placa creería
--      que salió bien. Mira `vista_cultivos_activos`, la misma que usa
--      `Resolver Cultivo`, para que los dos digan lo mismo. Sigue devolviendo
--      exactamente una fila.
--
-- QUÉ NO CAMBIA
--   Ninguna tabla ni dato. Las dos funciones conservan sus parámetros.
--
-- ORDEN (distinto al de otros pasos, a propósito)
--   BLOQUE 0 (MCP) → BLOQUE 3 ANTES (tiene que FALLAR) → WF1 nuevo → BLOQUE 1
--   → BLOQUE 3 DESPUÉS (tiene que dar TEST OK) → BLOQUE 2 (MCP).
--   WF1 VA PRIMERO porque esa combinación es segura: con la función vieja, una
--   lectura nueva sale "aceptada" y un reintento responde 500 y no guarda nada.
--   Al revés sería peligroso: el WF1 viejo no mira `duplicada`, así que un
--   reintento volvería a avisar y a regar.
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo (solo lectura).
-- Esperado: fn_registrar_telemetria devuelve TABLE(lectura_id bigint), sin
-- SECURITY DEFINER y solo service_role. fn_verificar_arranque sin mirar cultivos.
-- Verificado por MCP el 04/11: así. Una sola placa, con un cultivo activo.
-- ============================================================================
select p.oid::regprocedure as firma, p.prosecdef, p.proacl, pg_get_function_result(p.oid) as devuelve
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('fn_registrar_telemetria', 'fn_verificar_arranque');


-- ============================================================================
-- BLOQUE 1 — El cambio. Se pega entero, una sola vez.
-- ============================================================================
begin;

-- 1. fn_registrar_telemetria: un DNI repetido ya no es un error.
drop function public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text,
  double precision, double precision, double precision, double precision, double precision,
  double precision, double precision);

create function public.fn_registrar_telemetria(
  p_cultivo_id      uuid,
  p_dispositivo_id  uuid,
  p_arranque_id     bigint           default null,
  p_seq             bigint           default null,
  p_ts              bigint           default null,
  p_motivo          text             default null,
  p_humedad         double precision default null,
  p_ph              double precision default null,
  p_n               double precision default null,
  p_p               double precision default null,
  p_k               double precision default null,
  p_temperatura     double precision default null,
  p_conductividad   double precision default null
)
returns table (lectura_id bigint, duplicada boolean)
language plpgsql
set search_path to 'public'
as $function$
declare
  v_lectura_id bigint;
begin
  if p_arranque_id is null or p_seq is null or p_motivo is null then
    raise exception 'fn_registrar_telemetria: faltan p_arranque_id, p_seq o p_motivo. Desde el contrato v1, paso 4, cada lectura se guarda con su DNI: falta actualizar Consolidar datos en WF1.';
  end if;

  -- Solo el DNI repetido se perdona: cualquier otra regla rota sigue cortando.
  insert into public.lectura (dispositivo_id, cultivo_id, arranque_id, seq, ts_dispositivo, motivo)
  values (p_dispositivo_id, p_cultivo_id, p_arranque_id, p_seq, p_ts, p_motivo)
  on conflict on constraint lectura_dni_unico do nothing
  returning id into v_lectura_id;

  if v_lectura_id is null then
    -- Es un reintento: se devuelve la lectura que ya estaba y no se guarda nada.
    select l.id into v_lectura_id
    from public.lectura l
    where l.arranque_id = p_arranque_id and l.seq = p_seq;

    return query select v_lectura_id, true;
    return;
  end if;

  insert into public.lectura_sensores (lectura_id, cultivo_id, dispositivo_id, metrica_id, valor)
  select v_lectura_id, p_cultivo_id, p_dispositivo_id, tm.id, v.valor
  from (values
    ('Humedad',       p_humedad),
    ('Temperatura',   p_temperatura),
    ('pH',            p_ph),
    ('Conductividad', p_conductividad),
    ('Nitrógeno',     p_n),
    ('Fósforo',       p_p),
    ('Potasio',       p_k)
  ) as v(nombre, valor)
  join public.tipos_metricas tm on tm.nombre = v.nombre
  where v.valor is not null;

  return query select v_lectura_id, false;
end;
$function$;

revoke all on function public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text,
  double precision, double precision, double precision, double precision, double precision,
  double precision, double precision) from public, anon, authenticated;
grant execute on function public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text,
  double precision, double precision, double precision, double precision, double precision,
  double precision, double precision) to service_role;

comment on function public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text,
  double precision, double precision, double precision, double precision, double precision,
  double precision, double precision) is
  'Guarda una lectura (fila en lectura) y sus mediciones (una fila por métrica con valor; null = el sensor '
  'no midió) en una transacción. Devuelve lectura_id y duplicada. DNI repetido: no guarda nada y devuelve la '
  'lectura existente con duplicada = true. Contrato v1, pasos 3, 4 y 5. Solo service_role.';

-- 2. fn_verificar_arranque: la placa tiene que tener un cultivo activo.
create or replace function public.fn_verificar_arranque(p_mac text, p_arranque_id bigint)
returns table (valido boolean, errores text[])
language sql
stable
set search_path = public, pg_temp
as $$
  select (d.id is not null and a.id is not null and c.tiene_cultivo),
         case
           when d.id is null then
             array['dispositivo_mac: no corresponde a ningún dispositivo registrado']
           when a.id is null then
             array['arranque_id: no fue asignado a este dispositivo (pedir uno en /webhook/arranque)']
           when not c.tiene_cultivo then
             array['dispositivo_mac: este dispositivo no tiene un cultivo activo']
           else
             array[]::text[]
         end
    from (select 1) as una_fila          -- garantiza exactamente una fila
    left join public.dispositivo d
           on d.mac_address = p_mac
    left join public.arranque_dispositivo a
           on a.id = p_arranque_id
          and a.dispositivo_id = d.id
   cross join lateral (
     -- Con exists, dos cultivos activos en una placa no multiplican la fila.
     select exists (select 1 from public.vista_cultivos_activos v
                    where v.dispositivo_mac = p_mac) as tiene_cultivo
   ) as c;
$$;

commit;

notify pgrst, 'reload schema';


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura; la corre el agente por MCP).
-- Esperado: fn_registrar_telemetria devuelve TABLE(lectura_id bigint, duplicada
-- boolean), sin SECURITY DEFINER y solo service_role. fn_verificar_arranque, con
-- los mismos permisos que antes y mirando vista_cultivos_activos.
-- ============================================================================
select p.oid::regprocedure as firma, p.prosecdef, p.proacl, pg_get_function_result(p.oid) as devuelve,
       p.prosrc like '%vista_cultivos_activos%' as mira_cultivos,
       p.prosrc like '%on conflict on constraint lectura_dni_unico%' as perdona_el_dni
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('fn_registrar_telemetria', 'fn_verificar_arranque');


-- ============================================================================
-- BLOQUE 3 — Test que se deshace solo. Se pega entero.
-- Crea un arranque propio para la placa de demo y una placa falsa sin cultivo,
-- con su arranque (todo se revierte). Termina SIEMPRE con un error a propósito:
--   "TEST OK: ..."     → la base cumple el paso 3.
--   "TEST FALLÓ: ..."  → la lista de lo que no funcionó.
-- Correrlo ANTES del BLOQUE 1: tiene que dar TEST FALLÓ (6 bien), nombrando los
-- casos "lectura nueva", "reintento", "otra seq" y "puerta, sin cultivo" (los 6
-- que pasan son las reglas que ya existían). Si da OK, el test no prueba nada.
-- Deja huecos en los id de lectura, lectura_sensores y arranque_dispositivo:
-- son inocuos.
-- ============================================================================
do $$
declare
  v_mac      constant text := '24:0A:C4:A1:B2:C3';
  v_mac_sin  constant text := '00:00:00:00:00:01';
  v_disp     uuid;
  v_cultivo  uuid;
  v_arr      bigint;   -- arranque de la placa de demo
  v_arr_otra bigint;   -- arranque de la placa sin cultivo
  v_otra     uuid;
  v_id       bigint;
  v_id2      bigint;
  v_dup      boolean;
  v_n        int;
  v_m        int;
  v_valor    double precision;
  v_valido   boolean;
  v_errores  text[];
  v_texto    text;
  v_texto2   text;
  v_fallas   text[] := '{}';
  v_ok       int := 0;
begin
  select dispositivo_id, cultivo_id into v_disp, v_cultivo
  from public.vista_cultivos_activos
  where dispositivo_mac = v_mac;
  if v_cultivo is null then
    raise exception 'TEST NO CORRIÓ: no encontré el cultivo de demo en la vista.';
  end if;

  insert into public.arranque_dispositivo (dispositivo_id, version_firmware)
  values (v_disp, 'test-paso3') returning id into v_arr;
  insert into public.dispositivo (mac_address) values (v_mac_sin) returning id into v_otra;
  insert into public.arranque_dispositivo (dispositivo_id, version_firmware)
  values (v_otra, 'test-paso3') returning id into v_arr_otra;

  -- Caso 1 — lectura nueva: duplicada = false, con su lectura y sus 7 mediciones.
  begin
    execute $q$select lectura_id, duplicada from public.fn_registrar_telemetria(
        p_cultivo_id => $1, p_dispositivo_id => $2, p_arranque_id => $3, p_seq => 0,
        p_ts => 1793000000, p_motivo => 'programada',
        p_humedad => 68, p_temperatura => 22.5, p_ph => 6.4, p_conductividad => 1.2,
        p_n => 25, p_p => 40, p_k => 60)$q$
      into v_id, v_dup using v_cultivo, v_disp, v_arr;
    execute 'select count(*) from public.lectura_sensores where lectura_id = $1' into v_n using v_id;
    if v_id is not null and v_dup is false and v_n = 7 then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "lectura nueva": lectura_id %s, duplicada %s, %s mediciones (esperaba un id, false y 7)', v_id, v_dup, v_n));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "lectura nueva": ' || sqlerrm);
  end;

  -- Caso 2 — el mismo DNI otra vez: SIN error, la misma lectura, duplicada = true,
  -- y no se guarda nada (ni los valores nuevos: se manda humedad 10 a propósito).
  begin
    execute $q$select lectura_id, duplicada from public.fn_registrar_telemetria(
        p_cultivo_id => $1, p_dispositivo_id => $2, p_arranque_id => $3, p_seq => 0,
        p_ts => 1793000000, p_motivo => 'programada', p_humedad => 10)$q$
      into v_id2, v_dup using v_cultivo, v_disp, v_arr;
    execute 'select count(*) from public.lectura where arranque_id = $1' into v_n using v_arr;
    execute 'select count(*) from public.lectura_sensores s join public.lectura l on l.id = s.lectura_id
             where l.arranque_id = $1' into v_m using v_arr;
    execute $q$select s.valor from public.lectura_sensores s join public.tipos_metricas tm on tm.id = s.metrica_id
                where s.lectura_id = $1 and tm.nombre = 'Humedad'$q$ into v_valor using v_id;
    if v_id2 = v_id and v_dup is true and v_n = 1 and v_m = 7 and v_valor = 68 then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "reintento": lectura_id %s (la primera era %s), duplicada %s, %s lecturas, %s mediciones, humedad %s (esperaba la misma, true, 1, 7 y 68)',
        v_id2, v_id, v_dup, v_n, v_m, v_valor));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "reintento": ' || sqlerrm);
  end;

  -- Caso 3 — otra seq del mismo arranque: es otra lectura, no un duplicado.
  begin
    execute $q$select lectura_id, duplicada from public.fn_registrar_telemetria(
        p_cultivo_id => $1, p_dispositivo_id => $2, p_arranque_id => $3, p_seq => 1,
        p_ts => null, p_motivo => 'programada')$q$
      into v_id2, v_dup using v_cultivo, v_disp, v_arr;
    if v_id2 is not null and v_id2 <> v_id and v_dup is false then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "otra seq": lectura_id %s, duplicada %s (esperaba otro id y false)', v_id2, v_dup));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "otra seq": ' || sqlerrm);
  end;

  -- Caso 4 — un arranque de OTRA placa sigue cortando: no se perdona como duplicado.
  begin
    begin
      perform public.fn_registrar_telemetria(
        p_cultivo_id => v_cultivo, p_dispositivo_id => v_disp, p_arranque_id => v_arr_otra,
        p_seq => 0, p_motivo => 'programada', p_humedad => 68);
      v_fallas := array_append(v_fallas, 'caso "arranque de otra placa": la base lo ACEPTÓ');
    exception when foreign_key_violation then
      v_ok := v_ok + 1;
    end;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "arranque de otra placa": ' || sqlerrm);
  end;

  -- Caso 5 — un motivo inválido sigue cortando.
  begin
    begin
      perform public.fn_registrar_telemetria(
        p_cultivo_id => v_cultivo, p_dispositivo_id => v_disp, p_arranque_id => v_arr,
        p_seq => 2, p_motivo => 'cualquiera', p_humedad => 68);
      v_fallas := array_append(v_fallas, 'caso "motivo inválido": la base lo ACEPTÓ');
    exception when check_violation then
      v_ok := v_ok + 1;
    end;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "motivo inválido": ' || sqlerrm);
  end;

  -- Caso 6 — sin DNI (WF1 sin actualizar) sigue cortando con un error que lo dice.
  begin
    begin
      perform public.fn_registrar_telemetria(
        p_cultivo_id => v_cultivo, p_dispositivo_id => v_disp, p_humedad => 68);
      v_fallas := array_append(v_fallas, 'caso "sin DNI": la base ACEPTÓ una lectura sin arranque ni seq');
    exception when raise_exception then
      if sqlerrm like '%faltan p_arranque_id%' then
        v_ok := v_ok + 1;
      else
        v_fallas := array_append(v_fallas, 'caso "sin DNI": cortó con otro mensaje: ' || sqlerrm);
      end if;
    end;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "sin DNI": ' || sqlerrm);
  end;

  -- Caso 7 — permisos: la función sigue cerrada para anon y authenticated.
  begin
    if not has_function_privilege('anon',
         'public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text, double precision, '
         'double precision, double precision, double precision, double precision, double precision, '
         'double precision)', 'execute')
       and not has_function_privilege('authenticated',
         'public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text, double precision, '
         'double precision, double precision, double precision, double precision, double precision, '
         'double precision)', 'execute')
       and has_function_privilege('service_role',
         'public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text, double precision, '
         'double precision, double precision, double precision, double precision, double precision, '
         'double precision)', 'execute') then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, 'caso "permisos": anon o authenticated pueden ejecutarla, o service_role no');
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "permisos": ' || sqlerrm);
  end;

  -- Caso 8 — la puerta, placa con cultivo y arranque propio: válida, sin errores.
  begin
    select valido, errores into v_valido, v_errores from public.fn_verificar_arranque(v_mac, v_arr);
    if v_valido is true and cardinality(v_errores) = 0 then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format('caso "puerta, placa sana": valido %s, errores %s', v_valido, v_errores));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "puerta, placa sana": ' || sqlerrm);
  end;

  -- Caso 9 — la puerta, placa registrada SIN cultivo activo: rechazada, y lo dice.
  begin
    select valido, errores into v_valido, v_errores from public.fn_verificar_arranque(v_mac_sin, v_arr_otra);
    if v_valido is false and cardinality(v_errores) = 1 and v_errores[1] like '%cultivo activo%' then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format('caso "puerta, sin cultivo": valido %s, errores %s', v_valido, v_errores));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "puerta, sin cultivo": ' || sqlerrm);
  end;

  -- Caso 10 — la puerta sigue distinguiendo los otros dos rechazos, una fila cada uno.
  begin
    select count(*), bool_or(valido), max(errores[1]) into v_n, v_valido, v_texto
    from public.fn_verificar_arranque('00:00:00:00:00:02', v_arr);
    select count(*), max(errores[1]) into v_m, v_texto2
    from public.fn_verificar_arranque(v_mac, v_arr_otra);
    if v_n = 1 and v_valido is false and v_texto like 'dispositivo_mac: no corresponde%'
       and v_m = 1 and v_texto2 like 'arranque_id:%' then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format('caso "puerta, otros rechazos": %s filas, valido %s, error %s; %s filas, error %s', v_n, v_valido, v_texto, v_m, v_texto2));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "puerta, otros rechazos": ' || sqlerrm);
  end;

  if array_length(v_fallas, 1) > 0 then
    raise exception 'TEST FALLÓ (% bien): %', v_ok, array_to_string(v_fallas, ' | ');
  end if;
  raise exception 'TEST OK: % de 10. Todo revertido.', v_ok;
end $$;


-- ============================================================================
-- REVERSO — solo si hubiera que deshacer el BLOQUE 1.
-- OJO: con la función vieja, un reintento vuelve a dar error (WF1 responde 500).
-- ============================================================================
-- begin;
-- drop function public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text,
--   double precision, double precision, double precision, double precision, double precision,
--   double precision, double precision);
-- create function public.fn_registrar_telemetria(
--   p_cultivo_id uuid, p_dispositivo_id uuid, p_arranque_id bigint default null,
--   p_seq bigint default null, p_ts bigint default null, p_motivo text default null,
--   p_humedad double precision default null, p_ph double precision default null,
--   p_n double precision default null, p_p double precision default null, p_k double precision default null,
--   p_temperatura double precision default null, p_conductividad double precision default null)
-- returns table (lectura_id bigint)
-- language plpgsql set search_path to 'public'
-- as $function$
-- declare
--   v_lectura_id bigint;
--   v_existente  bigint;
-- begin
--   if p_arranque_id is null or p_seq is null or p_motivo is null then
--     raise exception 'fn_registrar_telemetria: faltan p_arranque_id, p_seq o p_motivo. Desde el contrato v1, paso 4, cada lectura se guarda con su DNI: falta actualizar Consolidar datos en WF1.';
--   end if;
--   begin
--     insert into public.lectura (dispositivo_id, cultivo_id, arranque_id, seq, ts_dispositivo, motivo)
--     values (p_dispositivo_id, p_cultivo_id, p_arranque_id, p_seq, p_ts, p_motivo)
--     returning id into v_lectura_id;
--   exception when unique_violation then
--     select l.id into v_existente from public.lectura l
--     where l.arranque_id = p_arranque_id and l.seq = p_seq;
--     raise exception 'Lectura duplicada: el arranque % ya tiene la seq % (lectura %). Es un reintento de la placa: no se guarda ni se evalúa de nuevo.',
--                     p_arranque_id, p_seq, v_existente
--       using errcode = 'unique_violation';
--   end;
--   insert into public.lectura_sensores (lectura_id, cultivo_id, dispositivo_id, metrica_id, valor)
--   select v_lectura_id, p_cultivo_id, p_dispositivo_id, tm.id, v.valor
--   from (values ('Humedad', p_humedad), ('Temperatura', p_temperatura), ('pH', p_ph),
--                ('Conductividad', p_conductividad), ('Nitrógeno', p_n), ('Fósforo', p_p),
--                ('Potasio', p_k)) as v(nombre, valor)
--   join public.tipos_metricas tm on tm.nombre = v.nombre
--   where v.valor is not null;
--   return query select v_lectura_id;
-- end;
-- $function$;
-- revoke all on function public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text,
--   double precision, double precision, double precision, double precision, double precision,
--   double precision, double precision) from public, anon, authenticated;
-- grant execute on function public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text,
--   double precision, double precision, double precision, double precision, double precision,
--   double precision, double precision) to service_role;
-- create or replace function public.fn_verificar_arranque(p_mac text, p_arranque_id bigint)
-- returns table (valido boolean, errores text[])
-- language sql stable set search_path = public, pg_temp
-- as $$
--   select (d.id is not null and a.id is not null),
--          case
--            when d.id is null then
--              array['dispositivo_mac: no corresponde a ningún dispositivo registrado']
--            when a.id is null then
--              array['arranque_id: no fue asignado a este dispositivo (pedir uno en /webhook/arranque)']
--            else array[]::text[]
--          end
--     from (select 1) as una_fila
--     left join public.dispositivo d on d.mac_address = p_mac
--     left join public.arranque_dispositivo a on a.id = p_arranque_id and a.dispositivo_id = d.id;
-- $$;
-- commit;
-- notify pgrst, 'reload schema';

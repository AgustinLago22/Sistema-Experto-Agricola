-- ============================================================================
-- Sesión 21 · Contrato v1, paso 4 (16.47) — Cada lectura con su DNI y su hora
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 03/11/2026 contra el estado verificado ese día por MCP.
--
-- QUÉ RESUELVE (la parte de la base)
--   Hoy una lectura no existe como cosa: son 5 a 7 filas sueltas en
--   `lectura_sensores` con la misma hora. La placa manda `arranque_id`, `seq`,
--   `ts` y `motivo`, la puerta de WF1 los valida, y se pierden. Consecuencias:
--   - Un reintento (la placa no recibió la respuesta y manda la misma lectura)
--     se guarda dos veces, y se evalúa dos veces: con humedad 55, dos Telegram
--     y dos pedidos de riego.
--   - La hora de medición no se guarda: solo la de llegada.
--   - Una lectura con las 7 en null no deja ningún rastro.
--
-- LO QUE HACE
--   1. Tabla nueva `lectura`: una fila por lectura recibida, con su DNI
--      (`arranque_id`, `seq`), la hora de la placa (`ts_dispositivo`, en
--      segundos Unix, tal como llegó), la de recepción y el motivo.
--      - `unique (arranque_id, seq)`: el mismo DNI no entra dos veces.
--      - FK (arranque_id, dispositivo_id) → arranque_dispositivo: el arranque
--        tiene que ser DE ESA placa. Hoy lo verifica la puerta; con esto la
--        base lo hace imposible. Para eso, `arranque_dispositivo` necesita un
--        unique (id, dispositivo_id) (redundante con la PK, pero es lo que pide
--        una FK de dos columnas).
--      - RLS encendido y sin permisos para anon ni authenticated, como las
--        tablas del arranque (sesión 17).
--   2. `lectura_sensores.lectura_id`: cada medición apunta a su lectura.
--      - Las 359 filas viejas quedan en null: no se reparan retroactivamente.
--      - Una regla `NOT VALID` exige lectura_id en las filas NUEVAS sin revisar
--        las viejas: una medición suelta ya no puede entrar.
--      - `unique (lectura_id, metrica_id)`: una lectura no puede tener dos
--        humedades. Sirve también de índice para buscar por lectura.
--   3. `fn_registrar_telemetria` crea la lectura y sus mediciones en una sola
--      transacción, y devuelve `lectura_id`.
--      - Sin arranque_id, seq o motivo, corta con un error que lo dice (un WF1
--        sin actualizar falla fuerte, no guarda una lectura sin DNI).
--      - Un DNI repetido corta con "Lectura duplicada", código 23505 (la API
--        de Supabase responde 409). WF1 se detiene ahí: no avisa ni riega dos
--        veces. Responder "duplicada" limpio, sin error, es el paso 3.
--
-- PERMISOS DE LA FUNCIÓN (cambio, a propósito)
--   Hoy es SECURITY DEFINER y la pueden ejecutar anon y authenticated (B.9).
--   Si se dejara así, cualquiera con la clave pública podría escribir en
--   `lectura` A TRAVÉS de la función, y cerrar la tabla no serviría de nada.
--   Pasa al patrón de las funciones de la sesión 17: sin SECURITY DEFINER y
--   solo para service_role. Verificado el 03/11: la credencial "Sup S" de n8n
--   es service_role (llama a fn_registrar_arranque y fn_verificar_arranque,
--   que solo service_role puede ejecutar).
--
-- QUÉ NO CAMBIA
--   - Las vistas y el Motor siguen usando la hora de recepción
--     (`lectura_sensores.fecha_hora`): ninguna decisión cambia.
--   - "Hora no confiable" (contrato, sección 4) no se guarda: se deriva de
--     ts_dispositivo (null o más de 5 min adelante de fecha_recepcion).
--
-- LIMPIEZAS FUTURAS
--   Sin cascadas, a propósito (una cascada borra de más sin avisar). Orden:
--   lectura_sensores → lectura → arranque_dispositivo.
--
-- ORDEN
--   BLOQUE 0 (lo corre el agente por MCP) → BLOQUE 3 ANTES (tiene que FALLAR)
--   → BLOQUE 1 → BLOQUE 3 DESPUÉS (tiene que dar TEST OK) → BLOQUE 2 (MCP).
--   Después, WF1 (JSON aparte). ENTRE EL BLOQUE 1 Y EL WF1 NUEVO NO MANDAR
--   LECTURAS: el WF1 de hoy no manda el DNI y la base la rechaza (con un error
--   que lo dice, pero la lectura se pierde).
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo (solo lectura).
-- Esperado: no existe `lectura`; lectura_sensores sin lectura_id; la función
-- con 9 parámetros, SECURITY DEFINER.
-- Verificado por MCP el 03/11: así, con 359 filas en lectura_sensores.
-- ============================================================================
select to_regclass('public.lectura') as tabla_lectura,
       exists (select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'lectura_sensores'
                 and column_name = 'lectura_id') as tiene_lectura_id,
       (select count(*) from public.lectura_sensores) as filas_lectura_sensores;

select p.oid::regprocedure as firma, p.prosecdef, p.proacl
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fn_registrar_telemetria';


-- ============================================================================
-- BLOQUE 1 — El cambio. Se pega entero, una sola vez.
-- ============================================================================
begin;

-- 1. El arranque tiene que ser de esa placa: la FK de dos columnas lo necesita.
alter table public.arranque_dispositivo
  add constraint arranque_dispositivo_id_dispositivo_key unique (id, dispositivo_id);

-- 2. La lectura.
create table public.lectura (
  id               bigint generated always as identity primary key,
  dispositivo_id   uuid        not null,
  cultivo_id       uuid        not null references public.cultivo (id),
  arranque_id      bigint      not null,
  seq              bigint      not null check (seq >= 0),
  ts_dispositivo   bigint      check (ts_dispositivo >= 0),
  fecha_recepcion  timestamptz not null default now(),
  motivo           text        not null check (motivo in ('programada', 'recheck')),
  constraint lectura_dni_unico unique (arranque_id, seq),
  constraint lectura_arranque_de_la_placa foreign key (arranque_id, dispositivo_id)
    references public.arranque_dispositivo (id, dispositivo_id)
);

comment on table public.lectura is
  'Una fila por lectura recibida (contrato v1, paso 4, 16.47). DNI = (arranque_id, seq). '
  'ts_dispositivo: hora de la placa en segundos Unix, tal como llegó (null = la placa no tiene hora).';

alter table public.lectura enable row level security;
revoke all on public.lectura from anon, authenticated;
revoke all on sequence public.lectura_id_seq from anon, authenticated;
grant select, insert on public.lectura to service_role;

-- 3. Cada medición apunta a su lectura.
alter table public.lectura_sensores
  add column lectura_id bigint references public.lectura (id);

alter table public.lectura_sensores
  add constraint lectura_sensores_una_por_metrica unique (lectura_id, metrica_id);

-- NOT VALID: se exige en cada fila nueva, sin revisar las viejas (que quedan en null).
alter table public.lectura_sensores
  add constraint lectura_sensores_con_lectura check (lectura_id is not null) not valid;

-- 4. La función: crea la lectura y sus mediciones, y devuelve lectura_id.
drop function public.fn_registrar_telemetria(uuid, uuid, double precision, double precision,
  double precision, double precision, double precision, double precision, double precision);

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
returns table (lectura_id bigint)
language plpgsql
set search_path to 'public'
as $function$
declare
  v_lectura_id bigint;
  v_existente  bigint;
begin
  if p_arranque_id is null or p_seq is null or p_motivo is null then
    raise exception 'fn_registrar_telemetria: faltan p_arranque_id, p_seq o p_motivo. Desde el contrato v1, paso 4, cada lectura se guarda con su DNI: falta actualizar Consolidar datos en WF1.';
  end if;

  begin
    insert into public.lectura (dispositivo_id, cultivo_id, arranque_id, seq, ts_dispositivo, motivo)
    values (p_dispositivo_id, p_cultivo_id, p_arranque_id, p_seq, p_ts, p_motivo)
    returning id into v_lectura_id;
  exception when unique_violation then
    select l.id into v_existente
    from public.lectura l
    where l.arranque_id = p_arranque_id and l.seq = p_seq;
    raise exception 'Lectura duplicada: el arranque % ya tiene la seq % (lectura %). Es un reintento de la placa: no se guarda ni se evalúa de nuevo.',
                    p_arranque_id, p_seq, v_existente
      using errcode = 'unique_violation';
  end;

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

  return query select v_lectura_id;
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
  'no midió) en una transacción, y devuelve lectura_id. DNI repetido: error 23505 "Lectura duplicada". '
  'Contrato v1, pasos 4 y 5 (16.47, 16.48). Solo service_role.';

commit;

notify pgrst, 'reload schema';


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura; la corre el agente por MCP).
-- Esperado: la tabla con RLS y sin anon/authenticated; las reglas nuevas; la
-- función con 13 parámetros, sin SECURITY DEFINER y solo para service_role.
-- ============================================================================
select c.relname, c.relrowsecurity, c.relacl
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname in ('lectura', 'lectura_id_seq');

select conrelid::regclass as tabla, conname, convalidated, pg_get_constraintdef(oid) as regla
from pg_constraint
where conrelid in ('public.lectura'::regclass, 'public.lectura_sensores'::regclass,
                   'public.arranque_dispositivo'::regclass)
order by 1, 2;

select p.oid::regprocedure as firma, p.prosecdef, p.proacl, pg_get_function_result(p.oid) as devuelve
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fn_registrar_telemetria';


-- ============================================================================
-- BLOQUE 3 — Test que se deshace solo. Se pega entero.
-- Crea un arranque propio para la placa de demo y una placa falsa con su
-- arranque (todo se revierte). Termina SIEMPRE con un error a propósito:
--   "TEST OK: ..."     → la base cumple el paso 4.
--   "TEST FALLÓ: ..."  → la lista de lo que no funcionó.
-- Correrlo ANTES del BLOQUE 1: tiene que dar TEST FALLÓ (0 bien). Si da OK,
-- el test no prueba nada.
-- Deja huecos en los id de lectura_sensores, arranque_dispositivo (y de
-- lectura, después del cambio): son inocuos.
-- ============================================================================
do $$
declare
  v_disp     uuid;
  v_cultivo  uuid;
  v_arr      bigint;   -- arranque de la placa de demo
  v_arr_otra bigint;   -- arranque de otra placa
  v_otra     uuid;
  v_id       bigint;
  v_n        int;
  v_m        int;
  v_fila     record;
  v_fallas   text[] := '{}';
  v_ok       int := 0;
begin
  select dispositivo_id, cultivo_id into v_disp, v_cultivo
  from public.vista_cultivos_activos
  where dispositivo_mac = '24:0A:C4:A1:B2:C3';
  if v_cultivo is null then
    raise exception 'TEST NO CORRIÓ: no encontré el cultivo de demo en la vista.';
  end if;

  insert into public.arranque_dispositivo (dispositivo_id, version_firmware)
  values (v_disp, 'test-paso4') returning id into v_arr;
  insert into public.dispositivo (mac_address) values ('00:00:00:00:00:01') returning id into v_otra;
  insert into public.arranque_dispositivo (dispositivo_id, version_firmware)
  values (v_otra, 'test-paso4') returning id into v_arr_otra;

  -- Caso 1 — lectura completa: devuelve lectura_id, la lectura guarda su DNI,
  -- su hora y su motivo, y las 7 mediciones apuntan a ella.
  begin
    execute $q$select lectura_id from public.fn_registrar_telemetria(
        p_cultivo_id => $1, p_dispositivo_id => $2, p_arranque_id => $3, p_seq => 0,
        p_ts => 1793000000, p_motivo => 'programada',
        p_humedad => 68, p_temperatura => 22.5, p_ph => 6.4, p_conductividad => 1.2,
        p_n => 25, p_p => 40, p_k => 60)$q$
      into v_id using v_cultivo, v_disp, v_arr;
    execute 'select * from public.lectura where id = $1' into v_fila using v_id;
    execute 'select count(*) from public.lectura_sensores where lectura_id = $1' into v_n using v_id;
    if v_id is not null and v_fila.arranque_id = v_arr and v_fila.seq = 0
       and v_fila.ts_dispositivo = 1793000000 and v_fila.motivo = 'programada' and v_n = 7 then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "lectura completa": lectura_id %s, %s mediciones (esperaba un id y 7)', v_id, v_n));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "lectura completa": ' || sqlerrm);
  end;

  -- Caso 2 — el mismo DNI otra vez (reintento): error 23505 "duplicada", y no
  -- se guarda nada más.
  begin
    begin
      execute $q$select lectura_id from public.fn_registrar_telemetria(
          p_cultivo_id => $1, p_dispositivo_id => $2, p_arranque_id => $3, p_seq => 0,
          p_ts => 1793000000, p_motivo => 'programada', p_humedad => 68)$q$
        into v_id using v_cultivo, v_disp, v_arr;
      v_fallas := array_append(v_fallas, 'caso "reintento": la base ACEPTÓ el mismo DNI dos veces');
    exception when unique_violation then
      execute 'select count(*) from public.lectura where arranque_id = $1' into v_n using v_arr;
      execute 'select count(*) from public.lectura_sensores s join public.lectura l on l.id = s.lectura_id
               where l.arranque_id = $1' into v_m using v_arr;
      if sqlerrm like 'Lectura duplicada%' and v_n = 1 and v_m = 7 then
        v_ok := v_ok + 1;
      else
        v_fallas := array_append(v_fallas, format(
          'caso "reintento": %s lecturas y %s mediciones (esperaba 1 y 7); mensaje: %s', v_n, v_m, sqlerrm));
      end if;
    end;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "reintento": ' || sqlerrm);
  end;

  -- Caso 3 — todo sin dato y sin hora: la lectura queda registrada, sin mediciones.
  begin
    execute $q$select lectura_id from public.fn_registrar_telemetria(
        p_cultivo_id => $1, p_dispositivo_id => $2, p_arranque_id => $3, p_seq => 1,
        p_ts => null, p_motivo => 'programada')$q$
      into v_id using v_cultivo, v_disp, v_arr;
    execute 'select * from public.lectura where id = $1' into v_fila using v_id;
    execute 'select count(*) from public.lectura_sensores where lectura_id = $1' into v_n using v_id;
    if v_id is not null and v_fila.ts_dispositivo is null and v_n = 0 then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "todo sin dato": lectura_id %s, %s mediciones (esperaba un id y 0)', v_id, v_n));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "todo sin dato": ' || sqlerrm);
  end;

  -- Caso 4 — un arranque de OTRA placa: la base lo rechaza.
  begin
    begin
      execute $q$select lectura_id from public.fn_registrar_telemetria(
          p_cultivo_id => $1, p_dispositivo_id => $2, p_arranque_id => $3, p_seq => 0,
          p_ts => null, p_motivo => 'programada', p_humedad => 68)$q$
        into v_id using v_cultivo, v_disp, v_arr_otra;
      v_fallas := array_append(v_fallas, 'caso "arranque de otra placa": la base lo ACEPTÓ');
    exception when foreign_key_violation then
      v_ok := v_ok + 1;
    end;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "arranque de otra placa": ' || sqlerrm);
  end;

  -- Caso 5 — la llamada de hoy, sin DNI (WF1 sin actualizar): corta con un error que lo dice.
  begin
    begin
      perform public.fn_registrar_telemetria(
        p_cultivo_id => v_cultivo, p_dispositivo_id => v_disp,
        p_humedad => 68, p_ph => 6.4, p_n => 25, p_p => 40, p_k => 60);
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

  -- Caso 6 — una medición suelta, sin lectura: la base la rechaza.
  begin
    begin
      insert into public.lectura_sensores (cultivo_id, dispositivo_id, metrica_id, valor)
      values (v_cultivo, v_disp, 1, 68);
      v_fallas := array_append(v_fallas, 'caso "medición suelta": la base ACEPTÓ una medición sin lectura');
    exception when check_violation then
      v_ok := v_ok + 1;
    end;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "medición suelta": ' || sqlerrm);
  end;

  -- Caso 7 — permisos: anon no puede ejecutar la función ni escribir en lectura.
  begin
    if not has_function_privilege('anon',
         'public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text, double precision, '
         'double precision, double precision, double precision, double precision, double precision, '
         'double precision)', 'execute')
       and not has_table_privilege('anon', 'public.lectura', 'insert') then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, 'caso "permisos": anon puede ejecutar la función o escribir en lectura');
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "permisos": ' || sqlerrm);
  end;

  if array_length(v_fallas, 1) > 0 then
    raise exception 'TEST FALLÓ (% bien): %', v_ok, array_to_string(v_fallas, ' | ');
  end if;
  raise exception 'TEST OK: % de 7. Todo revertido.', v_ok;
end $$;


-- ============================================================================
-- REVERSO — solo si hubiera que deshacer el BLOQUE 1.
-- OJO: antes, WF1 tiene que volver a la versión del paso 5 (sin el DNI).
-- Se pierden los DNI y las horas de las lecturas guardadas desde el cambio
-- (las mediciones quedan).
-- ============================================================================
-- begin;
-- drop function public.fn_registrar_telemetria(uuid, uuid, bigint, bigint, bigint, text,
--   double precision, double precision, double precision, double precision, double precision,
--   double precision, double precision);
-- alter table public.lectura_sensores drop constraint lectura_sensores_con_lectura;
-- alter table public.lectura_sensores drop constraint lectura_sensores_una_por_metrica;
-- alter table public.lectura_sensores drop column lectura_id;
-- drop table public.lectura;
-- alter table public.arranque_dispositivo drop constraint arranque_dispositivo_id_dispositivo_key;
-- create function public.fn_registrar_telemetria(p_cultivo_id uuid, p_dispositivo_id uuid,
--   p_humedad double precision default null, p_ph double precision default null,
--   p_n double precision default null, p_p double precision default null, p_k double precision default null,
--   p_temperatura double precision default null, p_conductividad double precision default null)
-- returns void language plpgsql security definer set search_path to 'public'
-- as $function$
-- begin
--   insert into public.lectura_sensores (cultivo_id, dispositivo_id, metrica_id, valor)
--   select p_cultivo_id, p_dispositivo_id, tm.id, v.valor
--   from (values ('Humedad', p_humedad), ('Temperatura', p_temperatura), ('pH', p_ph),
--                ('Conductividad', p_conductividad), ('Nitrógeno', p_n), ('Fósforo', p_p),
--                ('Potasio', p_k)) as v(nombre, valor)
--   join public.tipos_metricas tm on tm.nombre = v.nombre
--   where v.valor is not null;
-- end;
-- $function$;
-- grant execute on function public.fn_registrar_telemetria(uuid, uuid, double precision, double precision,
--   double precision, double precision, double precision, double precision, double precision)
--   to anon, authenticated, service_role;
-- commit;
-- notify pgrst, 'reload schema';

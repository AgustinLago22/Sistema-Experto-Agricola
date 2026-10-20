-- ============================================================================
-- Sesión 17 · Contrato de telemetría v1, pasos 1 y 2
--             1 = el arranque lo asigna el servidor (/webhook/arranque, WF7)
--             2 = revisión en la puerta de WF1 (cierra 16.52)
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 19/10/2026 contra el estado verificado ese día.
-- Contrato: docs/contrato_telemetria.md · Plan: docs/implementation_plan.md, v61.
--
-- QUÉ CAMBIA
--   1. Tabla `arranque_dispositivo` (nueva). Una fila por encendido de la placa.
--      Su `id` ES el `arranque_id` del contrato:
--        · GENERATED ALWAYS AS IDENTITY → nadie lo elige desde afuera;
--        · PRIMARY KEY                  → no puede repetirse, aunque alguien
--                                         reinicie el contador a mano.
--      El contador da números que solo suben; la clave primaria es la garantía.
--      Es la regla de 16.25: un identificador único se garantiza con un registro
--      que lo asigne, no con una convención.
--   2. `fn_registrar_arranque(mac, fw)` (nueva). La llama WF7. MAC desconocida
--      no es un error: devuelve `registrado = false` y WF7 responde 404.
--   3. `fn_verificar_arranque(mac, arranque_id)` (nueva). La llama la puerta de
--      WF1. Devuelve SIEMPRE exactamente una fila (`valido`, `errores`): un
--      nodo de n8n que recibe cero filas corta la rama en silencio (regla 1).
--   4. `vista_ultimo_arranque` (nueva). El firmware vigente de cada placa,
--      DERIVADO del último arranque.
--   5. Se BORRA `dispositivo.version_firmware`. Decisión del 19/10 (regla 3 de
--      la sesión 14: no se mantiene sincronizado a mano lo que se puede
--      derivar). Verificado antes de escribir esto: ninguna vista, ninguna
--      función y ningún workflow la lee. Dejarla sin escribir la convertía en
--      una columna que miente ("v1.0.0" con la placa corriendo otra versión);
--      escribirla en cada arranque era mantener dos fuentes de la misma verdad.
--   6. Tabla `lectura_rechazada` + `fn_registrar_rechazo` (nuevas). El contrato
--      dice "el rechazo queda registrado": un fallo manejado tiene que seguir
--      siendo contado. Se guarda el cuerpo SIN la foto.
--
-- PERMISOS (mismo criterio que `evaluacion_fenologica`, 16.25)
--   Tablas y vista: RLS encendido, sin políticas, sin permisos para anon ni
--   authenticated. La vista además con `security_invoker`: una vista común
--   corre con los permisos de su dueño y salteaba RLS (familia de 16.13).
--   Funciones: solo service_role (la credencial `Sup S` de n8n). Sin
--   SECURITY DEFINER (B.9).
--
-- ORDEN DE APLICACIÓN (cada paso deja el sistema andando)
--   Antes de todo: el test T0 de 16.52 (SQL/sesion17_test_puerta_en_vivo.sql),
--   con WF1 todavía sin tocar.
--   BLOQUE 1 → BLOQUE 2 → BLOQUE 3 → importar y activar WF7 → cambios de WF1.
--   WF1 sigue andando con el BLOQUE 1 aplicado: no lee nada de lo que cambia.
--   BLOQUE R es el reverso: solo si hay que volver atrás (primero revertir n8n).
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo, registrado el 19/10 (no hace falta correrlo)
-- ============================================================================
-- dispositivo: 1 fila. id 3581a79d-75a0-4116-b924-13444b4bdb85,
--   mac '24:0A:C4:A1:B2:C3', version_firmware 'v1.0.0' (varchar(20), cargado
--   a mano), tiene_actuador_riego true, caudal_bomba_ml_s 40.
--   Restricciones: PRIMARY KEY (id), UNIQUE (mac_address).
-- Nadie lee version_firmware: 0 vistas, 0 funciones, 0 workflows (grep de
--   WORKFLOWS/*.json y pg_get_viewdef / pg_get_functiondef).
-- evento_riego 8 (max id 10) · comando_dispositivo 8 (max id 10) ·
--   lectura_sensores 230 (max id 289).
-- No existen: arranque_dispositivo, lectura_rechazada, vista_ultimo_arranque,
--   fn_registrar_arranque, fn_verificar_arranque, fn_registrar_rechazo.


-- ============================================================================
-- BLOQUE 1 — Aplicar (todo o nada)
-- ============================================================================
begin;

-- 1a · Arranques -----------------------------------------------------------
create table public.arranque_dispositivo (
  id               bigint generated always as identity primary key,
  dispositivo_id   uuid        not null references public.dispositivo (id),
  version_firmware varchar(20) not null
                   check (length(btrim(version_firmware)) > 0),
  fecha_hora       timestamptz not null default now()
);

comment on table public.arranque_dispositivo is
  'Un encendido de la placa. id = arranque_id del contrato de telemetría v1: lo asigna la base, solo sube, no se repite (PK).';
comment on column public.arranque_dispositivo.version_firmware is
  'Firmware informado al arrancar (campo fw del contrato). El vigente de cada placa se deriva en vista_ultimo_arranque.';

-- Sirve a la vista (último arranque por placa). La verificación usa la PK.
create index arranque_dispositivo_disp_id_idx
  on public.arranque_dispositivo (dispositivo_id, id desc);

alter table public.arranque_dispositivo enable row level security;
revoke all on public.arranque_dispositivo from anon, authenticated;
revoke all on sequence public.arranque_dispositivo_id_seq from anon, authenticated;


-- 1b · Lecturas rechazadas -------------------------------------------------
create table public.lectura_rechazada (
  id              bigint generated always as identity primary key,
  fecha_hora      timestamptz not null default now(),
  -- Tal como llegó. Sin FK a dispositivo a propósito: puede no ser una MAC
  -- válida, y justamente por eso se rechazó.
  dispositivo_mac varchar(64),
  errores         text[]      not null check (cardinality(errores) > 0),
  -- El pedido SIN la foto (una foto pesa decenas de KB y no explica el rechazo).
  cuerpo          jsonb       not null
);

comment on table public.lectura_rechazada is
  'Lecturas que no cumplieron el contrato de telemetría v1 y se respondieron con 400. Las escribe WF1 (Registrar Rechazo).';

create index lectura_rechazada_fecha_idx on public.lectura_rechazada (fecha_hora desc);

alter table public.lectura_rechazada enable row level security;
revoke all on public.lectura_rechazada from anon, authenticated;
revoke all on sequence public.lectura_rechazada_id_seq from anon, authenticated;


-- 1c · fn_registrar_arranque (WF7) ------------------------------------------
create function public.fn_registrar_arranque(p_mac text, p_fw text)
returns table (registrado boolean, motivo text, arranque_id bigint)
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_disp uuid;
  v_id   bigint;
begin
  -- La MAC llega normalizada por WF7 (mayúsculas, sin espacios).
  select d.id into v_disp
    from public.dispositivo d
   where d.mac_address = p_mac;

  -- MAC desconocida: es una respuesta, no un error del sistema (404 en WF7).
  if v_disp is null then
    return query select false, 'mac_desconocida'::text, null::bigint;
    return;
  end if;

  -- Un firmware vacío o de más de 20 caracteres lo frena la tabla (CHECK y
  -- varchar(20)), aunque WF7 no lo haya frenado antes.
  insert into public.arranque_dispositivo (dispositivo_id, version_firmware)
  values (v_disp, btrim(p_fw))
  returning id into v_id;

  return query select true, 'registrado'::text, v_id;
end;
$$;

revoke all on function public.fn_registrar_arranque(text, text) from public, anon, authenticated;
grant execute on function public.fn_registrar_arranque(text, text) to service_role;


-- 1d · fn_verificar_arranque (puerta de WF1) --------------------------------
-- Acepta CUALQUIER arranque que se le haya dado a esa placa, no solo el último:
-- una lectura medida antes de un reinicio y reintentada después sigue siendo
-- válida (contrato, regla 4: el reintento va idéntico).
create function public.fn_verificar_arranque(p_mac text, p_arranque_id bigint)
returns table (valido boolean, errores text[])
language sql
stable
set search_path = public, pg_temp
as $$
  select (d.id is not null and a.id is not null),
         case
           when d.id is null then
             array['dispositivo_mac: no corresponde a ningún dispositivo registrado']
           when a.id is null then
             array['arranque_id: no fue asignado a este dispositivo (pedir uno en /webhook/arranque)']
           else
             array[]::text[]
         end
    from (select 1) as una_fila          -- garantiza exactamente una fila
    left join public.dispositivo d
           on d.mac_address = p_mac
    left join public.arranque_dispositivo a
           on a.id = p_arranque_id
          and a.dispositivo_id = d.id;
$$;

revoke all on function public.fn_verificar_arranque(text, bigint) from public, anon, authenticated;
grant execute on function public.fn_verificar_arranque(text, bigint) to service_role;


-- 1e · fn_registrar_rechazo (WF1) -------------------------------------------
create function public.fn_registrar_rechazo(p_mac text, p_errores text[], p_cuerpo jsonb)
returns table (rechazo_id bigint)
language sql
set search_path = public, pg_temp
as $$
  insert into public.lectura_rechazada (dispositivo_mac, errores, cuerpo)
  values (left(p_mac, 64), p_errores, coalesce(p_cuerpo, '{}'::jsonb))
  returning id;
$$;

revoke all on function public.fn_registrar_rechazo(text, text[], jsonb) from public, anon, authenticated;
grant execute on function public.fn_registrar_rechazo(text, text[], jsonb) to service_role;


-- 1f · El firmware vigente, derivado ----------------------------------------
-- Ordena por id y no por fecha: el id es estrictamente creciente, la fecha
-- puede empatar.
create view public.vista_ultimo_arranque
with (security_invoker = true) as
select distinct on (a.dispositivo_id)
       a.dispositivo_id,
       d.mac_address,
       a.id            as arranque_id,
       a.version_firmware,
       a.fecha_hora
  from public.arranque_dispositivo a
  join public.dispositivo d on d.id = a.dispositivo_id
 order by a.dispositivo_id, a.id desc;

revoke all on public.vista_ultimo_arranque from anon, authenticated;


-- 1g · Baja de la columna que pasa a derivarse ------------------------------
alter table public.dispositivo drop column version_firmware;

commit;


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura)
-- ============================================================================
-- Esperado: 3 filas, prosecdef = false,
-- ACL = {postgres=X/postgres,service_role=X/postgres}
select p.proname, pg_get_function_result(p.oid) as retorno, p.prosecdef, p.proacl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('fn_registrar_arranque', 'fn_verificar_arranque', 'fn_registrar_rechazo')
 order by 1;

-- Esperado: 3 filas. Las dos tablas con relrowsecurity = true; las tres con
-- ACL {postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres} (sin anon
-- ni authenticated).
select c.relname, c.relkind, c.relrowsecurity, c.relacl
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relname in ('arranque_dispositivo', 'lectura_rechazada', 'vista_ultimo_arranque')
 order by 1;

-- Esperado: version_firmware ya no figura. Conteos: 1 · 0 · 0 · 230 · 8 · 8.
select (select string_agg(column_name, ', ' order by ordinal_position)
          from information_schema.columns
         where table_schema = 'public' and table_name = 'dispositivo') as columnas_dispositivo,
       (select count(*) from dispositivo)          as dispositivos,
       (select count(*) from arranque_dispositivo) as arranques,
       (select count(*) from lectura_rechazada)    as rechazos,
       (select count(*) from lectura_sensores)     as lecturas,
       (select count(*) from evento_riego)         as eventos,
       (select count(*) from comando_dispositivo)  as comandos;


-- ============================================================================
-- BLOQUE 3 — Test en la base. SE DESHACE SOLO.
-- ============================================================================
-- Termina SIEMPRE con un error, a propósito: el error deshace todo lo que el
-- test escribió. Leé el TEXTO del error:
--   'TEST OK: ...'      → pasó.
--   'TEST FALLÓ: ...'   → no pasó, y dice qué.
--   'PRECONDICIÓN: ...' → no se pudo probar.
-- Después de correrlo, el BLOQUE 2 tiene que seguir dando 1 · 0 · 0 · 230 · 8 · 8.
-- Ojo: el contador de arranques NO vuelve atrás (los contadores de Postgres
-- no se deshacen con la transacción). El primer arranque real no va a ser el
-- número 1. Es un hueco, y un hueco es inocuo: es la regla 3 del arranque.
-- ============================================================================
do $$
declare
  v_mac   constant text := '24:0A:C4:A1:B2:C3';   -- la placa real
  v_otra  constant text := 'AA:BB:CC:DD:EE:FF';   -- una placa de test
  v_nadie constant text := '11:22:33:44:55:66';   -- una MAC que no existe
  v_disp  uuid;
  v_n     integer;
  r1 record; r2 record; r3 record; v record;
begin
  select id into v_disp from dispositivo where mac_address = v_mac;
  if v_disp is null then
    raise exception 'PRECONDICIÓN: no está el dispositivo %', v_mac;
  end if;
  if exists (select 1 from dispositivo where mac_address in (v_otra, v_nadie)) then
    raise exception 'PRECONDICIÓN: las MAC de test ya existen';
  end if;

  -- T1 · Arranque de una placa conocida: registra y devuelve un número.
  select * into r1 from fn_registrar_arranque(v_mac, '  1.0.0  ');
  if r1.registrado is not true or r1.motivo <> 'registrado' or r1.arranque_id is null then
    raise exception 'TEST FALLÓ (T1): el arranque debía registrarse → %', to_json(r1);
  end if;

  -- T2 · Pedir otra vez da OTRO número, mayor: el contador solo sube.
  select * into r2 from fn_registrar_arranque(v_mac, '1.0.1');
  if r2.registrado is not true or r2.arranque_id <= r1.arranque_id then
    raise exception 'TEST FALLÓ (T2): el segundo arranque debía ser mayor → % y %', to_json(r1), to_json(r2);
  end if;

  -- T3 · El firmware vigente se DERIVA del último arranque; se guarda sin espacios.
  select * into v from vista_ultimo_arranque where mac_address = v_mac;
  if v.arranque_id is distinct from r2.arranque_id or v.version_firmware is distinct from '1.0.1' then
    raise exception 'TEST FALLÓ (T3): la vista debía mostrar el arranque % con 1.0.1 → %', r2.arranque_id, to_json(v);
  end if;
  if (select version_firmware from arranque_dispositivo where id = r1.arranque_id) <> '1.0.0' then
    raise exception 'TEST FALLÓ (T3): el firmware debía guardarse sin espacios';
  end if;

  -- T4 · MAC desconocida: responde 'mac_desconocida' y NO crea nada.
  select count(*) into v_n from arranque_dispositivo;
  select * into r3 from fn_registrar_arranque(v_nadie, '1.0.0');
  if r3.registrado is not false or r3.motivo <> 'mac_desconocida' or r3.arranque_id is not null then
    raise exception 'TEST FALLÓ (T4): una MAC desconocida debía devolver mac_desconocida → %', to_json(r3);
  end if;
  if (select count(*) from arranque_dispositivo) <> v_n then
    raise exception 'TEST FALLÓ (T4): se creó un arranque para una MAC desconocida';
  end if;

  -- T5 · Verificar: el último arranque es válido, y el anterior TAMBIÉN
  --      (una lectura reintentada después de un reinicio sigue siendo válida).
  select * into v from fn_verificar_arranque(v_mac, r2.arranque_id);
  if v.valido is not true or cardinality(v.errores) <> 0 then
    raise exception 'TEST FALLÓ (T5): el arranque vigente debía ser válido → %', to_json(v);
  end if;
  select * into v from fn_verificar_arranque(v_mac, r1.arranque_id);
  if v.valido is not true then
    raise exception 'TEST FALLÓ (T5): un arranque anterior de la misma placa debía ser válido → %', to_json(v);
  end if;

  -- T6 · Un número que no existe: inválido, con el error de arranque_id.
  select * into v from fn_verificar_arranque(v_mac, r2.arranque_id + 1000000);
  if v.valido is not false or v.errores[1] not like 'arranque_id:%' then
    raise exception 'TEST FALLÓ (T6): un arranque inexistente debía ser inválido → %', to_json(v);
  end if;

  -- T7 · Un número AJENO: existe, pero se le dio a otra placa. Inválido.
  --      (Distinguible de T6 solo si la otra placa tiene arranques de verdad.)
  insert into dispositivo (mac_address, tiene_actuador_riego) values (v_otra, false);
  select * into r3 from fn_registrar_arranque(v_otra, 'test');
  select * into v from fn_verificar_arranque(v_otra, r3.arranque_id);
  if v.valido is not true then
    raise exception 'TEST FALLÓ (T7): la placa de test debía poder usar su propio arranque → %', to_json(v);
  end if;
  select * into v from fn_verificar_arranque(v_mac, r3.arranque_id);
  if v.valido is not false or v.errores[1] not like 'arranque_id:%' then
    raise exception 'TEST FALLÓ (T7): un arranque de OTRA placa debía ser inválido → %', to_json(v);
  end if;

  -- T8 · MAC que no existe: inválido, con el error de dispositivo_mac.
  select * into v from fn_verificar_arranque(v_nadie, r2.arranque_id);
  if v.valido is not false or v.errores[1] not like 'dispositivo_mac:%' then
    raise exception 'TEST FALLÓ (T8): una MAC desconocida debía ser inválida → %', to_json(v);
  end if;

  -- T9 · Siempre UNA fila, aunque no haya nada que encontrar (regla 1 de n8n).
  select count(*) into v_n from fn_verificar_arranque(v_nadie, null);
  if v_n <> 1 then
    raise exception 'TEST FALLÓ (T9): fn_verificar_arranque devolvió % filas; tiene que ser siempre 1', v_n;
  end if;

  -- T10 · El número no lo elige nadie de afuera...
  begin
    insert into arranque_dispositivo (id, dispositivo_id, version_firmware)
    values (999999999, v_disp, 'x');
    raise exception 'TEST FALLÓ (T10): se pudo elegir el arranque_id desde afuera';
  exception when sqlstate '428C9' then null;   -- generated_always
  end;
  -- ...y aunque alguien lo fuerce, no puede repetirse.
  begin
    insert into arranque_dispositivo (id, dispositivo_id, version_firmware)
    overriding system value values (r1.arranque_id, v_disp, 'x');
    raise exception 'TEST FALLÓ (T10): se pudo insertar un arranque_id repetido';
  exception when unique_violation then null;
  end;

  -- T11 · Un firmware vacío lo frena la base, aunque WF7 no lo frene.
  begin
    perform fn_registrar_arranque(v_mac, '   ');
    raise exception 'TEST FALLÓ (T11): se registró un arranque con firmware vacío';
  exception when check_violation then null;
  end;

  -- T12 · Rechazos: se registran, y un rechazo sin errores no se puede registrar.
  select * into v from fn_registrar_rechazo('no-es-una-mac', array['v: falta'], '{"planta":"Tomate"}'::jsonb);
  if v.rechazo_id is null
     or (select errores from lectura_rechazada where id = v.rechazo_id) <> array['v: falta'] then
    raise exception 'TEST FALLÓ (T12): el rechazo no quedó registrado como se mandó';
  end if;
  begin
    perform fn_registrar_rechazo(v_mac, array[]::text[], '{}'::jsonb);
    raise exception 'TEST FALLÓ (T12): se registró un rechazo sin errores';
  exception when check_violation then null;
  end;

  -- T13 · La columna que pasó a derivarse ya no existe.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'dispositivo'
                and column_name = 'version_firmware') then
    raise exception 'TEST FALLÓ (T13): dispositivo.version_firmware sigue existiendo';
  end if;

  raise exception 'TEST OK: T1–T13 pasaron. Este error deshace todo lo que el test escribió.';
end;
$$;


-- ============================================================================
-- BLOQUE R — Reverso. Solo si hay que volver atrás, y DESPUÉS de revertir n8n
--            (WF1 sin la puerta, WF7 desactivado).
-- ============================================================================
-- Se pierden los arranques y los rechazos registrados hasta ese momento.
-- begin;
-- drop view     if exists public.vista_ultimo_arranque;
-- drop function if exists public.fn_verificar_arranque(text, bigint);
-- drop function if exists public.fn_registrar_arranque(text, text);
-- drop function if exists public.fn_registrar_rechazo(text, text[], jsonb);
-- drop table    if exists public.arranque_dispositivo;
-- drop table    if exists public.lectura_rechazada;
-- alter table public.dispositivo add column version_firmware varchar(20);
-- update public.dispositivo set version_firmware = 'v1.0.0'
--  where mac_address = '24:0A:C4:A1:B2:C3';
-- commit;

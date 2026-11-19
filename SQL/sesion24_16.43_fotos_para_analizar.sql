-- ============================================================================
-- Sesión 24 · 16.43 — Análisis de rutina de la foto (WF4 reconvertido)
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 18/11/2026 contra el estado verificado ese día por MCP.
-- BLOQUE 0 verificado por MCP el 18/11: ni la vista ni la columna existen.
-- APLICADO el 18/11/2026 por Agustín: BLOQUE 3 antes → TEST FALLÓ (0 de 16);
-- BLOQUE 1; BLOQUE 3 después → TEST OK: 16 de 16. BLOQUE 2 verificado por MCP
-- (vista con security_invoker y permisos solo de postgres y service_role; el
-- CHECK de origen; vista vacía; el test no dejó filas). El advisor de
-- seguridad no muestra hallazgos nuevos.
-- En vivo el 19/11 con WF2, WF4 y WF6 (plan v77, 16.43).
--
-- QUÉ RESUELVE (la parte de la base)
--   Hoy una foto que llega con la lectura en rango no la analiza nadie
--   (16.43). WF4 pasa a revisar cada 6 h la última foto de cada cultivo y a
--   mandarla a WF2. Esta vista le dice cuáles:
--
--   1. vista_fotos_para_analizar: las filas de vista_estado_cultivo cuya
--      última foto
--        · está en Storage (ultima_foto_fecha no es null),
--        · tiene menos de 48 h: corta los reintentos si Gemini falla
--          (como mucho 8 turnos de WF4) y no analiza fotos que ya no
--          describen a la planta,
--        · tiene más de 10 min: deja terminar a un WF2 que haya disparado
--          una alerta con esa misma foto,
--        · nadie la analizó: no hay fila en seguimiento_fenologico con esa
--          foto (la de una alerta o un /diagnostico también cuenta).
--      Y el cultivo no está en pausa (como WF1: pausa = no avisar).
--      Las columnas son las de vista_estado_cultivo: WF4 arma el pedido a
--      WF2 igual que /diagnostico.
--
--   2. seguimiento_fenologico.origen: quién pidió el diagnóstico ('alerta',
--      'consulta' = /diagnostico, 'proactivo' = WF4). Las filas anteriores
--      quedan en null. Lo escribe WF2.
--
-- POR QUÉ ASÍ
--   · La regla vive en la base y se prueba acá; WF4 solo la lee.
--   · Sin SECURITY DEFINER y solo para service_role, como vista_estado_cultivo
--     (Supabase da permisos a anon y authenticated en cada vista nueva: por
--     eso el REVOKE). security_invoker: lee con los permisos de quien consulta.
--
-- QUÉ NO CAMBIA
--   Ningún dato. La columna nueva admite null, así que WF2 sigue guardando
--   igual hasta que se le agregue el campo. Nadie lee la vista hasta el WF4
--   nuevo.
--
-- ORDEN
--   BLOQUE 0 (MCP) → BLOQUE 3 ANTES (tiene que FALLAR) → BLOQUE 1
--   → BLOQUE 3 DESPUÉS (tiene que dar TEST OK) → BLOQUE 2 (MCP) → WF2 y WF4.
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo (solo lectura).
-- Esperado: la vista no existe y seguimiento_fenologico no tiene `origen`.
-- ============================================================================
select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'vista_fotos_para_analizar';

select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'seguimiento_fenologico' and column_name = 'origen';


-- ============================================================================
-- BLOQUE 1 — El cambio. Se pega entero, una sola vez.
-- ============================================================================
begin;

alter table public.seguimiento_fenologico
  add column origen text
  constraint seguimiento_fenologico_origen_check
  check (origen in ('alerta', 'consulta', 'proactivo'));

comment on column public.seguimiento_fenologico.origen is
  'Quién pidió el diagnóstico: alerta (WF1), consulta (/diagnostico de WF6) o proactivo '
  '(análisis de rutina de WF4). Null en las filas anteriores al 18/11/2026. 16.43.';

create view public.vista_fotos_para_analizar
with (security_invoker = true) as
select e.*
from public.vista_estado_cultivo e
where e.ultima_foto_fecha >  now() - interval '48 hours'
  and e.ultima_foto_fecha <= now() - interval '10 minutes'
  and (e.mantenimiento_hasta is null or e.mantenimiento_hasta <= now())
  and not exists (
    select 1 from public.seguimiento_fenologico s
     where s.cultivo_id = e.cultivo_id
       and s.path_foto  = e.ultima_foto_path
  );

revoke all on public.vista_fotos_para_analizar from anon, authenticated;

comment on view public.vista_fotos_para_analizar is
  'Cultivos activos cuya última foto está en Storage, tiene entre 10 min y 48 h, no se analizó '
  'nunca y el cultivo no está en pausa. La lee WF4 (análisis de rutina). 16.43. Solo service_role.';

commit;

notify pgrst, 'reload schema';


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura; la corre el agente por MCP).
-- Esperado: vista con security_invoker y permisos solo de postgres y
-- service_role; la columna con su CHECK; ninguna fila en la vista (la única
-- foto real es del 04/11 y ya está analizada).
-- ============================================================================
select c.relname, c.reloptions, c.relacl
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'vista_fotos_para_analizar';

select conname, pg_get_constraintdef(oid) from pg_constraint
where conrelid = 'public.seguimiento_fenologico'::regclass and conname like '%origen%';

select cultivo_id, ultima_foto_path, ultima_foto_fecha from public.vista_fotos_para_analizar;


-- ============================================================================
-- BLOQUE 3 — Test que se deshace solo. Se pega entero.
-- Crea un cultivo falso por caso, cada uno con su placa, su foto en Storage
-- (con la fecha que pide el caso) y, si corresponde, un diagnóstico previo.
-- Todo se revierte. Termina SIEMPRE con un error a propósito:
--   "TEST OK: ..."     → la base cumple el diseño.
--   "TEST FALLÓ: ..."  → la lista de lo que no funcionó.
-- Correrlo ANTES del BLOQUE 1: tiene que dar TEST FALLÓ (0 de 16 bien), y
-- cada caso tiene que decir "does not exist" (la vista o la columna). Otro
-- motivo (por ejemplo, que no pudo crear la foto en Storage) quiere decir que
-- el test no está probando lo que debe: avisame antes de seguir.
--
-- Probado el 18/11 en un Postgres local (PGlite) con una copia de las tablas,
-- las tres vistas reales y storage.objects: antes, TEST FALLÓ (0 de 16, todos
-- por "does not exist"); después, TEST OK 16 de 16, sin dejar filas, y otra
-- vez OK al repetirlo. Con 14 defectos metidos a propósito (sin tope de 48 h,
-- tope de 72 o de 24 h, sin margen de 10 min o de 20, sin pausa, pausa
-- vencida tomada como pausa, sin "ya analizada", "ya analizada" por cultivo y
-- no por foto, sin REVOKE, sin security_invoker, sin CHECK, CHECK sin
-- 'proactivo', columnas de menos) el test detectó los 14.
-- Deja huecos en algunos id: son inocuos.
-- ============================================================================
do $$
declare
  v_mac_demo constant text := '24:0A:C4:A1:B2:C3';
  v_demo  record;
  c       record;
  v_i     int := 0;
  v_disp  uuid;
  v_cult  uuid;
  v_path  text;
  v_hay   boolean;
  v_uno   uuid;      -- el cultivo del caso "fresca", para comparar columnas
  v_fallas text[] := '{}';
  v_ok    int := 0;
  v_total int := 0;
begin
  select * into v_demo from public.vista_cultivos_activos where dispositivo_mac = v_mac_demo;
  if v_demo.cultivo_id is null then
    raise exception 'TEST NO CORRIÓ: no encontré el cultivo de la placa de demo.';
  end if;

  -- edad: antigüedad de la foto (null = sin foto). storage: si | no | archivada.
  -- pausa: hasta cuándo, relativo a ahora (null = sin pausa).
  -- analizada: misma (esa foto) | otra (una foto anterior) | null.
  for c in
    select * from (values
      ('fresca',             interval '2 hours',    'si',        null::interval,     null,     true),
      ('ya analizada',       interval '2 hours',    'si',        null,               'misma',  false),
      ('analizada otra',     interval '2 hours',    'si',        null,               'otra',   true),
      ('de 49 h',            interval '49 hours',   'si',        null,               null,     false),
      ('de 47 h',            interval '47 hours',   'si',        null,               null,     true),
      ('de 5 min',           interval '5 minutes',  'si',        null,               null,     false),
      ('de 11 min',          interval '11 minutes', 'si',        null,               null,     true),
      ('en pausa',           interval '2 hours',    'si',        interval '1 hour',  null,     false),
      ('pausa vencida',      interval '2 hours',    'si',        interval '-1 hour', null,     true),
      ('no está en Storage', interval '2 hours',    'no',        null,               null,     false),
      ('archivada',          interval '2 hours',    'archivada', null,               null,     false),
      ('sin foto',           null,                  'no',        null,               null,     false)
    ) as t(nombre, edad, storage, pausa, analizada, esperado)
  loop
    v_i := v_i + 1;
    v_total := v_total + 1;
    begin
      v_path := case when c.edad is null then null else format('test-16.43/caso%s.jpg', v_i) end;

      insert into public.dispositivo (mac_address)
      values (format('00:00:00:00:43:%s', lpad(to_hex(v_i), 2, '0'))) returning id into v_disp;

      insert into public.cultivo (especie_id, etapa_actual_id, dispositivo_id, active,
                                  nombre_personalizado, ultima_foto_path, mantenimiento_hasta)
      select x.especie_id, x.etapa_actual_id, v_disp, true, 'Prueba ' || c.nombre, v_path,
             now() + c.pausa
        from public.cultivo x where x.id = v_demo.cultivo_id
      returning id into v_cult;
      if v_i = 1 then v_uno := v_cult; end if;

      if c.storage in ('si', 'archivada') then
        insert into storage.objects (bucket_id, name, created_at, archived_at)
        values ('fotos-cultivos', v_path, now() - c.edad,
                case when c.storage = 'archivada' then now() end);
      end if;

      if c.analizada is not null then
        insert into public.seguimiento_fenologico (cultivo_id, path_foto, fecha_registro)
        values (v_cult,
                case when c.analizada = 'misma' then v_path else 'test-16.43/anterior.jpg' end,
                now() - interval '1 hour');
      end if;

      select exists (select 1 from public.vista_fotos_para_analizar f where f.cultivo_id = v_cult)
        into v_hay;
      if v_hay = c.esperado then
        v_ok := v_ok + 1;
      else
        v_fallas := array_append(v_fallas, format('caso "%s": %s en la vista (esperaba %s)',
          c.nombre, case when v_hay then 'está' else 'no está' end,
          case when c.esperado then 'que esté' else 'que no esté' end));
      end if;
    exception when others then
      v_fallas := array_append(v_fallas, format('caso "%s": %s', c.nombre, sqlerrm));
    end;
  end loop;

  -- Las columnas y los valores son los de vista_estado_cultivo.
  v_total := v_total + 1;
  begin
    if (select to_jsonb(f) from public.vista_fotos_para_analizar f where f.cultivo_id = v_uno)
       = (select to_jsonb(e) from public.vista_estado_cultivo e where e.cultivo_id = v_uno) then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, 'caso "mismas columnas": la fila no es igual a la de vista_estado_cultivo');
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "mismas columnas": ' || sqlerrm);
  end;

  -- origen: acepta los tres valores y null; rechaza cualquier otro.
  v_total := v_total + 1;
  begin
    insert into public.seguimiento_fenologico (cultivo_id, origen)
    values (v_uno, 'alerta'), (v_uno, 'consulta'), (v_uno, 'proactivo'), (v_uno, null);
    v_ok := v_ok + 1;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "origen válido": ' || sqlerrm);
  end;

  v_total := v_total + 1;
  begin
    insert into public.seguimiento_fenologico (cultivo_id, origen) values (v_uno, 'otro');
    v_fallas := array_append(v_fallas, 'caso "origen inválido": aceptó ''otro''');
  exception
    when check_violation then v_ok := v_ok + 1;
    when others then v_fallas := array_append(v_fallas, 'caso "origen inválido": ' || sqlerrm);
  end;

  -- Permisos: cerrada para anon y authenticated, abierta para service_role.
  v_total := v_total + 1;
  begin
    if not has_table_privilege('anon', 'public.vista_fotos_para_analizar', 'select')
       and not has_table_privilege('authenticated', 'public.vista_fotos_para_analizar', 'select')
       and has_table_privilege('service_role', 'public.vista_fotos_para_analizar', 'select')
       and (select 'security_invoker=true' = any(x.reloptions) from pg_class x
             where x.oid = 'public.vista_fotos_para_analizar'::regclass) then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas,
        'caso "permisos": anon o authenticated pueden leer, service_role no, o falta security_invoker');
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "permisos": ' || sqlerrm);
  end;

  if array_length(v_fallas, 1) > 0 then
    raise exception 'TEST FALLÓ (% de % bien): %', v_ok, v_total, array_to_string(v_fallas, ' | ');
  end if;
  raise exception 'TEST OK: % de %. Todo revertido.', v_ok, v_total;
end $$;


-- ============================================================================
-- REVERSO — solo si hubiera que deshacer el BLOQUE 1.
-- Antes, sacar `origen` del nodo Persistir de WF2 y apagar WF4.
-- ============================================================================
-- begin;
-- drop view public.vista_fotos_para_analizar;
-- alter table public.seguimiento_fenologico drop column origen;
-- commit;
-- notify pgrst, 'reload schema';

-- ============================================================================
-- 16.25 / 16.27 · Test N=2, camino `avanza` y política de terminación
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Fecha: 23/08/2026 — sesión 8
--
-- QUÉ PRUEBA, Y QUE HOY NO ESTÁ PROBADO
--   1. Cardinalidad: que `Registrar Evaluacion` emita UN ítem por cultivo.
--      Es un nodo HTTP nuevo, o sea una superficie de cardinalidad nueva, de la
--      misma familia que 16.16 / 16.17 / 16.18. Con N=1, "emite 1" y "emite N"
--      dan el mismo resultado correcto.
--   2. Que dos ítems puedan tomar RAMAS DISTINTAS en `Cambio de etapa?` sin
--      contaminarse (path_foto y diagnóstico de cada uno con SU cultivo).
--   3. El camino `avanza` de la función: UPDATE de etapa + INSERT en la
--      historia clínica, dentro de la transacción. NUNCA se ejecutó.
--   4. La política de terminación de 16.27: dos fallos que NO marcan la foto,
--      y un tercero que pasa a 'agotada' y sí la marca.
--
-- DISEÑO
--   Cultivo B va en VEGETATIVO (no en Floración) a propósito: la pregunta del
--   prompt es distinta, la etapa destino es distinta (ee_id 9 vs 8) y los dos
--   ítems pueden irse por ramas distintas. Si los dos hicieran lo mismo, un
--   cruce entre ellos sería indetectable (16.16).
--
--   El camino `avanza` se prueba por LLAMADA DIRECTA a la RPC y no vía Gemini:
--   la respuesta del modelo no está bajo nuestro control, y una aserción no
--   puede depender de una dependencia no determinística. Gemini prueba la
--   integración; la llamada directa prueba la transacción.
--
--   Dispositivo propio para B: compartir el de A haría que `Resolver Cultivo`
--   de WF1 (activo) devuelva dos filas para la misma MAC.
--
-- LIMITACIÓN CONOCIDA
--   Las 4 fotos del bucket son la MISMA imagen subida varias veces, así que un
--   cruce de DIAGNÓSTICOS entre cultivos sería indetectable. Lo que sí detecta
--   este test es el cruce de `path_foto` y de `cultivo_id`, que es el punto 3
--   de 16.16. Para cerrar el hueco haría falta una foto visualmente distinta.
--
-- ORDEN: F0 → F1 → correr → F2 → correr → F3 → F4 → F5 → (romper modelo)
--        → correr ×3 con F6 en el medio → F7 (restaurar TODO)
-- ============================================================================


-- ============================================================================
-- F0 — Snapshot ANTES. Guardá la salida.
-- ============================================================================
select
  (select count(*) from cultivo)                  as cultivos,
  (select count(*) from dispositivo)              as dispositivos,
  (select count(*) from seguimiento_fenologico)   as filas_seguimiento,
  (select count(*) from evaluacion_fenologica)    as filas_evaluacion,
  (select fecha_inicio_etapa from cultivo)        as fecha_inicio_etapa_A,
  (select etapa_actual_id from cultivo)           as etapa_A,
  (select ultima_foto_evaluada_path from cultivo) as foto_evaluada_A;

-- Esperado: 1 · 1 · 24 · 0 · 2026-08-12 19:39:05.008+00 · 4 · null


-- ============================================================================
-- F1 — Crear el escenario N=2
-- ============================================================================

-- Dispositivo propio para B, con MAC reconocible como de test.
insert into dispositivo (id, mac_address, version_firmware, tiene_actuador_riego, caudal_bomba_ml_s)
values ('b2222222-2222-4222-8222-222222222222', 'TEST:16:25:N2:00', 'test', false, null);

-- Cultivo B: misma especie, VEGETATIVO (etapa_actual_id = 3, dura 40 días,
-- ventana 32) con 35 días en etapa, y una foto DISTINTA de la de A.
insert into cultivo (
  id, usuario_id, especie_id, nombre_personalizado, entorno, fecha_inicio,
  active, dispositivo_id, etapa_actual_id, fecha_inicio_etapa,
  ultima_foto_path, volumen_maceta_litros
) values (
  'b1111111-1111-4111-8111-111111111111',
  '10434a28-a99e-47d9-b5cd-c0f2c0a95657',
  3,
  'TEST N2 - Cultivo B (borrar)',
  'indoor',
  now() - interval '90 days',
  true,
  'b2222222-2222-4222-8222-222222222222',
  3,
  now() - interval '35 days',
  'a1327127-1570-474a-a49e-6d506b300759/1787165120466.jpg',
  20
);

-- Abrir la ventana de A (11 días de 16 → se cortaría en `Hay cultivos a evaluar?`).
update cultivo
   set fecha_inicio_etapa = now() - interval '17 days'
 where id = 'a1327127-1570-474a-a49e-6d506b300759';

-- ---------------------------------------------------------------------------
-- VERIFICACIÓN CRÍTICA. Sin esto, el test de cardinalidad puede dar verde sin
-- haberse corrido: `vista_cultivos_activos` tiene JOIN (inner) contra
-- dispositivo, así que un cultivo mal armado simplemente NO APARECE y N sigue
-- siendo 1. Tienen que salir DOS filas, las dos con dias_en_etapa >= ventana.
-- ---------------------------------------------------------------------------
select cultivo_id, planta, etapa_actual, duracion_estimada_dias,
       floor(extract(epoch from (now() - fecha_inicio_etapa))/86400) as dias_en_etapa,
       round(duracion_estimada_dias * 0.8) as ventana_dias,
       ultima_foto_path, ultima_foto_evaluada_path
from vista_cultivos_activos
order by planta, cultivo_id;

-- Esperado: 2 filas.
--   A · Floración  · 20 días · 17 en etapa · ventana 16 ✅ · foto ...1094.jpg
--   B · Vegetativo · 40 días · 35 en etapa · ventana 32 ✅ · foto ...0466.jpg
-- Si sale UNA sola fila, PARAR: el escenario no está armado.


-- ============================================================================
-- >>> CORRIDA 1 en n8n: "Test workflow" sobre WF3. NO lo actives.
--     Ojo al panel de cada nodo: `Registrar Evaluacion` debe mostrar
--     2 ítems de entrada y 2 de salida. Si muestra 1, ahí está el bug.
-- ============================================================================


-- ============================================================================
-- F2 — Verificación de la CORRIDA 1 (cardinalidad y no-contaminación)
-- ============================================================================
select e.id, c.nombre_personalizado, e.resultado, e.etapa_detectada,
       e.etapas_especie_id_origen, e.etapas_especie_id_destino,
       e.confianza, e.path_foto, e.fecha
from evaluacion_fenologica e
join cultivo c on c.id = e.cultivo_id
order by e.id;

-- QUÉ TIENE QUE DAR
--   · DOS filas, una por cultivo. Una sola fila = pérdida de cardinalidad.
--   · Cada fila con SU path_foto: A con ...1094.jpg, B con ...0466.jpg.
--     Cruzadas = contaminación entre ítems (16.16 punto 3).
--   · A: origen 9 (Floración) → destino 8 (Cosecha).
--     B: origen 10 (Vegetativo) → destino 9 (Floración).
--     Cruzados = el catálogo se resolvió mal por ítem.
--   · Los resultados PUEDEN diferir entre los dos, y está bien: eso significa
--     que tomaron ramas distintas en `Cambio de etapa?`, que es lo que se busca.

-- Estado de los dos cultivos.
select id, nombre_personalizado, etapa_actual_id, fecha_inicio_etapa,
       ultima_foto_path, ultima_foto_evaluada_path
from cultivo order by nombre_personalizado;

-- La historia clínica solo crece si ALGUNO avanzó, y en ese caso UNA fila.
select count(*) as filas_seguimiento, max(fecha_registro) as ultima
from seguimiento_fenologico;


-- ============================================================================
-- >>> CORRIDA 2 en n8n, sin tocar nada.
-- ============================================================================


-- ============================================================================
-- F3 — Deduplicación con N=2
--
-- Los DOS deben quedar filtrados en `Validacion de foto`, sin ítems hacia
-- `Descargar Foto`. Si pasa uno solo, la dedup está actuando globalmente y no
-- por ítem, que sería un bug nuevo invisible con N=1.
-- ============================================================================
select count(*) as filas_evaluacion, max(id) as ultimo_id
from evaluacion_fenologica;
-- Esperado: exactamente lo mismo que en F2.


-- ============================================================================
-- F4 — Camino `avanza` de la función, por llamada DIRECTA (determinístico)
--
-- Nunca se ejecutó: es el UPDATE de etapa + el INSERT en la historia clínica
-- dentro de la transacción. Se usa una tercera foto para no chocar con la
-- clave de idempotencia de las corridas anteriores.
-- ============================================================================
select public.fn_registrar_evaluacion_fenologica(
  p_cultivo_id                => 'b1111111-1111-4111-8111-111111111111'::uuid,
  p_path_foto                 => 'a1327127-1570-474a-a49e-6d506b300759/1787164746750.jpg',
  p_resultado                 => 'avanza',
  p_etapas_especie_id_origen  => 10,   -- Vegetativo
  p_etapas_especie_id_destino => 9,    -- Floración
  p_etapa_destino_id          => 4,    -- tipo_etapa.id de Floración
  p_etapa_detectada           => 'Floración',
  p_confianza                 => 0.91,
  p_diagnostico               => '{"cambio_confirmado": true, "confianza": 0.91, "etapa_detectada": "Floración", "evidencia_visual": "test F4", "justificacion": "test directo del camino avanza", "diagnostico_fallido": false}'::jsonb
);
-- Esperado: avanzo = true, seguimiento_id con un uuid (NO null), foto_marcada = true.

-- Verificar contra el estado persistido, no contra la respuesta.
select id, nombre_personalizado, etapa_actual_id, fecha_inicio_etapa, ultima_foto_evaluada_path
from cultivo where id = 'b1111111-1111-4111-8111-111111111111';
-- Esperado: etapa_actual_id = 4 (Floración), fecha_inicio_etapa = ahora,
--           ultima_foto_evaluada_path = ...4746750.jpg

select id, cultivo_id, etapas_especie_id, confianza_ia, path_foto,
       jsonb_typeof(diagnostico_ia) as tipo_diagnostico,
       diagnostico_ia->>'etapa_detectada' as etapa_detectada
from seguimiento_fenologico order by fecha_registro desc limit 1;
-- Esperado: tipo_diagnostico = 'object' (NO 'string'), etapa_detectada = 'Floración'.
-- Que sea 'object' es la prueba de que 16.19 / 16.28 quedaron cerrados.


-- ============================================================================
-- F5 — Reset para el test de fallas
-- ============================================================================
delete from evaluacion_fenologica;

delete from seguimiento_fenologico
 where cultivo_id = 'b1111111-1111-4111-8111-111111111111';

update cultivo set ultima_foto_evaluada_path = null;

-- Devolver B a Vegetativo con la ventana abierta.
update cultivo
   set etapa_actual_id    = 3,
       fecha_inicio_etapa = now() - interval '35 days'
 where id = 'b1111111-1111-4111-8111-111111111111';

-- Si A avanzó en la corrida 1, devolverlo a Floración con la ventana abierta.
update cultivo
   set etapa_actual_id    = 4,
       fecha_inicio_etapa = now() - interval '17 days'
 where id = 'a1327127-1570-474a-a49e-6d506b300759';

-- Confirmar que vuelven a salir 2 filas evaluables.
select cultivo_id, etapa_actual, dias_en_etapa, ventana_dias from (
  select cultivo_id, etapa_actual,
         floor(extract(epoch from (now() - fecha_inicio_etapa))/86400) as dias_en_etapa,
         round(duracion_estimada_dias * 0.8) as ventana_dias
  from vista_cultivos_activos) t;


-- ============================================================================
-- >>> EN n8n: en `IA Vision Fenologica`, cambiar el modelo de la URL a uno
--     INEXISTENTE (inyección de fallos, igual que 16.14):
--
--     .../v1beta/models/gemini-3.5-flash-inexistente:generateContent
--
--     Después correr WF3 a mano TRES VECES seguidas, verificando entre cada una.
--
--     OJO: ese nodo tiene retryOnFail con 5 s de espera, así que cada corrida
--     va a tardar ~30-45 s con 2 cultivos. Es esperable, no está colgado.
-- ============================================================================


-- ============================================================================
-- F6 — Verificación del contador (correr DESPUÉS DE CADA corrida)
-- ============================================================================
select resultado, count(*) as filas
from evaluacion_fenologica group by resultado order by resultado;

select id, nombre_personalizado, ultima_foto_evaluada_path
from cultivo order by nombre_personalizado;

-- QUÉ TIENE QUE DAR
--   Tras la corrida 1: 2 filas 'diagnostico_fallido' · las DOS fotos SIN marcar
--   Tras la corrida 2: 4 filas 'diagnostico_fallido' · las DOS fotos SIN marcar
--   Tras la corrida 3: 4 'diagnostico_fallido' + 2 'agotada' · fotos MARCADAS
--
--   Que la foto NO se marque en las dos primeras es el punto: un 503 pasajero
--   de Gemini no puede consumir la única evidencia disponible del avance.
--   Que se marque en la tercera es la política de terminación de 16.27.
--
--   OPCIONAL — corrida 4: debe cortarse en `Validacion de foto` y no agregar
--   ninguna fila. Eso es el bucle infinito quedando cortado, que es el
--   resultado que este test existe para demostrar.


-- ============================================================================
-- F7 — RESTAURAR TODO. No es opcional.
-- ============================================================================

-- >>> PRIMERO en n8n: devolver la URL de `IA Vision Fenologica` a
--     .../v1beta/models/gemini-3.5-flash:generateContent

-- Borrar el cultivo de test. Las FK de evaluacion_fenologica y de
-- seguimiento_fenologico son ON DELETE CASCADE, así que se limpian solas.
delete from cultivo     where id = 'b1111111-1111-4111-8111-111111111111';
delete from dispositivo where id = 'b2222222-2222-4222-8222-222222222222';

-- Limpiar lo que quede de A.
delete from evaluacion_fenologica;

update cultivo
   set fecha_inicio_etapa        = '2026-08-12 19:39:05.008+00',
       etapa_actual_id           = 4,
       ultima_foto_evaluada_path = null
 where id = 'a1327127-1570-474a-a49e-6d506b300759';

-- Confirmar que quedó igual que en F0.
select
  (select count(*) from cultivo)                  as cultivos,
  (select count(*) from dispositivo)              as dispositivos,
  (select count(*) from seguimiento_fenologico)   as filas_seguimiento,
  (select count(*) from evaluacion_fenologica)    as filas_evaluacion,
  (select fecha_inicio_etapa from cultivo)        as fecha_inicio_etapa_A,
  (select etapa_actual_id from cultivo)           as etapa_A,
  (select ultima_foto_evaluada_path from cultivo) as foto_evaluada_A;

-- Esperado: 1 · 1 · 24 · 0 · 2026-08-12 19:39:05.008+00 · 4 · null

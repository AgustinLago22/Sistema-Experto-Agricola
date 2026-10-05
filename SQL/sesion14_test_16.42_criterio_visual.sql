-- ============================================================================
-- Sesión 14 · Test en vivo de 16.42 (criterio_visual en el prompt de WF3)
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 01/10/2026 contra el estado verificado ese día.
--
-- QUÉ PRUEBA
--   Que WF3 lee `criterio_visual` del catálogo, lo mete en el prompt, y que el
--   modelo decide sobre ESA transición (Fructificación → Cosecha).
--
-- POR QUÉ PUEDE FALLAR (y entonces sirve)
--   La foto de demo muestra frutos VERDES. Con el criterio de Cosecha
--   ("frutos con cambio de color"), lo correcto es `no_avanza`.
--   - `avanza`              → el prompt no está usando el criterio: el cambio está mal.
--   - `etapa_no_coincide`   → el modelo nombró otra etapa: revisar la respuesta.
--   - `diagnostico_fallido` → el body nuevo rompió la llamada a Gemini.
--   - corta en `Calcular Dias en Etapa` con "Falta criterio_visual"
--                           → el select de `Obtener Orden Etapas` no pide la columna.
--
-- POR QUÉ HACE FALTA PREPARAR DATOS (regla 5: que el workflow LLEGUE a los nodos)
--   1. La ventana de Fructificación se abre a los 32 días (16.65); hoy van ~8.
--      Sin atrasar `fecha_inicio_etapa`, la corrida corta en
--      `Hay cultivos a evaluar?` y daría verde sin probar nada.
--   2. La foto actual ya está evaluada (marca = foto). Sin foto nueva, corta en
--      `Validacion de foto`. Y limpiar la marca NO sirve: la RPC devuelve
--      `duplicado` por su clave (cultivo_id, path_foto) — lección de v53.
--
-- ORDEN
--   BLOQUE 0 (estado previo) → PASO A (telemetría con foto, PowerShell) →
--   BLOQUE 1 (abrir la ventana) → PASO B (ejecutar WF3 a mano) →
--   BLOQUE 2 (verificar) → BLOQUE 3 (restaurar la fecha)
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo, registrado el 01/10 (no hace falta correrlo)
-- ============================================================================
-- cultivo a1327127: etapa_actual_id 6 (Fructificación)
--   fecha_inicio_etapa        = 2026-09-23 23:18:15.868662+00   ← SE RESTAURA EN BLOQUE 3
--   ultima_foto_path          = a1327127-1570-474a-a49e-6d506b300759/1790205442303.jpg
--   ultima_foto_evaluada_path = (la misma)
-- evaluacion_fenologica 2 · seguimiento_fenologico 25 · lectura_sensores 225
-- evento_riego 8 · comando_dispositivo 8


-- ============================================================================
-- PASO A — Telemetría con foto nueva por WF1 (PowerShell, una línea)
-- ============================================================================
-- Valores ideales de FRUCTIFICACIÓN, para que no dispare alerta, WF2 ni riego.
-- (Ojo: humedad 55 o 58 ahora es Sequía y dispara WF5.)
--
-- $body = @{dispositivo_mac="24:0A:C4:A1:B2:C3"; planta="Tomate Cherry"; humedad=68.0; ph=6.4; n=25; p=40; k=60; foto_base64=(Get-Content "D:\tesis\test\foto_demo_base64.txt" -Raw).Trim()} | ConvertTo-Json; Invoke-RestMethod -Uri "http://localhost:5678/webhook/telemetria" -Method POST -ContentType "application/json" -Headers @{ "X-Device-Key" = "LA_CLAVE" } -Body $body
--
-- Esperado: lectura_sensores 225 → 230, ultima_foto_path = foto NUEVA,
-- sin Telegram de alerta, evento_riego sigue en 8.


-- ============================================================================
-- BLOQUE 1 — Abrir la ventana de evaluación (35 días > 32)
-- ============================================================================
update cultivo
   set fecha_inicio_etapa = now() - interval '35 days'
 where id = 'a1327127-1570-474a-a49e-6d506b300759';


-- ============================================================================
-- PASO B — Ejecutar WF3 a mano ("Execute workflow")
-- ============================================================================
-- Además del resultado, mirar en la ejecución el INPUT de `IA Vision Fenologica`:
-- el texto del prompt tiene que mostrar los dos criterios (Fructificación y
-- Cosecha), no "undefined". Si dice undefined, el test no probó nada.
-- Esperado: sin Telegram (`no_avanza` no notifica).


-- ============================================================================
-- BLOQUE 2 — Verificación contra el estado persistido
-- ============================================================================
select id, resultado, etapa_detectada, confianza,
       etapas_especie_id_origen, etapas_especie_id_destino,
       diagnostico->>'cambio_confirmado' as cambio_confirmado,
       diagnostico->>'justificacion'     as justificacion,
       fecha
from evaluacion_fenologica
order by id desc limit 1;
-- Esperado: resultado 'no_avanza', etapa_detectada 'Fructificación',
-- cambio_confirmado false, origen 14 → destino 8.

select etapa_actual_id,                                  -- 6 (sigue en Fructificación)
       ultima_foto_path = ultima_foto_evaluada_path as foto_marcada,   -- true
       (select count(*) from seguimiento_fenologico) as seguimientos,  -- 25 (sin cambio)
       (select count(*) from evento_riego)           as riegos         -- 8
from cultivo where id = 'a1327127-1570-474a-a49e-6d506b300759';


-- ============================================================================
-- BLOQUE 3 — Restaurar la fecha (NO SALTEAR: los datos del test son parte del test)
-- ============================================================================
update cultivo
   set fecha_inicio_etapa = '2026-09-23 23:18:15.868662+00'
 where id = 'a1327127-1570-474a-a49e-6d506b300759';
--
-- Qué se CONSERVA a propósito, mismo criterio que v53: la foto nueva, sus 5
-- lecturas y la fila de evaluación. Son coherentes entre sí y con la planta
-- (misma imagen, resultado verdadero). Borrarlos exigiría además revertir
-- ultima_foto_path y borrar el objeto de Storage desde el dashboard — el
-- dual-write foto + puntero de v40. Si se prefiere la limpieza total, se arma
-- aparte.

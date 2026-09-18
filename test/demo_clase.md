# Demo de clase — 12/08/2026

Base preparada y verificada. Orden sugerido: **1 → 2 → 3 → 4**.

---

## 0. Estado en que dejé la base

| Campo | Valor |
|---|---|
| Cultivo | `a1327127-1570-474a-a49e-6d506b300759` — Tomate Cherry |
| Dispositivo | `3581a79d-75a0-4116-b924-13444b4bdb85` — MAC `24:0A:C4:A1:B2:C3` |
| Etapa actual | **Vegetativo** (`etapa_actual_id = 3`) |
| Días en etapa | **35 de 40 = 88%** → entra en la ventana del 80% de WF3 |
| Foto en el bucket | `a1327127-.../1786557238709.jpg` — existe, 67 KB, subida hoy 17:53 UTC |
| Mantenimiento | `null` (el sistema no está silenciado) |
| Actuador de riego | `true` · maceta 20 L · caudal 40 ml/s |

**Antes estaba en:** `etapa_actual_id = 4` (Floración), `fecha_inicio_etapa = 2026-07-28 21:09:59.938+00`.
El SQL para restaurar está al final.

**Por qué Vegetativo y no Floración:** desde Floración la única etapa siguiente del catálogo es Cosecha, que **no tiene parámetros cargados** — WF3 avanzaría a un estado que después rompe WF1 y WF4. Desde Vegetativo la transición es a Floración, que sí tiene umbrales completos. La demo queda limpia y la base sana.

---

## 1. WF1 en condiciones óptimas (no debe alertar)

Valores en el centro del rango de **Vegetativo**: humedad 60-75%, pH 6,0-6,8, N 50, P 30, K 30.

```powershell
$body = @{ dispositivo_mac="24:0A:C4:A1:B2:C3"; planta="Tomate Cherry";
           humedad=67.5; ph=6.4; n=50; p=30; k=30;
           foto_base64=(Get-Content "D:\tesis\test\foto_demo_base64.txt" -Raw) } | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:5678/webhook/telemetria" `
  -Method POST -ContentType "application/json" `
  -Headers @{ "X-Device-Key" = "<clave que está arriba de todo en test_escenarios.txt>" } -Body $body
```

**Esperado:** estado `OK`, 5 filas nuevas en `lectura_sensores`, foto subida a Storage, **ningún mensaje en Telegram**, ni WF2 ni WF5 disparados.

---

## 2. WF1 con sequía (dispara WF2 + WF5 en cascada)

```powershell
$body = @{ dispositivo_mac="24:0A:C4:A1:B2:C3"; planta="Tomate Cherry";
           humedad=25.0; ph=6.4; n=50; p=30; k=30;
           foto_base64=(Get-Content "D:\tesis\test\foto_demo_base64.txt" -Raw) } | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:5678/webhook/telemetria" `
  -Method POST -ContentType "application/json" `
  -Headers @{ "X-Device-Key" = "<clave>" } -Body $body
```

**Esperado:** alerta de sequía en Telegram en menos de 1 s → riego automático (déficit 42,5 puntos · 20 L → **2125 ml** → 53 s recortado al tope de **30 s**) → diagnóstico de la IA con foto ~10 s después.

> **Ojo con el cooldown:** el último riego real fue hoy **17:54 UTC (14:54 hora local)**. WF5 no vuelve a regar hasta **15:09 hora local**. Si lo corrés antes, todo lo demás funciona pero no se crea el riego — y eso también es demostrable ("el sistema se niega a regar dos veces"). Si querés forzar que riegue ya:
> ```sql
> UPDATE public.evento_riego SET fecha_inicio = now() - interval '30 minutes'
> WHERE id = (SELECT id FROM public.evento_riego ORDER BY fecha_inicio DESC LIMIT 1);
> ```

---

## 3. WF3 — validación fenológica

Ya está todo listo: etapa Vegetativo al 88% del tiempo esperado y foto real en el bucket.

**En n8n: abrir WF3 → botón "Test Workflow".**

Verificación después de correr:

```sql
-- ¿avanzó la etapa y se reinició el contador?
SELECT te.nombre_etapa, c.fecha_inicio_etapa
FROM public.cultivo c JOIN public.tipo_etapa te ON te.id = c.etapa_actual_id
WHERE c.active = true;

-- ¿qué vio la IA y con cuánta confianza?
SELECT fecha_registro, confianza_ia, path_foto, diagnostico_ia
FROM public.seguimiento_fenologico ORDER BY fecha_registro DESC LIMIT 1;
```

**Esperado:** la IA analiza la foto real, confirma el paso a **Floración** (confianza > 0,70), el sistema actualiza la etapa solo, reinicia `fecha_inicio_etapa` en `now()`, guarda la evidencia visual y avisa por Telegram con la foto.

---

## 4. El remate (opcional, 30 segundos)

Volvé a mandar **exactamente el mismo comando del punto 1** — el que hace un minuto era perfecto.

Ahora el cultivo está en Floración, así que 67,5% de humedad **supera el máximo de 65%** y N/P/K quedaron fuera del rango de la etapa nueva.

**Esperado:** el mismo dato que no generaba ninguna alerta ahora dispara `Exceso Hídrico` más los desvíos de nutrientes.

> Es la demostración en vivo de la tesis: **el umbral no es una propiedad de la especie, es una propiedad de la etapa**. Un sistema con un valor fijo por planta habría dicho "todo bien" en los dos casos.

---

## 5. Restaurar el estado original

```sql
UPDATE public.cultivo
SET etapa_actual_id = 4,
    fecha_inicio_etapa = '2026-07-28 21:09:59.938+00'
WHERE id = 'a1327127-1570-474a-a49e-6d506b300759';

-- opcional: borrar las lecturas y diagnósticos generados en la demo
-- DELETE FROM public.lectura_sensores WHERE fecha_hora > '2026-08-12 18:00:00+00';
-- DELETE FROM public.seguimiento_fenologico WHERE fecha_registro > '2026-08-12 18:00:00+00';
```

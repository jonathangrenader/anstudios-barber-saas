# EVALUACIÓN: SINCRONIZACIÓN CON GOOGLE CALENDAR (T-015)

Estado: **nivel A (feed ICS) implementado en código (T-020); pendiente de ejecutar el SQL y desplegar la Edge Function.** Niveles B y C: solo evaluación. Fecha: 2026-11-23.

La app no tiene integración con Google vía OAuth. El feed ICS no la necesita: es una URL de solo lectura con token por profesional. Los niveles B y C sí requieren proyecto de Google Cloud, verificación y secretos, y no se pueden probar en el entorno actual.

## 1. Qué pediría el usuario

Que el profesional (o el dueño) vea sus turnos en el calendario que ya usa en el teléfono, sin duplicar cargas y sin que un turno cancelado siga apareciendo.

Hay tres niveles posibles, de menor a mayor costo:

| Nivel | Qué hace | Dirección | Complejidad |
|-------|----------|-----------|-------------|
| A. Feed ICS | Suscribirse a una URL con los turnos del profesional | ANSTUDIOS → Google | Baja |
| B. Push por OAuth | Crear/actualizar/borrar eventos en un calendario secundario del profesional | ANSTUDIOS → Google | Media |
| C. Sincronización bidireccional | Además trae cambios hechos en Google y bloquea horarios | Ambos sentidos | Alta |

## 2. Nivel A — Feed ICS de solo lectura (recomendado para empezar)

- Una Edge Function (o RPC + endpoint) devuelve `text/calendar` con los turnos del profesional para un rango de ±90 días.
- URL con token aleatorio por profesional (`staff.calendar_token`), revocable y regenerable. Sin OAuth, sin cuentas de Google, sin secretos de terceros.
- El profesional la agrega en Google Calendar como "Suscribirse a un calendario" (Otros calendarios → Desde URL).
- **Límites reales:** Google refresca los feeds externos cada varias horas (no es tiempo real), no se puede escribir de vuelta y el feed no debe exponer datos sensibles de más (nombre del cliente y servicio alcanzan; evitar teléfono y notas).
- Costo estimado: 1 migración + 1 función + 1 botón "Copiar link de calendario" en Ajustes/Equipo. Es la opción con mejor relación valor/riesgo.

### 2.1 Implementación actual (T-020)

- `supabase/migrations/20261123_calendar_feed.sql`: `staff.calendar_token` (UUID único, default `gen_random_uuid()`), RPCs `fn_calendar_token` y `fn_rotate_calendar_token` (dueño o propio profesional).
- `supabase/functions/calendar-feed/index.ts`: ICS de ±90 días, `UID` estable por turno, cancelados como `STATUS:CANCELLED`, ausentes con "(no asistió)", sin teléfono ni notas.
- `src/components/CalendarFeedSection.tsx`: bloque "Calendario del teléfono" en la ficha del profesional (Equipo) y en la vista del profesional, con copiar y regenerar.
- `listStaff` no selecciona `calendar_token`, así que el token no se guarda en el caché offline.
- Despliegue: `supabase functions deploy calendar-feed --no-verify-jwt` (Google consulta sin JWT; el token es la autorización).

## 3. Nivel B — Push por OAuth (si se quiere "de verdad")

### 3.1 Requisitos externos

1. Proyecto en Google Cloud Console con la **Google Calendar API** habilitada.
2. Pantalla de consentimiento OAuth (tipo externo), dominio verificado y política de privacidad publicada.
3. Credenciales **OAuth 2.0 Client** (client ID + secret) con redirect URI de la Edge Function de callback.
4. Scopes: `https://www.googleapis.com/auth/calendar.events` (o el más acotado `calendar.app.created`, que solo da acceso a calendarios creados por la app).
5. Si la app se distribuye a locales de terceros, Google exige **verificación** del consentimiento para scopes sensibles; el trámite puede tardar semanas.
6. Edge Function con secretos (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, clave de cifrado) y cron para renovar canales si se usa el nivel C.

### 3.2 Arquitectura mínima

- Tabla `staff_calendar_links` (`staff_id`, `provider`, `calendar_id`, `refresh_token_cifrado`, `sync_token`, `connected_at`, `last_error`), con RLS solo dueño/staff propio y sin lectura del token desde el frontend.
- Flujo: botón "Conectar Google Calendar" → OAuth con `state` firmado → callback guarda el refresh token **cifrado** (Supabase Vault o `pgsodium`) → se crea un calendario secundario "ANSTUDIOS — <local>" o se usa el primario con permiso explícito.
- Origen del cambio: trigger/enqueue en `appointments` (INSERT/UPDATE de `status`/`starts_at`) → Edge Function `calendar-sync` consume la cola y llama a la API.
- Idempotencia: `extendedProperties.private.appointment_id` en cada evento; el evento se actualiza o cancela, nunca se duplica.
- Mapeo: `pending`/`confirmed` → evento normal; `cancelled` → evento eliminado; `no_show` → evento con título "No vino"; `completed` → sin cambios.
- Reintentos con backoff y estado visible ("Calendar desconectado, reconectar") en Ajustes; desconectar borra el token y, opcionalmente, los eventos creados.
- Zona horaria: usar `shops.timezone` y `dateTime` con offset, nunca UTC "flotante".

### 3.3 Qué NO resuelve el nivel B

- No evita que el profesional cargue un turno personal en Google a la misma hora: la agenda de ANSTUDIOS no se entera.
- Si el profesional edita el evento en Google, el cambio se pierde en la próxima actualización desde la app.

## 4. Nivel C — Bidireccional (no recomendado por ahora)

- Requiere canales `watch` sobre el calendario (vencen a los 7 días y hay que renovarlos con cron), endpoint público de notificaciones, `syncToken` para cambios incrementales y resolución de conflictos.
- Implica aceptar eventos externos como bloqueos de agenda, lo que choca con las restricciones actuales de no-solapamiento (`appointments_no_overlap`), el cálculo de disponibilidad pública y la cola offline.
- Riesgo alto de doble reserva y de fuga de datos entre profesionales. Costo estimado: varias semanas y soporte permanente.

## 5. Privacidad y seguridad

- El refresh token es una credencial de larga duración: nunca en el frontend, nunca en `localStorage`, siempre cifrado y con acceso restringido por RLS.
- El feed ICS y los eventos deben exponer lo mínimo: cliente (nombre), servicio, hora y profesional. Nada de teléfono, notas ni importes.
- Documentar en la política de privacidad qué se envía a Google y permitir desconectar y borrar todo.
- Argentina (Ley 25.326): datos de clientes en un tercero requieren consentimiento/aviso; el dueño es responsable del tratamiento.

## 6. Recomendación

1. **Empezar por el feed ICS, ya implementado.** Cubre el 80% del caso ("ver los turnos en el teléfono"), no requiere OAuth ni verificación de Google. Falta que el usuario ejecute el SQL, despliegue la función y haga la prueba manual con Google Calendar.
2. **No implementar el nivel B todavía.** No hay credenciales ni forma de probarlo en este entorno, y el valor depende de que los locales pidan escritura desde la app.
3. Medir uso del feed y pedidos de escritura antes de invertir en el nivel B. El nivel C queda descartado para el MVP.

## 7. Definición de "listo" si se implementa el nivel A

- [x] Migración con `staff.calendar_token` (único, regenerable) y RLS.
- [x] Endpoint que devuelva ICS válido (UTF-8, `DTSTART` en UTC, `UID` estable por turno, `STATUS:CANCELLED` para cancelados).
- [x] Botón en Equipo y en la vista del profesional para copiar y regenerar el link.
- [x] Nota en la UI: "Se actualiza cada varias horas".
- [x] Prueba manual (2026-11-23): SQL ejecutado, función desplegada y turno de prueba visible en el feed con hora UTC y duración correctas.
- [ ] Verificar en Google Calendar el refresh del turno y la cancelación/regeneración de token.

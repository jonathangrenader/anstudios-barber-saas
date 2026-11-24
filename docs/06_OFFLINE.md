# MODO OFFLINE TOLERANTE — ANSTUDIOS

## 1. Objetivo

Permitir que el local siga operando durante un corte de internet sin convertir al navegador en una segunda fuente de verdad para el dinero.

La app funciona como **offline tolerante**, no como local-first completo:

- Las lecturas visitadas se guardan en IndexedDB.
- Las escrituras permitidas se encolan y se reintentan al reconectar.
- La base recalcula comisiones, descuentos, insumos y netos al sincronizar.
- Las operaciones críticas de dinero agregado (liquidaciones) y la configuración siguen siendo online-only.

## 2. Almacenamiento local

Base: **IndexedDB** nativa, sin dependencias nuevas.

Nombre: `anstudios-offline` (versión 1).

Stores:

| Store | Contenido |
|-------|-----------|
| `cache` | Última respuesta de lecturas por clave: local, equipo, catálogo, clientes, visitas, agenda por día y caja por día. |
| `outbox` | Operaciones pendientes de sincronizar, con `shopId`, estado, intentos y último error. |

Claves de caché principales:

- `shop:<userId>`
- `staff:<shopId>`
- `catalog:<shopId>`
- `clients:<shopId>`
- `visitStats:<shopId>`
- `agenda:<shopId>:<inicio>:<fin>`
- `cash:<shopId>:<inicio>:<fin>`

## 3. Lecturas

`cachedQuery` intenta la consulta a Supabase y guarda la respuesta. Solo si el error es de transporte (sin conexión, `Failed to fetch`, `Load failed`, timeout) devuelve la última copia local. Los errores de negocio, RLS o validación **no** se tapan con caché.

El local se cachea al cargar `ShopGate`, lo que permite abrir la app offline después de haberla usado online al menos una vez con la sesión vigente.

## 4. Escrituras en cola

Se encolan cuando el navegador está offline o cuando la petición online falla por red:

| Tipo | Operación | Notas |
|------|-----------|-------|
| `client.create` | Alta de cliente | UUID generado en el cliente. |
| `client.update` | Edición de ficha / notas | Por `id`. |
| `appointment.create` | Turno nuevo | UUID propio; permite usarlo luego en caja. |
| `appointment.status` | Cambio de estado | Idempotente por `id`. |
| `appointment.reminder` | Marca de recordatorio enviado | Idempotente. |
| `cash.income` | Cobro | UUID propio; la base recalcula montos. |
| `cash.outflow` | Gasto o adelanto | UUID propio. |

Cada mutación devuelve `{ queued, id }`. Los formularios avisan si el guardado fue local y las tarjetas muestran `Guardado local` o `Error al sincronizar`.

## 5. Idempotencia y orden

- Los IDs de entidades se generan con `crypto.randomUUID()` (con fallback).
- Reintentar un insert con el mismo `id` produce `23505`; el sincronizador lo trata como éxito si la fila ya existe.
- La cola se procesa por `createdAt` ascendente para respetar dependencias: cliente → turno → cobro.
- Si un cliente ya existe por teléfono en el servidor, se reutiliza su `id` y se reemplaza la referencia en los turnos/ediciones que sigan en la cola.
- El sincronizador se ejecuta al iniciar la app, al volver `online`, al recuperar visibilidad y con el botón **Reintentar**.

## 6. Qué se puede hacer offline

- Consultar agenda y caja de días ya visitados.
- Consultar local, equipo, catálogo y clientes ya cargados.
- Crear turnos usando clientes existentes.
- Crear clientes nuevos.
- Registrar cobros, gastos y adelantos.
- Cambiar estados de turnos y marcar recordatorios.
- Editar fichas técnicas.

## 7. Qué queda online-only

- **Liquidaciones**: requieren preview y cierre atómico en la base. La tarjeta de Caja se deshabilita sin conexión.
- Alta/edición de local, equipo y catálogo.
- Reserva pública `/r/:slug` y gestión del turno en `/turno/:token` (consultar, cancelar, reprogramar).
- Login/onboarding por primera vez.
- **Agenda del profesional**: `fn_my_agenda` se calcula en la base; la pantalla de acceso de profesional avisa cuando no hay conexión.
- **Estados del profesional y perfil**: `fn_set_my_appointment_status` y `fn_update_my_profile` son RPC online; no se encolan.
- **Ajustes del salón y fotos**: datos, foto del salón y foto/bio del profesional se suben a Supabase Storage y se guardan online; no hay cola offline para configuración.

## 8. Conflictos y errores

- Turno que se ocupó sin conexión: la restricción `appointments_no_overlap` devuelve `23P01`; el turno queda marcado como fallido y no se pierde silenciosamente.
- Cobro inválido: el trigger de base devuelve `23514`; el movimiento queda fallido con el mensaje.
- Referencias borradas (`23503`) o permisos (`42501`): quedan fallidos para revisión.
- Los fallos no se reintentan automáticamente en cada apertura; el banner permite **Reintentar**.
- Los montos de movimientos locales son **estimados** hasta que la base los recalcula.

## 9. Límites conocidos

- No hay resolución automática de conflictos de agenda; la base rechaza y el usuario debe reacomodar el turno.
- No hay edición ni descarte individual de operaciones fallidas desde la UI.
- El caché local no se borra al cerrar sesión. Es un dispositivo operativo del local; no debe compartirse con terceros.
- No se promete sesión offline por tiempo indefinido: si el token no puede refrescarse, hace falta reconectar.
- No se usa Background Sync del navegador porque no es confiable en iOS/Safari; la sincronización se dispara desde la app.
- No hay tests automatizados de IndexedDB; la verificación es de compilación y flujo manual.
- Las preferencias de tema y tamaño de letra son locales al dispositivo y no se sincronizan entre dispositivos.

## 10. SQL

**No hay cambios de esquema ni SQL nuevo.** Las tablas ya aceptan `id` enviado por el cliente y los triggers/RPCs siguen siendo la fuente de verdad. El modo offline solo cambia el orden en que el frontend envía las operaciones.

## 11. Verificación manual sugerida

1. Online: abrir Agenda, Caja y Clientes para poblar el caché.
2. DevTools → Network → Offline.
3. Recargar: debe abrir con local y agenda guardados.
4. Crear un turno con cliente existente o nuevo y registrar un cobro.
5. Verificar badges `Guardado local` y banner `Sin conexión`.
6. Volver a Online: la cola debe vaciarse y los badges desaparecer.
7. Repetir con un turno que se solape: debe quedar como error visible, no duplicarse.

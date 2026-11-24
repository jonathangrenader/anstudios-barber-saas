# TAREAS DEL PROYECTO — ANSTUDIOS

Leyenda: `[ ]` Pendiente | `[~]` En progreso | `[x]` Completada

## Fase 0: Preparación y Auditoría Técnica
- [x] T-000: Revisar y completar `docs/02_DATABASE.md` (índices, RLS, constraints y función/vista de liquidación) antes de ejecutar SQL en Supabase.

## Fase 1: Setup, Auth y Onboarding
- [x] T-001: Inicializar proyecto React + Vite + TypeScript + Tailwind + Lucide + PWA y configurar cliente Supabase con variables de entorno.
- [x] T-002: Implementar autenticación básica y flujo de creación/configuración inicial del local (`shops`).

## Fase 2: Catálogo, Equipo, Clientes y Agenda
- [x] T-003: CRUD de servicios/productos (`catalog_items`) y profesionales/comisiones (`staff`).
- [x] T-004: Agenda diaria por profesional, creación de turnos y ficha técnica de clientes (`clients`).
- [x] T-005: Recordatorios 1-Tap por WhatsApp (`wa.me`) y actualización de estados de turno.

## Fase 3: Link Público de Turnos
- [x] T-006: Vista pública `/r/:slug` con cálculo de horarios disponibles y guardado seguro de reservas.

## Fase 4: Caja, Descuentos y Liquidación de Comisiones
- [x] T-007: Cobro de turnos y movimientos de caja (`income`, `expense`, `staff_advance`) con cálculo de descuentos, insumos y comisiones.
- [x] T-008: Pantalla de liquidación por profesional (resumen bruto, descuentos/insumos, adelantos y cierre/marcado `is_settled`).

## Fase 5: Verificación y Cierre MVP
- [x] T-009: Revisión de responsive móvil, pruebas de flujo completo y verificación de build (`tsc` y `vite build`).
  - Nota: no se pudo ejecutar el flujo completo contra un Supabase real en este entorno (sin credenciales ni Docker/Postgres). Se verificaron build, revisión responsive con emulación móvil (320 px y 390 px) de las pantallas accesibles sin sesión y auditoría estática del resto. Pendiente de repetir el flujo con una base real.

## Fase 6: Operación sin Internet
- [x] T-010: Modo offline tolerante con caché de lectura en IndexedDB, cola de escrituras idempotente y sincronización al reconectar. Liquidaciones y configuración siguen online-only.

## Fase 7: Acceso de Profesionales
- [x] T-011: Login de profesionales con código de invitación por ficha: códigos en `staff_invites` (solo dueño), RPCs de reclamo/rotación/desvinculación, contexto del local y agenda diaria propia en solo lectura (`fn_staff_context`, `fn_my_agenda`).
## Fase 8: Validación con Supabase real (P0)

Checklist ejecutable para cerrar la nota de T-009. Marcar cada punto y anotar la fecha y el resultado.

- [ ] **Preparación:** 2 ventanas (dueño / profesional en incógnito), 1 servicio público, 1 producto, 2 profesionales activos.
- [ ] **Dueño:** crear local, cargar catálogo y equipo; copiar el código de 8 caracteres de cada profesional.
- [ ] **Profesional:** crear cuenta, ingresar el código en el onboarding y verificar que entra a "Mi agenda" y no al panel del local.
- [ ] **Aislamiento:** el profesional A no ve turnos ni clientes del profesional B; en Caja/Equipo/Configuración no hay acceso.
- [ ] **Escritura bloqueada:** `update public.appointments set status = 'completed'` autenticado como profesional devuelve `42501`.
- [ ] **Código de dueño:** `select public.fn_claim_staff_invite('<codigo>')` con la cuenta dueña devuelve error.
- [ ] **Rotación:** "Generar otro código" invalida el anterior (el código viejo devuelve error) y permite reclamar con el nuevo.
- [ ] **Desvinculación:** "Desvincular acceso" saca al profesional de su agenda y rota el código.
- [ ] **Ficha inactiva:** desactivar al profesional muestra "acceso desactivado" y `fn_my_agenda` responde `42501`.
- [ ] **Flujo completo:** reserva pública → turno visible en agenda del dueño y del profesional → cobro con comisión → liquidación → historial.
- [ ] **Ajustes (T-014):** guardar nombre, descripción, dirección, teléfonos y Maps; subir foto del salón; verificar que todo aparece en el link público.
- [ ] **Perfil del profesional (T-014):** subir foto y bio desde "Mi perfil"; la foto reemplaza al inicial en su agenda y aparece en el link público.
- [ ] **Estados propios (T-012):** el profesional inicia y completa un turno; la comisión no aparece hasta cobrar en Caja; completar sin iniciar devuelve `22023` y un turno ajeno `42501`.
- [ ] **No vino:** marcar ausente un turno pendiente y confirmar que no cuenta como visita.
- [ ] **Visitas (T-013):** completar un turno y verificar `clients.total_visits` + `last_visit_at`; cancelarlo después y confirmar que se revierte; el listado de clientes debe mostrar el mismo número que la ficha.
- [ ] **Gestión pública (T-016):** reservar, abrir "Gestionar mi turno", reprogramar a otro horario y ver el cambio en la agenda del dueño y del profesional; el turno vuelve a pendiente.
- [ ] **Cancelación pública (T-016):** cancelar desde el link, ver el turno cancelado y el horario liberado en la reserva pública; reintentar cancelar devuelve `22023`.
- [ ] **Token inválido:** abrir `/turno/<uuid-inexistente>` muestra "No encontramos este turno" sin pedir login.
- [x] **Feed de calendario (T-020) — despliegue:** ejecutar `20261123_calendar_feed.sql`, desplegar `calendar-feed --no-verify-jwt`, copiar el link desde Equipo y ver un turno real en el feed. Validado el 2026-11-23: el ICS devuelve el turno con hora UTC correcta (21:00Z = 18:00 ART), `UID` del turno y duración de 30 min.
- [ ] **Feed de calendario (T-020) — cambios:** cancelar el turno y confirmar `STATUS:CANCELLED` en el feed; regenerar el token y verificar que el link viejo devuelve 404; desactivar al profesional y confirmar que su link devuelve 404.
- [ ] **Licencias (T-022):** ejecutar `20261123_platform_licensing.sql`, dar de alta tu `user_id` en `platform_admins`, entrar al panel, suspender un local y confirmar pantalla de bloqueo + link público caído + reserva rechazada; habilitarlo; otorgar 90 días y ver el aviso; simular el vencimiento (`update shops set trial_ends_at = now() - interval '1 day'`) y confirmar que queda bloqueado.
- [ ] **Preferencias:** modo oscuro y los 3 tamaños de letra se ven bien en móvil y persisten al recargar (son por dispositivo).
- [ ] **Offline:** con red cortada, crear turno y cobro; reconectar y confirmar que la cola drena sin duplicados (`23P01`/`23505` visibles si aplica).
- [ ] **Cierre:** registrar el resultado en `docs/05_CHANGELOG.md` y corregir cualquier desvío antes de la siguiente fase.

## Fase 9: Operación del día a día y personalización

- [x] T-012: Estados de turno desde el acceso del profesional (iniciar, completar, marcar "no vino") con RPC `fn_set_my_appointment_status`, auditoría `status_changed_by`/`status_changed_at` y validación de transiciones; no genera dinero (la comisión nace al cobrar). UI con error por turno en `StaffHome`.
- [x] T-013: Visitas de clientes calculadas en la base: trigger `trg_appointments_client_visits` + backfill de `clients.total_visits` y `last_visit_at` al completar o revertir turnos.
- [x] T-014: Ajustes del salón y perfiles. La pestaña "Local" pasa a "Ajustes": nombre, descripción breve, foto, dirección, link de Maps, WhatsApp, fijo, celular, horario y link público. Cada profesional puede subir foto y bio (Storage `media`, RPC `fn_update_my_profile`). Tipografía en 3 tamaños y modo oscuro persistidos por dispositivo. El link público muestra foto/descripción/contacto del salón y foto/bio del profesional.
  - Nota: `supabase/migrations/20261123_appointments_settings.sql` fue ejecutada en Supabase el 2026-11-23 (columnas, RPCs, trigger, bucket `media` y políticas). Falta validar el flujo real con datos (incluido en el checklist P0).
- [x] T-015: Evaluación de sincronización con Google Calendar. Documento con arquitectura, credenciales, riesgos y alcance mínimo en `docs/07_GOOGLE_CALENDAR.md`; la alternativa recomendada (feed ICS de solo lectura) se implementó en T-020. Niveles B/C (escritura vía OAuth) siguen sin implementar.
- [x] T-016: Cancelar y reprogramar el turno desde el link público. `appointments.public_token` (capacidad), RPCs `fn_public_manage_appointment`, `fn_public_cancel_appointment` y `fn_public_reschedule_appointment`; la reserva devuelve el token y la confirmación ofrece "Gestionar mi turno" (`/turno/:token`). Reprogramar reutiliza disponibilidad y vuelve el turno a `pending`; los conflictos `23P01` se muestran.
  - Nota: `supabase/migrations/20261123_public_manage.sql` fue ejecutada en Supabase el 2026-11-23. Falta probar el flujo real (incluido en el checklist P0).
- [x] T-017: Visitas con una sola fuente. El listado y la ficha de clientes leen `clients.total_visits` (mantenido por el trigger) y se eliminó el conteo paralelo desde `appointments`; el detalle de visitas sigue usando el historial para mostrar servicio y profesional.
- [x] T-018: Tests automatizados y CI. Vitest en entorno node con 18 tests de la lógica crítica (zona horaria del local y rangos de día, grilla de horarios con solapamientos, normalización de teléfonos para WhatsApp y transiciones de estado). Scripts `npm test` / `npm run test:watch` y workflow de GitHub Actions que corre tests y build en cada push a `main` y en pull requests.

- [x] T-019: Code splitting del bundle. `manualChunks` separa React, Supabase y date-fns; el chunk principal baja de ~605 kB a ~231 kB y desaparece la advertencia de Vite de chunks > 500 kB. Sin cambios de comportamiento.
- [x] T-021: Acceso del profesional visible. El onboarding ahora arranca con una elección explícita ("Tengo un local" / "Soy profesional") en lugar de esconder el código al pie del formulario de local; el login enlaza a crear cuenta con la aclaración del código. Sin cambios en RPCs ni en la base.
- [x] T-022: Licencias y panel de superadmin. `shops.is_suspended`, `suspended_at`, `suspension_note` y `trial_ends_at`; tabla `platform_admins` (alta manual por `user_id`); RPCs `fn_platform_me`, `fn_platform_shops`, `fn_platform_set_suspension` y `fn_platform_set_trial` (90 días o quitar). RLS restrictiva en las tablas del local, bloqueo del link público, de la disponibilidad, de cualquier alta de turno y del feed ICS. Panel mobile-first con conteos, estado por local, suspender/habilitar y otorgar/quitar prueba. Pantalla de bloqueo para dueño y profesional, y aviso de vencimiento de prueba para el dueño.
  - Nota: `20261123_platform_licensing.sql` ejecutada y superadmin registrado el 2026-11-23; el panel ya abre para esa cuenta. Falta validar suspensión/prueba/vencimiento (checklist P0, ítem "Licencias").
- [x] T-020: Feed ICS de solo lectura por profesional.
- [x] T-023: Permiso individual para que los profesionales agenden turnos (`staff.can_book_appointments`, RLS de inserción, toggle en ficha de Equipo, UI en StaffHome) y vista colapsable del equipo. `staff.calendar_token` (capacidad regenerable), RPCs `fn_calendar_token`/`fn_rotate_calendar_token` (dueño o propio profesional), Edge Function `calendar-feed` con turnos de ±90 días (`STATUS:CANCELLED`, sin teléfonos ni notas) y bloque "Calendario del teléfono" en Equipo y en la vista del profesional con copiar/regenerar. `listStaff` no trae el token para que no entre al caché offline.
  - Nota: `20261123_calendar_feed.sql` fue ejecutada y `calendar-feed` desplegada en Supabase el 2026-11-23; hay un turno de prueba visible en el feed. Falta verificar cancelación, regeneración de token y desactivación del profesional (checklist P0).

- [x] T-024: Equipo colapsable por defecto con expandir/colapsar todos; reserva pública con botones para guardar en calendario (.ics con recordatorios opcionales de 1 día y 2 horas antes) y compartir por WhatsApp; búsqueda de turno existente por teléfono/nombre en el link público mediante RPC `fn_public_find_appointments` (migración `20261126_public_find_appointments.sql`). Correcciones de migración: orden de columnas `working_days` y `professionals_can_manage_appointments`; constraint de duración de productos permite 0. `npm run build` y `npm test` (18/18) pasan. Pendiente: ejecutar la migración en Supabase y validar el flujo real.

- [x] T-025: Notificaciones internas y gestión de turnos pendientes: banner con contador en ShopHome, sección en Agenda para aceptar/rechazar turnos pendientes con observación visible para el cliente en "Mi turno". `npm run build` y `npm test` (18/18) pasan.

## Fase 10: Publicación

- [x] T-026: Configuración de despliegue en Vercel. `vercel.json` con `framework: vite`, `buildCommand: npm run build`, `outputDirectory: dist` y rewrite `/(.*)` → `/index.html` para que `/r/:slug` y `/turno/:token` (rutas resueltas por `window.location`, sin router) no devuelvan 404 al abrirlas directo. Las variables `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` se cargan en Vercel, no en el repo.
  - Pendiente en base (bloquea funcionalidad nueva, no el deploy): ejecutar `supabase/migrations/20261126_public_find_appointments.sql`; validar el checklist de la Fase 8 con datos reales.

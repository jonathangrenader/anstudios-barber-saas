# PRD — WEB APP GESTIÓN PARA ESTÉTICA Y BARBERÍAS (ANSTUDIOS)

## 1. OBJETIVO Y MODELO DE USO
Aplicación web progresiva (PWA) económica y de rápida operación diaria para barberías, peluquerías y centros de estética.
- Soporta operar con una base por cliente (instancia dedicada) o múltiples locales aislados por `shop_id`.
- Moneda principal: Pesos Argentinos (`ARS`), formato claro y legible.

## 2. ROLES
- **Dueño / Administrador:** configura el local, servicios, productos, profesionales y comisiones; gestiona agenda, caja, descuentos, adelantos y liquidaciones.
- **Profesional (Barbero / Estilista / Manicura):** consulta su agenda, revisa notas técnicas del cliente y ve su producción/comisión.
- **Cliente final (vía Link Público):** reserva turno eligiendo servicio, profesional, fecha y hora sin crear cuenta compleja.

## 3. MÓDULOS PRINCIPALES
1. **Onboarding del local:** nombre, slug del link público, horarios de atención, duración base y primer servicio/profesional.
2. **Agenda:** vista diaria por profesional con estados (`pending`, `confirmed`, `in_progress`, `completed`, `cancelled`, `no_show`), registro de turnos manuales o al paso (`walk_in`) y **Recordatorio 1-Tap por WhatsApp** (`wa.me` con mensaje prearmado).
3. **Clientes + Ficha técnica:** historial de visitas y campo de notas técnicas (cortes, fórmulas, alergias, preferencias).
4. **Link público de reserva (`/r/:slug`):** muestra disponibilidad real según horarios y turnos ya ocupados, evitando solapamientos.
5. **Caja y Comisiones (con descuentos):**
   - Registro de ingresos por turno o venta de producto, gastos del local, adelantos a empleados y pagos de liquidación.
   - Cálculo de comisión contemplando: descuento al cliente (`discount_amount`), descuento de insumos antes de comisionar (`supply_deduction`), base neta comisionable (`net_base_amount`), porcentaje del profesional (`staff_commission_amount`) y neto del local (`shop_net_amount`).
   - Liquidación periódica por profesional descontando adelantos (`staff_advance`) ya entregados y marcando movimientos como liquidados (`is_settled`).

## 4. MODO OFFLINE TOLERANTE (T-010)

La app es una PWA que permite seguir operando durante cortes de internet sin reemplazar la base como fuente de verdad.

- **Lecturas offline:** local, equipo, catálogo, clientes, agenda y caja ya visitados se guardan en IndexedDB.
- **Escrituras en cola:** altas de clientes, turnos, cambios de estado, recordatorios, cobros, gastos, adelantos y edición de fichas se guardan localmente y se sincronizan al reconectar.
- **Idempotencia:** las entidades usan UUID generados en el cliente para que un reintento no duplique registros.
- **La base manda:** al sincronizar, los triggers y RPCs recalculan descuentos, insumos, comisiones y netos. Los montos locales son estimados.
- **Online-only:** liquidaciones, onboarding, configuración de local/equipo/catálogo y link público de reservas.
- **Conflictos:** si un turno se ocupó, la restricción de la base lo rechaza y la app lo muestra como error de sincronización.

El detalle técnico y los límites están en `docs/06_OFFLINE.md`.
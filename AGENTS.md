# INSTRUCCIONES MAESTRAS PARA AGENTES DE IA (ANSTUDIOS - GESTIÓN ESTÉTICA & BARBERÍAS)

## 1. PROTOCOLO DE INICIO Y CONTINUIDAD (OBLIGATORIO)
Antes de escribir o modificar cualquier archivo de código:
1. Lee `docs/04_TASKS.md` para identificar la siguiente tarea pendiente (`[ ]`) o en progreso (`[~]`).
2. Lee `docs/05_CHANGELOG.md` (últimas 10 entradas) para conocer el estado actual y evitar repetir errores ya resueltos.
3. Consulta `docs/02_DATABASE.md` y `docs/03_DESIGN_SYSTEM.md` antes de crear componentes o consultas a Supabase.

## 2. STACK TECNOLÓGICO ESTRICTO
- Framework: React 18 + Vite + TypeScript (Strict Mode).
- Estilos: Tailwind CSS + Lucide React (iconos). Prohibido usar CSS puro externo salvo `index.css` para variables y fuentes.
- Backend/DB: Supabase (`@supabase/supabase-js`).
- Estado/Fechas: `date-fns` (con locale `es`) para manejo estricto de zonas horarias locales (Argentina UTC-3).

## 3. REGLAS DE DISEÑO ("ANTI-SLOP AI")
- Prohibido usar estética genérica de IA (fondos oscuros con degradados violetas/neón, tarjetas genéricas sin jerarquía, sombras difusas excesivas).
- Seguir estrictamente `docs/03_DESIGN_SYSTEM.md`: estética Editorial/Táctil, fondo alabastro cálido (`#F7F5F0`), tinta carbón (`#141413`), tarjetas con bordes definidos (`1px solid #E2DFD7`), tipografía contrastada (`Plus Jakarta Sans` + `JetBrains Mono` para números/dinero).
- Diseño Mobile-First real: botones de acción primaria mínimo `44px` de alto, navegación inferior tipo app nativa en móvil.

## 4. REGLAS DE REGISTRO EN TIEMPO REAL
Al finalizar CADA tarea, bugfix o actualización:
1. Marca la tarea como `[x]` en `docs/04_TASKS.md`.
2. Agrega una entrada en `docs/05_CHANGELOG.md` con formato:
   `[YYYY-MM-DD HH:MM] [TIPO: FEAT/FIX/REFACTOR] [ID-TAREA] - Descripción breve + archivos tocados.`
3. Si hubo un bug, documenta brevemente la causa raíz para futuros agentes.
4. Verifica que `npm run build` / `tsc` compile sin errores antes de dar por cerrada la tarea.

## 5. REGLAS DEL MODO OFFLINE
- La app es offline tolerante: IndexedDB guarda lecturas y una cola `outbox` de escrituras; no es una segunda fuente de verdad.
- Toda entidad que se pueda crear sin conexión debe recibir un UUID generado en el cliente y los inserts deben ser idempotentes.
- Al sincronizar, la base recalcula el dinero. Nunca enviar comisiones, netos ni totales derivados desde el frontend.
- Liquidaciones, onboarding, configuración de local/equipo/catálogo y link público son online-only.
- Los conflictos de agenda se resuelven con las restricciones de la base (`23P01`); la UI debe mostrarlos, nunca ignorarlos.
- Documentación de referencia: `docs/06_OFFLINE.md`.
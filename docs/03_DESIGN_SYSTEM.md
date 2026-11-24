# DESIGN SYSTEM — ANSTUDIOS (ESTÉTICA EDITORIAL / TÁCTIL)

## 1. IDENTIDAD VISUAL Y PRINCIPIO "ANTI-SLOP AI"
- Estética **Editorial / Táctil**: limpia, de alto contraste, con jerarquía tipográfica clara y superficies firmes.
- **Prohibido:** fondos oscuros con degradados neón o violetas/azules genéricos, sombras difusas pesadas (`shadow-xl` / `shadow-2xl` difusos), tarjetas sin borde ni separación clara, y textos decorativos innecesarios.
- **Mobile-First real:** pensado primero para operar rápido con una mano en el celular del dueño o profesional del local, y adaptable a escritorio/tablet.

## 2. PALETA DE COLORES (TOKENS CSS)

Los colores se declaran como **canales RGB** en `src/index.css` y `tailwind.config.js` los expone como `rgb(var(--c-*) / <alpha-value>)`, para conservar modificadores de opacidad (`border-strong/20`, `bg-black/50` en overlays). No escribir hex sueltos en componentes: usar siempre los tokens (`bg-canvas`, `text-ink`, etc.).

### Tema claro (por defecto)
- Fondo general de la app (`bg-canvas`): `#F7F5F0` (crema / alabastro cálido).
- Superficie principal de tarjetas (`bg-surface`): `#FFFFFF`.
- Superficie secundaria / cabeceras suaves (`bg-surface-alt`): `#EFECE4`.
- Borde estándar (`border-base`): `#E2DFD7`.
- Borde de énfasis / alto contraste (`border-strong`): `#141413`.
- Texto principal (`text-ink`): `#141413` (carbón profundo).
- Texto secundario (`text-muted`): `#5C5A54`.
- Color primario de marca (`brand-primary`): `#1E3A2F` (verde bosque clásico) con texto blanco `#FFFFFF`.
- Color acento secundario (`brand-accent`): `#C84B31` (terracota cálido) para alertas o acciones destacadas puntuales.

### Semántica financiera y de estados
- Ingresos / Cobrado / Confirmado: texto `#15803D`, fondo suave `#DCFCE7`.
- Gastos / Adelantos / Cancelado / Ausente: texto `#B91C1C`, fondo suave `#FEE2E2`.
- Pendiente / Por liquidar / En curso: texto `#B45309`, fondo suave `#FEF3C7`.

### Tema oscuro (opcional por dispositivo)

Se activa con `html[data-theme='dark']` y replica la misma paleta cálida, sin negro puro ni neón. `color-scheme: dark` para que los controles nativos acompañen.

| Token | Oscuro | Hex |
|-------|--------|-----|
| canvas | `21 20 18` | `#151412` |
| surface | `30 28 25` | `#1E1C19` |
| surface-alt | `41 38 34` | `#292622` |
| border (base) | `61 56 49` | `#3D3831` |
| ink | `243 239 230` | `#F3EFE6` |
| muted | `174 167 156` | `#AEA79C` |
| brand | `47 91 72` | `#2F5B48` |
| accent | `224 102 76` | `#E0664C` |
| income / soft | `110 214 155` / `23 53 33` | `#6ED69B` / `#173521` |
| expense / soft | `240 138 128` / `58 30 27` | `#F08A80` / `#3A1E1B` |
| pending / soft | `240 195 107` / `58 44 20` | `#F0C36B` / `#3A2C14` |
| sombra sólida | `#000000` | `#000000` |

Reglas del modo oscuro:
- Los overlays de modales usan `bg-black/50`, nunca `bg-ink/40` (en oscuro `ink` es claro y el fondo se lavaría).
- No introducir sombras difusas: la sombra sólida desplazada se mantiene, con `#000` como color.
- El tema y el tamaño de letra se guardan en `localStorage` (`anstudios.preferences`) y son **por dispositivo**, no por cuenta.

## 3. TIPOGRAFÍA
- Fuente UI y títulos: `Plus Jakarta Sans` (pesos 500, 600, 700).
- Fuente para montos, horarios, comisiones y métricas: `JetBrains Mono` con `font-variant-numeric: tabular-nums` (`tabular-nums`).
- Regla: **todo importe en pesos (`$`), porcentaje (`%`) o franja horaria** debe usar `tabular-nums` para alinear cifras en columnas y tarjetas.
- **Tamaño de letra** (accesibilidad, elegido en Ajustes): `data-text-size='compact'` = `15px`, sin atributo = `16px`, `data-text-size='large'` = `17.5px` sobre `html`. Los componentes usan unidades relativas (`text-sm`, `text-xs`, `rem`), así que todo escala junto; no fijar `px` en textos nuevos.

## 4. COMPONENTES, ESPACIADO Y TAMAÑOS TÁCTILES
- Botones principales y acciones frecuentes (cobrar, agendar, guardar, enviar recordatorio): altura mínima `44px` (`min-h-[44px]`), etiqueta corta y directa.
- Botón primario: fondo `#1E3A2F`, texto `#FFFFFF`, borde `1px solid #141413`, sombra sólida desplazada sutil `shadow-[2px_2px_0px_#141413]`.
- Tarjetas: `rounded-xl` (`12px`), `border border-[#E2DFD7]`, `bg-white`, padding cómodo (`p-4` en móvil, `p-5` en escritorio).
- Navegación en móvil: barra inferior fija de **5 pestañas** (`Agenda`, `Caja`, `Catálogo`, `Equipo`, `Ajustes`), iconos Lucide de 18 px, etiqueta de 11 px y objetivo táctil de 44 px. Clientes se abre desde Agenda y Liquidaciones desde Caja; no suman pestañas para no romper 320 px.
- **Fotos e imágenes:** `PhotoPicker` con preview cuadrada, borde `1px`, `object-cover` y límite de 5 MB (JPG/PNG/WebP). Avatares de profesionales redondos (`rounded-full`), foto del salón `rounded-lg`/`rounded-xl`. Toda imagen lleva `alt` o `alt=""` si es decorativa.

### Estados de conexión y sincronización
- **Sin conexión / pendiente:** `text-pending` sobre `bg-pending-soft` con borde suave. No usar rojo: el dato local es válido y todavía no es un error.
- **Error de sincronización:** `text-expense` sobre `bg-expense-soft`, reservado para conflictos o rechazos de la base.
- **Badges en tarjetas:** `Guardado local` (pendiente) y `Error al sincronizar` (fallido), en mayúsculas pequeñas como el resto de estados.
- El banner de conexión va arriba del contenido, debajo del encabezado del local, y sus acciones (`Reintentar`) respetan `min-h-[44px]`.
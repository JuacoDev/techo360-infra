# Techo 360 — contexto para trabajar en este monorepo

Proyecto de grado (UPB Bucaramanga) de Juan David Téllez (`Juaco`, git `Juaco@tellez.pro`,
GitHub `JuacoDev`) — plataforma de mapa de calor sobre pobreza/déficit de vivienda en
Colombia. **No es un proyecto en solitario**: hay teammates reales con commits propios
(Daniel Holguín en backend; Luis Morales Palencia y MSoto en frontend). Proceso Scrum
formal (Sprints + Historias de Usuario). Existe un documento de requisitos numerado por
módulo (RF/RNF) que **no vive en ningún repo** — está en Downloads del usuario; si hace
falta, pregúntale por él en vez de asumir que no existe.

## Estructura del monorepo

Repos hermanos bajo esta misma carpeta (`techo360/`):

- **techo360-backend** — FastAPI + PostgreSQL/PostGIS (tabla principal `mapcalordb`),
  Python. Toda la lógica de ingesta de datos vive en `ingestion/`.
- **techo360-frontend** — React + Vite + Leaflet (mapa de calor), CSS plano (no
  Tailwind, no CSS Modules) en `src/Css/StyleComponents.css`.
- **techo360-chatbot** — chatbot RAG (Ollama + LLM propio fine-tuneado, pgvector),
  consumer de RabbitMQ para tareas largas.
- **techo360-proyeccion** — servicio de proyección tabular (no LLM). Ya **no usa
  LightGBM**: se retiró el 23-sep-2026 tras medir que métodos más simples lo
  superaban (regresión lineal sobre los últimos puntos reales para densidad,
  baseline de último valor observado para las coberturas).
- **techo360-infra** — docker-compose, nginx, definiciones de infraestructura.
- `techo360-ai-service` (si aparece referenciado) está **huérfano/muerto** desde
  2026-08-06 — se dividió en chatbot + proyeccion, no es parte de la arquitectura viva.

## Acceso a la base de datos y al VPS

Hay dos vías, y ninguna sustituye a la autorización del usuario para escribir:

1. **Conexión directa a Postgres** vía `DATABASE_URL` en `<ruta_del_env>`, que apunta a una IP de **Tailscale** (`100.116.197.118:5432`), nunca `0.0.0.0` — así el DBA puede usar pgAdmin/DBeaver sin gastar el presupuesto de puertos públicos aprobados por el comité de infraestructura de la universidad (ver más abajo). Para consultar la BD real desde un script Python: leer `DATABASE_URL` de ese archivo con `psycopg2.connect(...)`, exactamente como ya hacen `ingestion/proyeccion_2024.py` y los scripts de una sola corrida en `ingestion/`.
2. **SSH al VPS** (puerto 22, ya aprobado por el CCA): desde el 4-oct es la vía de trabajo habitual en cada fase que el usuario autoriza (consultas de solo lectura con `docker exec`, respaldos, despliegues, mediciones). Nació el 24-sep-2026 como respaldo cuando Tailscale cayó (timeout total en el TCP connect hacia `100.116.197.118:5432`, aunque `tailscale ping` respondía vía DERP).
   - Host: `<IP_VPS>` (IP pública del VPS); usuario `<usuario_ssh>` (confirmado por el usuario, no asumido), con una llave ya instalada en el PC de trabajo (no se documenta su ruta).
   - El usuario pertenece a los grupos `docker`, `adm` y `sudo`, pero `sudo` pide contraseña: `ufw`, `iptables` y `journalctl` con `sudo` no son accesibles; `journalctl` sin `sudo` sí lo es (grupo `adm`).
   - Solo con autorización explícita del usuario para cada fase; si una conexión falla, informar y esperar (no probar otra ruta). El 5-oct hubo dos cortes de acceso desde el PC de trabajo (~19:56 y ~21:15 UTC), resueltos cambiando de red; causa desconocida.

**No pegar contraseñas/URLs de conexión en el chat** — señalar la ruta (`<ruta_del_env>`) en vez de citar el valor, aunque el usuario sea el dueño del archivo.

## Restricciones reales de infraestructura (no asumir que no aplican)

1. **CCA** (comité de aprobación de infra de la universidad) solo aprobó los puertos
   22, 80, 443, 5432 (+ ping/snmp). Por eso **solo `techo360-frontend` expone puerto**
   — corre Nginx como reverse proxy (`/api/` → backend, `/chatbot/` → chatbot, dentro
   de la red Docker). Backend y chatbot nunca exponen su propio puerto directamente.
2. **Dominio y TLS**: el dominio institucional `techo360.bucaramanga.upb.edu.co` **ya
   resuelve** a la IP del VPS (registro A, comprobado el 16-oct-2026 contra DNS público; sin
   AAAA ni CAA) y el `443:443` del frontend está publicado desde el 12-oct. El 443 **sigue
   sirviendo el certificado autofirmado** (CN=localhost; los navegadores avisan). El intento
   de Let's Encrypt (HTTP-01) del 17-oct falló en *staging* con «Timeout during connect»:
   el puerto 80 responde desde algunas redes pero los validadores de Let's Encrypt no lo
   alcanzan (probable filtro del lado de la universidad/CCA). Pendiente: que CTIC/CCA abra el
   80 a internet, o validar por DNS-01 con ayuda de CTIC. nginx y el compose ya quedaron
   listos (reto ACME, mounts de certbot); detalle y reversa en
   `techo360-infra/docs/certificado-letsencrypt.md`. **Sigue sin confirmarse con CTIC** la
   autenticación de dominio de email (Brevo, SPF/DKIM): no darla por hecha.
3. VPS: 6 CPU y 11 GiB de RAM (medido el 5-oct-2026 con `nproc` y `free`), **sin GPU** —
   Ollama en producción corre un modelo pequeño (~3B parámetros o menos) con una cuota
   de 3 CPU y 3 GiB. La suma de los límites de CPU de los contenedores es 5,3 de las 6.
   Modelos grandes se entrenan en GPU local de algún teammate, nunca en la VPS.
4. 3 bases Postgres separadas: `postgres-principal` (PostGIS, `mapcalordb`),
   `postgres-vector` (compartida chatbot+proyeccion), `postgres-users`.

## Git — flujo testing-first, NUNCA development directo por defecto

Convención establecida y confirmada repetidamente en este proyecto:

1. El trabajo nuevo va primero a la rama **testing** de cada repo, no a `development`.
2. Cuando algo está verificado, se hace merge **testing → development** explícito
   (nunca al revés) — si `development` tiene commits que testing no tiene, primero se
   sincroniza testing desde development.
3. No trabajar directo en `development` salvo que el usuario lo pida explícitamente
   para esa tarea puntual.
4. `main` es solo snapshot de sprint/milestone — nunca recibe trabajo directo.

**Nombre exacto de la rama testing por repo (verificar siempre con
`git ls-remote --heads origin`, este proyecto ha tenido colisiones reales
`Testing`/`testing` en Windows por case-insensitivity del filesystem):**
- `techo360-backend` → `testing` (minúscula)
- `techo360-frontend` → `Testing` (mayúscula)
- `techo360-chatbot` → `Testing` (mayúscula)
- `techo360-infra` → `Testing` (mayúscula)
- `techo360-proyeccion` → `Testing` (mayúscula)

No asumir que el nombre se mantuvo estable de una sesión a otra — este proyecto ha
reestructurado ramas más de una vez.

## Convenciones de ingeniería ya establecidas en `techo360-backend/ingestion/`

Este es el patrón real que sigue el código de ingesta de datos (`ingestion/*.py`) — hay
que seguirlo, no improvisar uno nuevo:

- **Documentación honesta en docstrings**, no en un archivo separado de
  "decisions-and-learnings" (no existe tal archivo) — las decisiones metodológicas
  (fórmulas de fiabilidad, por qué una fuente sí/no se usa, limitaciones conocidas) se
  documentan directo en el docstring del módulo relevante, con bloques `>>> AVISO
  IMPORTANTE, no ocultar <<<` para lo que no se debe minimizar. El índice central de
  convenciones de la columna `originVar` de `mapcalordb` vive en
  `ingestion/db.py` (líneas ~100-200) — siempre agregar ahí una entrada nueva cuando se
  agrega un origen nuevo, con referencia cruzada al adapter que lo genera.
- **Scripts de una sola corrida** (correcciones, re-etiquetados, auditorías) viven en
  `ingestion/` junto a los adapters, con flag `--dry-run` obligatorio, y NO se agregan
  al plan semanal del scheduler (`ingestion/run.py`/`scheduler.py`) si son correcciones
  puntuales sobre datos históricos fijos — solo se corren a mano cuando hace falta.
  Ejemplos reales: `reetiquetar_ultimo_valor_observado.py`,
  `auditoria_cobertura_variables.py`, `actualizar_densidad_dane.py`.
- **Antes de escribir en la BD real**: siempre `--dry-run` primero, checksum
  (`hashlib.sha256` sobre las filas relevantes) del estado "antes" de todo lo que NO
  debería cambiar, sanity check con umbral de aborto explícito si el nuevo cálculo se
  desvía demasiado de lo ya existente (ver `actualizar_densidad_dane.py` como
  plantilla), y verificación "después" contra ese mismo checksum.
- **UPDATE, no INSERT duplicado**: `mapcalordb` tiene un trigger `BEFORE INSERT` que
  lanza excepción ante duplicado — por eso `guardar_indicador()` en `ingestion/db.py`
  intenta `UPDATE` primero (por llave única `codigoDivipola+nameVar+yearM`, o por
  nombre si no hay código) y solo hace `INSERT` si no actualizó ninguna fila. Reusar
  esa función, no escribir SQL de insert directo.
- **Join por `codigoDivipola`, nunca por nombre de municipio** — nombres duplicados
  entre municipios reales distintos (ej. "Sabanalarga") ya causaron un bug real de
  UPDATE cruzado. La tabla `zonas_municipio` (1,105 filas, capa canónica IGAC) es la
  referencia contra la que se audita "qué municipio existe de verdad" para el mapa —
  hay ~20 códigos DANE reales (corregimientos departamentales de Amazonas/Guainía/
  Vaupés) que NO están en esa capa; es un desalineamiento real documentado, no basura
  a limpiar sin más.
- **Prefijo `"proyeccion-"` en `originVar`** = dato de relleno/proyección, lo detecta
  el frontend (`esProyeccion()` en `PanelIndicadores.jsx`) para separar visualmente
  "Fuentes confirmadas" de "Proyecciones" con badge de fiabilidad
  (`intervaloConfianza`, reusado como % 0-100, no como intervalo estadístico riguroso).
  Cualquier origen SIN ese prefijo se muestra como dato real/confirmado — si algo es
  relleno pero no lleva el prefijo, es un bug de clasificación (ya ocurrió una vez con
  `"ultimo-valor-observado"`, corregido).
- **Excluir filas agregadas espurias**: TerriData mezcla filas de total nacional
  (`"01001"`) y total departamental (código terminado en `"000"`) junto con las
  municipales reales en el mismo export — siempre filtrar antes de usar, ver
  `terridata_adapter.py::_es_agregado_nacional/_es_agregado_departamental` como
  referencia de qué ya se sabe que hay que excluir.
- **Verificar en vivo, no confiar en documentación externa sin cruzarla**: varias
  fuentes gubernamentales (páginas de DANE, resúmenes de búsqueda web) han resultado
  desactualizadas o imprecisas respecto a lo que la fuente real expone — antes de
  comprometerse a una fuente para scraping, confirmar contra la fuente cruda (API,
  export real) con al menos 2 métodos cuando sea posible.

## Frontend — convenciones

- CSS plano en `src/Css/StyleComponents.css`, sin scoping — cuidado con clases
  duplicadas entre bloques (ya hay precedente de dos bloques de reglas para el mismo
  componente en el mismo archivo).
- No hay suite de Playwright versionada en el repo (`@playwright/test` se agregó como
  devDependency, pero las verificaciones puntuales se hacen con scripts ad-hoc que se
  borran después de confirmar, no se dejan commiteados salvo que el usuario pida una
  suite real).
- El frontend local (`npm run dev`, puerto 5173) apunta por defecto a la **API de
  producción real** (archivo de entorno con `VITE_API_URL`), no a localhost — no hace falta levantar
  el backend en local. La API requiere sesión (`Authorization: Bearer <token>`); sin
  credenciales de prueba, la forma establecida de verificar cambios de UI es
  **mockear las rutas de red con Playwright** (`page.route(...)`) usando datos que
  respeten el shape real que expone `techo360-backend/routers/zonas.py` — nunca pegar
  URLs de producción sin mockear si no hay login real disponible.
- `ANIO_INDICADORES` en `src/services/api.js` está fijo en 2024 (sin selector de año en
  la UI todavía) — es el único punto que fija qué año se muestra en todo el frontend.

## Estado del proyecto al cierre de esta sesión (2026-09-23)

- **Fase 2 (reducción de dependencia de proyecciones vía scraping)** cerrada
  formalmente. Déficit habitacional: descartado (CNPV 2018 es la única fuente
  municipal que existe, confirmado). Tenencia informal/UPRA: descartado como
  reemplazo (solo PDF, vigencia fija 2020). Densidad poblacional: implementado
  (fuente DANE reemplazó a TerriData para los 1,104 municipios comparables), 2 de 3
  gaps cerrados. Acueducto/alcantarillado (SSPD): decidido no investigar (retorno
  incierto, misma fuente primaria que TerriData).
- **Deuda conocida y documentada, no urgente**: bug de tenencia_informal_terrenos
  (816/1,118 municipios en 0% probablemente falso, documentado en
  `igac_catastro_adapter.py`); 52-53 gaps de acueducto/alcantarillado sin resolver;
  ~20 códigos huérfanos sin decisión sobre si ampliar la capa del mapa; fila fantasma
  `01001`/`Colombia` en `mapcalordb` (inerte, ya excluida de la API).
- Panel de Indicadores del frontend ya separa visualmente "Fuentes confirmadas" de
  "Proyecciones" (con badge de fiabilidad dinámica).

## Operación en producción — actualizado 2026-10-05

Solo lo que un agente futuro necesita; el detalle por servicio está en el README de cada repo (sección «Estado en producción») y en el de `techo360-infra` («Pruebas operativas del 5-oct-2026»). Marcas: COMPROBADO = medido, HIPÓTESIS = inferido, «no verificado» = no se pudo comprobar.

### Reglas de trabajo vigentes (fijadas por el usuario)
- **Autorización por paso.** Ningún merge a `development` (despliega producción) sin un «autorizo paso X» del usuario. Tras cada deploy se entrega: SHA del merge, run y log tal cual, SHA anterior y comando de reversa (`git revert -m 1 <SHA>` + nuevo deploy).
- **BD de producción en solo lectura** salvo autorización escrita: sesión con `default_transaction_read_only = on` (confirmar con `SHOW`). Toda escritura lleva respaldo previo fuera de la rotación (subcarpeta propia, `gzip -t`, sha256) y copia al PC del usuario verificada antes de borrar. Al validar contenido de mensajes, usar indicadores y conteos, no el texto.
- Sin force-push; no borrar ramas sin lista aprobada (solo con `-d`); una rama por cambio; PR a la rama Testing real de cada repo; merge, no rebase.
- Marcar COMPROBADO / HIPÓTESIS / «no verificado» y no escribir nada más fuerte que lo medido.
- Si una herramienta o un permiso bloquea una acción, informar y esperar: no buscar otro camino (por ejemplo, no usar `sudo` con contraseña ni otra ruta de red).
- Procesos locales: terminar solo por PID propio, nunca por nombre de imagen (`taskkill /IM`).
- Nunca imprimir credenciales, tokens ni el contenido de las variables de entorno.
- No tocar sin autorización: Reportes de MSoto, la rama `Corrección` de Jeremy y el chatbot de Daniel.
- SSH al VPS: solo con autorización del usuario para cada fase (ver «Acceso a la base de datos y al VPS» más arriba).

### Qué recrea cada deploy (medido)
- **Backend / frontend / chatbot:** un push a `development` de cada repo corre `deploy-service.sh <servicio>`: backup (se conservan solo los 2 últimos dumps por base), build y recreación **solo de ese servicio**.
  - Frontend: el puerto 80 queda inaccesible ~0,8–0,9 s (D12, medido desde dentro del VPS).
  - Chatbot: si cambia `app/`, se recrea y `chatbot_requests` queda ~3,1 s sin consumer (D10 y D11). Si cambian solo archivos fuera de `app/` (como la migración 0002), no se recrea.
  - Cambiar una variable de entorno del backend exige recrear (`docker compose up -d --no-deps backend`); `restart` no la relee.
- **Infra:** `deploy-infra.yml` corre backup, `git reset --hard origin/development` del repo de infra y `docker compose up -d --remove-orphans`, que **recrea solo los servicios cuya configuración cambió** (el 5-oct: ollama y proyeccion; Redis no se vació). `docker compose up -d --dry-run` lo predice sin ejecutarlo. Proyeccion se recrea cuando cambian las variables de entorno compartidas del compose.
- Cada deploy rota los respaldos: copiar los dumps que importen a una subcarpeta fuera de la rotación.

### Líneas base (5-oct-2026)
- Ollama (cuota de 3 CPU, 3 GiB): 5,32 → 7,18 tokens/s tras D11 (medición directa con un prompt corto). Respuestas reales hasta hoy: ≤ ~250 tokens (1010 caracteres). Tope `NUM_PREDICT = 400`.
- Chatbot: ~46 s por mensaje antes de D11; se atiende en serie (`prefetch 1`). Carga en frío del modelo ~5–12 s.
- Timeouts: chatbot→Ollama 120 s; RPC del backend 200 s; nginx 210 s en `/chatbot/conversaciones` y `/chatbot/mensajes`, 200 s en `/api/`, 60 s por defecto en el resto; el cliente del frontend no tiene timeout propio.
- Red interna: `/api/tags` de Ollama desde el contenedor del chatbot en 0,02–0,09 s. Acceso SSH desde el PC de trabajo: dos cortes el 5-oct (~19:56 y ~21:15 UTC), resueltos cambiando de red; causa desconocida.
- Scores de referencia (por departamento): Antioquia 0,3332, Atlántico 0,1864, Chocó 0,4615 y Santander 0,3953. Fuente: el traspaso del 4-oct; no los medí yo en esta tanda.
- Red, `/api/zonas` (de la verificación posterior a I1, informada por el usuario; no medido por mí, y sin dato de dónde se midió): departamentos 303 ms y 86 ms con 304; municipios 420 ms y 103 ms con 304.

### Trampas aprendidas
- Las pestañas ocultas del navegador frenan los temporizadores (el sondeo de TechoBot se atrasa; reportado, no medido por mí).
- El token de sesión no va en cookie: es un JWT en `Authorization: Bearer` (reportado; la sesión dura 8 h, `ACCESS_TOKEN_EXPIRE_HOURS`).
- `docker stop` bloquea al vigilante que lo lanza: las marcas de tiempo del vigilante se retrasan lo que dure la parada y la espera (COMPROBADO en R2d); contrastarlas con los logs.
- `rabbitmqctl` tarda ~6–7 s por llamada: no sirve para medir ventanas de segundos; usar los eventos de Docker (`docker events`) y los logs.
- `pg_dump` del VPS emite `\restrict`/`\unrestrict`: restaurar con el `psql` del propio contenedor (misma versión); un `psql` local 16.4 no los entiende.
- Al validar patrones de contenido usar indicadores no ambiguos (la `N` de «Estres N» se interpretó como número).
- Windows: los heredocs con apóstrofes fallan en la herramienta Bash (escribir los scripts con la herramienta de archivos); muchos archivos del repo están en CRLF (conservarlos al editar).
- No abrir decenas de conexiones SSH seguidas: `sshd` cortó con `Connection reset by peer` en el intercambio de claves tras una ráfaga de 36 conexiones (HIPÓTESIS: límite de conexiones de `sshd`; no se comprobó). Usar una sola conexión (`tar` o `scp` en bloque) y espaciar las ráfagas.

### Capacidades medidas
- 3 envíos simultáneos al chatbot: 46,3 / 81,0 / 119,7 s. 4 simultáneos: 46,9 / 94,3 / 147,5 / 183,8 s, con ~16 s de margen frente a los 200 s del backend (antes de D11). El quinto no se probó.
- Monitoreo de 60 min: memoria máxima de Ollama 81,9 % de 3 GiB; throttling >50 % durante cada generación (78 % → 5 % en la medición directa de D11); cola `chatbot_requests` con máximo de 4; 0 OOM y 0 reinicios **de Ollama** (el chatbot y el frontend sí se recrearon por D11 y D12).

### No verificado
El nivel 5; Reintentar con la cola ocupada y el posible 504 de nginx; el efecto de D11 medido por la app; el reencolado de un mensaje en vuelo al recrear el chatbot; los proxies o firewalls fuera del VPS; `ufw`/`iptables` (piden `sudo`); la causa de los dos cortes de red.

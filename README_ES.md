# kirunt

[English](README.md) · [Español](README_ES.md)

kirunt es un **paquete de agentes** (agent bundle) que deriva el trabajo intensivo en I/O (lecturas de archivos grandes, generación de código repetitivo y llamadas a herramientas MCP) a un modelo worker más económico, ahorrando tokens en los tres casos.

kirunt es un paquete, no un harness: Kiro CLI se encarga del bucle del modelo, la ejecución de herramientas y la ventana de contexto, mientras que kirunt aporta la configuración del agente, los agentes worker, los hooks, los scripts y las skills que se ejecutan encima. kirunt delega mediante `kiro-cli chat --no-interactive` — no requiere ningún CLI externo, servicio ni autenticación adicional aparte de la que ya usas para ejecutar `kiro-cli`.

Kiro se puede usar tanto desde el IDE como desde la CLI. kirunt instala sus perfiles de agente en `~/.kiro/agents/`, así que ambas superficies pueden cargarlos.

kirunt también mantiene más ligero el contexto del agente principal: `agents/kirunt.json` expone solo los grupos de herramientas `read`, `write`, `shell` y `web`, y ninguna herramienta MCP. El agente por defecto carga más herramientas integradas y los servidores MCP configurados. Las lecturas de archivos grandes y las respuestas MCP las gestionan sesiones worker, así que nunca entran en el contexto del agente principal.

## Cómo funciona

Tres capas, desde el bloqueo estricto hasta la sugerencia flexible:

1. **Hooks** bloquean al agente `kirunt` para impedirle leer archivos grandes y lo redirigen a la skill de lectura masiva (bulk-reader).
2. **Scripts** invocan un agente worker dedicado mediante `kiro-cli chat` y limpian su salida.
3. **Skills** indican al modelo cuándo y cómo llamar a los scripts.

El agente no necesita averiguar cómo delegar. Llama a un script con argumentos con nombre, y el script se encarga del resto, incluido el arranque del modelo worker.

## Requisitos previos

- [`jq`](https://jqlang.org) — `brew install jq`
- `kiro-cli` propiamente dicho (cualquiera que sea la versión que ya estés usando para ejecutar este paquete)
- Un modelo worker al que tengas permiso de llamar con `--model` (el valor predeterminado es `claude-haiku-4.5` — consulta [Configuración](#configuración) para cambiarlo)
- Kiro CLI V3 es el objetivo probado (validado en 2.36.0). Los hooks también aceptan el payload de V2 por compatibilidad, pero las builds actuales ejecutan V3.

> [!IMPORTANT]
> Los nombres de modelo dependen de tu cuenta y del catálogo vigente, así que envejecen.
> **Prefiere `claude-haiku-5.5` cuando tu cuenta lo tenga disponible**: es el worker económico
> más nuevo y la opción recomendada donde exista; `claude-haiku-4.5` es el valor predeterminado
> porque es el respaldo con mayor disponibilidad. Define `worker_model` en `config.json` para
> cambiarlo. No hace falta cambiar nada más — los scripts y las configuraciones de los agentes
> worker nunca codifican un nombre de modelo.

No se requiere ningún CLI externo, un flujo de autenticación separado ni un paso de creación de modos. Los tres agentes worker (`kirunt-bulk-reader`, `kirunt-code-writer`, `kirunt-mcp-caller`) son configuraciones de agentes normales de Kiro incluidas en este paquete.

## Instalación

kirunt no es un «plugin» de Kiro en el sentido del marketplace — Kiro CLI no cuenta con un sistema de empaquetado de ese tipo. Es un paquete de agentes distribuido como archivos planos: instalarlo significa colocar sus componentes donde `kiro-cli` los descubre — las configuraciones de agentes en `~/.kiro/agents/` y el paquete de ejecución (hooks, scripts y skills) en una ubicación estable.

> [!NOTE]
> **¿Instalas en Kiro CLI 2.x o con el motor V2?** usa el agente integrado por defecto de Kiro
> para las llamadas MCP. Instala con `--mcp-caller-mode kiro-default`, o define
> `"mcp_caller_mode": "kiro-default"` en `config.json`. La ruta del agente worker está orientada
> a V3. Los hooks y scripts de kirunt siguen aceptando el payload de V2, así que el bloqueo de
> lecturas, `bulk-read` y `code-write` funcionan con el motor V2 de Kiro 2.36.0.

### Instalación desde GitHub

Requiere `curl` y `tar`. El instalador descarga `Redooz/kirunt` por defecto — define
`KIRUNT_REPO=OWNER/REPO` para instalar desde un fork:

```bash
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh | bash
```

Después, úsalo desde cualquier ubicación:

```bash
kiro-cli chat --agent kirunt
```

Opcionalmente, puedes convertirlo en el agente predeterminado (sin necesidad del indicador `--agent`):

```bash
kiro-cli agent set-default kirunt
```

### Opciones del instalador

```bash
# Fija una rama o un tag de release
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh \
  | KIRUNT_VERSION=v0.1.0 bash

# Instala en otra ubicación
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh \
  | KIRUNT_HOME=/opt/kirunt bash

# Instala desde un fork
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh \
  | KIRUNT_REPO=OWNER/kirunt bash

# Usa el agente integrado por defecto de Kiro para las llamadas MCP (V2 / fallback)
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh \
  | bash -s -- --mcp-caller-mode kiro-default

# Desinstala
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh \
  | bash -s -- --uninstall
```

Define `KIRUNT_SHA256` para verificar el archivo descargado. El instalador rechaza cualquier
`mcp_caller_mode` distinto de `worker` o `kiro-default`.

### Instalación de desarrollo desde un checkout

Para trabajar en kirunt, ejecuta el instalador directamente. Es el mismo script que usa la
instalación de una línea:

```bash
install/install.sh
```

Se aplican las mismas opciones: `KIRUNT_HOME=/opt/kirunt install/install.sh`,
`install/install.sh --mcp-caller-mode kiro-default` e `install/install.sh --uninstall`.
Volver a ejecutarlo es idempotente.

Valida cualquier configuración instalada:

```bash
kiro-cli agent validate --path ~/.kiro/agents/kirunt.json
```

## Scripts

### bulk-read

Delega la lectura de archivos al agente worker `kirunt-bulk-reader`. Los archivos se envuelven en etiquetas XML (`<file path="...">`) para delimitar claramente sus límites.

```bash
scripts/bulk-read --question "What does this service do?" --paths src/Service.ts src/Handler.ts

# Seguimiento: vuelve a preguntar con las mismas rutas
scripts/bulk-read --question "Which methods call the database?" --paths src/Service.ts src/Handler.ts
```

### code-write

Delega la generación de código repetitivo al agente worker `kirunt-code-writer`. Elimina los delimitadores Markdown de la salida. Puede escribir directamente en el disco mediante `--target`. `--reference` es obligatorio — sin un archivo cuyos patrones pueda seguir, el worker generaría código sin contexto que no encajaría en ninguna parte del proyecto.

```bash
# Generar y escribir en un archivo
scripts/code-write --spec "Write tests for UserService" --reference tests/OrderTest.ts --target tests/UserTest.ts

# Continuar sobre lo que se acaba de generar, referenciándolo
scripts/code-write --spec "Now add edge case tests" --reference tests/UserTest.ts --target tests/UserEdgeCases.ts

# Enviar la salida a stdout
scripts/code-write --spec "Generate a config stub" --reference config/existing.yaml
```

### mcp-call

Delega una llamada a un servidor MCP (Confluence, AWS docs, GitHub, etc.) en un modelo worker. El agente principal no tiene herramientas MCP propias, así que la respuesta cruda del servidor entraría en su contexto. El worker lee la respuesta y devuelve solo la respuesta resumida.

```bash
# Haz una pregunta; el worker encuentra la herramienta adecuada
scripts/mcp-call --question "Busca en Confluence la página del rollout Q3 y resume la línea de tiempo"

# Llama a una herramienta conocida directamente (omite el descubrimiento)
scripts/mcp-call --tool "@confluence/conf_search" --args '{"query":"Q3 rollout"}' --question "Resume el primer resultado"
```

`--args` y `--args-file` reciben argumentos JSON para `--tool`. Usa uno u otro, no ambos. `--args` requiere `--tool`.

El modo se configura con `mcp_caller_mode` en `config.json`:
- `worker` (valor predeterminado del paquete): delega en el agente dedicado `kirunt-mcp-caller`, que usa `includeMcpJson` + `@mcp` y funciona en Kiro CLI V3 (verificado en 2.36.0, donde las herramientas MCP se cargan bajo demanda).
- `kiro-default`: delega en el agente integrado por defecto de Kiro. Usa este modo en Kiro CLI 2.x / el motor V2, o cuando quieras que el agente por defecto gestione las llamadas MCP. En CLI V3 los agentes integrados se seleccionan omitiendo `--agent`; pasar `--agent kiro_default` ahora da error.

### Una sola ejecución por llamada

Cada invocación de `kiro-cli chat --no-interactive` es una sesión nueva sin memoria de llamadas anteriores. Repetir un corpus de archivos entre llamadas es precisamente el coste que este paquete existe para evitar, así que kirunt no lo hace — cada llamada funciona de forma independiente. Volver a enviar archivos no tiene coste donde importa, porque el corpus se envía al modelo worker y nunca entra en el contexto del agente principal.

## Hooks

### check-file-size (hook `read`)

Se ejecuta en cada llamada a la herramienta `read`. Bloquea las lecturas de archivos completos que superen `min_lines` (config.json; valor predeterminado: 350). Acepta tanto el payload V3 de un solo `read_file` (`tool_input.path` + `offset`/`limit`, resuelto contra el `cwd` del evento) como el payload V2 con `tool_input.operations[]`. Permite continuar en estos casos:
- Lecturas dirigidas (`offset` o `limit` establecido, incluido `0`)
- Archivos por debajo del límite
- Archivos inexistentes (deja que `read` gestione el error)
- Herramientas distintas de `read_file` cubiertas por el matcher `read` (listar directorios, buscar, etc.)
- Todo, sin condiciones, cuando `enable_bulk_reader: false` en config.json (ver más adelante)

### check-bash-read (hook `shell`)

Se ejecuta en cada llamada a la herramienta `shell`. Detecta `cat`, `head`, `tail`, `less` y `more` sobre archivos grandes. Permite continuar en estos casos:
- Comandos canalizados (`cat file | grep`) — lecturas dirigidas
- Redirecciones (`cat file > out`) — no leen el contenido hacia el contexto
- Comandos que no son de lectura (`git status`, `grep`, etc.)
- Todo, sin condiciones, cuando `enable_bulk_reader: false` en config.json

Ambos hooks leen desde stdin el JSON del evento `PreToolUse` y comunican su decisión mediante el código de salida: `0` permite la operación y `2` la bloquea, mostrando el motivo en stderr (el contrato de hooks de Kiro — distinto de la convención de decisión JSON en stdout que usaba Claude Code en el plugin original). Los hooks se instalan como definiciones V3 con ámbito de perfil (`trigger: "PreToolUse"`), no como archivos globales en `~/.kiro/hooks/`, así que solo afectan al agente `kirunt`.

## Configuración

Todos los ajustes de kirunt viven en un único archivo: `config.json`
(o `~/.kiro/kirunt/config.json` una vez instalado). No hay variables de
entorno para estos ajustes — edita el JSON directamente.

| Clave | Tipo | Valor predeterminado | Propósito |
|-------|------|---------|-----------|
| `min_lines` | number | `350` | Número de líneas por encima del cual los hooks de lectura/bash bloquean y redirigen |
| `worker_model` | string | `claude-haiku-4.5` | Modelo que se pasa a `kiro-cli chat --model` para las llamadas delegadas. **El único lugar que debes editar para cambiar el modelo worker** — los scripts y las configuraciones de los agentes worker nunca codifican un nombre de modelo. Prefiere `claude-haiku-5.5` cuando tu cuenta lo tenga disponible |
| `timeout_seconds` | number | `180` | Techo de tiempo para una invocación al worker |
| `enable_bulk_reader` | boolean | `true` | Interruptor único y autoritativo para la capacidad de lectura masiva — ver más adelante |
| `enable_code_writer` | boolean | `true` | Interruptor para la capacidad de escritura de código — solo afecta al script, sin un hook que lo coordine |
| `enable_mcp_caller` | boolean | `true` | Interruptor para la capacidad de llamadas MCP — solo afecta al script, sin un hook que lo coordine |
| `mcp_caller_mode` | string | `worker` | `worker` (agente dedicado `kirunt-mcp-caller`, valor predeterminado en V3) o `kiro-default` (agente integrado por defecto de Kiro — se selecciona omitiendo `--agent` en V3; ver los comentarios en `scripts/lib/kirunt.sh`). Si el valor no es reconocido, el código usa `worker` |

`KIRUNT_KIRO_CLI_BIN` sigue siendo una variable de entorno (no un ajuste en
`config.json`): sobrescribe cómo se invoca el binario `kiro-cli` para las
llamadas delegadas — es plomería de bajo nivel para apuntar a un binario
distinto, no un ajuste de comportamiento de kirunt.

Después de editar `config.json` no es necesario reiniciar nada — cada
invocación de un hook o script lo relee desde disco.

Si instalaste kirunt globalmente (`install/install.sh`), edita
`~/.kiro/kirunt/config.json` — es una copia independiente del archivo del
repositorio, no un symlink. Para propagar un cambio hecho en el repo a una
instalación existente, vuelve a ejecutar `install.sh`.

### Desactivar bulk-reader de forma segura

`enable_bulk_reader` es leído por **ambos** hooks y por el script `bulk-read`, y es el único interruptor que los mantiene sincronizados. Establecerlo en `false`:
- Hace que `check-file-size` y `check-bash-read` permitan todo de forma incondicional (dejan de bloquear, ya que no habría ningún destino útil al que redirigir).
- Hace que el propio `bulk-read` se niegue a ejecutarse (defensa en profundidad, por si algo lo llama directamente).

**No** intentes desactivar bulk-reader editando únicamente el script o únicamente los hooks — si los hooks siguen bloqueando pero la delegación está desactivada, el agente principal queda atascado: bloqueado para leer directamente, rechazado por la ruta de delegación, y empujado hacia lecturas fragmentadas por `offset`/`limit` que cuestan aproximadamente tantos tokens como una sola lectura grande (a veces más, por la sobrecarga repetida de las llamadas a herramientas). Si quieres limitar en lugar de desactivar por completo, aumenta `min_lines` — así mantienes coherente el par bloqueo/delegación mientras cambias el punto en el que se aplica el límite.

### Desactivar code-writer

`enable_code_writer: false` es seguro y sencillo — no existe ningún hook que imponga el uso de code-writer (la misma limitación que documentaba el plugin original), por lo que desactivarlo simplemente hace que el agente principal vuelva a escribir el código por sí mismo, exactamente como si este paquete no estuviera instalado.

## Qué no se delega

Este paquete está diseñado para saber cuándo NO delegar:
- **Depuración** — requiere el razonamiento del agente principal, no un resumen
- **Edición** — el agente necesita el contenido exacto en el contexto; usa lecturas dirigidas (`offset`/`limit`)
- **Archivos pequeños** — la sobrecarga de la delegación supera el ahorro por debajo del límite
- **Decisiones arquitectónicas** — las decisiones de criterio permanecen en el agente principal

## Evals

```bash
# Enrutamiento de hooks + capa de transporte — no necesita acceso a un modelo real (kiro-cli simulado)
bash evals/run.sh

# También vuelve a medir el ahorro de tokens contra el modelo worker real — necesita kiro-cli + acceso al modelo
bash evals/run.sh --benchmark

# Contrasta la estimación anterior contra la contabilidad real de la ventana de contexto de kiro-cli
# (solo V2 hoy; ver "Benchmarks" abajo) — necesita kiro-cli + acceso al modelo
bash evals/run.sh --context-benchmark

# Comportamiento real del worker MCP — necesita kiro-cli + acceso al modelo y node (servidor MCP fixture)
bash evals/run.sh --mcp-live
```

`run.sh` ejecuta 79 casos offline: 28 para `check-file-size` (payloads V2 y V3), 20 para `check-bash-read`, 15 para la capa de transporte (`scripts/lib/kirunt.sh`, con `kiro-cli` simulado) y 16 para `mcp-call` (validación de argumentos y modo de delegación, también con `kiro-cli` simulado). Todos deben aprobarse (salida `0`) sin acceso a un modelo activo. `--mcp-live` añade 9 comprobaciones en vivo contra el servidor MCP fixture: una consulta con una pista genérica de herramientas debe llamar a la herramienta MCP, una pregunta aritmética autocontenida no debe hacerlo, y una llamada explícita con `--tool` debe llegar al servidor fixture. `evals.json` contiene 6 escenarios de extremo a extremo que describen el comportamiento esperado del modelo (redirección de bulk-read, generación mediante code-write, un caso de depuración que NO debe delegarse, delegación MCP, fallo con MCP vacío y una llamada explícita con `--tool`) — estos escenarios describen el comportamiento esperado para verificación manual o basada en agentes, en lugar de comprobarse automáticamente mediante `run.sh`. `--context-benchmark` y `--mcp-live` quedan excluidos de `--all` porque son más lentos y necesitan acceso a un modelo activo — hay que activarlos explícitamente.

## Benchmarks

Medidos con los propios fixtures de este paquete (`evals/fixtures/`) usando `claude-haiku-4.5` en Kiro CLI V3 (2.36.0), una ejecución representativa:

| Escenario | Líneas | Sin kirunt | Con kirunt | Ahorro |
|-----------|--------|------------|------------|--------|
| Un solo archivo grande | 602 | 12.006 tk | 142 tk | 98% |
| Lectura cruzada de varios archivos | 692 | 12.686 tk | 206 tk | 98% |
| Par de código fuente y prueba | 90 | 680 tk | 221 tk | 67% |
| Generación de código | — | 1.690 tk | 0 tk | 100% |
| Llamada MCP (página de fixture) | — | 1.447 tk | 163 tk | 88% |

En total: **97% de ahorro** en estos cinco escenarios (`bash evals/run.sh --benchmark`). Los recuentos de tokens son una estimación conservadora de `caracteres / 4`; la salida de generación se pondera 5x para aproximar el precio por token de salida. Tus propios resultados variarán según el tamaño de los archivos y el modelo worker. El benchmark ahora falla de forma explícita si una delegación no devuelve respuesta, en lugar de reportar 0 tokens y un 100% falso.


### Contraste contra el uso real de la ventana de contexto

kiro-cli no expone ninguna API pública ni comando que devuelva un recuento absoluto de tokens por solicitud: `/usage` reporta créditos de facturación a nivel de cuenta, y `/context` reporta un porcentaje de la ventana de contexto redondeado a un decimal — ninguno de los dos es lo bastante preciso para medir un solo archivo fixture de forma aislada, y esto es una [limitación abierta conocida](https://github.com/kirodotdev/Kiro/issues/5760) del propio CLI.

Con `KIRO_LOG_LEVEL=trace`, el log de CLI V2 (`$TMPDIR/kiro-log/kiro-chat.log` en macOS) registra un evento `EndStream` por turno con `context_usage_percentage` como un float sin redondear — más precisión que la que la interfaz de terminal muestra jamás. La misma estructura tiene campos `total_tokens` / `*_input_tokens` / `output_tokens`, pero el backend nunca los rellena; el porcentaje es la señal real más precisa disponible allí.

CLI V3 movió los logs a `~/.kiro/logs/<timestamp>/kiro.log`, y ese formato no expone actualmente `context_usage_percentage`. `context-benchmark.sh` detecta ambas ubicaciones, pero en V3 reporta `n/a` con un aviso explícito en lugar de inventar números. Por tanto, este contraste es solo para V2 hasta que se encuentre una señal de uso utilizable en V3.

`evals/context-benchmark.sh` usa esto para contrastar la estimación de `caracteres / 4` de arriba: para cada escenario ejecuta un agente descartable dos veces en un workspace aislado — una con `resources: []` (línea base, que captura el ruido del entorno proveniente de skills/steering instalados globalmente) y otra con los fixtures del escenario declarados como `resources` — y toma la diferencia entre ambos porcentajes reportados. Esa diferencia, escalada por el tamaño de ventana de contexto que el modelo anuncia, aproxima el coste real en tokens del fixture:

| Escenario | Estimación caracteres/4 | Diferencia real de ventana de contexto |
|-----------|--------------------------|------------------------------------------|
| Un solo archivo grande | 12.006 tk | ~14.600–14.900 tk |
| Lectura cruzada de varios archivos | 12.686 tk | ~15.800–15.900 tk |
| Par de código fuente y prueba | 680 tk | ~850–950 tk |
| Generación de código | 2.635 tk | ~2.900–3.600 tk |

Los números reales son consistentemente ~20–35% más altos que la estimación de `caracteres / 4` — algo esperado, ya que el código (con mucha puntuación, camelCase, símbolos) tokeniza más cerca de caracteres/3.5–3.8 que de caracteres/4, y la estimación existente es deliberadamente conservadora. Esto significa que los porcentajes de ahorro de `--benchmark` mencionados arriba son, si acaso, una *subestimación*.

**Limitaciones:**
- Lee un formato de log interno no documentado; una actualización de kiro-cli puede cambiarlo o eliminarlo sin aviso. V3 ya no expone el campo, así que este contraste es solo para V2 hoy (la estimación principal de `--benchmark` no depende de esto y sigue funcionando en cualquier caso).
- Los logs con `KIRO_LOG_LEVEL=trace` pueden contener rutas de archivo, fragmentos de código y salidas de comandos; `context-benchmark.sh` los escribe en un `TMPDIR` descartable y lo elimina al salir.
- El porcentaje de la ventana sigue siendo una aproximación del recuento real de tokens, no una cifra exacta — pero es una aproximación considerablemente más cercana que `caracteres / 4`, ya que proviene de la contabilidad propia del backend en lugar de una estimación del lado del cliente.
- Los números varían unos pocos puntos porcentuales entre ejecuciones (variación normal de un modelo real) y dependen de la ventana anunciada del modelo (`KIRO_CONTEXT_BENCHMARK_WINDOW`, 200.000 por defecto; ajústala si cambias `KIRO_CONTEXT_BENCHMARK_MODEL` respecto al valor por defecto `claude-sonnet-4.5`).

## Limitaciones conocidas

- **Sin imposición para code-writer** — solo bulk-reader tiene imposición mediante hooks. code-writer depende de que el modelo reconozca cuándo usarlo a partir de la descripción de la skill.
- **Coste de invocación del worker** — cada llamada delegada genera un subproceso completo de `kiro-cli chat` (con su propio inicio, ida y vuelta con el modelo, y cierre) en lugar de una llamada ligera a una API. Esto es más lento por llamada que la invocación directa de acciones del sistema original, aunque sigue siendo mucho más económico en tokens que leer el archivo directamente.
- **La limpieza de stdout es de mejor esfuerzo** — `kirunt_invoke` elimina los códigos de escape ANSI y un prefijo inicial de eco del prompt `"> "` de la salida estándar de `kiro-cli chat`. Esto coincide con el formato de salida actual del CLI; una futura versión de `kiro-cli` que cambie ese formato podría requerir actualizar `scripts/lib/kirunt.sh`.
- **No se impone hoy ningún límite de tamaño de solicitud** — el mensaje se pasa como argumento de línea de comandos a `kiro-cli chat`, por lo que un corpus muy grande puede alcanzar el límite `ARG_MAX` de tu plataforma. Divide las lecturas grandes en lotes más pequeños de `--paths` si te encuentras con esto.

## Créditos

kirunt está inspirado en [shunt](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt),
el paquete de agentes original que deriva el trabajo intensivo en I/O a un modelo worker más
económico. kirunt adapta esa idea a Kiro CLI.

kirunt se distribuye bajo la [Apache License 2.0](LICENSE).

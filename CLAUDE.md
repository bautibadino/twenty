# CLAUDE.md

Twenty is an open-source CRM — an Nx / Yarn 4 monorepo. Main packages: `twenty-front` (React 18, Jotai, Linaria, Vite), `twenty-server` (NestJS, TypeORM, PostgreSQL, Redis, GraphQL), `twenty-shared` (isomorphic types/utils), `twenty-ui`, `twenty-sdk` (application SDK + CLI), `twenty-e2e-testing` (Playwright).

Match the surrounding code — the adjacent files in the directory you are editing beat any written rule, including for file naming, which varies by area.

## House rules

Where this repo differs from your defaults:

- Short-form `//` comments, never JSDoc blocks; comment only WHY (a constraint the code cannot express, still true for a reader who never saw your change), never WHAT.
- Types over interfaces (except when extending third-party interfaces); string literals over enums (except GraphQL enums); no `any`; descriptive generics (`TData`, not `T`).
- Named exports only. Functional components only.
- Prefer event handlers over `useEffect` for state updates.
- No abbreviations in names (`fieldMetadata`, not `fm`); constants in SCREAMING_SNAKE_CASE; component props types suffixed `Props`.
- Use existing guards and helpers before writing your own: `isDefined`, `isNonEmptyArray`, `isPlainObject`, … from `twenty-shared/utils`; `isNonEmptyString`, `isString`, `isNull`, `isObject`, … from `@sniptt/guards`. Reimplementing an existing util is the most common AI-authored defect here.
- Lingui for user-facing strings, `doNotTranslate()` from `twenty-shared/i18n` for text that must stay as written (error diagnostics, protocol tokens); Linaria (zero-runtime, styled-components pattern) for twenty-front styling.
- For Twenty product concepts, consult `packages/twenty-ui/src/icon/icon-dictionary.md` and use the canonical icon.
- Import icons from `twenty-ui/icon`, never directly from `@tabler/icons-react`; action and status concepts should use their action or status icons.
- Test behavior, not implementation: query by user-visible text/roles, `@testing-library/user-event` for interactions.

## Comment sparingly

Most code is self-explanatory and a comment on it is just noise — cognitive overhead to read and maintenance debt to keep accurate. Only comment code that is genuinely unintuitive or complex: a non-obvious why , a workaround, a subtle invariant, a deliberate deviation from the obvious approach. Do not narrate what the code does — the code already says that. When a comment truly earns its place, keep it as terse as possible. This overrides matching the surrounding file's comment density. Write lean even in a verbose file.

Two or three lines, and a hard ceiling of five. "Terse" is not relative: much of this repo predates the rule and carries paragraph-length comments, so a file you are editing is not evidence of the standard — it is usually the thing the rule exists to stop spreading. If the why will not fit in five lines, the explanation belongs in a module docstring, a README or an ADR, and the comment is one line pointing there.

The same ceiling applies to a comment's neighbours: do not restate one fact in the Dockerfile, the manifest and the code that reads it. Put it once, where a reader hits it first, and let the others be silent.

Docstrings carry the what and the design; they are not exempt from terseness, but they are the right home for anything a comment is too small to hold.

## Commands

```bash
bash packages/twenty-utils/setup-dev-env.sh   # Postgres/Redis + DB init; only for tasks needing a running app
yarn start                                    # front + server + worker

npx jest path/to/file.spec.ts --config=packages/<pkg>/jest.config.mjs   # single test file (preferred)
npx vitest run --root packages/twenty-ui --project unit <file>          # twenty-ui runs on vitest, not jest
npx nx test twenty-server                     # package unit tests (same for twenty-front, ...)
npx nx run twenty-server:test:integration:with-db-reset
npx nx storybook:build twenty-front && npx nx storybook:test twenty-front

npx nx lint:diff-with-main twenty-server      # diff-based lint (fast; add --configuration=fix); run with typecheck after changes
npx nx fmt <pkg>                              # format
npx nx build twenty-shared                    # required before building/testing packages that depend on it
npx nx database:reset twenty-server
npx nx run twenty-front:graphql:generate      # after GraphQL schema changes (--configuration=metadata for metadata schema)
```

## Gotchas

- **`twenty-shared/dist` is per-branch state nothing tracks.** After switching branches or editing `twenty-shared`, run `npx nx build twenty-shared --skip-nx-cache` before trusting any typecheck or test failure in a dependent package.
- **Nx caching can serve a stale pass.** To verify a fix, run `npx tsgo -p tsconfig.json --noEmit` in the package directly rather than `nx typecheck`.
- **Do not commit translation catalogs unless translations are the task.** `lingui extract`/`compile` regenerate `packages/twenty-server/src/engine/core-modules/i18n/locales/*.po` and `locales/generated/*` with thousands of lines of churn as a side effect of touching any `msg` string. The i18n pipeline maintains them; leave them out of your commit.
- **Commit messages must not carry AI attribution.** CI rejects commits containing `@anthropic.com` co-author trailers or "Generated with Claude Code" lines.
- **Upgrade commands** (`packages/twenty-server/src/database/commands/upgrade-version-command/`): add or edit files only under the current `TWENTY_CURRENT_VERSION` directory, with a real epoch-ms timestamp strictly greater than every existing one in that directory — CI enforces both, and the upgrade cursor silently skips a command that sorts before an already-applied one. Include `up` and `down`; never rewrite committed command logic. Keep command-only helpers and constants in the version folder, never in runtime modules, and never make runtime code branch on migration state. See `packages/twenty-server/docs/UPGRADE_COMMANDS.md`.
- **Entity file changes need a generated instance command**: `npx nx run twenty-server:database:migrate:generate --name <name> --type <fast|slow>` (slow = adds a data-backfill step).
- A read-only Postgres MCP server is configured in `.mcp.json` for inspecting workspace data, metadata, and migration results. Writes go through the CLI commands above.
- E2E login: click "Continue with Email" and use the prefilled credentials.

## Fork de Bautista (`bautibadino/twenty`)

Este repo es un fork. `upstream` es twentyhq/twenty y se mergea por versión (`merge: upstream twenty/vX into fork`). Lo propio del fork vive en esta sección, al final del archivo, para que los merges de upstream no choquen. `AGENTS.md` es un symlink a este archivo: Codex y Claude leen lo mismo.

### Comunicación

Castellano. Frases cortas, una idea por frase, voz activa. Arrancar con el resultado o la acción. Sin preámbulos ni resúmenes. Términos técnicos sólo si hacen falta.

### Pedidos de clientes: configuración antes que código

Los clientes (por ejemplo Grupo Sport) piden cosas que Twenty ya resuelve sin código: invitar miembros, idioma por usuario (Settings > Experience), campos custom (Settings > Data model), vistas y filtros, dashboards con gráficos agrupados (`modules/dashboards`, `modules/page-layout`), roles. Antes de planear código, verificar si alcanza con configurar. Configurar la instancia de un cliente es una operación remota: pedir la URL y el OK explícito antes.

### Coordinador y subagentes

El agente que recibe el mensaje es el coordinador. Procesa el prompt, escribe un plan corto (qué, qué archivos, qué queda afuera, qué hay que preguntar) y, si hay una decisión de producto, pregunta y espera. Después orquesta workers. No implementa el diff grande.

Tarea muy rápida (la hace el coordinador solo) si cumple todo: cabe en un archivo o es una pregunta de lectura, no cruza front y server, no pide diseño, y no toca auth, permisos, workspace, migraciones ni upgrade commands. Si duda, no es rápida.

Los workers se abren con Orca. La herramienta nativa de subagentes de Claude Code sólo ofrece modelos Claude; los workers GPT salen de `orca`. No decirle al usuario que no se puede usar GPT sin correr antes `orca orchestration worker-start --help`.

- `twenty-server`, datos, análisis e investigación: Codex, `gpt-5.6-terra`, esfuerzo `high`.
- `twenty-front` y `twenty-ui`: Claude Sonnet, esfuerzo `high`.

```bash
orca orchestration run-create --objective "<objetivo en una frase>" --json
orca orchestration task-create --spec "<brief>" --task-title "<título corto>" --json
orca orchestration worker-start --task <task_id> --worktree current --agent codex --model gpt-5.6-terra --effort high --json
orca orchestration worker-start --task <task_id> --worktree current --agent claude --model sonnet --effort high --json
orca orchestration worker-show --dispatch <dispatch_id> --json
orca orchestration worker-read --dispatch <dispatch_id> --json
```

Si Orca rechaza el id del modelo, frenar y preguntar. No sustituir por otro modelo.

El brief de cada Task trae: objetivo, archivos permitidos, qué queda afuera, comandos de verificación exactos (de la sección Commands) y formato del reporte: archivos tocados, `<comando>: <resultado>` por verificación, y pendientes. Tasks sin archivos en común corren en paralelo; dos workers nunca escriben el mismo archivo.

El coordinador revisa el diff, corre una verificación y reporta. Un follow-up por Task si no cumple. Los workers no hacen deploy, no tocan instancias de clientes y no hacen push.

### Memoria

Usar engram: `mem_search` antes de arrancar algo con historia, `mem_save` para decisiones, causas raíz y gotchas. Lo estable y repetido va a este archivo, no sólo a engram.

# Test suite map

| Scope | Location or command |
| --- | --- |
| Rails unit/service/job/request specs | `spec/models/`, `spec/services/`, `spec/jobs/`, `spec/requests/` |
| Architecture contracts | `spec/architecture/` |
| Shared spec support | `spec/support/` |
| Frontend unit/component tests | colocated `*.test.ts` / `*.test.tsx`, run focused with `npx vitest run <file>` |
| Frontend type checking | `npm run typecheck` |
| Frontend lint | `npm run lint` |
| CLI tests | `cli/`, using the declared Go toolchain and `GOWORK=off` where configured |
| Desktop tests/build | `desktop/` package scripts |
| Website tests/build | `website/` package scripts |
| Plugin tests | plugin-owned specs and package/container tests under `plugins/<name>/` |
| Migration checks | `bin/check-migrations`, collision and baseline checks from `.syrus.yml` |

Use the narrowest relevant example or file while implementing. Agent loops,
pollers, GitHub calls, and invocation services use the existing test seams and
stubs; they do not call real agents or GitHub. Broader configured graders run
after the implementation step. See [Testing conventions](../conventions/testing.md).

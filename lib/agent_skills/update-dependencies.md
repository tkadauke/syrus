---
name: update-dependencies
description: Update all packages to their latest compatible versions and fix any regressions.
allowed-tools:
  - Read
  - Edit
  - Write
  - Bash(bundle:*)
  - Bash(npm:*)
  - Bash(yarn:*)
  - Bash(pip:*)
  - Bash(go:*)
  - Bash(cargo:*)
  - Bash(grep:*)
  - Bash(cat:*)
---

# Update dependencies

This skill updates all package manager dependencies to their latest compatible
versions and fixes any regressions.

## Process for each package manager

### Ruby (Bundler)

```bash
bundle update          # update all gems within existing constraints
bundle exec rake test  # or rspec, minitest, etc.
```

If a gem fails: check the changelog, pin the breaking version, note it in
the commit message.

### Node.js (npm)

```bash
npm update             # update within semver ranges
npm test
```

For major version bumps: use `npm install <pkg>@latest` individually,
test after each one.

### Node.js (Yarn)

```bash
yarn upgrade           # update within semver ranges
yarn test
```

### Python (pip)

```bash
pip list --outdated
pip install --upgrade <package>==<version>
# Update requirements.txt or pyproject.toml accordingly
```

### Go

```bash
go get -u ./...        # update all direct + transitive dependencies
go mod tidy
go test ./...
```

### Rust (Cargo)

```bash
cargo update           # updates Cargo.lock within SemVer constraints
cargo test
```

## Strategy

1. **Update within constraints first** — run the package manager's update
   command with no version changes to specfiles. Commit the lockfile if tests
   pass.

2. **Identify outdated packages** — list packages that are pinned below
   their current release. Update one category at a time (patch → minor → major).

3. **Widen constraints only when necessary** — if a dependency can't be
   updated within its current range because the range itself is too tight,
   widen it to `>= current, < next-major` and update.

4. **Security first** — if any package has a known CVE at its current
   version, update it unconditionally even if it requires a major bump.

## Commit message guidance

List what changed:
```
Update dependencies

- rails 7.1.2 → 7.1.3 (security: CVE-2024-XXXX)
- rspec 3.12 → 3.13
- node_modules: 4 packages bumped (patch)
```

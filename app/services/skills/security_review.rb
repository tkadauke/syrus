require "find"

module Skills
  # Built-in skill (EPIC-234): reviews the current diff (or, absent a
  # meaningful diff, the repository as a whole) for OWASP-top-10-style
  # issues, injection risks, and secret leakage — generic to any language
  # Syrus can read. Mirrors this chat environment's own `security-review`
  # skill, but scoped to a repo Syrus has never seen before with zero
  # repo-specific configuration.
  #
  # Deliberately separate from Skills::DependencyAudit and
  # Skills::LicenseAudit: those cover *third-party* dependency risk
  # (known CVEs, license terms). This skill covers the repo's *own* code —
  # the classes of bug a dependency scanner cannot see, like a raw SQL
  # string built by interpolation or a hardcoded credential.
  #
  # Report-only by default, given the sensitivity of auto-fixing security
  # issues without review. `apply_fixes` (boolean, default false) gates
  # whether this skill ever produces a diff at all — and even when true, it
  # may only fix **clearly-scoped, unambiguous** findings (e.g. a single
  # missing input-sanitization call), never a broad refactor. The same
  # apply_fixes-is-the-floor-not-the-ceiling discipline as
  # Skills::DeadCodeSweep: a false apply_fixes always ends via the
  # no_changes report-only path; a true apply_fixes may still end there if
  # nothing found qualifies as unambiguous.
  #
  # Where a real on-disk checkout is available (currently only
  # Steps::RunSkill), this class runs a real, bounded, regex-based
  # secret-leakage pre-scan (mirrors Skills::LicenseAudit's real
  # node_modules scan: a concrete finding demonstrable against a fixture,
  # not just prose) — but never echoes a matched secret's actual value
  # into the generated instructions, since those get persisted to
  # Workflow/Run artifacts and JobLog. Only the file, line, and matched
  # pattern label are reported; the agent is told to redact the same way
  # when it writes its own findings report.
  class SecurityReview < Base
    SECURITY_TOOLS = [
      {
        language: "Ruby",
        signal: "Gemfile",
        tools: [
          "`bundle exec brakeman` if this repo already has Brakeman set up — a Rails-focused static analyzer for injection, XSS, mass assignment, and unsafe redirects",
          "`bundle exec rubocop --only Security` if this repo's Rubocop config already includes the Security cop department"
        ]
      },
      {
        language: "JavaScript/TypeScript",
        signal: "package.json",
        tools: [
          "`npx eslint . --rule '{\"security/detect-*\":\"error\"}'` if `eslint-plugin-security` is already part of this repo's toolchain",
          "`npx semgrep --config=auto` if `semgrep` is already available"
        ]
      },
      {
        language: "Python",
        signal: "requirements.txt",
        tools: [
          "`bandit -r .` if Bandit is already part of this repo's toolchain"
        ]
      },
      {
        language: "Go",
        signal: "go.mod",
        tools: [
          "`gosec ./...` if gosec is already part of this repo's toolchain"
        ]
      }
    ].freeze

    SECRET_PATTERNS = [
      [ "AWS Access Key ID", /AKIA[0-9A-Z]{16}/ ],
      [ "Private key block", /-----BEGIN (?:RSA |EC |OPENSSH |DSA |)PRIVATE KEY-----/ ],
      [ "GitHub token", /gh[pousr]_[A-Za-z0-9]{36,}/ ],
      [ "Slack token", /xox[baprs]-[A-Za-z0-9\-]{10,}/ ],
      [ "Hardcoded credential assignment", /(?i)\b(password|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\b\s*[=:]\s*["'][^"'\s]{8,}["']/ ]
    ].freeze

    EXCLUDED_DIR_NAMES = %w[.git node_modules vendor .bundle tmp log coverage dist build .syrus .next .cache].freeze
    MAX_SCANNED_FILES = 500
    MAX_FILE_SIZE_BYTES = 200 * 1024
    MAX_SECRET_FINDINGS = 20

    def self.skill_name
      "security-review"
    end

    def self.description
      "Reviews the current diff (or the whole repo, absent one) for OWASP-top-10-style issues, injection " \
        "risks, and secret leakage. Report-only by default; can optionally fix clearly-scoped, unambiguous " \
        "findings and commit."
    end

    def self.parameter_schema
      [
        { key: "apply_fixes", type: "boolean", required: false, label: "Apply fixes", default: false }
      ]
    end

    def to_s
      [ intro, pre_scan_section, step_by_step_instructions ].compact.join("\n\n")
    end

    private

    # Present only when a real on-disk checkout was available at
    # resolution time (Steps::RunSkill) — nil for every other resolution
    # path (picker, chat slash command, ScheduledTask fire), which fall
    # back to the generic detection table and category checklist in
    # step_by_step_instructions with no concrete findings to report.
    def scan
      return nil unless @workspace_path

      @scan ||= { languages: detected_languages, secrets: secret_scan }
    end

    def detected_languages
      path = Pathname.new(@workspace_path)
      SECURITY_TOOLS.select { |entry| path.join(entry[:signal]).exist? }
    end

    def secret_scan
      root = Pathname.new(@workspace_path)
      findings = []
      scanned = 0

      Find.find(root.to_s) do |path|
        pathname = Pathname.new(path)

        if pathname.directory?
          Find.prune if EXCLUDED_DIR_NAMES.include?(pathname.basename.to_s)
          next
        end

        next unless pathname.file?
        break if scanned >= MAX_SCANNED_FILES

        begin
          next if pathname.size > MAX_FILE_SIZE_BYTES
        rescue Errno::ENOENT
          next
        end

        scanned += 1
        findings.concat(secret_findings_in(pathname, root))
      end

      { scanned_files: scanned, findings: findings.first(MAX_SECRET_FINDINGS), truncated: findings.size > MAX_SECRET_FINDINGS }
    rescue Errno::ENOENT
      { scanned_files: 0, findings: [], truncated: false }
    end

    def secret_findings_in(pathname, root)
      relative = pathname.relative_path_from(root).to_s

      pathname.readlines(chomp: true).each_with_index.filter_map do |line, index|
        matched = SECRET_PATTERNS.find { |_label, regex| line.match?(regex) }
        next unless matched

        { file: relative, line: index + 1, pattern: matched.first }
      end
    rescue ArgumentError, IOError, Errno::ENOENT, Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      []
    end

    def intro
      <<~TXT.strip
        You are running a security review on this repository: look for
        OWASP-top-10-style issues, injection risks, and secret leakage in
        the current diff — or, if there is no meaningful diff yet to
        review, in the repository as a whole. This is generic to whatever
        language(s) this repo uses; it does not assume any repo-specific
        configuration.

        This is a code-level review, not a dependency scan — third-party
        vulnerability and license checks are separate skills
        (`dependency-audit`, `license-audit`). Focus on this repo's own
        code: how it handles untrusted input, how it authenticates and
        authorizes, how it stores and transmits secrets, and how it talks
        to the filesystem, a shell, a database, or the network.

        Apply fixes: {{apply_fixes}}
      TXT
    end

    def pre_scan_section
      return nil unless scan

      <<~TXT.strip
        ## Automated pre-scan results

        Syrus already scanned this checkout before invoking you — use
        these findings as your starting point rather than re-detecting
        from scratch. Verify against the real repo rather than trusting
        it blindly; a regex-based pre-scan produces candidates, not
        verdicts.

        - Detected languages and recommended static analysis tools: #{languages_summary}
        - Secret-leakage pre-scan: #{secret_scan_summary}

        Do not repeat a matched secret's actual value anywhere in your
        output — logs, commit messages, or your final report. Reference
        it only by file, line, and pattern name (e.g. "hardcoded
        credential assignment at `config/settings.rb:12`"), the same way
        this pre-scan does.
      TXT
    end

    def languages_summary
      languages = scan[:languages]
      return "none detected — no recognized language signal found" if languages.empty?

      languages.map { |l| "#{l[:language]} (from `#{l[:signal]}`)" }.join("; ")
    end

    def secret_scan_summary
      result = scan[:secrets]
      return "#{result[:scanned_files]} file(s) scanned, no likely secrets found" if result[:findings].empty?

      rows = result[:findings].map { |f| "  - `#{f[:file]}:#{f[:line]}` — #{f[:pattern]}" }.join("\n")
      truncated = result[:truncated] ? "\n  - ...additional matches were not shown; the scan stopped at #{MAX_SECRET_FINDINGS} findings." : ""
      "#{result[:scanned_files]} file(s) scanned, #{result[:findings].size} likely secret(s) found:\n#{rows}#{truncated}"
    end

    def step_by_step_instructions
      <<~INSTRUCTIONS.strip
        ## Step 1 — establish what you're reviewing

        Prefer reviewing the current diff over the whole repository — a
        focused review of what actually changed is more useful than a
        repo-wide sweep, and it's what "the current diff or recent changes
        on a branch" means in practice:

        - If this checkout is on a branch ahead of its default branch,
          review `git diff <default-branch>...HEAD` (three-dot, not
          two-dot — it isolates what this branch actually changed even if
          the default branch has moved forward since).
        - If there is no such diff (a fresh checkout of the default
          branch itself, or a branch with no unique commits), review the
          repository as a whole instead. That is a valid, larger-scope
          review, not an error.

        ## Step 2 — run language-appropriate static analysis, then verify manually

        For each language you detect, run its appropriate tool(s) where
        already available in this repo's own toolchain — do not install a
        new dependency merely to run one audit:

        #{detection_table}

        If none of the above are already available, or for anything a
        tool doesn't cover, review the changed (or, per Step 1, whole)
        code manually against these categories. Treat this list as a
        floor, not a ceiling — call out anything else you notice that
        clearly falls under "a real security issue" even if it doesn't
        fit a named category below:

        - **Injection** — SQL, NoSQL, OS command, LDAP, XPath, or template
          injection: any place untrusted input reaches a query, a shell
          command, or an `eval`-like construct without parameterization,
          escaping, or an allowlist.
        - **Broken access control** — missing or incorrect authorization
          checks, direct object references a user could tamper with
          (IDOR), privilege escalation paths.
        - **Cryptographic failures** — sensitive data transmitted or
          stored without adequate protection: plaintext secrets, weak or
          homegrown crypto, missing TLS enforcement.
        - **Insecure design** — a missing security control that no amount
          of correct implementation would fix (e.g. no rate limiting on
          an auth endpoint).
        - **Security misconfiguration** — permissive defaults, verbose
          error pages leaking internals, unnecessary features enabled.
        - **Identification and authentication failures** — weak session
          handling, missing brute-force protection, credentials in URLs.
        - **Software and data integrity failures** — unsigned/unverified
          deserialization of untrusted data, insecure CI/CD or update
          mechanisms.
        - **Security logging and monitoring failures** — security-
          relevant events (auth failures, access-control violations) not
          logged, or logs that themselves leak secrets.
        - **Server-side request forgery (SSRF)** — server-side code that
          fetches a URL built from untrusted input without validating the
          target.
        - **Secret leakage** — hardcoded credentials, API keys, tokens, or
          private keys committed to the repository (see the pre-scan
          above for a starting list; also check config files, fixtures,
          and test files, which are common places a "temporary" secret
          gets left behind).

        ## Step 3 — write the findings report

        For every finding, report: what it is, its file and line (or line
        range), its category from the list above, its severity
        (critical/high/medium/low), and a concrete remediation
        suggestion. Do not include a matched secret's actual value — file,
        line, and pattern name are enough for an operator to find and
        rotate it. Do not present a finding as certain if it depends on
        a data flow you couldn't actually trace — say so and rate it
        accordingly, the same discipline `dead-code-sweep` applies to its
        own findings.

        If you find nothing, say so plainly. That is a valid, successful
        outcome.

        ## Step 4 — apply fixes flag

        If apply fixes is not `true`: stop here. Do not edit, delete, or
        commit anything, no matter how confident you are in a finding.
        Your final report (Step 3) is the entire output. This always
        closes without a diff — a findings-only report is a valid,
        successful outcome even when you found a real vulnerability.

        If apply fixes is `true`: from your findings, fix only the
        **clearly-scoped, unambiguous** ones — specifically, a fix that is
        a single, obviously-correct, narrowly-targeted change, such as
        adding a missing parameterization/escaping call at one call site,
        replacing one unsafe string-interpolated shell/SQL call with its
        safe equivalent, or removing one hardcoded secret and replacing it
        with a reference to this repo's existing configuration/credential
        mechanism (environment variable, credentials store — never invent
        a fake secret value or a new secrets-management approach). Never
        perform a broad refactor, never touch code unrelated to the
        specific finding, and never attempt a fix for anything you rated
        below high confidence in Step 3 — leave it in the report for a
        human to review instead.

        Before committing, run this repository's own grade commands
        (prefer the graders already configured in this repo's
        `.syrus.yml`; otherwise use the test/lint tooling this repo's own
        signals indicate) to confirm the fix doesn't break anything. If
        they pass, commit the fix(es). If any of them fail, do not commit
        — revert your changes, leave the working tree exactly as you
        found it, and report which grade command failed and why instead
        of guessing at a further fix. That is a valid, successful
        outcome — it closes without a diff.
      INSTRUCTIONS
    end

    def detection_table
      SECURITY_TOOLS.flat_map do |entry|
        tools = entry[:tools].map { |t| "  - #{t}" }.join("\n")
        "- #{entry[:language]} (signal: `#{entry[:signal]}`):\n#{tools}"
      end.join("\n")
    end
  end
end

module Skills
  # Built-in skill (EPIC-234): scans the dependency tree for license
  # compliance issues using each detected ecosystem's standard
  # license-listing tooling, and reports what it finds. Report-only,
  # always — unlike Skills::DependencyAudit (which can optionally bump
  # and commit) or Skills::DeadCodeSweep (which can optionally remove
  # unambiguous findings), this skill never produces a diff. It always
  # ends via Steps::RunSkill's no_changes handling, the same happy path
  # Skills::CoverageGapReport/ExplainFailingCi/Investigate use.
  #
  # No repo-specific policy is assumed — just a generic allow/deny
  # parameter (`denied_licenses`, default `"GPL, AGPL"`). An operator
  # wanting a custom policy overrides it per invocation rather than
  # needing a repo-local skill, which is what keeps this built-in
  # instead of borderline (see the Epic description).
  #
  # Ecosystem detection mirrors Skills::DependencyAudit's lockfile
  # signals (which mirror the registered :prepare_detector plugins'
  # signals), so the ecosystems
  # this skill audits agree with what Syrus already installs. Where a
  # real on-disk checkout is available (currently only Steps::RunSkill),
  # the Node ecosystem gets a genuine Ruby-side pre-scan: every
  # `node_modules/*/package.json` (including scoped `@scope/pkg`
  # packages) is read directly for its declared `license` field and
  # classified against the policy — a real finding, not a description of
  # what the agent should go find. This is a static file read exactly
  # like Skills::DependencyAudit's ecosystem detection, not a shelled-out
  # audit command; it exists so the default policy can be demonstrated
  # against a concrete, testable fixture rather than only described in
  # prose. Ruby ecosystem license data lives in installed gemspecs, not
  # anything staticially readable from a `Gemfile`/`Gemfile.lock` alone,
  # so it's left to the agent's own `bundle licenses` invocation like
  # every other ecosystem's real audit.
  class LicenseAudit < Base
    RUBY_ECOSYSTEM = [
      [ "Gemfile", "bundle licenses" ]
    ].freeze

    NODE_ECOSYSTEM = [
      [ "yarn.lock", "yarn licenses list" ],
      [ "pnpm-lock.yaml", "pnpm licenses list" ],
      [ "package-lock.json", "npx license-checker --summary" ],
      [ "package.json", "npx license-checker --summary" ]
    ].freeze

    ECOSYSTEMS = { "Ruby" => RUBY_ECOSYSTEM, "Node" => NODE_ECOSYSTEM }.freeze

    DEFAULT_DENIED_LICENSES = %w[GPL AGPL].freeze

    NODE_SCAN_LIMIT = 25

    def self.skill_name
      "license-audit"
    end

    def self.description
      "Scans the dependency tree for license compliance issues using each detected ecosystem's " \
        "standard license-listing tooling and reports what it finds. Report-only, makes no changes."
    end

    def self.parameter_schema
      [
        { key: "denied_licenses", type: "string", required: false,
          label: "Denied licenses (comma-separated)", default: DEFAULT_DENIED_LICENSES.join(", ") }
      ]
    end

    def to_s
      [ intro, pre_scan_section, step_by_step_instructions ].compact.join("\n\n")
    end

    private

    # Present only when a real on-disk checkout was available at
    # resolution time (Steps::RunSkill) — nil for every other resolution
    # path (picker, chat slash command, ScheduledTask fire), which fall
    # back to the generic step-by-step instructions with no concrete
    # findings to report.
    def scan
      return nil unless @workspace_path

      @scan ||= { ecosystems: detected_ecosystems, node_packages: node_license_scan }
    end

    def detected_ecosystems
      path = Pathname.new(@workspace_path)
      ECOSYSTEMS.filter_map do |ecosystem_name, signals|
        match = signals.find { |file, _command| path.join(file).exist? }
        next unless match

        file, command = match
        { ecosystem: ecosystem_name, file: file, command: command }
      end
    end

    def denied_tokens
      raw = @args["denied_licenses"].presence || DEFAULT_DENIED_LICENSES.join(", ")
      raw.to_s.split(",").map { |token| token.strip.upcase }.reject(&:blank?)
    end

    def flagged?(license)
      return false if license.blank?

      normalized = license.to_s.strip.upcase
      denied_tokens.any? { |token| normalized.start_with?(token) }
    end

    def node_license_scan
      node_modules = Pathname.new(@workspace_path).join("node_modules")
      return nil unless node_modules.directory?

      packages = node_modules.children.select(&:directory?).flat_map do |entry|
        entry.basename.to_s.start_with?("@") ? entry.children.select(&:directory?) : [ entry ]
      end

      packages.filter_map { |pkg_dir| read_package_license(pkg_dir) }.sort_by { |pkg| pkg[:name] }
    end

    def read_package_license(pkg_dir)
      package_json = pkg_dir.join("package.json")
      return nil unless package_json.file?

      data = JSON.parse(package_json.read)
      { name: data["name"].presence || pkg_dir.basename.to_s, license: normalize_license_field(data["license"] || data["licenses"]) }
    rescue JSON::ParserError
      nil
    end

    def normalize_license_field(value)
      case value
      when String then value.presence
      when Hash then value["type"].presence
      when Array then value.filter_map { |entry| entry.is_a?(Hash) ? entry["type"] : entry.to_s.presence }.presence&.join(" OR ")
      end
    end

    def intro
      <<~TXT.strip
        You are running a license compliance audit on this repository:
        detect which package manager(s) it uses, run the ecosystem-
        appropriate license-listing command for each one, and report what
        you find against the policy below. This is a report-only skill —
        it never edits, removes, or replaces a dependency, no matter what
        it finds.

        Denied licenses (deny list — flag a dependency whose license
        starts with any of these, everything else is treated as
        allowed): {{denied_licenses}}
      TXT
    end

    def pre_scan_section
      return nil unless scan

      <<~TXT.strip
        ## Automated pre-scan results

        Syrus already scanned this checkout's lockfiles before invoking
        you — use these findings as your starting point rather than
        re-detecting from scratch. Verify against the real repo rather
        than trusting it blindly.

        - Detected ecosystems and license commands: #{ecosystems_summary}
        #{node_scan_summary}
      TXT
    end

    def ecosystems_summary
      ecosystems = scan[:ecosystems]
      return "none detected — no recognized lockfile found" if ecosystems.empty?

      ecosystems.map { |e| "#{e[:ecosystem]} (`#{e[:command]}`, from `#{e[:file]}`)" }.join("; ")
    end

    def node_scan_summary
      packages = scan[:node_packages]
      return "" if packages.nil?
      return "- Node `node_modules` license scan: no installed packages found" if packages.empty?

      flagged = packages.select { |pkg| flagged?(pkg[:license]) }
      unknown = packages.select { |pkg| pkg[:license].blank? }

      <<~TXT.rstrip
        - Node `node_modules` license scan: #{packages.size} package(s) read, #{flagged.size} flagged, #{unknown.size} with no declared license
        #{flagged_table(flagged)}
        #{unknown_note(unknown)}
      TXT
    end

    def flagged_table(flagged)
      return "  - No flagged dependencies against the current denied list." if flagged.empty?

      rows = flagged.first(NODE_SCAN_LIMIT).map { |pkg| "  - `#{pkg[:name]}` — #{pkg[:license]}" }.join("\n")
      truncated = flagged.size > NODE_SCAN_LIMIT ? "\n  - ...and #{flagged.size - NODE_SCAN_LIMIT} more flagged package(s), not shown here." : ""
      "  Flagged:\n#{rows}#{truncated}"
    end

    def unknown_note(unknown)
      return "" if unknown.empty?

      "  #{unknown.size} package(s) declared no `license` field in their `package.json` — call these out for manual review rather than assuming they're compliant."
    end

    def step_by_step_instructions
      <<~INSTRUCTIONS.strip
        ## Step 1 — detect the package manager(s)

        Check for these lockfile/manifest signals, in this priority order
        within each ecosystem — a repo can use more than one ecosystem at
        once (e.g. a Rails app with a Node-based frontend). Audit every
        ecosystem you find evidence for, not just the first:

        #{detection_table}

        If you find none of these files, stop and report that no
        recognized package manager was detected. Make no changes.

        ## Step 2 — run the license-listing command(s)

        For each detected ecosystem, run its standard license-listing
        command and read the output for every dependency's declared
        license. If the repo has more than one ecosystem, run all of
        them. Where Syrus already pre-scanned `node_modules` above, treat
        that as your starting point and verify anything you're unsure
        about rather than re-reading every `package.json` yourself.

        ## Step 3 — apply the policy

        Classify every dependency's license against the denied list
        above: flag it if its license starts with any denied entry
        (matching is by license family prefix — e.g. a denied entry of
        `GPL` flags `GPL-2.0`/`GPL-3.0` but not `LGPL-2.1`, since LGPL is
        a materially weaker copyleft license and is not implied by a
        `GPL` deny entry). Treat every other declared license as
        allowed. Treat a dependency with no declared license as neither
        flagged nor allowed — call it out separately for manual review,
        since "no license declared" is a compliance risk in its own
        right that a deny-list match can't express.

        ## Step 4 — write the findings report

        Produce your findings as your final report. For every flagged
        dependency, state its name, version (if available from the
        ecosystem's lockfile), its license, and which denied entry it
        matched. List dependencies with no declared license separately.
        Do not exhaustively enumerate every allowed dependency — a
        summary count is enough for the compliant majority; the flagged
        and undeclared-license lists are what the operator needs to act
        on.

        If nothing is flagged and nothing has an undeclared license, say
        so plainly. That is a valid, successful outcome.

        ## Step 5 — make no changes

        Do not edit, remove, or replace any dependency, and make no
        commit, regardless of what you find — this skill is report-only
        by design; a policy violation is an operator decision, not
        something to fix automatically. This always closes without a
        diff, which is the correct, successful outcome: it closes
        without opening a PR.
      INSTRUCTIONS
    end

    def detection_table
      ECOSYSTEMS.flat_map do |ecosystem_name, signals|
        signals.map { |file, command| "- #{ecosystem_name}: `#{file}` → `#{command}`" }
      end.join("\n")
    end
  end
end

module Steps
  # Config-driven codegen pass. Runs after Format and before the grader
  # retry loop's check phase, on *every* iteration — a fix iteration can
  # touch `sources` again just as easily as the first agentic turn did.
  #
  # `.syrus.yml`'s `generated:` array (`GeneratedStep#command`/`sources`/
  # `generates`/`codegen_ignore`) drives it the same diff-scoped way Format
  # uses `formatters:`: an entry runs only when this iteration's diff
  # touches its `sources` glob (an entry with no `sources` configured
  # always runs), regenerating and committing whatever it produces — the
  # commit only happens if the regenerated output actually differs from
  # what's committed, so this doubles as the `regen == committed` check the
  # `GeneratedStep` doc comment describes. Entries marked `codegen_ignore`
  # are skipped here: that flag exists precisely because their generator is
  # non-deterministic across environments (e.g. `db:schema:dump`'s SQLite
  # vs. MySQL adapter output), so auto-running and auto-committing their
  # output here would introduce environment-specific noise rather than fix
  # anything — that assertion is grader-validated, not diff-validated.
  #
  # There is no plugin-provided default for codegen — it's inherently
  # repo-specific (protobuf vs. GraphQL vs. Rails schema dump vary too much
  # to guess) — so this step simply no-ops when `generated:` isn't
  # configured. `generated: false` (or `off`) explicitly opts out.
  class Generate < Base
    include DiffScopedAutofix

    def call
      workspace.setup

      files = changed_files
      if files.empty?
        log("[generate] no changed files this iteration — skipping")
        return
      end

      commands = commands_for(load_syrus_yml, files)
      if commands.empty?
        log("[generate] no applicable generators — skipping")
        return
      end

      run_commands(commands)
      commit_agent_changes("Generate: apply deterministic code generation")
    end

    private

    def commands_for(config, files)
      generated = config&.generated

      case generated
      when false
        log("[generate] generated explicitly disabled in .syrus.yml")
        []
      when Array
        explicit_commands(generated, files)
      else
        []
      end
    end

    def explicit_commands(generated, files)
      generated.filter_map do |entry|
        if entry.codegen_ignore
          log("[generate] skipped #{entry.command.inspect} (codegen_ignore)")
          next
        end

        if files_match?(entry.sources, files)
          entry.command
        else
          log("[generate] skipped #{entry.command.inspect} (no matching sources changed)")
          next
        end
      end
    end
  end
end

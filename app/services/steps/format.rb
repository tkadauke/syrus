module Steps
  # Config-driven formatting pass. Runs after the agentic step
  # (implement/respond) and before the grader retry loop's check phase, on
  # *every* iteration — not just once after the first agentic turn — since a
  # later fix iteration can reintroduce unformatted code just as easily as
  # the first one did.
  #
  # `.syrus.yml`'s `formatters:` array is the source of truth when present:
  # each entry runs only when its own `files:` glob matches at least one
  # file in this iteration's diff; an entry whose glob matches nothing is
  # skipped. `formatters: false` (or `off`) explicitly opts the repo out of
  # formatting altogether, including the plugin defaults below. With no
  # `formatters:` key at all, no formatting runs at all — that is the safe
  # default. An explicit `formatters: []` (a blank array) is the opt-in
  # signal for the `:autofix_command` plugin providers (Ruby's `rubocop -a`,
  # JavaScript's `eslint --fix`/`prettier --write`, Go's `gofmt -w`,
  # Python's `ruff format`/`black`) — every applicable one, gated on this
  # iteration's diff being non-empty (plugin providers don't declare their
  # own file globs the way explicit `.syrus.yml` formatters do).
  class Format < Base
    include DiffScopedAutofix

    def call
      workspace.setup

      files = changed_files
      if files.empty?
        log("[format] no changed files this iteration — skipping")
        return
      end

      commands = commands_for(load_syrus_yml, files)
      if commands.empty?
        log("[format] no applicable formatters — skipping")
        return
      end

      run_commands(commands)
      commit_agent_changes("Format: apply deterministic formatting")
    end

    private

    def commands_for(config, files)
      formatters = config&.formatters

      case formatters
      when nil
        log("[format] no formatters: key in .syrus.yml — skipping (set formatters: [] to opt into plugin defaults)")
        []
      when false
        log("[format] formatters explicitly disabled in .syrus.yml")
        []
      when []
        plugin_default_commands
      when Array
        explicit_commands(formatters, files)
      end
    end

    def explicit_commands(formatters, files)
      formatters.filter_map do |formatter|
        if files_match?(formatter.files, files)
          formatter.command
        else
          log("[format] skipped #{formatter.command.inspect} (no matching files changed)")
          nil
        end
      end
    end

    def plugin_default_commands
      Syrus::PluginRegistry.providers_for(:autofix_command).filter_map do |provider|
        PerformanceLogging.plugin_call(extension_point: :autofix_command, provider: provider, operation: :autofix_command) do
          provider.autofix_command(workspace_path: workspace.path)
        end
      end
    end
  end
end

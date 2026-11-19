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
      revert_out_of_scope_changes(files)
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
        plugin_default_commands(files)
      when Array
        explicit_commands(formatters, files)
      end
    end

    def explicit_commands(formatters, files)
      formatters.each_with_index.filter_map do |formatter, index|
        if files_match?(formatter.files, files)
          next if reusable_target_health?("//:format/#{index}")

          formatter.command
        else
          log("[format] skipped #{formatter.command.inspect} (no matching files changed)")
          nil
        end
      end
    end

    def plugin_default_commands(files)
      Syrus::PluginRegistry.providers_for(:autofix_command).filter_map do |provider|
        result = Syrus::PluginInvocation.call(
          extension_point: :autofix_command, provider:, operation: :autofix_command, on_decline: nil
        ) do
          method = provider.method(:autofix_command)
          supports_changed_files = method.parameters.any? { |kind, name| kind == :keyrest || name == :changed_files }
          kwargs = { workspace_path: workspace.path }
          kwargs[:changed_files] = files if supports_changed_files
          method.call(**kwargs)
        end
        Syrus::PluginInvocation.value(result)
      end
    end

    # Explicit formatter commands may operate on the whole repository even
    # though their configuration is gated by this Job's diff. Keep formatter
    # edits to tracked files within that diff. Untracked files are deliberately
    # left alone because they may be legitimate formatter output, except when
    # they recreate paths this Job deleted or renamed away.
    def revert_out_of_scope_changes(files)
      git = GitRunner.new
      tracked_changes = git.run(
        "diff", "--name-only", "--no-renames", "--diff-filter=DMRTUXB", "HEAD",
        chdir: workspace.path.to_s
      ).split("\n").map(&:strip).reject(&:empty?)
      out_of_scope_files = tracked_changes - files
      deleted_files = git.run(
        "diff", "--name-only", "--no-renames", "--diff-filter=D", "#{default_branch_ref}...HEAD",
        chdir: workspace.path.to_s
      ).split("\n").map(&:strip).reject(&:empty?)
      resurrected_files = if deleted_files.empty?
        []
      else
        git.run(
          "ls-files", "--others", "--exclude-standard", "-z", "--", *deleted_files,
          chdir: workspace.path.to_s
        ).split("\0").reject(&:empty?)
      end
      reverted_files = (out_of_scope_files + resurrected_files).uniq
      return if reverted_files.empty?

      unless out_of_scope_files.empty?
        git.run(
          "restore", "--source=HEAD", "--staged", "--worktree", "--", *out_of_scope_files,
          chdir: workspace.path.to_s
        )
      end
      git.run("clean", "-f", "--", *resurrected_files, chdir: workspace.path.to_s) unless resurrected_files.empty?
      log("[format] reverted #{reverted_files.size} formatter change(s) outside this Job's diff: #{reverted_files.join(', ')}")
    rescue GitRunner::GitError => e
      log("[format] WARNING (non-fatal): could not revert formatter changes outside this Job's diff: #{e.message}")
    end
  end
end

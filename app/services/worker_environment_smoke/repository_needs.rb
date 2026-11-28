class WorkerEnvironmentSmoke
  # What a repository's prepare plan needs from a worker, read from a prepared
  # workspace: the commands it runs and the lockfiles they install from.
  #
  # Recorded on the Repository when a workspace is prepared, so routing can ask
  # for it later without reading the repository (RunQueueResolver runs far too
  # often for that). The first workflow of a new repository therefore routes
  # on the base requirements only; every one after it routes on what the
  # repository actually installs.
  module RepositoryNeeds
    # A prepare command's first word, through common wrappers, to the checks it
    # needs. `bundle install` builds native extensions, so it needs the C
    # toolchain as well as Ruby.
    COMMAND_CHECKS = {
      "bundle" => %w[ruby bundler c_compiler],
      "bundler" => %w[ruby bundler c_compiler],
      "gem" => %w[ruby],
      "rake" => %w[ruby bundler],
      "npm" => %w[node npm],
      "npx" => %w[node npm],
      "node" => %w[node],
      "yarn" => %w[node],
      "pnpm" => %w[node]
    }.freeze
    WRAPPERS = %w[env exec time nice command mise].freeze

    # Lockfile entries that need more than the command implies.
    LOCKFILE_CHECKS = {
      "Gemfile.lock" => { /^    mysql2 \(/ => %w[mysql_client c_compiler] }
    }.freeze

    module_function

    def detect(workspace_path, commands:)
      checks = Array(commands).flat_map { |command| command_checks(command) }
      LOCKFILE_CHECKS.each do |lockfile, patterns|
        path = File.join(workspace_path.to_s, lockfile)
        next unless File.file?(path)

        contents = File.read(path)
        patterns.each { |pattern, needed| checks.concat(needed) if contents.match?(pattern) }
      end
      checks.uniq.sort
    rescue SystemCallError
      checks.to_a.uniq.sort
    end

    # Each `&&`/`;`/`|` segment of a shell command, by its leading program.
    def command_checks(command)
      command.to_s.split(/&&|\|\||;|\|/).flat_map do |segment|
        words = segment.strip.split(/\s+/)
        # `FOO=1 bundle install`, `mise exec -- npm ci`, `env bundle ...`
        words.shift while words.any? && skippable_prefix?(words.first)
        COMMAND_CHECKS.fetch(File.basename(words.first.to_s), [])
      end
    end

    def skippable_prefix?(word)
      word.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/) || WRAPPERS.include?(File.basename(word)) || %w[x -- sudo].include?(word)
    end

    # Persist on the repository when it changed. Never raises: recording is a
    # routing hint, and a prepare step must not fail because of it.
    def record!(repository, checks)
      return if repository.nil? || !repository.respond_to?(:worker_environment_requirements)

      checks = Array(checks).map(&:to_s).uniq.sort
      return if Array(repository.worker_environment_requirements).map(&:to_s).sort == checks

      repository.update_columns(worker_environment_requirements: checks, updated_at: Time.current)
    rescue StandardError => e
      Rails.logger.warn("[WorkerEnvironmentSmoke] recording repository needs failed: #{e.class}: #{e.message}")
    end
  end
end

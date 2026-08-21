module JavaScript
  # :prepare_detector for Node/JS (and TS) repositories: picks exactly one
  # package manager command based on which lockfile is present, in priority
  # order. Matches the signal RepoPrepPlan::AUTO_DETECT used to hardcode for
  # Node repos — npm/yarn/pnpm/bun + package.json detection is identical for
  # JS and TS, so one detector covers both.
  class PrepareDetector
    PRIORITY = [
      [ "yarn.lock",         "yarn install --frozen-lockfile" ],
      [ "pnpm-lock.yaml",    "pnpm install --frozen-lockfile" ],
      [ "package-lock.json", "npm ci" ],
      [ "package.json",      "npm install" ]
    ].freeze

    def self.detect?(repo_path)
      !matching_entry(repo_path).nil?
    end

    def self.prepare_commands(repo_path)
      entry = matching_entry(repo_path)
      entry ? [ entry.last ] : []
    end

    def self.matching_entry(repo_path)
      path = Pathname.new(repo_path)
      PRIORITY.find { |file, _command| path.join(file).exist? }
    end
    private_class_method :matching_entry

    def self.mise_version_file
      ".node-version"
    end

    SPAN_LABELS = [
      [ /\b(?:npm|yarn|pnpm)\s+(?:run\s+)?(?:test|test:react|vitest)\b|\bvitest\b|\bjest\b/, "frontend tests" ],
      [ /\b(?:npm|yarn|pnpm)\s+(?:run\s+)?(?:build|typecheck)\b|\btsc\s+--noEmit\b/, "frontend build" ]
    ].freeze

    def self.span_labels
      SPAN_LABELS
    end
  end
end

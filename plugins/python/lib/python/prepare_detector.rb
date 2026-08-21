module Python
  # :prepare_detector for Python repositories: picks exactly one package
  # manager install command based on which signal is present, in priority
  # order. Matches the signal RepoPrepPlan::AUTO_DETECT's own comment already
  # flagged as deferred: "Python (poetry/uv/pip) deferred until we need it."
  class PrepareDetector
    PRIORITY = [
      [ "uv.lock",            "uv sync" ],
      [ "poetry.lock",        "poetry install" ],
      [ "requirements.txt",   "pip install -r requirements.txt" ],
      [ "pyproject.toml",     "pip install -e ." ]
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
      ".python-version"
    end
  end
end

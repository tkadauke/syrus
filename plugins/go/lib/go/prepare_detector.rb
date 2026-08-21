module Go
  # :prepare_detector for Go repositories: go.mod is the single package-manifest
  # signal for the module system (Go modules), so there is no priority list to
  # pick between like javascript/python — one signal, one command.
  class PrepareDetector
    def self.detect?(repo_path)
      Pathname.new(repo_path).join("go.mod").exist?
    end

    def self.prepare_commands(repo_path)
      detect?(repo_path) ? [ "go mod download" ] : []
    end

    def self.mise_version_file
      ".go-version"
    end

    SPAN_LABELS = [
      [ /\bgo\s+test\b/, "go test" ],
      [ /\bgo\s+vet\b/, "go vet" ],
      [ /\bgo\s+build\b/, "go build" ]
    ].freeze

    def self.span_labels
      SPAN_LABELS
    end
  end
end

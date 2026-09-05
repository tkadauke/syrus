require "go/prepare_detector"
require "go/review_criteria_provider"
require "go/gofmt_autofix"
require "go/dependency_audit_command"

module Go
  extend Syrus::PluginApi

  syrus_plugin "go" do
    description "Go prepare detection: go.mod → go mod download; gofmt autofix; govulncheck dependency scanning; default swallowed-error review criterion"
    long_description "Go provides language-level support for Go repositories. It detects `go.mod`, prepares dependencies with `go mod download`, contributes Go formatting and dependency-audit commands, and adds review criteria for common Go correctness risks.\n\nUse it for Go services, CLIs, libraries, and mixed-language repositories with Go components. It focuses on language conventions rather than a particular web framework."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/go.svg"
    author "Thomas Kadauke"
    category "language"
    prepare_priority 40

    suggests_enabling "Go repositories get `go mod download` prepare, gofmt autofix, and govulncheck dependency scanning." do |signals|
      signals.repositories_detecting("go")
    end

    provides prepare_detector: "Go::PrepareDetector",
             review_criteria_provider: "Go::ReviewCriteriaProvider",
             autofix_command: "Go::GofmtAutofix",
             dependency_audit_command: "Go::DependencyAuditCommand"
  end
end

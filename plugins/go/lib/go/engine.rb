require "rails"

module Go
  class Engine < ::Rails::Engine
    config.after_initialize do
      # Wire up the interface module now that Zeitwerk is active and all
      # Syrus::Plugin::* constants are autoloadable from the main app's lib/.
      Go::PrepareDetector.include(Syrus::Plugin::PrepareDetector)
      Go::ReviewCriteriaProvider.include(Syrus::Plugin::ReviewCriteriaProvider)
      Go::GofmtAutofix.include(Syrus::Plugin::AutofixCommand)
      Go::DependencyAuditCommand.include(Syrus::Plugin::DependencyAuditCommand)

      Syrus::PluginRegistry.register(
        name:             "go",
        version:          Go::VERSION,
        description:      "Go prepare detection: go.mod → go mod download; gofmt autofix; govulncheck dependency scanning; default swallowed-error review criterion",
        long_description: "Go provides language-level support for Go repositories. It detects `go.mod`, prepares dependencies with `go mod download`, contributes Go formatting and dependency-audit commands, and adds review criteria for common Go correctness risks.\n\nUse it for Go services, CLIs, libraries, and mixed-language repositories with Go components. It focuses on language conventions rather than a particular web framework.",
        homepage:         "https://github.com/tkadauke/syrus",
        author:           "Thomas Kadauke",
        icon_url:         "/plugin-icons/go.svg",
        category:         "language",
        prepare_priority: 40,
        provides: {
          prepare_detector:         Go::PrepareDetector,
          review_criteria_provider: Go::ReviewCriteriaProvider,
          autofix_command:          Go::GofmtAutofix,
          dependency_audit_command: Go::DependencyAuditCommand
        }
      )
    end
  end
end

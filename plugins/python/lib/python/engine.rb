require "rails"

module Python
  class Engine < ::Rails::Engine
    config.after_initialize do
      # Wire up interface modules now that Zeitwerk is active and all
      # Syrus::Plugin::* constants are autoloadable from the main app's lib/.
      Python::PrepareDetector.include(Syrus::Plugin::PrepareDetector)
      Python::GraderAugmentor.include(Syrus::Plugin::GraderAugmentor)
      Python::PromptContext.include(Syrus::Plugin::PromptInjector)
      Python::ReviewCriteriaProvider.include(Syrus::Plugin::ReviewCriteriaProvider)
      Python::RuffFormatAutofix.include(Syrus::Plugin::AutofixCommand)
      Python::BlackAutofix.include(Syrus::Plugin::AutofixCommand)
      Python::DependencyAuditCommand.include(Syrus::Plugin::DependencyAuditCommand)

      Syrus::PluginRegistry.register(
        name:             "python",
        version:          Python::VERSION,
        description:      "Python-generic intelligence: uv/poetry/pip prepare detection, " \
                           "pytest JSON-report grader detail, venv/uv prompt reminder, " \
                           "ruff format/black autofix, pip-audit dependency scanning, default type-hint review criterion",
        homepage:         "https://github.com/tkadauke/syrus",
        author:           "Thomas Kadauke",
        icon_url:         "/plugin-icons/python.svg",
        category:         "language",
        prepare_priority: 30,
        provides: {
          prepare_detector:         Python::PrepareDetector,
          grader_augmentor:         Python::GraderAugmentor,
          prompt_injector:          Python::PromptContext,
          review_criteria_provider: Python::ReviewCriteriaProvider,
          autofix_command:          [ Python::RuffFormatAutofix, Python::BlackAutofix ],
          dependency_audit_command: Python::DependencyAuditCommand
        }
      )
    end
  end
end

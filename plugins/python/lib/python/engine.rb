require "rails"

module Python
  class Engine < ::Rails::Engine
    config.after_initialize do
      # Wire up interface modules now that Zeitwerk is active and all
      # Syrus::Plugin::* constants are autoloadable from the main app's lib/.
      Python::PrepareDetector.include(Syrus::Plugin::PrepareDetector)
      Python::GraderAugmentor.include(Syrus::Plugin::GraderAugmentor)
      Python::PromptContext.include(Syrus::Plugin::PromptInjector)

      Syrus::PluginRegistry.register(
        name:             "python",
        version:          Python::VERSION,
        description:      "Python-generic intelligence: uv/poetry/pip prepare detection, " \
                           "pytest JSON-report grader detail, venv/uv prompt reminder",
        homepage:         "https://github.com/tkadauke/syrus",
        prepare_priority: 30,
        provides: {
          prepare_detector: Python::PrepareDetector,
          grader_augmentor: Python::GraderAugmentor,
          prompt_injector:  Python::PromptContext
        }
      )
    end
  end
end

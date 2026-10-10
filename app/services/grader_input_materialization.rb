class GraderInputMaterialization
  Context = Data.define(
    :repository,
    :workflow,
    :step,
    :run,
    :grader_name,
    :grader_definition,
    :workspace_path,
    :destination_path
  )

  def self.call(**kwargs)
    new(**kwargs).call
  end

  def initialize(repository:, workflow:, step:, run:, grader_name:, grader_definition:, workspace_path:, destination_path:, logger: Rails.logger)
    @context = Context.new(
      repository: repository,
      workflow: workflow,
      step: step,
      run: run,
      grader_name: grader_name,
      grader_definition: grader_definition,
      workspace_path: Pathname.new(workspace_path.to_s),
      destination_path: destination_path.presence
    )
    @logger = logger
  end

  def call
    providers = Syrus::PluginRegistry.providers_for(:grader_input_materializer)
    if providers.empty?
      warn("no providers available") if context.destination_path.present?
      return
    end

    providers.each do |provider|
      PerformanceLogging.plugin_call(extension_point: :grader_input_materializer, provider: provider, operation: :materialize_grader_inputs) do
        provider.materialize_grader_inputs(context)
      end
    rescue StandardError => e
      warn("#{provider} failed: #{e.class}: #{e.message}")
    end
  end

  private

  attr_reader :context, :logger

  def warn(message)
    text = "[grader:#{context.grader_name}] grader input materializer warning: #{message}"
    logger.warn(text)
    JobLog.append!(run: context.run, kind: "system", chunk: "#{text}\n")
  end
end

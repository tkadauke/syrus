module ChatTemplates
  class Registry
    UnknownTemplate = Class.new(ArgumentError)

    Rendered = Data.define(:title, :system_message, :user_message)

    ENTRIES = {
      "docs_maintenance" => :docs_maintenance,
      "walkthrough" => :walkthrough,
      "triage" => :triage,
      "postmortem" => :postmortem
    }.freeze

    def self.render(...)
      new(...).render
    end

    def initialize(key:, repository:, params: {})
      @key = key.to_s
      @repository = repository
      @params = params
    end

    def render
      case ENTRIES.fetch(@key) { raise UnknownTemplate, "Unknown chat template: #{@key}" }
      when :docs_maintenance
        render_object(ChatTemplates::DocsMaintenance.new(repository: @repository))
      when :walkthrough
        render_object(ChatTemplates::Walkthrough.new(repository: @repository))
      when :triage
        render_object(ChatTemplates::Triage.new(repository: @repository, target: param(:target)))
      when :postmortem
        render_postmortem
      end
    end

    private

    def render_postmortem
      job_id = param(:subject_job_id).presence || param(:job_id).presence
      job = @repository.jobs.find_by(id: job_id)
      raise ArgumentError, "Postmortem chat requires a valid Job." unless job

      render_object(ChatTemplates::Postmortem.new(job: job))
    end

    def render_object(template)
      rendered = template.respond_to?(:render) ? template.render : template
      user_message = fetch_value(rendered, :user_message).presence || rendered.to_s.strip
      title = fetch_value(rendered, :title).presence || user_message.truncate(80)
      system_message = fetch_value(rendered, :system_message).presence || fetch_value(rendered, :system_prompt).presence

      Rendered.new(title: title, system_message: system_message, user_message: user_message)
    end

    def fetch_value(object, method_name)
      object.public_send(method_name) if object.respond_to?(method_name)
    end

    def param(name)
      @params[name] || @params[name.to_s]
    end
  end
end

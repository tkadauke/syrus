class JobDefinitionUpdater
  Immutable = Class.new(ArgumentError)

  EDITABLE_STATES = %w[backlog needs_triage triaging blocked_by_epic queued].freeze

  def initialize(job)
    @job = job
  end

  def update!(title: nil, description: nil)
    attrs = {}
    attrs[:issue_title] = title if title.present?
    attrs[:issue_body] = description if description.present?
    raise ArgumentError, "title or description is required" if attrs.empty?

    ApplicationRecord.transaction do
      job.lock!
      unless job.state.in?(EDITABLE_STATES)
        raise Immutable, "#{job.slug}'s title and description are immutable once work starts; it is currently #{job.state}."
      end

      job.update!(attrs)
    end

    job
  end

  private

  attr_reader :job
end

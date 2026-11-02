class JobDefinitionUpdater
  Immutable = Class.new(ArgumentError)

  EDITABLE_STATES = Job::DEFINITION_EDITABLE_STATES

  def initialize(job)
    @job = job
  end

  def update!(title: nil, description: nil, title_pending: nil, preserve_updated_at: false)
    attrs = {}
    attrs[:issue_title] = title if title.present?
    attrs[:issue_body] = description if description.present?
    attrs[:title_pending] = title_pending unless title_pending.nil?
    raise ArgumentError, "title or description is required" if attrs.empty?

    ApplicationRecord.transaction do
      job.lock!
      unless job.definition_editable?
        raise Immutable, "#{job.slug}'s title and description are immutable once work starts; it is currently #{job.state}."
      end

      job.assign_attributes(attrs)
      job.save!(touch: !preserve_updated_at)
    end

    job
  end

  private

  attr_reader :job
end

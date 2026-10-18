class GithubIssueJobAttributes
  CREATION_ATTRIBUTE_NAMES = %w[
    skip_prepare
    prepare_skip_reason_override
    delivery_track
    investigation
  ].freeze

  SYNC_ATTRIBUTE_NAMES = %w[
    skip_prepare
    delivery_track
  ].freeze

  def self.for_creation(issue)
    new(issue).for_creation
  end

  def self.for_sync(issue)
    new(issue).for_sync
  end

  def initialize(issue)
    @label_names = Workflows.label_names(issue.labels)
    @labels = issue.labels
  end

  def for_creation
    {
      skip_prepare: label_names.include?(Workflows::SKIP_PREPARE_LABEL),
      prepare_skip_reason_override: prepare_skip_reason,
      delivery_track: Workflows.track_label_value(labels),
      investigation: label_names.include?(Workflows::INVESTIGATION_LABEL)
    }
  end

  # Investigation is intentionally absent here. It is read once at ingest
  # because changing it later would make the Job disagree with the workflow
  # chain that was already instantiated.
  def for_sync
    for_creation.slice(*SYNC_ATTRIBUTE_NAMES.map(&:to_sym))
  end

  private

  attr_reader :label_names, :labels

  def prepare_skip_reason
    "issue_label" if label_names.include?(Job::PREPARE_SKIP_LABEL)
  end
end

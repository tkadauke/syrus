module AgentQuestions
  class PolicyResolution
    Result = Data.define(:eagerness, :eagerness_source, :timeout, :timeout_source)

    def self.for(job)
      new(job).call
    end

    def initialize(job) = @job = job

    def call
      eagerness, eagerness_source = resolve(:question_eagerness, "balanced")
      timeout_seconds, timeout_source = resolve(:question_answer_timeout_seconds, nil)
      Result.new(eagerness:, eagerness_source:, timeout: timeout_seconds&.seconds, timeout_source:)
    end

    private

    def resolve(attribute, fallback)
      [ [ @job, "job" ], [ @job.repository, "repository" ], [ @job.user, "user" ] ].each do |record, source|
        value = record.public_send(attribute)
        return [ value, source ] if value.present?
      end
      [ fallback, "default" ]
    end
  end
end

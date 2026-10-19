module EmergencyLand
  class Eligibility
    Result = Data.define(:eligible, :message) do
      def eligible? = eligible
    end

    def self.call(...) = new(...).call

    def initialize(chat_session:, job:, branch_name: nil, user: chat_session.user)
      @chat_session = chat_session
      @job = job
      @branch_name = GitBranchName.normalize(branch_name)
      @user = user
    end

    def call
      return failure("Emergency land is not enabled on this instance. Enable it, or use complete_implement_step for the normal handoff path.") unless Feature.emergency_land_enabled?
      return failure("emergency_land requires a Coding Mode chat. Open the Job in Coding Mode, or use the normal Job controls.") unless chat_session.coding?
      return failure("#{job.slug} is not in coding state for emergency_land (current: #{job.state}). Open an implemented or approved Job with open_in_coding_mode first.") unless job.coding?
      return failure("#{job.slug} must be linked to this Coding Mode chat. Open it here with open_in_coding_mode first.") unless job.linked_chat_id == chat_session.id
      return failure("Emergency land requires repository admin permissions. Ask a repository admin to perform or confirm the landing.") unless Permission.granted?(user: user, repository: job.repository)
      return failure("branch_name is not a valid branch name. Supply the already-pushed branch associated with this Job.") if branch_name.present? && !GitBranchName.valid?(branch_name)
      return failure("branch_name is required because this Job has no pushed branch recorded. Push the active Coding Mode checkout, then pass that branch name.") if branch_name.blank? && job.branch_name.blank?

      Result.new(eligible: true, message: nil)
    end

    private

    attr_reader :chat_session, :job, :branch_name, :user

    def failure(message)
      Result.new(eligible: false, message: message)
    end
  end
end

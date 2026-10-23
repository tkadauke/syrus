module EmergencyLand
  class Eligibility
    Result = Data.define(:eligible, :message) do
      def eligible? = eligible
    end

    def self.call(...) = new(...).call

    def initialize(chat_session:, job:, repository: job&.repository, branch_name: nil, title: nil, description: nil, user: chat_session.user)
      @chat_session = chat_session
      @job = job
      @repository = repository
      @branch_name = GitBranchName.normalize(branch_name)
      @title = title
      @description = description
      @user = user
    end

    def call
      return failure("Emergency land is not enabled on this instance. Enable it, or use complete_implement_step for the normal handoff path.") unless Feature.emergency_land_enabled?
      return failure("emergency_land requires a Coding Mode chat. Use the normal Job controls outside Coding Mode.") unless chat_session.coding?
      return failure("repository not found or not accessible") unless repository
      return failure("Emergency land requires repository admin permissions. Ask a repository admin to perform or confirm the landing.") unless Permission.granted?(user: user, repository: repository)
      return failure("branch_name is not a valid branch name. Supply a valid pushed branch name.") if branch_name.present? && !GitBranchName.valid?(branch_name)

      if job
        return failure("branch_name is required because #{job.slug} has no recorded branch.") if job.branch_name.blank?
        return failure("branch_name must match #{job.slug}'s recorded branch #{job.branch_name}.") if branch_name.present? && branch_name != job.branch_name
        unless Lander.eligible_state?(job)
          return failure("#{job.slug} is not eligible for emergency land from state #{job.state}; finish or cancel the current lifecycle action first.")
        end
      else
        return failure("title is required for direct emergency land") if title.to_s.strip.blank?
        return failure("description is required for direct emergency land") if description.to_s.strip.blank?
      end

      Result.new(eligible: true, message: nil)
    end

    private

    attr_reader :chat_session, :job, :repository, :branch_name, :title, :description, :user

    def failure(message)
      Result.new(eligible: false, message: message)
    end
  end
end

# frozen_string_literal: true

module ScheduledTasks
  module Cli
    class Run < Syrus::Host::CliCommandHandler
      def call(args:, flags:, user:)
        task = Task.where(user: user).find(args.fetch(0))
        raise Pundit::NotAuthorizedError unless Syrus::Host::RepositoryRecord.writable_by(user).where(id: task.repository_id).exists?

        result = Fire.new(task).call
        raise StandardError, "Fire skipped: #{result.reason}." unless result.fired?

        self.class.text("Created #{result.job.slug}")
      end
    end
  end
end

module Syrus
  module Host
    # Answers repository permission questions for a user. Policy evaluation
    # details are not promised.
    module RepositoryAccess
      def self.write?(user, repository) = ::RepositoryPolicy.new(user, repository).write?
    end
  end
end

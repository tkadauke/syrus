module Signups
  class Creator
    Result = Data.define(:user, :status) do
      def created? = status == :created
      def forbidden? = status == :forbidden
    end

    def self.call(attributes:, invitation: nil)
      new(attributes:, invitation:).call
    end

    def initialize(attributes:, invitation:)
      @user = User.new(attributes)
      @invitation = invitation
    end

    def call
      result = nil

      User.transaction do
        BootstrapLock.fetch!(User::BOOTSTRAP_ADMIN_LOCK_NAME).with_lock do
          invitation&.lock!

          unless signup_allowed?
            result = Result.new(user:, status: :forbidden)
            next
          end

          if user.save
            invitation.accept! if invitation&.usable?
            result = Result.new(user:, status: :created)
          else
            result = Result.new(user:, status: :invalid)
          end
        end
      end

      result
    rescue ActiveRecord::RecordNotUnique
      user.errors.add(:email_address, :taken)
      Result.new(user:, status: :invalid)
    end

    private

    attr_reader :user, :invitation

    def signup_allowed?
      invitation&.usable? || !User.exists? || AppSetting.signups_open?
    end
  end
end

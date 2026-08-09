class PurgeExpiredPasskeyChallengesJob < ApplicationJob
  queue_as :cleanup

  def perform
    PasskeyChallenge.where("expires_at < ?", Time.current).delete_all
  end
end

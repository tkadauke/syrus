module TracksFinishedAt
  extend ActiveSupport::Concern

  included do
    scope :running,  -> { where(finished_at: nil) }
    scope :finished, -> { where.not(finished_at: nil) }
  end

  def running?  = finished_at.nil?
  def finished? = !running?
end

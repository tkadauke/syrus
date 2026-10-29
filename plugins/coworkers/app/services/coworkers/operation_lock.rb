class Coworkers::OperationLock
  class Busy < StandardError; end

  def self.with(coworker, &block) = new(coworker).with(&block)

  def initialize(coworker)
    @coworker = coworker
  end

  def with
    @coworker.class.transaction do
      @coworker.class.lock.find(@coworker.id)
      raise Busy, "coworker has work in flight" if work_in_flight?
      yield
    end
  end

  private

  def work_in_flight?
    WorkUnitLock.active.exists?(lock_key: "coworker:#{@coworker.id}") ||
      @coworker.chats.where(turn_in_flight: true).exists?
  end
end

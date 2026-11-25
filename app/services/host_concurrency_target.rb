require "json"
require "fileutils"
require "tmpdir"

# How much compute work this worker runs at once, found by feedback instead of
# fixed by formula.
#
# Every earlier attempt sized concurrency from estimates -- units per grader,
# reserves for agent turns, learned memory reservations, one whole-host grader
# per worker -- and each one was tuned to the worst case, so together they
# kept a fleet of mostly idle workers refusing work. This controller has no
# model of what a Run costs. It raises the target by one whenever the worker is
# full and healthy, and halves it when the worker is measurably pressured --
# additive increase, multiplicative decrease, the way TCP finds a link's
# capacity. Overshoot is bounded by the halving and made cheap by the
# infrastructure retry of a Run a pressured worker loses.
#
# State lives on the worker itself: only that worker's admissions read or move
# it, and a restart simply starts again from the host's CPU count.
class HostConcurrencyTarget
  ADJUST_INTERVAL = 30.seconds
  MIN_TARGET = 1
  # A ceiling for runaway growth only; pressure is what actually stops it.
  MAX_TARGET_PER_CPU = 3

  def self.reset!(path: default_path) = FileUtils.rm_f(path)

  def self.default_path
    Pathname.new(Dir.tmpdir).join("syrus-host-concurrency#{ENV['TEST_ENV_NUMBER']}.json")
  end

  def initialize(cpus:, now: Time.current, path: self.class.default_path)
    @cpus = [ cpus.to_i, 1 ].max
    @now = now
    @path = Pathname.new(path)
  end

  # Moves the target from one observation and returns it. `active` is the
  # compute work running here now; `pressured` is whether the worker is
  # measurably struggling.
  def observe!(active:, pressured:)
    with_state do |state|
      target = state.fetch("target", initial_target).to_i.clamp(MIN_TARGET, max_target)
      if due?(state)
        if pressured
          target = [ target / 2, MIN_TARGET ].max
          state["adjusted_at"] = now.iso8601
        elsif active >= target
          target = [ target + 1, max_target ].min
          state["adjusted_at"] = now.iso8601
        end
      end
      state["target"] = target
      target
    end
  end

  def initial_target = cpus

  def max_target = cpus * MAX_TARGET_PER_CPU

  private

  attr_reader :cpus, :now, :path

  def due?(state)
    adjusted_at = state["adjusted_at"].presence && Time.iso8601(state["adjusted_at"])
    adjusted_at.nil? || adjusted_at <= now - ADJUST_INTERVAL
  rescue ArgumentError
    true
  end

  # An unreadable or unwritable state file degrades to the initial target for
  # this decision rather than failing admission.
  def with_state
    FileUtils.mkdir_p(path.dirname)
    File.open(path, File::RDWR | File::CREAT, 0o644) do |file|
      file.flock(File::LOCK_EX)
      raw = file.read
      state = raw.present? ? JSON.parse(raw) : {}
      state = {} unless state.is_a?(Hash)
      result = yield state
      file.rewind
      file.truncate(0)
      file.write(JSON.generate(state))
      result
    end
  rescue SystemCallError, JSON::ParserError
    yield({})
  end
end

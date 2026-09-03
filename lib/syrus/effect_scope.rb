module Syrus
  # A scope that remembers how to undo what it installed.
  #
  # `effect` runs an install immediately; whatever it returns, if callable, is
  # recorded as that install's teardown. `dispose` runs the recorded teardowns
  # in **reverse order**, so the last thing installed is the first thing undone
  # -- which is what makes a dependent plugin unwind before the plugin it
  # depends on.
  #
  # Scopes nest: a child's teardowns run before its parent's, so a contribution
  # to a plugin-hosted extension point dies with either side. Modelled on
  # Cordis's `effect(execute) -> Disposable` (the kernel under DeepSeek
  # Harness); see G13 in docs/plans/plugin-model-and-component-moves.md for
  # what does and does not transfer to a multi-process Rails app.
  class EffectScope
    class DisposedScope < StandardError; end

    attr_reader :label

    def initialize(label:)
      @label = label.to_s
      @entries = []
      @children = []
      @disposed = false
    end

    def disposed? = @disposed

    # Runs the install now. A callable return value is the teardown; nil means
    # "nothing to undo". Anything else is a mistake worth surfacing rather than
    # silently dropping, since a missing teardown is invisible until a disable
    # fails to take effect.
    def effect(label = nil)
      raise DisposedScope, "cannot add an effect to disposed scope #{@label.inspect}" if @disposed

      teardown = yield(self)
      return teardown if teardown.nil?

      unless teardown.respond_to?(:call)
        raise ArgumentError, "effect #{label.inspect} in #{@label.inspect} must return a callable teardown or nil, got #{teardown.class}"
      end

      @entries << [ label, teardown ]
      teardown
    end

    # The bare-cleanup shape, for call sites where the thing has already
    # happened and there is nothing to pair with -- a daemon spawned inside a
    # plugin's on_boot, say. `effect` is preferable where the install and its
    # teardown can be written as one expression, because that is what makes
    # the cleanup hard to forget.
    def add_teardown(label = nil, &cleanup)
      raise DisposedScope, "cannot add a teardown to disposed scope #{@label.inspect}" if @disposed
      raise ArgumentError, "cleanup block required" unless cleanup

      @entries << [ label, cleanup ]
      cleanup
    end

    def empty? = @entries.empty? && @children.all?(&:empty?)

    def child(label:)
      raise DisposedScope, "cannot nest under disposed scope #{@label.inspect}" if @disposed

      self.class.new(label: "#{@label}/#{label}").tap { |scope| @children << scope }
    end

    # A failing teardown must not strand the teardowns after it: a half-disposed
    # scope is worse than a logged error, because the next install would stack
    # on top of whatever was left behind.
    def dispose
      return if @disposed

      @disposed = true
      @children.reverse_each(&:dispose)
      @entries.reverse_each { |label, teardown| safely(label) { teardown.call } }
      @entries.clear
      @children.clear
    end

    private

    def safely(label)
      yield
    rescue StandardError => e
      Rails.logger.error("[Syrus::EffectScope] teardown #{label.inspect} in #{@label.inspect} failed: #{e.class}: #{e.message}")
    end
  end
end

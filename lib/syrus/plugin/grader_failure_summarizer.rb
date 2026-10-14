module Syrus
  module Plugin
    # Interface for grader failure summarizers registered with PluginRegistry
    # under :grader_failure_summarizer. Summarizers are consulted by
    # Steps::GraderCollect after a grader Step has failed, and return a short,
    # already-formatted account of *what* failed for the repair agent that runs
    # next.
    #
    # This exists because the grader log is the wrong shape for that question.
    # A failing test suite writes tens or hundreds of kilobytes of prose, the
    # failures are scattered through it, and the excerpt core can afford to
    # keep inline routinely omits most of them. A plugin that already ingested
    # the run's structured results can answer exactly and in a couple of
    # kilobytes instead.
    #
    # Core deliberately does not interpret the result: it embeds the returned
    # lines and nothing more. Which parser applies, what counts as a test case,
    # and how a failure is best described all belong to whichever plugin owns
    # test results -- the same boundary Steps::Grader keeps when it announces
    # test output rather than parsing it.
    #
    # Implementations must define:
    #
    #   summarize_grader_failure(grader_step:, run:, grader_name:) -> Array<String> | nil
    #     Called once per failed grader Step. `run` is the grader's own latest
    #     Run, so results can be looked up by run rather than re-parsed from a
    #     workspace file that may no longer exist on this machine. Return the
    #     lines to show the repair agent, or nil/[] when this summarizer has
    #     nothing to say about that grader (the usual case for a grader that
    #     produced no structured results at all).
    #
    #     Keep it short. The lines travel in the workflow's artifacts column
    #     and are rendered into a repair prompt, so this is a summary, not a
    #     second copy of the log. The method must not raise -- handle missing
    #     records and parse failures internally.
    #
    # Register an implementation at boot time:
    #   Syrus::PluginRegistry.register(
    #     name: "my-plugin",
    #     version: "1.0.0",
    #     provides: { grader_failure_summarizer: MySummarizer }
    #   )
    module GraderFailureSummarizer
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def summarize_grader_failure(grader_step:, run:, grader_name:)
          raise NotImplementedError, "#{self}#summarize_grader_failure is not implemented"
        end
      end

      def summarize_grader_failure(grader_step:, run:, grader_name:)
        raise NotImplementedError, "#{self.class}#summarize_grader_failure is not implemented"
      end
    end
  end
end

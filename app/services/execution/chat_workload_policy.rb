module Execution
  # The workload policy for a chat agent turn.
  #
  # Deliberately one policy for every chat agent. An earlier version of this
  # existed only for custom coworkers, on the reasoning that a coworker holds
  # read grants across repositories, runs unattended on a schedule, and keeps
  # instructions on a branch it can itself write -- so content it reads can
  # persist into its own instructions and act later. That risk is real, but it
  # is a property of *autonomy and breadth*, not of the word "coworker": an
  # interactive coworker chat in one repository is no more dangerous than any
  # other chat, and a non-coworker chat agent given the same grants would be
  # just as dangerous. Splitting containment by chat kind encoded the label
  # instead of the risk, so there is one policy and one operator switch.
  class ChatWorkloadPolicy
    def self.for_current_setting
      new if AppSetting.contained_chat_execution_requested?
    end

    def name = "chat agent"
    def chat_agent? = true

    # Only `required` is a boundary. In `preferred` an unavailable backend must
    # fall back to the worker rather than fail the turn -- the opposite choice
    # is how a capability that ships disabled took every chat down with it.
    def fail_closed? = AppSetting.contained_chat_execution_required?
  end
end

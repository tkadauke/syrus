module Syrus
  module Plugin
    # Adds plugin-owned actions to the chat Jobs workspace without teaching
    # core which optional feature owns them.
    #
    # Providers implement `.payload(chat_session:, jobs:)` and return a hash
    # merged into the job-status response's `extensions` member.
    module ChatJobStatusExtension
    end
  end
end

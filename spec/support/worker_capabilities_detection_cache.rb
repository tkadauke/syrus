# WorkerCapabilities memoizes its capability and version probe results for the life of the process
# (see app/services/worker_capabilities.rb): detection spawns a subprocess per
# probe and fingerprints run for every immutable checkout, so re-probing would
# pay for subprocesses to learn answers that cannot change without a
# restart.
#
# That memo outlives an example. Any spec that stubs `command_available?` to
# simulate a fleet with or without a given tool would otherwise read whatever
# the first example in the process detected, making the result depend on run
# order. Reset before every example so probe stubs mean what they say.
RSpec.configure do |config|
  config.before do
    WorkerCapabilities.reset_detection_cache!
  end
end

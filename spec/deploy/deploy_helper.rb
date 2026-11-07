# frozen_string_literal: true

require "spec_helper"
require "json"

# bin/deploy's implementation loads no Rails: it runs on an operator's machine,
# against a cluster, before the image it is deploying exists. These specs load
# it the same way the executable does.
module DeploySpec
  # Namespaced, not top-level. A bare `ROOT` here is loaded into the same
  # process as every other spec under a parallel runner, where it silently
  # replaced another spec file's own `ROOT` -- a Pathname -- and broke it with
  # "undefined method 'join' for an instance of String" nowhere near this file.
  ROOT = File.expand_path("../..", __dir__)
end

require_relative "#{DeploySpec::ROOT}/lib/deploy/errors"
Dir["#{DeploySpec::ROOT}/lib/deploy/*.rb"].sort.each { |path| require path }

module DeploySpec
  # A kubectl that answers from a table and records what it was asked to
  # change.
  #
  # This is the seam the whole phase suite hangs off. The previous
  # implementation had no equivalent -- its specs extracted bash function
  # bodies with a regular expression and drove them against a shell script
  # pretending to be kubectl -- so they could only assert what a phase ran,
  # never what it decided. Here a phase's decision is the thing under test.
  class FakeKubectl
    attr_reader :namespace, :writes, :reads

    def initialize(namespace: "syrus-test", resources: {}, logs: "", exec: {}, writes: nil, reads: nil)
      @namespace = namespace
      @resources = resources
      @logs = logs
      @exec = exec
      # A sibling pointed at another namespace shares the log, so an example
      # can assert the order of writes across both namespaces -- which is
      # where this deploy's load-bearing orderings live.
      @writes = writes || []
      @reads = reads || []
    end

    # `resources` may hold a value or an array; an array is consumed one entry
    # per read, so an example can say "pending, pending, complete".
    def stub(key, value)
      @resources[key] = value
      self
    end

    def in_namespace(other)
      self.class.new(namespace: other, resources: @resources, logs: @logs, exec: @exec,
        writes: @writes, reads: @reads)
    end

    def exists?(*target)
      !lookup(target).nil?
    end

    def get_json(*target)
      lookup(target)
    end

    def jsonpath(*target, path)
      document = lookup(target)
      return "" if document.nil?

      # Only the handful of paths the phases actually ask for.
      case path
      when "{.spec.suspend}" then document.dig("spec", "suspend").to_s
      when /matchLabels\.(\w+)/ then document.dig("spec", "selector", "matchLabels", Regexp.last_match(1)).to_s
      else document.is_a?(String) ? document : ""
      end
    end

    def logs(*_target, **_options) = @logs
    def describe(*_target) = "describe output"
    def events(**_options) = "events output"

    def apply(manifest)
      record([ "apply", manifest.dig("kind"), manifest.dig("metadata", "name") ], manifest: manifest)
    end

    # Patches are merged into the stored resource, so a phase that writes and
    # then reads back -- pinning Flux's image overrides and verifying them --
    # sees its own write, as it would against a cluster.
    def patch(*target, patch:, type: "merge", field_manager: nil)
      key = @resources.key?(target.join(" ")) ? target.join(" ") : nil
      @resources[key] = deep_merge(@resources[key], patch) if key && @resources[key].is_a?(Hash)
      record([ "patch", *target ], patch: patch, type: type, field_manager: field_manager)
    end

    def set_image(target, pairs)
      record([ "set_image", target, *pairs ])
    end

    def annotate(*target, annotation)
      record([ "annotate", *target, annotation ])
    end

    def delete(*target, **_options)
      record([ "delete", *target ])
    end

    # Keys may name a prefix of the command, so an example can say
    # "deployment/syrus-worker-home bash" without restating the probe script.
    def exec(target, *command, container: nil)
      key = [ target, *command ].join(" ")
      matched = @exec.keys.select { |candidate| key.start_with?(candidate) }.max_by(&:length)
      scripted = matched ? @exec[matched] : nil
      scripted = scripted.shift if scripted.is_a?(Array)
      scripted ||= { stdout: "", status: 0 }
      record([ "exec", target, *command ])
      Deploy::Shell::Result.new(
        argv: [ "kubectl", "exec", target ], stdout: scripted[:stdout].to_s,
        stderr: scripted[:stderr].to_s, status: scripted.fetch(:status, 0)
      )
    end

    def read(*args, **_options)
      @reads << args.join(" ")
      Deploy::Shell::Result.new(argv: args, stdout: "", stderr: "", status: 0)
    end

    def actions
      writes.map { |write| write[:action].join(" ") }
    end

    private

    def deep_merge(into, from)
      into.merge(from) do |_key, old, new|
        old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
      end
    end

    def record(action, **payload)
      @writes << { action: action, namespace: namespace, **payload }
      Deploy::Shell::Result.new(argv: action, stdout: "", stderr: "", status: 0)
    end

    # Keys may be exact strings or regular expressions. A phase that names a
    # resource after the clock and its own pid -- the migration Job does, to
    # stay unique across retries -- can only be matched by pattern.
    def lookup(target)
      key = target.join(" ")
      found = @resources.key?(key) ? key : @resources.keys.find { |k| k.is_a?(Regexp) && k.match?(key) }
      return nil if found.nil?

      value = @resources[found]
      value.is_a?(Array) ? value.shift : value
    end
  end

  module_function

  def reporter(out: StringIO.new, err: StringIO.new)
    Deploy::Reporter.new(out: out, err: err)
  end

  def config(env = {})
    Deploy::Config.new(env: env, staging: true, production: true)
  end

  def context(kubectl:, config: config(), clock: Deploy::Clock::Fake.new,
              reporter: DeploySpec.reporter, controls: nil, dry_run: false, label: "staging",
              sha: "abc1234", flux_kubectl: nil)
    Deploy::ClusterContext.new(
      label: label, sha: sha, config: config, kubectl: kubectl,
      flux_kubectl: flux_kubectl || kubectl.in_namespace("flux-system"),
      reporter: reporter, clock: clock,
      waiter: Deploy::Waiter.new(clock: clock, reporter: reporter, dry_run: dry_run),
      controls: controls || Deploy::ControlStack.new(reporter: reporter)
    )
  end

  def deployment(name, replicas: 2, generation: 2, observed: 2, updated: 2, available: 2,
                 total: 2, containers: [], conditions: [])
    {
      "kind" => "Deployment",
      "metadata" => { "name" => name, "generation" => generation },
      "spec" => {
        "replicas" => replicas,
        "selector" => { "matchLabels" => { "name" => name } },
        "template" => { "spec" => { "containers" => containers } }
      },
      "status" => {
        "observedGeneration" => observed, "updatedReplicas" => updated,
        "availableReplicas" => available, "replicas" => total, "conditions" => conditions
      }
    }
  end
end

# frozen_string_literal: true

require "json"

module Deploy
  # A typed kubectl for one cluster and namespace.
  #
  # Two things this buys over interpolating strings at 45 call sites. Manifests
  # are Ruby hashes serialised to JSON -- which is valid YAML, so it goes
  # straight to `apply -f -` -- rather than heredocs. A heredoc that references
  # an unset variable under `set -u` aborts the whole function, which is how the
  # pre-pull DaemonSet silently stopped being created at all: the manifest named
  # a variable nothing ever assigned, the apply never ran, and every deploy left
  # each node to pull a multi-gigabyte image cold during its own rollout. A hash
  # with a missing key raises where it is built, by name.
  #
  # And every call declares read or write, so the dry run has no classifying to
  # do. See Shell.
  class Kubectl
    attr_reader :shell, :kubeconfig, :namespace

    def initialize(shell:, kubeconfig:, namespace:)
      @shell = shell
      @kubeconfig = kubeconfig
      @namespace = namespace
    end

    # A sibling pointed at another namespace in the same cluster -- flux-system,
    # in practice.
    def in_namespace(other)
      self.class.new(shell: shell, kubeconfig: kubeconfig, namespace: other)
    end

    def exists?(*target)
      read("get", *target).success?
    end

    def get_json(*target)
      result = read("get", *target, "-o", "json")
      return nil unless result.success?

      JSON.parse(result.out)
    rescue JSON::ParserError
      nil
    end

    def jsonpath(*target, path)
      result = read("get", *target, "-o", "jsonpath=#{path}")
      result.success? ? result.out.strip : ""
    end

    def logs(*target, tail: nil, all_containers: true, since_time: nil)
      args = [ "logs", *target ]
      args << "--all-containers" if all_containers
      args.concat([ "--tail=#{tail}" ]) if tail
      args.concat([ "--since-time=#{since_time}" ]) if since_time
      read(*args).out
    end

    def describe(*target)
      read("describe", *target).out
    end

    def events(limit: 40, warnings_only: false)
      args = [ "get", "events", "--sort-by=.lastTimestamp" ]
      args << "--field-selector=type=Warning" if warnings_only
      read(*args).out.lines.last(limit).join
    end

    def apply(manifest)
      write("apply", "-f", "-", stdin: JSON.generate(manifest))
    end

    def patch(*target, patch:, type: "merge", field_manager: nil)
      args = [ "patch", *target, "--type", type ]
      args.concat([ "--field-manager", field_manager ]) if field_manager
      args.concat([ "-p", patch.is_a?(String) ? patch : JSON.generate(patch) ])
      write(*args)
    end

    def set_image(target, pairs)
      write("set", "image", target, *pairs)
    end

    def annotate(*target, annotation)
      write("annotate", *target, annotation, "--overwrite")
    end

    # `--wait=false` because the caller is deciding when to stop waiting, not
    # kubectl.
    def delete(*target, ignore_not_found: true, wait: false)
      args = [ "delete", *target ]
      args << "--ignore-not-found" if ignore_not_found
      args << "--wait=#{wait}"
      write(*args)
    end

    # `exec` can mutate whatever it runs, so it travels through `write` and a
    # dry run only records it. Everything this deploy execs is a verification,
    # and the verifications are skipped in a dry run anyway -- there are no new
    # pods to interrogate.
    def exec(target, *command, container: nil)
      args = [ "exec", target ]
      args.concat([ "-c", container ]) if container
      write(*args, "--", *command)
    end

    def read(*args, **options)
      shell.read(command(args), env: env, **options)
    end

    def write(*args, stdin: nil)
      shell.write(command(args), env: env, stdin: stdin)
    end

    private

    def command(args)
      [ "kubectl", "-n", namespace, *args.map(&:to_s) ]
    end

    # KUBECONFIG rather than `--context`: the two clusters are separate files,
    # and passing the file per invocation keeps them from racing each other
    # through a shared current-context. It travels in the environment so it
    # never shows up in the dry run's command stream, which would otherwise
    # differ between operators for no behavioural reason.
    def env
      { "KUBECONFIG" => kubeconfig }
    end
  end
end

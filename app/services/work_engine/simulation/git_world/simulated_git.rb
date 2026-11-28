# frozen_string_literal: true

module WorkEngine
  module Simulation
    class GitWorld
      # A GitRunner stand-in that answers git commands from a GitWorld
      # checkout instead of a clone. It implements the subset of commands the
      # production code the simulator runs for real issues (StackBaseFreshness
      # and the merge-driver registration it calls) with git's semantics:
      # failures raise GitRunner::GitError, a conflicted rebase or cherry-pick
      # stays in progress until it is aborted, and `diff --diff-filter=U` lists
      # the conflicted paths meanwhile.
      #
      # Anything outside that subset raises NotImplementedError (not a
      # StandardError, so no production rescue swallows it): a gap in the model
      # stops the scenario loudly instead of being read as a git failure.
      class SimulatedGit
        attr_reader :world, :checkout, :commands

        def initialize(world, checkout)
          @world = world
          @checkout = checkout
          @commands = []
        end

        def run(*args, chdir: nil, env: nil, **_options)
          args = args.flatten.map(&:to_s)
          commands << args
          case args.first
          when "rev-parse" then rev_parse(args.drop(1))
          when "merge-base" then merge_base(args.drop(1))
          when "cat-file" then cat_file(args.drop(1))
          when "rev-list" then rev_list(args.drop(1))
          when "rebase" then rebase(args.drop(1))
          when "cherry-pick" then cherry_pick(args.drop(1))
          when "reset" then reset(args.drop(1))
          when "diff" then diff(args.drop(1))
          when "check-attr" then "#{args.last}: merge: unspecified\n"
          when "config" then ""
          else unsupported!(args)
          end
        end

        private

        def rev_parse(args)
          ref = args.reject { |arg| arg.start_with?("-") }.first
          "#{resolve!(ref)}\n"
        end

        def merge_base(args)
          if args.first == "--is-ancestor"
            ancestor, descendant = args.drop(1).map { |ref| resolve!(ref) }
            return "" if world.ancestor?(ancestor, descendant)

            fail!(args.unshift("merge-base"), "", status: 1)
          end

          refs = args.reject { |arg| arg.start_with?("-") }.map { |ref| resolve!(ref) }
          "#{world.merge_base(*refs)}\n"
        end

        def cat_file(args)
          ref = args.reject { |arg| arg.start_with?("-") }.first
          return "" if world.resolve(ref)

          fail!(%w[cat-file] + args, "fatal: Not a valid object name #{ref}", status: 128)
        end

        def rev_list(args)
          count = args.delete("--count")
          merges = args.delete("--merges")
          no_merges = args.delete("--no-merges")
          reverse = args.delete("--reverse")
          args.delete("--topo-order")
          max_count = args.find { |arg| arg.start_with?("--max-count=") }
          args.delete(max_count) if max_count
          unsupported!(%w[rev-list] + args) if args.any? { |arg| arg.start_with?("--") }

          includes = []
          excludes = []
          args.each do |arg|
            if arg.include?("..")
              from, to = arg.split("..", 2)
              excludes << resolve!(from)
              includes << resolve!(to.presence || "HEAD")
            elsif arg.start_with?("^")
              excludes << resolve!(arg.delete_prefix("^"))
            else
              includes << resolve!(arg)
            end
          end
          commits = includes.flat_map { |head| world.range(head, exclude: excludes) }.uniq(&:id)
          commits = commits.select(&:merge?) if merges
          commits = commits.reject(&:merge?) if no_merges
          commits = commits.reverse unless reverse # git lists newest first by default
          commits = commits.first(max_count.split("=", 2).last.to_i) if max_count
          return "#{commits.size}\n" if count

          commits.map { |commit| "#{commit.id}\n" }.join
        end

        def rebase(args)
          return abort_operation!("rebase") if args == [ "--abort" ]

          in_progress_guard!("rebase")
          if args.first == "--onto"
            onto, upstream = args.drop(1).map { |ref| resolve!(ref) }
          else
            onto = resolve!(args.reject { |arg| arg.start_with?("-") }.first)
            upstream = onto
          end
          apply!(world.rebase(head: head!, onto: onto, upstream: upstream), "rebase", %w[rebase] + args)
        end

        def cherry_pick(args)
          return abort_operation!("cherry-pick") if args == [ "--abort" ]

          in_progress_guard!("cherry-pick")
          keep_redundant = args.delete("--keep-redundant-commits")
          commits = args.map { |ref| world.commit(resolve!(ref)) }
          apply!(world.replay(commits, onto: head!, keep_redundant: keep_redundant.present?), "cherry-pick", %w[cherry-pick] + args)
        end

        def reset(args)
          ref = args.reject { |arg| arg.start_with?("-") }.first || "HEAD"
          checkout.head = resolve!(ref)
          checkout.operation = nil
          ""
        end

        def diff(args)
          unless args.include?("--diff-filter=U")
            unsupported!(%w[diff] + args)
          end

          Array(checkout.operation&.conflicts).map { |path| "#{path}\n" }.join
        end

        def apply!(result, kind, command)
          if result.conflicted?
            checkout.operation = Operation.new(kind: kind, orig_head: checkout.head, conflicts: result.conflicts)
            fail!(command, "CONFLICT (add/add): Merge conflict in #{result.conflicts.join(", ")}", status: 1)
          end

          checkout.head = result.tip
          ""
        end

        def abort_operation!(kind)
          operation = checkout.operation
          fail!([ kind, "--abort" ], "fatal: no #{kind} in progress", status: 128) unless operation&.kind == kind

          checkout.head = operation.orig_head
          checkout.operation = nil
          ""
        end

        def in_progress_guard!(kind)
          return unless checkout.operation

          fail!([ kind ], "error: a #{checkout.operation.kind} is already in progress", status: 128)
        end

        def head!
          checkout.head || raise(GitWorld::UnknownRef, "simulated checkout #{checkout.key} has no HEAD")
        end

        def resolve!(ref)
          ref = ref.to_s
          return head! if ref == "HEAD"

          world.resolve(ref) || fail!([ "rev-parse", ref ], "fatal: ambiguous argument '#{ref}': unknown revision", status: 128)
        end

        def fail!(command, output, status:)
          raise GitRunner::GitError.new(command, status, output)
        end

        def unsupported!(args)
          raise NotImplementedError, "the simulated git world does not model `git #{args.join(" ")}`"
        end
      end
    end
  end
end

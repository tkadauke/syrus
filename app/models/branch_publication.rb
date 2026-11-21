# A branch head Syrus pushed (see GitRunner#run). PR publication uses it to
# recognise its own earlier output on a branch -- for example an attempt a
# stack rebase later rewrote -- so an implementation retry can replace that
# output instead of asking the operator whether to discard "someone's" work.
class BranchPublication < ApplicationRecord
  RETAIN_FOR = 90.days
  SHA = /\A\h{40,64}\z/

  scope :prunable, ->(now: Time.current) { where(created_at: ...(now - RETAIN_FOR)) }

  def self.record!(branch_name:, sha:, workflow: nil)
    return if branch_name.blank? || !sha.to_s.match?(SHA)

    create_or_find_by!(branch_name: branch_name, sha: sha) { |row| row.workflow_id = workflow&.id }
  end

  def self.published?(branch_name:, sha:)
    branch_name.present? && sha.present? && exists?(branch_name: branch_name, sha: sha)
  end

  # Branch heads named by a successful `git push`'s arguments: `src:refs/heads/x`
  # refspecs, with `src` resolved in `chdir` when it is not already a SHA.
  # Deletions (`:dst`, `--delete`) and non-branch refs (tags, checkpoints) are
  # not branch publications.
  def self.record_push!(args, chdir:, workflow: nil, resolve: nil)
    args = args.map(&:to_s)
    return unless args.first == "push"
    return if args.include?("--delete") || args.include?("-d")

    operands = args.drop(1).reject { |arg| arg.start_with?("-") }
    operands.drop(1).each do |refspec|
      source, destination = refspec.delete_prefix("+").split(":", 2)
      next if source.blank? || destination.blank?
      next unless destination.start_with?("refs/heads/")

      sha = source.match?(SHA) ? source : resolve&.call(source, chdir)
      record!(branch_name: destination.delete_prefix("refs/heads/"), sha: sha.to_s.strip, workflow: workflow)
    end
  end
end

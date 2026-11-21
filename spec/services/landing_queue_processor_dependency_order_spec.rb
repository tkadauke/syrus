require "rails_helper"

# The properties formal/SyrusModel/TrainOrder.lean checks exhaustively for its
# transcription of LandingQueueProcessor#dependency_order, checked here on the
# Ruby method itself over random member graphs (stack parents and job
# dependencies): the order is a permutation of the members, and for an acyclic
# graph every prerequisite precedes its dependent. Merge trains and job bundles
# store this order as member positions and integrate members in it.
RSpec.describe LandingQueueProcessor, ".dependency_ordered" do
  def dependency_class
    @dependency_class ||= Struct.new(:depends_on_job_id, :state, keyword_init: true) do
      def pending? = state == "pending"
    end
  end

  def member_class
    @member_class ||= Struct.new(:id, :parent_job_id, :dependencies, :dependencies_overridden_at, keyword_init: true)
  end

  def random_members(rng, count)
    ids = Array.new(count) { |index| 1000 + index }
    ids.map do |id|
      others = ids - [ id ]
      parent = rng.rand < 0.3 ? others.sample(random: rng) : nil
      dependencies = others.select { rng.rand < 0.3 }.map do |other|
        dependency_class.new(depends_on_job_id: other, state: rng.rand < 0.15 ? "pending" : "satisfied")
      end
      member_class.new(id: id, parent_job_id: parent, dependencies: dependencies,
                       dependencies_overridden_at: rng.rand < 0.1 ? Time.current : nil)
    end
  end

  # The prerequisites dependency_order honours: the stack parent, and resolved
  # job dependencies unless the Job's dependencies were overridden.
  def prerequisites(member, ids)
    edges = [ member.parent_job_id ]
    unless member.dependencies_overridden_at
      edges.concat(member.dependencies.reject(&:pending?).map(&:depends_on_job_id))
    end
    edges.compact.uniq & ids
  end

  def acyclic?(members)
    ids = members.map(&:id)
    graph = members.to_h { |member| [ member.id, prerequisites(member, ids) ] }
    visiting = Set.new
    done = Set.new
    visit = lambda do |id|
      return true if done.include?(id)
      return false if visiting.include?(id)

      visiting << id
      ok = graph.fetch(id).all? { |prerequisite| visit.call(prerequisite) }
      visiting.delete(id)
      done << id
      ok
    end
    ids.all? { |id| visit.call(id) }
  end

  it "returns every member exactly once and puts prerequisites first when the graph is acyclic" do
    seed = Integer(ENV.fetch("SYRUS_TRAIN_ORDER_SEED", Random.new_seed))
    rng = Random.new(seed)
    acyclic_cases = 0

    500.times do
      members = random_members(rng, 1 + rng.rand(7)).shuffle(random: rng)
      ordered = described_class.dependency_ordered(members)

      expect(ordered.map(&:id).sort).to eq(members.map(&:id).sort), "seed #{seed}: not a permutation"
      next unless acyclic?(members)

      acyclic_cases += 1
      position = ordered.each_with_index.to_h { |member, index| [ member.id, index ] }
      ids = members.map(&:id)
      members.each do |member|
        prerequisites(member, ids).each do |prerequisite|
          expect(position.fetch(prerequisite)).to be < position.fetch(member.id),
            "seed #{seed}: #{prerequisite} must precede #{member.id}"
        end
      end
    end

    expect(acyclic_cases).to be > 50
  end
end

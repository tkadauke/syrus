# Writes TestIdentity rows into the search index.
#
# The search database lives on the home node; the compute workers that run
# graders deliberately do not touch it (see config/queue.compute.yml). Test
# identity indexing was the one path that did, synchronously, from
# TestRunIngester inside a grader step on the `runs` queue -- so on a split
# deployment it either wrote to the wrong node's database or failed and got
# swallowed as an enrichment warning. Routing it through `indexing` like every
# other index write puts it back on the node that owns the file.
class IndexTestIdentitiesJob < ApplicationJob
  queue_as :indexing

  def perform(test_identity_ids)
    ids = Array(test_identity_ids).compact
    return if ids.empty?

    TestIdentitySearchIndex.upsert_many(TestIdentity.includes(:repository).where(id: ids))
  end
end

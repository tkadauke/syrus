# Security review

Syrus can run an optional, bounded security-review loop after adversarial review and before visual review and graders. It is disabled by default.

```yaml
security_review:
  rounds: 2
  required: false
  criteria:
    - Verify tenant authorization on changed endpoints.
    - Check outbound requests against the SSRF policy.
```

`rounds` must be between 0 and 10. A repository setting overrides the instance `security_review_rounds` setting. `required: true` makes reviewer unavailability fail instead of skip the review. Nested project criteria apply when the changed files belong to that project. Providers registered through `review_criteria_provider` contribute criteria to both adversarial and security review.

Admins can change the instance default in Admin Settings. A repository's detail
page shows its default-branch `.syrus.yml` security review rounds and criteria
alongside the other repository review configuration.

The reviewer is read-only. A `needs_work` verdict feeds its critique to the next repair step; `approved` ends the loop. Provider routing rules can select a provider with the `security_review` step-kind trigger. Review rules may also name an installation-local coworker reviewer separately from the provider/model that executes the review. Only active coworkers owned by the Job owner and granted `code.read` for the repository are selectable. The rule stores an opaque target reference plus a safe display snapshot; coworker identities never belong in `.syrus.yml`.
Every new security reviewer Run records the same immutable, SHA-bound evidence
as adversarial review. Verdict submission rejects a changed head or canonical
diff and permanently marks that evidence stale; only a fresh rereview can
advance the gate. The findings artifact remains the verdict authority and
links to evidence when present. Bound stale approvals are presented as stale,
while legacy entries remain valid presentation records with a `legacy` marker
and without fabricated provenance.
Security review supports the same provider-routing panels as adversarial
review. A multi-member panel runs serially, pins each member Run to its routed
provider/model/effort, and finishes with a collect step whose aggregate verdict
is appended after the member findings. Consensus and unavailable-member
handling come from the matched routing rule. No matching panel, or a panel
with one effective member, uses the existing single-review path unchanged.

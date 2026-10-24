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

The reviewer is read-only. A `needs_work` verdict feeds its critique to the next repair step; `approved` ends the loop. Provider routing rules can select a provider with the `security_review` step-kind trigger.

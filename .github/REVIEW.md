# Automatic stack review setup

The [review workflow](workflows/stack-review.yml) reads the contribution guide,
README outline, and review skill from the PR's base commit. It submits PR text to
the Anthropic Messages API and maintains one advisory PR comment. It cannot run
commands, use model tools, deploy, approve, or merge a PR.

## Maintainer setup

1. Make an Anthropic API credential available to this repository as the Actions
   secret `ANTHROPIC_API_KEY`. Use the existing organization credential only if its
   owner authorizes this consumer. Register the consumer with the organization's
   credential inventory and rotation process; never commit the value.
2. Optionally set the Actions variable `STACK_REVIEW_MODEL` to an available Claude
   model ID. The default is `claude-sonnet-4-6`.
3. Merge the workflow, guide, skill, and runner together. Open or update a test PR
   and confirm the comment identifies its head commit. The trusted-base workflow
   cannot review the PR that first introduces it before merge.

The workflow triggers on PR creation, pushes, reopening, and readiness, including
fork PRs and drafts. Drafts are included to provide feedback before human review.
No credential is sent to a fork checkout: only base-commit code runs, and the model
receives no credential or executable tools. Normal manifest CI continues through
`pull_request` with a read-only token and no repository secrets.

A missing API key produces an explicit warning and job summary. API failures fail
the review job. Neither is evidence that a contribution passed review. Keep this
advisory job outside required merge checks until its credential, rotation owner,
and a test run have been verified. Deterministic validation remains separate.

## Review limits

The runner sends changed-file diffs and, where space permits, complete changed
text files. Context is limited to roughly 200,000 characters; full files above
25,000 bytes are omitted. PRs over 200 changed files require manual review.
Omitted context is listed in the comment. Unchanged
dependencies and live environments require maintainer verification. The model
can make mistakes and cannot establish that an installation works.

Each run makes one model request with at most 4,096 output tokens. It discards a
review if the PR head changes while the request runs. New pushes cancel the
previous workflow. To disable automatic review, disable this workflow in Actions;
local review can still use the skill.

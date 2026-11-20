# Automatic stack review setup

The [review workflow](workflows/stack-review.yml) uses the guide and skill from the
base commit and reads PR files as text through the API. Only base-commit code runs.
The model has no executable tools. Its comment is labeled as AI-generated, never
maintainer approval or certification. All model text and context limits are shown
in literal code blocks, so links, images, HTML, and mentions cannot become active.
A model can still produce misleading prose; maintainers must assess its findings.

## Maintainer setup

1. Make an authorized Anthropic credential available as `ANTHROPIC_API_KEY` in
   Actions secrets. Register this consumer and its rotation owner through the
   organization's credential process. Never commit the value.
2. Set the Actions variable `STACK_REVIEW_ENABLED` to `true` to opt in. Setting it
   to any other value disables paid requests. Check the provider-side budget for
   the credential: per-PR limits do not impose a repository-wide monthly spend cap.
3. Optionally set `STACK_REVIEW_MODEL`. The default is `claude-sonnet-5-5`.
4. Create the `stack-review-approved` repository label. On a fork PR, add it only
   after inspecting the current head. The runner verifies the labeler's current
   write/maintain/admin permission and consumes the label before any paid request.
   Failed permission checks deny the request.
5. Merge the workflow, guide, skill, and runner together. Test authorization,
   comment rendering, missing-credential behavior, and budget receipts before
   making this advisory job a required merge check. It cannot review the PR that
   first introduces it before merge. Ensure the repository's Actions event policy
   permits this trusted-base workflow if applicable.

## Authorization and cost bounds

Automatic events are PR creation, pushes, reopening, and readiness. They are
eligible only for same-repository PRs whose author has MEMBER, OWNER, or
COLLABORATOR association and current write access. Drafts are eligible.

Every fork, including one owned by a member, needs a fresh maintainer label event.
A label authorizes only the head present in that event. A changed head, removed
label, unrelated label, or labeler without write access does not authorize a
request. External pushes never inherit an earlier approval.

The bot reserves an attempt in its own sticky comment before calling the model:

- At most one attempt for a given commit, including failures and reruns.
- At most five attempts per PR. Later changes need manual review.
- One model request per attempt, with no automatic retry, at most 200,000
  characters of PR context, and at most 4,096 output tokens.
- Per-PR serialization with no cancellation of a running request. A new push
  cannot undo billing for an already submitted request.

The hidden receipt is at the top of the bot's own comment. A missing/corrupt
receipt fails closed; do not delete it to retry requests. If a run fails after
reservation, the attempt remains spent. Disabling the workflow or the enable
variable stops future requests. An administrator should also set a provider-side
budget appropriate for all consumers of the credential.

Do not rely on GitHub's first-contributor approval setting as the paid-review
authorization boundary. `pull_request_target` uses the base repository's trust
and secrets; see [GitHub's security guidance](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target).
The script's explicit permission, event, head, and budget checks are required
regardless of that setting. Repository/organization settings need maintainer
verification; they were not readable with the implementation account.

## CI and review limits

Offline contribution checks, including README defaults, run for every PR on
`ubuntu-latest`. Ordinary Markdown-only changes skip the expensive render and
Platform job. Manifest, script, workflow, generator-source, and Run:ai generated
README changes still run it; dispatches and unknown history run the full check.
The Platform job also uses `ubuntu-latest`, a fresh GitHub-hosted VM, so fork code
never runs on an unverified persistent custom runner. No repository secrets are
passed to these `pull_request` jobs.

Review a Community contribution against the short checklist in CONTRIBUTING.md.
Custom test scripts are optional; existing scripts still run, and generated or
conditional behavior may need focused checks. One installation and functional
check should be verified before a new stack merges, by the contributor or a
reviewer. Do not invent certification criteria or demand a full test matrix.

When an external task template is intentionally supplied by Platform or installed
separately, help register its README installation instructions for validation.
`hack/external-template-references.yaml` is a list of entries with `path` (the
repository-relative StackTemplate file), `kind`, `name`, and `instructions` (the
README link and relevant version/installation requirements). The shared validator
still rejects undeclared missing references. Contributors can ask for this help
in the PR rather than learning the repository's validation configuration first.

The model sees changed-file diffs and, where space permits, complete changed text
files. Full files over 25,000 bytes are omitted; PRs over 200 files require manual
review. Omitted context is listed literally. Unchanged dependencies and live
behavior need maintainer verification. A response reaching the output-token limit
is posted as incomplete and still consumes one attempt. Other API failures fail
the advisory job; a missing key produces an explicit warning and job summary.
Neither is evidence that the contribution passed review. Findings for an obsolete
head are discarded, with the reservation retained.

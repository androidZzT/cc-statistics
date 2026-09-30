# GitHub AI Triage Automation

CCStats ships a conservative GitHub automation workflow in `.github/workflows/ai-triage.yml`.
It is designed to make PR/Issue monitoring useful without giving untrusted fork code access to repository secrets.

## What It Does

- Reviews PR metadata and changed-file lists on `pull_request_target` events.
- Triages new or edited issues on `issues` events.
- Responds to maintainer commands in issue/PR comments:
  - `/cc review` refreshes the automated PR review.
  - `/cc triage` refreshes issue triage.
  - `/cc plan` posts a safe implementation workflow outline.
  - `/cc fix` acknowledges the fix request and explains the maintainer-driven fix flow.

## Safety Model

- The workflow checks out trusted base-branch code only.
- It does not checkout or execute external fork PR code.
- It uses `GITHUB_TOKEN` with `contents: read`, `issues: write`, and `pull-requests: write`.
- `/cc fix` does not push code automatically. Maintainers should reproduce locally, implement on a maintainer-owned branch, run tests, and open a PR.

## Current Scope

The first version is deterministic and rule-based. It does not call an external LLM provider. That keeps the workflow free of API keys and safe for fork PRs.

Future extensions can add a separate, explicitly approved AI repair workflow guarded by maintainer-only commands and repository secrets.

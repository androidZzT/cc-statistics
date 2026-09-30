from scripts.github_triage import (
    build_fix_command_response,
    build_issue_triage,
    build_pr_review,
    is_maintainer_association,
    parse_cc_command,
)


def test_parse_cc_command_detects_supported_commands():
    assert parse_cc_command('/cc review please') == 'review'
    assert parse_cc_command('  /cc triage') == 'triage'
    assert parse_cc_command('/cc fix') == 'fix'
    assert parse_cc_command('/not-cc review') is None
    assert parse_cc_command('please review') is None


def test_pr_review_flags_cross_repo_and_workflow_changes():
    pr = {
        'number': 23,
        'title': 'feat: add automation',
        'html_url': 'https://github.com/androidZzT/cc-statistics/pull/23',
        'user': {'login': 'contributor'},
        'head': {'repo': {'full_name': 'contributor/cc-statistics'}},
        'base': {'repo': {'full_name': 'androidZzT/cc-statistics'}, 'ref': 'main'},
        'draft': False,
        'mergeable': False,
    }
    files = [
        {'filename': '.github/workflows/ai-triage.yml', 'additions': 80, 'deletions': 0, 'changes': 80},
        {'filename': 'scripts/github_triage.py', 'additions': 120, 'deletions': 5, 'changes': 125},
        {'filename': 'tests/test_github_triage.py', 'additions': 20, 'deletions': 0, 'changes': 20},
    ]

    body = build_pr_review(pr, files)

    assert 'cross-repository PR' in body
    assert 'Workflow changes detected' in body
    assert 'pytest -q' in body
    assert '<!-- cc-stats-ai-triage:pr-review -->' in body


def test_issue_triage_detects_bug_and_requests_repro():
    issue = {
        'number': 42,
        'title': 'Bug: loading hangs forever',
        'html_url': 'https://github.com/androidZzT/cc-statistics/issues/42',
        'user': {'login': 'user'},
        'body': 'The app freezes while loading sessions.',
    }

    body = build_issue_triage(issue)

    assert 'bug' in body.lower()
    assert 'reproduction' in body.lower()
    assert 'logs' in body.lower()
    assert '<!-- cc-stats-ai-triage:issue-triage -->' in body


def test_fix_command_response_is_safe_by_default():
    body = build_fix_command_response(23, is_pr=True)

    assert '/cc fix' in body
    assert 'not push code automatically' in body
    assert 'maintainer' in body.lower()


def test_maintainer_association_gate():
    assert is_maintainer_association('OWNER')
    assert is_maintainer_association('MEMBER')
    assert is_maintainer_association('COLLABORATOR')
    assert not is_maintainer_association('CONTRIBUTOR')
    assert not is_maintainer_association(None)


def test_client_rejects_non_github_api_url():
    import pytest
    from scripts.github_triage import GitHubClient, GitHubContext
    client = GitHubClient(GitHubContext('owner/repo', 'issues', 'test-token'))
    with pytest.raises(ValueError):
        client.get('https://example.com/comment')


def test_upsert_ignores_markers_in_user_comments(monkeypatch):
    from scripts.github_triage import GitHubClient, GitHubContext, PR_MARKER
    client = GitHubClient(GitHubContext('owner/repo', 'issues', 'test-token'))
    monkeypatch.setattr(client, 'issue_comments', lambda n: [
        {'body': PR_MARKER, 'url': 'https://api.github.com/repos/owner/repo/issues/comments/1',
         'user': {'login': 'contributor'}}])
    calls = []
    monkeypatch.setattr(client, 'patch', lambda *a: calls.append(('patch', a)))
    monkeypatch.setattr(client, 'post', lambda *a: calls.append(('post', a)))
    client.upsert_issue_comment(1, PR_MARKER, 'review')
    assert calls[0][0] == 'post'

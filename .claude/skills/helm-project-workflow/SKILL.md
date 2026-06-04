---
name: helm-project-workflow
description: Run Helm Project Inbox workflows inside one parent session using provider-native subagents or workflow orchestration when available.
---

# Helm Project Workflow

Use this skill only when Helm invokes it from Project Inbox. The user message following the invocation is the workflow instance: it contains the task prompt, node list, dependencies, workspace notes, and artifact requirements.

## Contract

- Keep the workflow inside the current Helm session. Do not ask Helm to create extra sidebar sessions, external threads, or unrelated conversations.
- Use provider-native child agents or workflow orchestration for nodes marked as subagent/workflow when the runtime supports them. Child work must remain scoped to this parent session and report results back here.
- If native child agents or workflow orchestration are unavailable, run the nodes sequentially in the parent agent and state that fallback clearly.
- Preserve unrelated user or agent changes. Inspect the workspace before editing and avoid overwriting concurrent Project Inbox work.
- Track artifacts explicitly when the workflow creates them: worktree paths, debug app or package paths, process IDs, screenshots or transcripts, cleanup actions, git base/head, commits, and push results.

## Node Semantics

- pre_process is a policy prompt that runs before the user task. It may prepare a worktree, inspect dependencies, load context, or do nothing if the workflow instance leaves it empty.
- process is always the user's Project Inbox task. Implement it in the prepared workspace or current project context.
- post_process is a policy prompt that runs after the user task. It may validate, clean up, merge, push, ask for review, or do nothing if the workflow instance leaves it empty.
- Do not treat Helm's visible nodes as a user-authored DAG. They are policy envelopes; decide the actual internal subagent/workflow orchestration yourself based on the task and runtime.

## Provider Guidance

- In Claude Code, prefer Dynamic Workflows when available for DAG-style node orchestration and parallel subagents. Otherwise use Claude Code's native subagent/task capability, then summarize child results in the parent session.

## Final Response

End with a concise workflow recap covering node outcomes, files changed, validation evidence, cleanup status, git result, and any remaining blocker.
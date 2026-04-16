# Create an agentic project board

Use this workflow to bootstrap a GitHub Project that tracks the agentic loop for an AL-Go repository with kanban stages such as New, Triaged, Implementing, Pull Request, and Released.

## Prerequisites

- A branch or repository that contains `.github/workflows/CreateAgenticProject.yaml`
- A `GhTokenWorkflow` secret containing either:
  - a classic PAT with `project` scope, or
  - AL-Go GitHub App JSON with `GitHubAppClientId` and `PrivateKey`
- For Microsoft organization projects, GitHub App authentication is the recommended option

## Run the workflow

1. Open the repository in GitHub.
2. Select **Actions**.
3. Select **Create Agentic Project**.
4. Choose **Run workflow**.
5. Set `targetRepository` to a repository such as `microsoft/BCAppsCampAIRHack`.
6. Set `projectOwner` to the user or organization that should own the project, such as `microsoft`.
7. Set `sourceProjectId` if you already have a template project to copy from.
8. Turn on `seedDemoData` if you want a fully populated demo board without creating any repository issues.
9. Wait for the workflow to complete and open the project URL from the job summary.

## What the workflow creates

- A new GitHub Project in the selected user or organization
- `Agentic Stage` and `Agentic Attention` fields when no template is provided
- Recommended repository labels such as `agentic:signal` and `attention:blocked`
- Optional demo draft issues that live only inside the project

## Current limitations

- GitHub does not copy auto-add workflows from project templates, so you still need to enable auto-add rules manually in the project UI.
- Fine-grained PATs are not the recommended path for this workflow because Projects automation is handled through classic `project` scope or GitHub App installation tokens.

______________________________________________________________________

[back](../README.md)

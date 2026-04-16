Param(
    [Parameter(Mandatory = $true)]
    [string] $TargetRepository,
    [Parameter(Mandatory = $true)]
    [string] $ProjectOwner,
    [string] $ProjectTitle = "",
    [string] $SourceProjectId = "",
    [string] $StageFieldName = "Agentic Stage",
    [string] $AttentionFieldName = "Agentic Attention",
    [bool] $CreateRepositoryLabels = $true,
    [bool] $DryRun = $false
)

$ErrorActionPreference = "Stop"

function Invoke-GraphQL {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Query,
        [Hashtable] $Variables = @{}
    )

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        @{
            query     = $Query
            variables = $Variables
        } | ConvertTo-Json -Depth 20 | Set-Content -Path $tempFile -Encoding utf8

        $response = gh api graphql --input $tempFile | ConvertFrom-Json -Depth 20
        if ($response.errors) {
            $messages = $response.errors | ForEach-Object { $_.message }
            throw ($messages -join "; ")
        }

        return $response.data
    }
    finally {
        if (Test-Path $tempFile) {
            Remove-Item -Path $tempFile -Force
        }
    }
}

function Get-OwnerAndRepo {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Repository
    )

    $parts = $Repository.Split("/")
    if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        throw "TargetRepository must be in the form owner/name."
    }

    return @{
        owner = $parts[0]
        name  = $parts[1]
    }
}

function Get-ProjectOwnerId {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $OwnerLogin
    )

    $query = @"
query(`$login: String!) {
  organization(login: `$login) {
    id
    login
  }
  user(login: `$login) {
    id
    login
  }
}
"@

    $data = Invoke-GraphQL -Query $query -Variables @{ login = $OwnerLogin }
    if ($data.organization) {
        return $data.organization.id
    }
    if ($data.user) {
        return $data.user.id
    }

    throw "Unable to resolve project owner '$OwnerLogin' as a GitHub organization or user."
}

function New-ProjectV2 {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $OwnerId,
        [Parameter(Mandatory = $true)]
        [string] $Title
    )

    $query = @"
mutation(`$ownerId: ID!, `$title: String!) {
  createProjectV2(input: { ownerId: `$ownerId, title: `$title }) {
    projectV2 {
      id
      number
      title
      url
    }
  }
}
"@

    return (Invoke-GraphQL -Query $query -Variables @{
            ownerId = $OwnerId
            title   = $Title
        }).createProjectV2.projectV2
}

function Copy-ProjectV2 {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $OwnerId,
        [Parameter(Mandatory = $true)]
        [string] $SourceProjectId,
        [Parameter(Mandatory = $true)]
        [string] $Title
    )

    $query = @"
mutation(`$ownerId: ID!, `$sourceProjectId: ID!, `$title: String!) {
  copyProjectV2(input: { ownerId: `$ownerId, sourceProjectId: `$sourceProjectId, title: `$title }) {
    projectV2 {
      id
      number
      title
      url
    }
  }
}
"@

    return (Invoke-GraphQL -Query $query -Variables @{
            ownerId         = $OwnerId
            sourceProjectId = $SourceProjectId
            title           = $Title
        }).copyProjectV2.projectV2
}

function New-SingleSelectField {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectId,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [object[]] $Options
    )

    $createQuery = @"
mutation(`$projectId: ID!, `$name: String!) {
  createProjectV2Field(input: { projectId: `$projectId, name: `$name, dataType: SINGLE_SELECT }) {
    projectV2Field {
      ... on ProjectV2SingleSelectField {
        id
        name
      }
    }
  }
}
"@

    $field = (Invoke-GraphQL -Query $createQuery -Variables @{
            projectId = $ProjectId
            name      = $Name
        }).createProjectV2Field.projectV2Field

    $updateQuery = @"
mutation(`$projectId: ID!, `$fieldId: ID!, `$options: [ProjectV2SingleSelectFieldOptionInput!]!) {
  updateProjectV2SingleSelectField(input: { projectId: `$projectId, fieldId: `$fieldId, options: `$options }) {
    projectV2SingleSelectField {
      id
      name
      options {
        id
        name
        color
      }
    }
  }
}
"@

    return (Invoke-GraphQL -Query $updateQuery -Variables @{
            projectId = $ProjectId
            fieldId   = $field.id
            options   = $Options
        }).updateProjectV2SingleSelectField.projectV2SingleSelectField
}

function Ensure-RepositoryLabels {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Repository
    )

    $labels = @(
        @{ name = "agentic:signal"; color = "BFD4F2"; description = "Created by signal ingestion" },
        @{ name = "agentic:triaged"; color = "0E8A16"; description = "Triaged and ready for planning" },
        @{ name = "agentic:implementing"; color = "FBCA04"; description = "Work is in implementation" },
        @{ name = "agentic:pr"; color = "5319E7"; description = "Tracked through a pull request" },
        @{ name = "agentic:released"; color = "1D76DB"; description = "Released or shipped" },
        @{ name = "attention:human"; color = "D93F0B"; description = "Needs a person to take action" },
        @{ name = "attention:blocked"; color = "B60205"; description = "Currently blocked" },
        @{ name = "attention:review"; color = "C2E0C6"; description = "Awaiting review or approval" },
        @{ name = "attention:in-progress"; color = "F9D0C4"; description = "Actively being worked" }
    )

    foreach ($label in $labels) {
        Write-Host "Ensuring label '$($label.name)' exists on $Repository"
        gh label create $label.name --repo $Repository --color $label.color --description $label.description --force | Out-Null
    }
}

if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    throw "GH_TOKEN is not set. Configure GhTokenWorkflow as a fine-grained PAT with project write access before running this workflow."
}

if ($env:GH_TOKEN.TrimStart().StartsWith("{")) {
    throw "This workflow currently expects GhTokenWorkflow to contain a PAT string. GitHub App JSON is not yet supported by .github/CreateAgenticProject.ps1."
}

$repoInfo = Get-OwnerAndRepo -Repository $TargetRepository
if ([string]::IsNullOrWhiteSpace($ProjectTitle)) {
    $ProjectTitle = "Agentic loop - $($repoInfo.owner)/$($repoInfo.name)"
}

$stageOptions = @(
    @{ name = "New"; color = "GRAY" },
    @{ name = "Triaged"; color = "BLUE" },
    @{ name = "Planned"; color = "PURPLE" },
    @{ name = "Implementing"; color = "YELLOW" },
    @{ name = "Pull Request"; color = "ORANGE" },
    @{ name = "Released"; color = "GREEN" }
)

$attentionOptions = @(
    @{ name = "OK"; color = "GREEN" },
    @{ name = "Human intervention"; color = "RED" },
    @{ name = "Blocked"; color = "RED" },
    @{ name = "Pending review"; color = "ORANGE" },
    @{ name = "In progress"; color = "BLUE" }
)

Write-Host "Target repository: $TargetRepository"
Write-Host "Project owner: $ProjectOwner"
Write-Host "Project title: $ProjectTitle"
Write-Host "Template source project: $(if ($SourceProjectId) { $SourceProjectId } else { '<none>' })"
Write-Host "Create repository labels: $CreateRepositoryLabels"
Write-Host "Dry run: $DryRun"

if ($DryRun) {
    Write-Host "Dry run selected. No changes were made."
    exit 0
}

$projectOwnerId = Get-ProjectOwnerId -OwnerLogin $ProjectOwner
$project = if ($SourceProjectId) {
    Copy-ProjectV2 -OwnerId $projectOwnerId -SourceProjectId $SourceProjectId -Title $ProjectTitle
}
else {
    New-ProjectV2 -OwnerId $projectOwnerId -Title $ProjectTitle
}

if (-not $SourceProjectId) {
    Write-Host "Creating project fields on $($project.url)"
    $null = New-SingleSelectField -ProjectId $project.id -Name $StageFieldName -Options $stageOptions
    $null = New-SingleSelectField -ProjectId $project.id -Name $AttentionFieldName -Options $attentionOptions
}

if ($CreateRepositoryLabels) {
    Ensure-RepositoryLabels -Repository $TargetRepository
}

$summary = @"
# Agentic project bootstrap complete

- Project: [$($project.title)]($($project.url))
- Target repository: `$TargetRepository`
- Project owner: `$ProjectOwner`
- Template mode: `$(if ($SourceProjectId) { "copy" } else { "new" })`

## Notes

- If you created the project from scratch, open the board view and group by `$StageFieldName`.
- GitHub does not copy auto-add workflows from project templates, so you still need to enable auto-add for `$TargetRepository` in the project workflows UI.
"@

Write-Host "Created project: $($project.url)"
if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $summary -Encoding utf8
}

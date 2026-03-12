# Morpheus.OpenApi PowerShell Module (v8.0.13)

Generated from Morpheus OpenAPI `8.0.13`.

## Important notice

- This module is generated from the Morpheus OpenAPI specification.
- Use at your own risk.
- No standard support is offered for this module.
- Support is best-effort only.

## Install

### Option 1: Install from this repository (recommended)

```powershell
git clone https://github.com/HewlettPackard/morpheus-powershell.git
Set-Location .\morpheus-powershell
Import-Module .\Morpheus.OpenApi.psd1 -Force
```

### Option 2: Manual install (copy to PowerShell modules path)

```powershell
$version = '8.0.13'
$moduleRoot = Join-Path $HOME "Documents\PowerShell\Modules\Morpheus.OpenApi\$version"
New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null

Copy-Item .\Morpheus.OpenApi.psd1 $moduleRoot -Force
Copy-Item .\Morpheus.OpenApi.psm1 $moduleRoot -Force
Copy-Item .\Morpheus.OpenApi.ColumnProfiles.psd1 $moduleRoot -Force

Import-Module Morpheus.OpenApi -RequiredVersion $version -Force
```

Manual install note: if you use a different PowerShell module path, copy the same files into `Morpheus.OpenApi\8.0.13` under that path.

## What this module includes

- `906` generated API operation cmdlets
- `4` session cmdlets:
  - `Connect-Morpheus`
  - `Disconnect-Morpheus`
  - `Get-MorpheusConnection`
  - `Set-MorpheusDefault`
- `2` async task cmdlets:
  - `Get-MorpheusTask`
  - `Wait-MorpheusTask`
- `1` helper cmdlet:
  - `New-MorpheusKeyValueMap`
- Full named parameter flags generated from OpenAPI operation parameters
- Request-body fields are also exposed as cmdlet flags (schema-driven), with clean names like `-PlanId`, `-ZoneId`, `-Copies`, `-LayoutSize`
- Dynamic live argument completion for common ID flags (for example `-ZoneId`, `-SiteId`, `-PlanId`, `-LayoutId`, `-NetworkId`) using connected Morpheus data
- Generated comment-based help on endpoint cmdlets (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.OUTPUTS`) sourced from OpenAPI metadata
- Typed object layer on API results using `PSTypeName` (for example `Morpheus.Group`, `Morpheus.Group.Summary`) for cleaner formatting/extensions
- Pipeline-first identity binding via `ValueFromPipelineByPropertyName` on ID-style parameters (supports chaining by `id`/`*Id` fields)
- Parameter tab completion for `-Morpheus` connection names
- Friendly resource-style names where possible (for example `Get-MorpheusGroups`, `New-MorpheusGroup`)
- Consolidated GET behavior for standard collection/item endpoints (`Get-MorpheusGroups -Id <id>` for a specific item)
  - use the plural cmdlet only (for example `Get-MorpheusGroups`)
  - `Id` is positional on consolidated GET cmdlets, so `Get-MorpheusServers 123` works
- Path parameters are positional for all endpoints (in path order)
  - examples: `Remove-MorpheusGroup 7`, `Get-MorpheusClusterAffinityGroup 12 3`
- Automatic pagination on GET endpoints that support `max`/`offset`
  - default behavior pages through all results
  - specify `-Max` / `-Offset` for manual paging windows
  - use `-NoPaging` to return only one page
- Smart response shaping for all endpoints:
  - Default GET output uses endpoint-aware defaults
    - list endpoints show concise operational columns
    - specific-item endpoints show richer detail by default
  - Use `-Property` to choose additional/alternate columns
  - Use `-Detailed` to return the full object graph
- JSON body handling for all endpoints: pass hashtables/objects or raw JSON strings
- Customizable default column profiles via `Morpheus.OpenApi.ColumnProfiles.psd1`
- Required request-body fields are prompted automatically (schema-driven) when omitted
- Remove actions support confirmation (`-Confirm`, `-Confirm:$false`, `-WhatIf`)
- Create/update actions (`POST`/`PUT`/`PATCH`) support `-WhatIf` / `-Confirm` parity via `ShouldProcess`
- Request preview mode on all endpoint cmdlets:
  - `-Curl` outputs the exact API call and does not execute it
  - `-Scrub` (with `-Curl`) only obfuscates the bearer API token in output

## Import the module

```powershell
Import-Module "<repo>\morpheus-powershell\Morpheus.OpenApi.psd1" -Force
```

## Connect to one or more Morpheus appliances

### Token-based

```powershell
Connect-Morpheus -Name prod -Server https://morpheus-prod.example.com -ApiToken '<token>' -Default
Connect-Morpheus -Name dev  -Server https://morpheus-dev.example.com  -ApiToken '<token>'
```

### Credential-based (OAuth token acquisition)

```powershell
$cred = Get-Credential
Connect-Morpheus -Name prod -Server https://morpheus-prod.example.com -Credential $cred -Default
```

### Username/password-based (OAuth token acquisition)

```powershell
$password = Read-Host 'Password' -AsSecureString
Connect-Morpheus -Name prod -Server https://morpheus-prod.example.com -Username 'admin' -Password $password -Default
```

### Username/plain-text password (automation convenience)

```powershell
Connect-Morpheus -Name prod -Server https://morpheus-prod.example.com -Username 'admin' -PlainTextPassword 'SuperSecret!'
```

Warning: `-PlainTextPassword` can expose credentials in shell history/logs. Prefer `-Password` when possible.

## Targeting behavior (`-Morpheus`)

- Read-style operations (`GET`, `HEAD`, `OPTIONS`):
  - `-Morpheus` is optional.
  - If omitted, request runs across all connected Morpheus appliances.
- `POST`, `PUT`, and `DELETE` operations:
  - If more than one Morpheus is connected, `-Morpheus` is required.
  - If only one Morpheus is connected, `-Morpheus` is optional.
- For all other operations:
  - If only one Morpheus is connected, `-Morpheus` is optional.

This matches the requested scoping behavior.

## Preview API calls (`-Curl`)

Use `-Curl` on any generated endpoint cmdlet to print the exact API call that would be sent.

- `-Curl` is preview-only and does not execute the request.
- `-Curl -Scrub` keeps output identical to `-Curl`, except the bearer API token is obfuscated.
- Works across all verbs (`GET`, `POST`, `PUT`, `DELETE`) and all generated endpoint cmdlets.

Examples:

```powershell
# GET preview
Get-MorpheusGroups -Curl

# POST preview
New-MorpheusApp -Morpheus prod -Body @{ app = @{ name = 'my-app' } } -Curl

# PUT preview with scrubbing
Set-MorpheusApp -Morpheus prod -Id 123 -Body @{ app = @{ description = 'updated' } } -Curl -Scrub

# DELETE preview with positional id and scrubbing
Remove-MorpheusGroup 123 -Curl -Scrub
```

## Defining variable `config` key/value blocks

For endpoints like `New-MorpheusInstance` (and others) where `config` is a flexible JSON object, use one of these patterns.

Preferred for scripts (clean + repeatable):

```powershell
$config = @{
  diskMode = 'thin'
  cpuHotAdd = $true
  maxConnections = 200
  tags = @('prod','web')
}

New-MorpheusInstance -Morpheus prod -Body @{
  instance = @{
    name = 'vm-demo'
    config = $config
  }
}
```

Direct map input (for scripted use):

```powershell
$config = New-MorpheusKeyValueMap -Map @{
  diskMode = 'thin'
  cpuHotAdd = $true
  maxConnections = 200
  tags = @('prod','web')
}
```

Interactive ad-hoc entry (variable pairs until blank key):

```powershell
$config = New-MorpheusKeyValueMap -Interactive
```

In interactive mode, users always enter a key and then a value (repeat until key is blank).

When required-field prompting encounters a missing `config` object, the module uses this same key/value flow automatically.

## Request body flags for all endpoints

For endpoints with request bodies, schema fields are available as direct flags so users do not need dotted property syntax.

Example (`New-MorpheusInstance`):

```powershell
New-MorpheusInstance -Morpheus prod -Name vm-demo -PlanId 995 -ZoneId 12 -Copies 2 -LayoutSize 50 -Config @{ diskMode = 'thin' }
```

Required value prompts now use clean flag-style names (for example `planId`) instead of dotted paths like `instance.plan.id`.

For array-of-object fields (for example `-NetworkInterfaces`, `-Volumes`, `-SecurityGroups`), the module now validates and prompts required per-item keys when needed.

Example pattern:

```powershell
New-MorpheusInstance -Morpheus prod -Name vm-demo -PlanId 995 -ZoneId 12 -NetworkInterfaces @(
  @{ network = @{ id = 201 } },
  @{ network = @{ id = 202 }; ipMode = 'dhcp' }
)
```

If a required nested key is missing in an item, prompts are clean (for example `networkId`) and scoped by item index.

## Async task wait helpers

Use these helpers to poll long-running Morpheus tasks in a consistent way.

```powershell
# Poll by explicit task id
Wait-MorpheusTask -TaskId 12345 -Morpheus prod

# Extract task id from response object (taskId/process/execution shapes)
$resp = New-MorpheusInstance -Morpheus prod -Name vm-demo -PlanId 995 -ZoneId 12
$resp | Wait-MorpheusTask -Morpheus prod -PassThru

# Inspect current task status without waiting
Get-MorpheusTask -TaskId 12345 -Morpheus prod
```

`Get-MorpheusTask` probes known Morpheus task endpoints and returns normalized task metadata (`TaskId`, `TaskPath`, `TaskStatus`, `IsTerminal`, `IsSuccess`) when available.

## Example calls

```powershell
# Read from all connected appliances (if -Morpheus omitted)
Get-MorpheusApps -Max 25

# Consolidated list/detail GET pattern
Get-MorpheusGroups
Get-MorpheusGroups -Id 1
Get-MorpheusServers 123
Get-MorpheusClusters 12

# Automatic paging (default) vs manual page
Get-MorpheusServers
Get-MorpheusServers -NoPaging
Get-MorpheusServers -Offset 0 -Max 25

# Custom columns
Get-MorpheusGroups -Property Id,Name,Code,Uuid

# Full payload
Get-MorpheusGroups -Detailed

# Example endpoint-aware defaults
Get-MorpheusInstances          # concise list view (id/name/group/site/zone...)
Get-MorpheusInstances -Id 123  # richer detail view by default

# Read from a specific appliance
Get-MorpheusApps -Morpheus prod -Max 25

# POST/PUT/DELETE with multiple connected Morpheus: specify one appliance
New-MorpheusApp -Morpheus prod -Body @{ app = @{ name = 'my-app' } }
Set-MorpheusApp -Morpheus prod -Id 123 -Body @{ app = @{ description = 'updated' } }

# WhatIf parity for non-delete changes
New-MorpheusInstance -Morpheus prod -Name vm-demo -PlanId 995 -ZoneId 12 -WhatIf
Set-MorpheusApp -Morpheus prod -Id 123 -Body @{ app = @{ description = 'updated' } } -WhatIf

# Preview-only API call generation (no execution)
Get-MorpheusGroups -Curl
Set-MorpheusApp -Morpheus prod -Id 123 -Body @{ app = @{ description = 'updated' } } -Curl

# Preview with API token scrubbing
Get-MorpheusGroups -Curl -Scrub
Remove-MorpheusGroup 123 -Curl -Scrub

# JSON body as string also works
Set-MorpheusApp -Morpheus prod -Id 123 -Body '{"app":{"description":"updated"}}'

# If required fields are omitted, module prompts interactively (example: group.name)
New-MorpheusGroup -Morpheus prod
```

## Customize default columns

Edit [GIT/morpheus-powershell/Morpheus.OpenApi.ColumnProfiles.psd1](GIT/morpheus-powershell/Morpheus.OpenApi.ColumnProfiles.psd1) to tune list/detail defaults by resource key (`instances`, `servers`, `groups`, `apps`, `default`).

Example profile section:

```powershell
instances = @{
  list = @('id','name','group','site','zone','status')
  detail = @('id','name','displayName','status','group','site','zone','uuid')
}
```

## Regenerate from OpenAPI

```powershell
Set-Location "<repo>\morpheus-powershell\scripts"
./Generate-MorpheusModule.ps1
```

This regenerates:
- `Morpheus.OpenApi.psm1`
- `Morpheus.OpenApi.psd1`

## Reload module without restarting PowerShell

```powershell
Remove-Module Morpheus.OpenApi -Force -ErrorAction SilentlyContinue
Import-Module "<repo>\morpheus-powershell\Morpheus.OpenApi.psd1" -Force
```

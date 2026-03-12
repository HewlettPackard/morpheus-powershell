[CmdletBinding()]
param(
    [Parameter()]
    [string]$SpecRoot = '',

    [Parameter()]
    [string]$OutputDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,

    [Parameter()]
    [string]$ModuleName = 'Morpheus.OpenApi'
)

if ([string]::IsNullOrWhiteSpace($SpecRoot)) {
    $specCandidates = @(
        (Join-Path $PSScriptRoot '..\\..\\morpheus-openapi'),
        (Join-Path $PSScriptRoot '..\\..\\..')
    )

    $resolvedSpec = $null
    foreach ($candidate in $specCandidates) {
        $openApiCandidate = Join-Path $candidate 'openapi.yaml'
        if (Test-Path $openApiCandidate) {
            $resolvedSpec = (Resolve-Path $candidate).Path
            break
        }
    }

    if (-not $resolvedSpec) {
        throw 'Unable to locate OpenAPI spec root. Pass -SpecRoot explicitly.'
    }

    $SpecRoot = $resolvedSpec
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    Import-Module powershell-yaml -ErrorAction SilentlyContinue
}

if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    throw 'ConvertFrom-Yaml is required. Install module powershell-yaml or use PowerShell 7+.'
}

$script:YamlCache = @{}

function Get-YamlObject {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = (Resolve-Path $Path).Path
    if ($script:YamlCache.ContainsKey($resolved)) {
        return $script:YamlCache[$resolved]
    }

    $raw = Get-Content -Raw -Path $resolved
    $obj = ConvertFrom-Yaml -Yaml $raw
    $script:YamlCache[$resolved] = $obj
    return $obj
}

function Resolve-OpenApiRef {
    param(
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$BaseFile
    )

    if ($Ref.StartsWith('#/')) {
        $doc = Get-YamlObject -Path $BaseFile
        $segments = $Ref.TrimStart('#/').Split('/') | ForEach-Object { $_.Replace('~1', '/').Replace('~0', '~') }
        $cursor = $doc
        foreach ($segment in $segments) {
            $cursor = Get-NodeValue -Node $cursor -Key $segment
        }
        return $cursor
    }

    $parts = $Ref -split '#', 2
    $refPath = $parts[0]
    $refFile = $null
    $primaryCandidate = Join-Path (Split-Path -Parent $BaseFile) $refPath
    if (Test-Path $primaryCandidate) {
        $refFile = (Resolve-Path $primaryCandidate).Path
    }
    else {
        $fallbackCandidates = @(
            (Join-Path $SpecRoot $refPath),
            (Join-Path (Join-Path $SpecRoot 'components') $refPath),
            (Join-Path (Join-Path $SpecRoot 'components\schemas') $refPath),
            (Join-Path (Join-Path $SpecRoot 'components\examples') $refPath),
            (Join-Path (Join-Path $SpecRoot 'paths') $refPath)
        )

        foreach ($candidate in $fallbackCandidates) {
            if (Test-Path $candidate) {
                $refFile = (Resolve-Path $candidate).Path
                break
            }
        }

        if (-not $refFile) {
            $leafName = [System.IO.Path]::GetFileName($refPath)
            $matches = @(Get-ChildItem -Path $SpecRoot -Recurse -File -Filter $leafName -ErrorAction SilentlyContinue)
            if ($matches.Count -gt 0) {
                $normalizedRef = $refPath.Replace('/', '\\')
                $best = @($matches | Where-Object { $_.FullName -like "*$normalizedRef" } | Select-Object -First 1)
                if ($best.Count -gt 0) {
                    $refFile = $best[0].FullName
                }
                else {
                    $refFile = $matches[0].FullName
                }
            }
        }
    }

    if (-not $refFile) {
        throw "Unable to resolve OpenAPI reference path [$refPath] from base file [$BaseFile]."
    }

    $doc = Get-YamlObject -Path $refFile

    if ($parts.Count -eq 1 -or [string]::IsNullOrWhiteSpace($parts[1])) {
        return $doc
    }

    $segments = $parts[1].TrimStart('/').Split('/') | ForEach-Object { $_.Replace('~1', '/').Replace('~0', '~') }
    $cursor = $doc
    foreach ($segment in $segments) {
        $cursor = Get-NodeValue -Node $cursor -Key $segment
    }

    return $cursor
}

function Convert-ToParameterName {
    param([Parameter(Mandatory)][string]$RawName)

    $parts = @($RawName -split '[^a-zA-Z0-9]+' | Where-Object { $_ })
    if (-not $parts -or $parts.Count -eq 0) {
        return 'Param'
    }

    return ($parts | ForEach-Object {
        if ($_.Length -eq 1) {
            $_.ToUpperInvariant()
        }
        else {
            $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1)
        }
    }) -join ''
}

function Convert-ToPSType {
    param([object]$Schema)

    if (-not $Schema) { return '[object]' }

    $typeValue = if (Test-NodeKey -Node $Schema -Key 'type') { Get-NodeValue -Node $Schema -Key 'type' } else { $null }
    if ($typeValue -is [System.Array]) {
        $typeValue = ($typeValue | Where-Object { $_ -ne 'null' } | Select-Object -First 1)
    }

    switch ($typeValue) {
        'integer' { return '[long]' }
        'number' { return '[double]' }
        'boolean' { return '[bool]' }
        'array' { return '[object[]]' }
        'string' { return '[string]' }
        default { return '[object]' }
    }
}

function Get-VerbFromOperation {
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Method
    )

    $verb = switch -Regex ($OperationId.ToLowerInvariant()) {
        '^(list|get|find|fetch|query)' { 'Get' }
        '^(add|create|new)' { 'New' }
        '^(update|set|edit|apply|refresh|reindex)' { 'Set' }
        '^(delete|remove|destroy|purge|cancel)' { 'Remove' }
        '^validate' { 'Test' }
        default {
            switch ($Method.ToUpperInvariant()) {
                'GET' { 'Get' }
                'POST' { 'New' }
                'PUT' { 'Set' }
                'PATCH' { 'Set' }
                'DELETE' { 'Remove' }
                default { 'Invoke' }
            }
        }
    }

    return [string]($verb | Select-Object -First 1)
}

function Convert-ToSingularNoun {
    param([Parameter(Mandatory)][string]$Noun)

    if ($Noun.EndsWith('ies')) {
        return $Noun.Substring(0, $Noun.Length - 3) + 'y'
    }

    if ($Noun.EndsWith('s') -and -not $Noun.EndsWith('ss')) {
        return $Noun.Substring(0, $Noun.Length - 1)
    }

    return $Noun
}

function Get-PathResourceNoun {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][bool]$Singular = $false
    )

    $segments = @($Path.Trim('/') -split '/' | Where-Object {
            $_ -and $_ -ne 'api' -and $_ -notmatch '^\{[^/]+\}$'
        })

    if ($segments.Count -eq 0) {
        return 'Operation'
    }

    $noun = Convert-ToParameterName -RawName $segments[$segments.Count - 1]
    if ($Singular) {
        return Convert-ToSingularNoun -Noun $noun
    }

    return $noun
}

function Get-PathContextNoun {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][int]$Depth = 2,
        [Parameter()][bool]$SingularLast = $false
    )

    $segments = @($Path.Trim('/') -split '/' | Where-Object {
            $_ -and $_ -ne 'api' -and $_ -notmatch '^\{[^/]+\}$'
        })

    if ($segments.Count -eq 0) {
        return 'Operation'
    }

    $take = [Math]::Min($Depth, $segments.Count)
    $tail = @($segments | Select-Object -Last $take)

    if ($SingularLast -and $tail.Count -gt 0) {
        $tail[$tail.Count - 1] = Convert-ToSingularNoun -Noun ([string]$tail[$tail.Count - 1])
    }

    return Convert-ToParameterName -RawName ($tail -join '-')
}

function Get-OperationNoun {
    param([Parameter(Mandatory)][string]$OperationId)

    $remaining = $OperationId
    $prefixes = @('list', 'get', 'find', 'fetch', 'query', 'add', 'create', 'new', 'update', 'set', 'edit', 'apply', 'refresh', 'reindex', 'delete', 'remove', 'destroy', 'purge', 'cancel', 'validate')

    $trimmed = $true
    while ($trimmed -and -not [string]::IsNullOrWhiteSpace($remaining)) {
        $trimmed = $false
        foreach ($prefix in $prefixes) {
            if ($remaining -imatch "^$prefix") {
                $remaining = $remaining.Substring($matches[0].Length)
                $trimmed = $true
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($remaining)) {
        $remaining = $OperationId
    }

    return Convert-ToParameterName -RawName $remaining
}

function Get-FriendlyCmdletName {
    param(
        [Parameter(Mandatory)][object]$Operation
    )

    $path = [string]$Operation.Path
    $method = [string]$Operation.Method
    $operationId = [string]$Operation.OperationId

    if ($path -match '^/api/[^/]+$') {
        switch ($method) {
            'GET' { return "Get-Morpheus$(Get-PathResourceNoun -Path $path -Singular:$false)" }
            'POST' { return "New-Morpheus$(Get-PathResourceNoun -Path $path -Singular:$true)" }
            'PUT' { return "Set-Morpheus$(Get-PathResourceNoun -Path $path -Singular:$true)" }
            'PATCH' { return "Set-Morpheus$(Get-PathResourceNoun -Path $path -Singular:$true)" }
            'DELETE' { return "Remove-Morpheus$(Get-PathResourceNoun -Path $path -Singular:$true)" }
        }
    }

    if ($path -match '^/api/[^/]+/\{[^/]+\}$') {
        switch ($method) {
            'GET' { return "Get-Morpheus$(Get-PathResourceNoun -Path $path -Singular:$false)" }
            'PUT' { return "Set-Morpheus$(Get-PathResourceNoun -Path $path -Singular:$true)" }
            'PATCH' { return "Set-Morpheus$(Get-PathResourceNoun -Path $path -Singular:$true)" }
            'DELETE' { return "Remove-Morpheus$(Get-PathResourceNoun -Path $path -Singular:$true)" }
        }
    }

    $verb = Get-VerbFromOperation -OperationId $operationId -Method $method
    $noun = Get-OperationNoun -OperationId $operationId

    return "$verb-Morpheus$noun"
}

function Get-UniqueCmdletName {
    param(
        [Parameter(Mandatory)][object]$Operation,
        [Parameter(Mandatory)][hashtable]$Existing
    )

    $base = Get-FriendlyCmdletName -Operation $Operation
    if (-not $Existing.ContainsKey($base)) {
        return $base
    }

    $verb = Get-VerbFromOperation -OperationId ([string]$Operation.OperationId) -Method ([string]$Operation.Method)
    $singularLast = @('POST', 'PUT', 'PATCH', 'DELETE') -contains ([string]$Operation.Method)

    foreach ($depth in @(2, 3, 4)) {
        $contextNoun = Get-PathContextNoun -Path ([string]$Operation.Path) -Depth $depth -SingularLast:$singularLast
        $candidate = "$verb-Morpheus$contextNoun"
        if (-not $Existing.ContainsKey($candidate)) {
            return $candidate
        }
    }

    $operationNoun = Get-OperationNoun -OperationId ([string]$Operation.OperationId)
    $candidateWithOp = "$verb-Morpheus$operationNoun"
    if (-not $Existing.ContainsKey($candidateWithOp)) {
        return $candidateWithOp
    }

    $counter = 2
    while ($true) {
        $candidate = "$candidateWithOp$counter"
        if (-not $Existing.ContainsKey($candidate)) {
            return $candidate
        }
        $counter++
    }
}

function Escape-SingleQuote {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace("'", "''")
}

function Get-NodeKeys {
    param([object]$Node)
    if ($null -eq $Node) { return @() }
    if ($Node -is [System.Collections.IDictionary]) { return @($Node.Keys) }
    return @($Node.PSObject.Properties.Name)
}

function Test-NodeKey {
    param(
        [object]$Node,
        [string]$Key
    )
    if ($null -eq $Node) { return $false }
    if ($Node -is [System.Collections.IDictionary]) { return $Node.Contains($Key) }
    return ($Node.PSObject.Properties[$Key] -ne $null)
}

function Get-NodeValue {
    param(
        [object]$Node,
        [string]$Key
    )
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains($Key)) { return $Node[$Key] }
        return $null
    }
    if ($Node.PSObject.Properties[$Key]) { return $Node.$Key }
    return $null
}

function Resolve-SchemaNode {
    param(
        [Parameter()][object]$Schema,
        [Parameter(Mandatory)][string]$BaseFile
    )

    if (-not $Schema) { return $null }
    if (Test-NodeKey -Node $Schema -Key '$ref') {
        return Resolve-OpenApiRef -Ref (Get-NodeValue -Node $Schema -Key '$ref') -BaseFile $BaseFile
    }
    return $Schema
}

function Get-SchemaPropertyNode {
    param(
        [Parameter(Mandatory)][object]$Schema,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][string]$BaseFile
    )

    if (-not (Test-NodeKey -Node $Schema -Key 'properties')) { return $null }
    $properties = Get-NodeValue -Node $Schema -Key 'properties'
    if (-not (Test-NodeKey -Node $properties -Key $PropertyName)) { return $null }

    $propNode = Get-NodeValue -Node $properties -Key $PropertyName
    return Resolve-SchemaNode -Schema $propNode -BaseFile $BaseFile
}

function Get-RequiredSchemaLeafPaths {
    param(
        [Parameter()][object]$Schema,
        [Parameter(Mandatory)][string]$BaseFile,
        [Parameter()][string]$Prefix = ''
    )

    try {
        $resolved = Resolve-SchemaNode -Schema $Schema -BaseFile $BaseFile
    }
    catch {
        return @()
    }
    if (-not $resolved) { return @() }

    $paths = New-Object System.Collections.Generic.List[string]

    if (Test-NodeKey -Node $resolved -Key 'allOf') {
        foreach ($part in @((Get-NodeValue -Node $resolved -Key 'allOf'))) {
            foreach ($childPath in @(Get-RequiredSchemaLeafPaths -Schema $part -BaseFile $BaseFile -Prefix $Prefix)) {
                if (-not [string]::IsNullOrWhiteSpace($childPath) -and -not $paths.Contains($childPath)) {
                    $paths.Add($childPath)
                }
            }
        }
    }

    if (-not (Test-NodeKey -Node $resolved -Key 'required')) {
        return @($paths)
    }

    $requiredNames = @((Get-NodeValue -Node $resolved -Key 'required'))
    foreach ($requiredName in $requiredNames) {
        $name = [string]$requiredName
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $currentPath = if ([string]::IsNullOrWhiteSpace($Prefix)) { $name } else { "$Prefix.$name" }
        $propertySchema = Get-SchemaPropertyNode -Schema $resolved -PropertyName $name -BaseFile $BaseFile

        $hasChildRequired = $false
        if ($propertySchema) {
            $childPaths = @(Get-RequiredSchemaLeafPaths -Schema $propertySchema -BaseFile $BaseFile -Prefix $currentPath)
            if ($childPaths.Count -gt 0) {
                $hasChildRequired = $true
                foreach ($child in $childPaths) {
                    if (-not $paths.Contains($child)) {
                        $paths.Add($child)
                    }
                }
            }
        }

        if (-not $hasChildRequired -and -not $paths.Contains($currentPath)) {
            $paths.Add($currentPath)
        }
    }

    return @($paths)
}

function Get-SchemaLeafDefinitions {
    param(
        [Parameter()][object]$Schema,
        [Parameter(Mandatory)][string]$BaseFile,
        [Parameter()][string]$Prefix = ''
    )

    $resolved = Resolve-SchemaNode -Schema $Schema -BaseFile $BaseFile
    if (-not $resolved) { return @() }

    $definitions = New-Object System.Collections.Generic.List[object]

    if (Test-NodeKey -Node $resolved -Key 'allOf') {
        foreach ($part in @((Get-NodeValue -Node $resolved -Key 'allOf'))) {
            foreach ($child in @(Get-SchemaLeafDefinitions -Schema $part -BaseFile $BaseFile -Prefix $Prefix)) {
                if ($null -eq $child) { continue }
                $existing = @($definitions | Where-Object { $_.Path -eq $child.Path } | Select-Object -First 1)
                if ($existing.Count -eq 0) { $definitions.Add($child) }
            }
        }
    }

    $hasProperties = (Test-NodeKey -Node $resolved -Key 'properties')
    if ($hasProperties) {
        $properties = Get-NodeValue -Node $resolved -Key 'properties'
        foreach ($propertyName in @(Get-NodeKeys -Node $properties)) {
            $propertyNameString = [string]$propertyName
            $childPath = if ([string]::IsNullOrWhiteSpace($Prefix)) { $propertyNameString } else { "$Prefix.$propertyNameString" }
            try {
                $childSchema = Resolve-SchemaNode -Schema (Get-NodeValue -Node $properties -Key $propertyNameString) -BaseFile $BaseFile
            }
            catch {
                continue
            }
            $childDefs = @(Get-SchemaLeafDefinitions -Schema $childSchema -BaseFile $BaseFile -Prefix ([string]$childPath))
            if ($childDefs.Count -gt 0) {
                foreach ($childDef in $childDefs) {
                    if ($null -eq $childDef) { continue }
                    $existing = @($definitions | Where-Object { $_.Path -eq $childDef.Path } | Select-Object -First 1)
                    if ($existing.Count -eq 0) { $definitions.Add($childDef) }
                }
            }
            else {
                $existing = @($definitions | Where-Object { $_.Path -eq $childPath } | Select-Object -First 1)
                if ($existing.Count -eq 0) {
                    $definitions.Add([pscustomobject]@{ Path = $childPath; Schema = $childSchema })
                }
            }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Prefix)) {
        $definitions.Add([pscustomobject]@{ Path = $Prefix; Schema = $resolved })
    }

    return $definitions.ToArray()
}

function Get-ArrayObjectRequirements {
    param(
        [Parameter()][object]$Schema,
        [Parameter(Mandatory)][string]$BaseFile,
        [Parameter()][string]$Prefix = ''
    )

    try {
        $resolved = Resolve-SchemaNode -Schema $Schema -BaseFile $BaseFile
    }
    catch {
        return @()
    }

    if (-not $resolved) { return @() }

    $results = New-Object System.Collections.Generic.List[object]

    if (Test-NodeKey -Node $resolved -Key 'allOf') {
        foreach ($part in @((Get-NodeValue -Node $resolved -Key 'allOf'))) {
            foreach ($item in @(Get-ArrayObjectRequirements -Schema $part -BaseFile $BaseFile -Prefix $Prefix)) {
                if ($null -eq $item) { continue }
                $existing = @($results | Where-Object { $_.Path -eq $item.Path } | Select-Object -First 1)
                if ($existing.Count -eq 0) {
                    $results.Add($item)
                }
                else {
                    foreach ($p in @($item.RequiredPaths)) {
                        if (-not @($existing[0].RequiredPaths).Contains($p)) {
                            $existing[0].RequiredPaths += @($p)
                        }
                    }
                }
            }
        }
    }

    $schemaType = if (Test-NodeKey -Node $resolved -Key 'type') { [string](Get-NodeValue -Node $resolved -Key 'type') } else { '' }
    if ($schemaType -eq 'array' -and -not [string]::IsNullOrWhiteSpace($Prefix)) {
        $itemsSchema = $null
        if (Test-NodeKey -Node $resolved -Key 'items') {
            try {
                $itemsSchema = Resolve-SchemaNode -Schema (Get-NodeValue -Node $resolved -Key 'items') -BaseFile $BaseFile
            }
            catch {
                $itemsSchema = $null
            }
        }

        if ($itemsSchema) {
            $itemRequired = @(Get-RequiredSchemaLeafPaths -Schema $itemsSchema -BaseFile $BaseFile -Prefix '')
            $itemRequiredEffective = @($itemRequired)

            if ($itemRequiredEffective.Count -eq 0) {
                $itemLeafDefs = @(Get-SchemaLeafDefinitions -Schema $itemsSchema -BaseFile $BaseFile -Prefix '')
                $itemLeafPaths = @($itemLeafDefs | ForEach-Object {
                        if (Test-NodeKey -Node $_ -Key 'Path') { [string](Get-NodeValue -Node $_ -Key 'Path') } else { '' }
                    } | Where-Object { $_ })

                $nestedIdPaths = @($itemLeafPaths | Where-Object { $_ -match '\.id$' -and $_ -ne 'id' })
                $directIdPaths = @($itemLeafPaths | Where-Object { $_ -eq 'id' })
                if ($nestedIdPaths.Count -gt 0) {
                    $itemRequiredEffective = @($nestedIdPaths)
                }
                elseif ($directIdPaths.Count -gt 0) {
                    $itemRequiredEffective = @($directIdPaths)
                }
            }

            if ($itemRequiredEffective.Count -gt 0) {
                $results.Add([pscustomobject]@{
                        Path = $Prefix
                        RequiredPaths = @($itemRequiredEffective)
                    })
            }
        }
    }

    if (Test-NodeKey -Node $resolved -Key 'properties') {
        $properties = Get-NodeValue -Node $resolved -Key 'properties'
        foreach ($propertyName in @(Get-NodeKeys -Node $properties)) {
            $propertyNameString = [string]$propertyName
            $childPath = if ([string]::IsNullOrWhiteSpace($Prefix)) { $propertyNameString } else { "$Prefix.$propertyNameString" }
            try {
                $childSchema = Resolve-SchemaNode -Schema (Get-NodeValue -Node $properties -Key $propertyNameString) -BaseFile $BaseFile
            }
            catch {
                continue
            }

            foreach ($item in @(Get-ArrayObjectRequirements -Schema $childSchema -BaseFile $BaseFile -Prefix $childPath)) {
                if ($null -eq $item) { continue }
                $existing = @($results | Where-Object { $_.Path -eq $item.Path } | Select-Object -First 1)
                if ($existing.Count -eq 0) {
                    $results.Add($item)
                }
                else {
                    foreach ($p in @($item.RequiredPaths)) {
                        if (-not @($existing[0].RequiredPaths).Contains($p)) {
                            $existing[0].RequiredPaths += @($p)
                        }
                    }
                }
            }
        }
    }

    return $results.ToArray()
}

function Convert-ToLowerCamelCase {
    param([Parameter(Mandatory)][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }
    if ($Name.Length -eq 1) { return $Name.ToLowerInvariant() }
    return $Name.Substring(0, 1).ToLowerInvariant() + $Name.Substring(1)
}

function Convert-OpenApiExampleToText {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) { return '' }

    if ($Value -is [string]) {
        return [string]$Value
    }

    try {
        return ($Value | ConvertTo-Json -Depth 50)
    }
    catch {
        return [string]$Value
    }
}

function Get-OperationResponseExample {
    param(
        [Parameter()][object]$OperationNode,
        [Parameter(Mandatory)][string]$BaseFile
    )

    if (-not $OperationNode -or -not (Test-NodeKey -Node $OperationNode -Key 'responses')) {
        return ''
    }

    $responsesNode = Get-NodeValue -Node $OperationNode -Key 'responses'
    if (-not $responsesNode) { return '' }

    $responseOrder = New-Object System.Collections.Generic.List[string]
    foreach ($preferred in @('200', '201', '202', '203', '204', 'default')) {
        if (Test-NodeKey -Node $responsesNode -Key $preferred) {
            $responseOrder.Add($preferred)
        }
    }
    foreach ($responseKey in @(Get-NodeKeys -Node $responsesNode)) {
        $responseKeyString = [string]$responseKey
        if (-not $responseOrder.Contains($responseKeyString)) {
            $responseOrder.Add($responseKeyString)
        }
    }

    foreach ($responseCode in $responseOrder) {
        $responseNode = Get-NodeValue -Node $responsesNode -Key $responseCode
        if ($responseNode -and (Test-NodeKey -Node $responseNode -Key '$ref')) {
            try {
                $responseNode = Resolve-OpenApiRef -Ref (Get-NodeValue -Node $responseNode -Key '$ref') -BaseFile $BaseFile
            }
            catch {
                continue
            }
        }

        if (-not $responseNode -or -not (Test-NodeKey -Node $responseNode -Key 'content')) { continue }

        $contentNode = Get-NodeValue -Node $responseNode -Key 'content'
        $contentTypes = @(Get-NodeKeys -Node $contentNode)
        if ($contentTypes.Count -eq 0) { continue }

        $selectedContentType = if ($contentTypes -contains 'application/json') { 'application/json' } else { [string]$contentTypes[0] }
        if (-not (Test-NodeKey -Node $contentNode -Key $selectedContentType)) { continue }

        $mediaNode = Get-NodeValue -Node $contentNode -Key $selectedContentType
        $exampleValue = $null

        if (Test-NodeKey -Node $mediaNode -Key 'example') {
            $exampleValue = Get-NodeValue -Node $mediaNode -Key 'example'
        }
        elseif (Test-NodeKey -Node $mediaNode -Key 'examples') {
            $examplesNode = Get-NodeValue -Node $mediaNode -Key 'examples'
            $exampleKeys = @(Get-NodeKeys -Node $examplesNode)
            if ($exampleKeys.Count -gt 0) {
                $exampleNode = Get-NodeValue -Node $examplesNode -Key ([string]$exampleKeys[0])
                if ($exampleNode -and (Test-NodeKey -Node $exampleNode -Key '$ref')) {
                    try {
                        $exampleNode = Resolve-OpenApiRef -Ref (Get-NodeValue -Node $exampleNode -Key '$ref') -BaseFile $BaseFile
                    }
                    catch {
                        $exampleNode = $null
                    }
                }
                if ($exampleNode -and (Test-NodeKey -Node $exampleNode -Key 'value')) {
                    $exampleValue = Get-NodeValue -Node $exampleNode -Key 'value'
                }
            }
        }

        if ($null -ne $exampleValue) {
            if ($exampleValue -is [System.Collections.IDictionary] -and (Test-NodeKey -Node $exampleValue -Key '$ref')) {
                try {
                    $exampleValue = Resolve-OpenApiRef -Ref (Get-NodeValue -Node $exampleValue -Key '$ref') -BaseFile $BaseFile
                }
                catch {
                }
            }
            $exampleText = [string](Convert-OpenApiExampleToText -Value $exampleValue)
            if ($exampleText.Length -gt 2400) {
                $exampleText = $exampleText.Substring(0, 2400) + "`n..."
            }
            return $exampleText
        }
    }

    return ''
}

$openApiFile = Join-Path $SpecRoot 'openapi.yaml'
if (-not (Test-Path $openApiFile)) {
    throw "Unable to locate openapi.yaml under $SpecRoot"
}

$openApi = Get-YamlObject -Path $openApiFile

$operations = New-Object System.Collections.Generic.List[object]

foreach ($pathName in (Get-NodeKeys -Node $openApi.paths)) {
    $pathNode = Get-NodeValue -Node $openApi.paths -Key $pathName
    if (-not (Test-NodeKey -Node $pathNode -Key '$ref')) { continue }

    $pathFile = (Resolve-Path (Join-Path $SpecRoot (Get-NodeValue -Node $pathNode -Key '$ref'))).Path
    $pathDoc = Get-YamlObject -Path $pathFile

    $pathLevelParams = @()
    if (Test-NodeKey -Node $pathDoc -Key 'parameters') {
        $pathLevelParams = @((Get-NodeValue -Node $pathDoc -Key 'parameters'))
    }

    foreach ($method in @('get', 'post', 'put', 'patch', 'delete', 'head', 'options')) {
        if (-not (Test-NodeKey -Node $pathDoc -Key $method)) { continue }

        $operation = Get-NodeValue -Node $pathDoc -Key $method
        $operationId = if (Test-NodeKey -Node $operation -Key 'operationId') { [string](Get-NodeValue -Node $operation -Key 'operationId') } else { "${method}_${pathName}" }

        $allParamsRaw = @($pathLevelParams)
        if (Test-NodeKey -Node $operation -Key 'parameters') {
            $allParamsRaw += @((Get-NodeValue -Node $operation -Key 'parameters'))
        }

        $resolvedParams = New-Object System.Collections.Generic.List[object]
        foreach ($paramEntry in $allParamsRaw) {
            $paramObj = if (Test-NodeKey -Node $paramEntry -Key '$ref') {
                Resolve-OpenApiRef -Ref (Get-NodeValue -Node $paramEntry -Key '$ref') -BaseFile $pathFile
            }
            else {
                $paramEntry
            }
            $resolvedParams.Add($paramObj)
        }

        $requestBody = $null
        if (Test-NodeKey -Node $operation -Key 'requestBody') {
            $requestBodyNode = Get-NodeValue -Node $operation -Key 'requestBody'
            $requestBody = if (Test-NodeKey -Node $requestBodyNode -Key '$ref') {
                Resolve-OpenApiRef -Ref (Get-NodeValue -Node $requestBodyNode -Key '$ref') -BaseFile $pathFile
            }
            else {
                $requestBodyNode
            }
        }

        $requestContentType = 'application/json'
        $requestSchema = $null
        if ($requestBody -and (Test-NodeKey -Node $requestBody -Key 'content')) {
            $contentNode = Get-NodeValue -Node $requestBody -Key 'content'
            $contentTypes = @(Get-NodeKeys -Node $contentNode)
            if ($contentTypes.Count -gt 0) {
                if ($contentTypes -contains 'application/json') {
                    $requestContentType = 'application/json'
                }
                else {
                    $requestContentType = [string]$contentTypes[0]
                }
            }

            if (Test-NodeKey -Node $contentNode -Key $requestContentType) {
                $selectedContent = Get-NodeValue -Node $contentNode -Key $requestContentType
                if (Test-NodeKey -Node $selectedContent -Key 'schema') {
                    $requestSchema = Resolve-SchemaNode -Schema (Get-NodeValue -Node $selectedContent -Key 'schema') -BaseFile $pathFile
                }
            }
        }

        $requiredBodyPaths = @()
        $bodyLeafDefinitions = @()
        $arrayObjectRequirements = @()
        $rootBodyProperty = ''
        $responseExample = [string](Get-OperationResponseExample -OperationNode $operation -BaseFile $pathFile)
        if ($requestSchema) {
            $requiredBodyPaths = @(Get-RequiredSchemaLeafPaths -Schema $requestSchema -BaseFile $pathFile)
            $bodyLeafDefinitions = @(Get-SchemaLeafDefinitions -Schema $requestSchema -BaseFile $pathFile)
            $arrayObjectRequirements = @(Get-ArrayObjectRequirements -Schema $requestSchema -BaseFile $pathFile)

            if (Test-NodeKey -Node $requestSchema -Key 'properties') {
                $topKeys = @(Get-NodeKeys -Node (Get-NodeValue -Node $requestSchema -Key 'properties'))
                if ($topKeys.Count -eq 1) {
                    $rootBodyProperty = [string]$topKeys[0]
                }
            }
        }

        $opsObj = [pscustomobject]@{
            Path = [string]$pathName
            Method = $method.ToUpperInvariant()
            OperationId = $operationId
            Summary = if (Test-NodeKey -Node $operation -Key 'summary') { [string](Get-NodeValue -Node $operation -Key 'summary') } else { '' }
            Description = if (Test-NodeKey -Node $operation -Key 'description') { [string](Get-NodeValue -Node $operation -Key 'description') } else { '' }
            Parameters = $resolvedParams
            RequestBody = $requestBody
            RequestContentType = $requestContentType
            RequiredBodyPaths = $requiredBodyPaths
            BodyLeafDefinitions = $bodyLeafDefinitions
            ArrayObjectRequirements = $arrayObjectRequirements
            RootBodyProperty = $rootBodyProperty
            ResponseExample = $responseExample
            IsDetailPath = ($method.ToUpperInvariant() -eq 'GET' -and ([string]$pathName -match '^/api/.+/\{[^/]+\}$'))
        }

        $operations.Add($opsObj)
    }
}

$skipOperationKeys = New-Object System.Collections.Generic.HashSet[string]

foreach ($collectionOp in @($operations | Where-Object { $_.Method -eq 'GET' -and $_.Path -match '^/api/[^/]+$' })) {
    $collectionRegex = '^' + [Regex]::Escape($collectionOp.Path) + '/\{[^/]+\}$'
    $itemCandidates = @($operations | Where-Object {
            $_.Method -eq 'GET' -and $_.Path -match $collectionRegex
        })

    if ($itemCandidates.Count -ne 1) { continue }

    $itemOp = $itemCandidates[0]
    $idPathParam = @($itemOp.Parameters | Where-Object {
            (Test-NodeKey -Node $_ -Key 'in') -and ((Get-NodeValue -Node $_ -Key 'in') -eq 'path')
        } | Select-Object -First 1)

    if ($idPathParam.Count -eq 0) { continue }

    $collectionOp | Add-Member -MemberType NoteProperty -Name ConsolidatedItemPath -Value $itemOp.Path -Force
    $collectionOp | Add-Member -MemberType NoteProperty -Name ConsolidatedIdParam -Value $idPathParam[0] -Force

    $itemKey = "{0}|{1}" -f $itemOp.Method, $itemOp.Path
    [void]$skipOperationKeys.Add($itemKey)
}

$operationsToGenerate = @($operations | Where-Object {
    -not $skipOperationKeys.Contains(("{0}|{1}" -f $_.Method, $_.Path))
    })

$commandNames = @{}
foreach ($op in $operationsToGenerate) {
    $cmdlet = Get-UniqueCmdletName -Operation $op -Existing $commandNames
    $commandNames[$cmdlet] = 1

    $op | Add-Member -MemberType NoteProperty -Name CmdletName -Value $cmdlet -Force
}

$generatedOn = (Get-Date).ToString('u')

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Generated by scripts/Generate-MorpheusModule.ps1')
$lines.Add("# Generated: $generatedOn")
$lines.Add('Set-StrictMode -Version Latest')
$lines.Add('$ErrorActionPreference = ''Stop''')
$lines.Add('')
$lines.Add('$script:MorpheusConnections = @{}')
$lines.Add('$script:DefaultMorpheus = $null')
$lines.Add('$script:MorpheusColumnProfiles = $null')
$lines.Add('$script:MorpheusDynamicCompleterMap = @{')
$lines.Add('    ZoneId = @{ Path = ''/api/zones''; Collection = ''zones'' }')
$lines.Add('    SiteId = @{ Path = ''/api/groups''; Collection = ''groups'' }')
$lines.Add('    GroupId = @{ Path = ''/api/groups''; Collection = ''groups'' }')
$lines.Add('    PlanId = @{ Path = ''/api/service-plans''; Collection = ''plans'' }')
$lines.Add('    LayoutId = @{ Path = ''/api/library/layouts''; Collection = ''layouts'' }')
$lines.Add('    NetworkId = @{ Path = ''/api/networks''; Collection = ''networks'' }')
$lines.Add('    ClusterId = @{ Path = ''/api/clusters''; Collection = ''clusters'' }')
$lines.Add('    ServerId = @{ Path = ''/api/servers''; Collection = ''servers'' }')
$lines.Add('    InstanceId = @{ Path = ''/api/instances''; Collection = ''instances'' }')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusConnectionNameCompletions {')
$lines.Add('    param([string]$WordToComplete)')
$lines.Add('    $prefix = if ($null -eq $WordToComplete) { '''' } else { $WordToComplete }')
$lines.Add('    return $script:MorpheusConnections.Keys | Where-Object { $_ -like "$prefix*" } | Sort-Object')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Resolve-MorpheusCompleterTarget {')
$lines.Add('    param([hashtable]$BoundParameters)')
$lines.Add('')
$lines.Add('    if ($script:MorpheusConnections.Count -eq 0) { return $null }')
$lines.Add('')
$lines.Add('    if ($BoundParameters -and $BoundParameters.ContainsKey(''Morpheus'')) {')
$lines.Add('        $requested = [string]$BoundParameters[''Morpheus'']')
$lines.Add('        if ($requested -and $script:MorpheusConnections.ContainsKey($requested)) {')
$lines.Add('            return $script:MorpheusConnections[$requested]')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($script:DefaultMorpheus -and $script:MorpheusConnections.ContainsKey($script:DefaultMorpheus)) {')
$lines.Add('        return $script:MorpheusConnections[$script:DefaultMorpheus]')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($script:MorpheusConnections.Count -eq 1) {')
$lines.Add('        return @($script:MorpheusConnections.Values | Select-Object -First 1)[0]')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $firstName = @($script:MorpheusConnections.Keys | Sort-Object | Select-Object -First 1)')
$lines.Add('    if ($firstName.Count -gt 0) {')
$lines.Add('        return $script:MorpheusConnections[[string]$firstName[0]]')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return $null')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusDynamicCollectionItems {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][object]$Response,')
$lines.Add('        [Parameter()][string]$CollectionName')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($null -eq $Response) { return @() }')
$lines.Add('')
$lines.Add('    if ($Response -is [System.Collections.IEnumerable] -and $Response -isnot [string] -and $Response -isnot [pscustomobject]) {')
$lines.Add('        return @($Response)')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Response -is [pscustomobject]) {')
$lines.Add('        if ($CollectionName -and $Response.PSObject.Properties[$CollectionName]) {')
$lines.Add('            return @($Response.$CollectionName)')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        foreach ($prop in $Response.PSObject.Properties) {')
$lines.Add('            $val = $prop.Value')
$lines.Add('            if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {')
$lines.Add('                return @($val)')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return @()')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusDynamicIdCompletions {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][string]$ParameterName,')
$lines.Add('        [Parameter()][string]$WordToComplete,')
$lines.Add('        [Parameter()][hashtable]$BoundParameters')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ([string]::IsNullOrWhiteSpace($ParameterName)) { return @() }')
$lines.Add('    if (-not $script:MorpheusDynamicCompleterMap.ContainsKey($ParameterName)) { return @() }')
$lines.Add('')
$lines.Add('    $target = Resolve-MorpheusCompleterTarget -BoundParameters $BoundParameters')
$lines.Add('    if ($null -eq $target) { return @() }')
$lines.Add('')
$lines.Add('    $spec = $script:MorpheusDynamicCompleterMap[$ParameterName]')
$lines.Add('    $path = [string]$spec.Path')
$lines.Add('    $collection = [string]$spec.Collection')
$lines.Add('')
$lines.Add('    try {')
$lines.Add('        $uriBuilder = [System.UriBuilder]::new([System.Uri]::new([System.Uri][string]$target.Server, $path))')
$lines.Add('        $uriBuilder.Query = ''max=200''')
$lines.Add('        $response = Invoke-RestMethod -Method GET -Uri $uriBuilder.Uri.AbsoluteUri -Headers @{ Authorization = "Bearer $($target.AccessToken)" } -ErrorAction Stop')
$lines.Add('    }')
$lines.Add('    catch {')
$lines.Add('        return @()')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $items = @(Get-MorpheusDynamicCollectionItems -Response $response -CollectionName $collection)')
$lines.Add('    if ($items.Count -eq 0) { return @() }')
$lines.Add('')
$lines.Add('    $prefix = if ($null -eq $WordToComplete) { '''' } else { [string]$WordToComplete }')
$lines.Add('    $results = New-Object System.Collections.Generic.List[System.Management.Automation.CompletionResult]')
$lines.Add('')
$lines.Add('    foreach ($item in $items) {')
$lines.Add('        $idValue = $null')
$lines.Add('        if ($item -is [pscustomobject] -and $item.PSObject.Properties[''id'']) {')
$lines.Add('            $idValue = $item.id')
$lines.Add('        }')
$lines.Add('        elseif ($item -is [System.Collections.IDictionary] -and $item.Contains(''id'')) {')
$lines.Add('            $idValue = $item[''id'']')
$lines.Add('        }')
$lines.Add('        if ($null -eq $idValue) { continue }')
$lines.Add('')
$lines.Add('        $idText = [string]$idValue')
$lines.Add('        if (-not $idText) { continue }')
$lines.Add('')
$lines.Add('        $nameText = ''''')
$lines.Add('        if ($item -is [pscustomobject]) {')
$lines.Add('            foreach ($nameField in @(''name'', ''displayName'', ''code'')) {')
$lines.Add('                if ($item.PSObject.Properties[$nameField] -and $item.$nameField) { $nameText = [string]$item.$nameField; break }')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('        elseif ($item -is [System.Collections.IDictionary]) {')
$lines.Add('            foreach ($nameField in @(''name'', ''displayName'', ''code'')) {')
$lines.Add('                if ($item.Contains($nameField) -and $item[$nameField]) { $nameText = [string]$item[$nameField]; break }')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        if ($prefix -and -not ($idText -like "$prefix*" -or ($nameText -and $nameText -like "$prefix*"))) { continue }')
$lines.Add('')
$lines.Add('        $toolTip = if ($nameText) { "$idText - $nameText" } else { $idText }')
$lines.Add('        $results.Add([System.Management.Automation.CompletionResult]::new($idText, $idText, ''ParameterValue'', $toolTip))')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return @($results | Select-Object -First 100)')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Resolve-MorpheusTargets {')
$lines.Add('    [CmdletBinding()]')
$lines.Add('    param(')
$lines.Add('        [Parameter()]')
$lines.Add('        [string]$Morpheus,')
$lines.Add('        [Parameter(Mandatory)]')
$lines.Add('        [string]$Method')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($script:MorpheusConnections.Count -eq 0) {')
$lines.Add('        throw ''No Morpheus connections found. Use Connect-Morpheus first.''')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Morpheus) {')
$lines.Add('        if (-not $script:MorpheusConnections.ContainsKey($Morpheus)) {')
$lines.Add('            throw "Unknown Morpheus connection [$Morpheus]. Use Get-MorpheusConnection."')
$lines.Add('        }')
$lines.Add('        return @($script:MorpheusConnections[$Morpheus])')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($script:MorpheusConnections.Count -eq 1) {')
$lines.Add('        return @($script:MorpheusConnections.Values | Select-Object -First 1)')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if (@(''POST'', ''PUT'', ''DELETE'') -contains $Method) {')
$lines.Add('        throw ''This operation requires -Morpheus when more than one Morpheus is connected.''')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return @($script:MorpheusConnections.Values)')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Convert-MorpheusBodyInput {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][object]$Body,')
$lines.Add('        [Parameter()][string]$ContentType')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($null -eq $Body) { return $null }')
$lines.Add('')
$lines.Add('    if ($ContentType -ne ''application/json'') {')
$lines.Add('        return $Body')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Body -isnot [string]) {')
$lines.Add('        return $Body')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $trimmed = $Body.Trim()')
$lines.Add('    if (-not $trimmed) { return $Body }')
$lines.Add('')
$lines.Add('    if ($trimmed.StartsWith(''{'') -or $trimmed.StartsWith(''['')) {')
$lines.Add('        try {')
$lines.Add('            return ($Body | ConvertFrom-Json -Depth 100)')
$lines.Add('        }')
$lines.Add('        catch {')
$lines.Add('            return $Body')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return $Body')
$lines.Add('}')
$lines.Add('')
$lines.Add('function ConvertTo-MorpheusObject {')
$lines.Add('    param([Parameter()][object]$Value)')
$lines.Add('')
$lines.Add('    if ($null -eq $Value) { return $null }')
$lines.Add('')
$lines.Add('    if ($Value -is [string] -or $Value -is [ValueType]) {')
$lines.Add('        return $Value')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Value -is [System.Collections.IDictionary]) {')
$lines.Add('        $o = [ordered]@{}')
$lines.Add('        foreach ($k in $Value.Keys) {')
$lines.Add('            $o[[string]$k] = ConvertTo-MorpheusObject -Value $Value[$k]')
$lines.Add('        }')
$lines.Add('        return [pscustomobject]$o')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {')
$lines.Add('        $list = foreach ($item in $Value) {')
$lines.Add('            ConvertTo-MorpheusObject -Value $item')
$lines.Add('        }')
$lines.Add('        return @($list)')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $props = @()')
$lines.Add('    if ($null -ne $Value.PSObject -and $null -ne $Value.PSObject.Properties) {')
$lines.Add('        $props = @($Value.PSObject.Properties)')
$lines.Add('    }')
$lines.Add('    if (@($props).Count -eq 0) { return $Value }')
$lines.Add('')
$lines.Add('    $o = [ordered]@{}')
$lines.Add('    foreach ($prop in $props) {')
$lines.Add('        $o[$prop.Name] = ConvertTo-MorpheusObject -Value $prop.Value')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return [pscustomobject]$o')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusPayloadData {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][object]$Response,')
$lines.Add('        [Parameter()][string]$Path,')
$lines.Add('        [Parameter()][bool]$IsDetailRequest')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($null -eq $Response) {')
$lines.Add('        return @{ IsCollection = $false; Data = $null }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Response -is [System.Collections.IEnumerable] -and $Response -isnot [string] -and $Response -isnot [pscustomobject]) {')
$lines.Add('        return @{ IsCollection = $true; Data = @($Response) }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Response -isnot [pscustomobject]) {')
$lines.Add('        return @{ IsCollection = $false; Data = $Response }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $resourceCandidates = @()')
$lines.Add('    if ($Path) {')
$lines.Add('        $segments = @($Path.Trim(''/'') -split ''/'' | Where-Object { $_ -and $_ -notmatch ''^\d+$'' -and $_ -notmatch ''^[0-9a-fA-F-]{8,}$'' })')
$lines.Add('        if ($segments.Count -gt 0) {')
$lines.Add('            $leaf = [string]$segments[$segments.Count - 1]')
$lines.Add('            if ($leaf -eq ''api'' -and $segments.Count -gt 1) {')
$lines.Add('                $leaf = [string]$segments[$segments.Count - 2]')
$lines.Add('            }')
$lines.Add('            if ($leaf -ne ''api'') {')
$lines.Add('                $resourceCandidates += $leaf.ToLowerInvariant()')
$lines.Add('                if ($leaf.ToLowerInvariant().EndsWith(''ies'')) {')
$lines.Add('                    $resourceCandidates += ($leaf.Substring(0, $leaf.Length - 3) + ''y'').ToLowerInvariant()')
$lines.Add('                }')
$lines.Add('                elseif ($leaf.ToLowerInvariant().EndsWith(''s'') -and -not $leaf.ToLowerInvariant().EndsWith(''ss'')) {')
$lines.Add('                    $resourceCandidates += $leaf.Substring(0, $leaf.Length - 1).ToLowerInvariant()')
$lines.Add('                }')
$lines.Add('                else {')
$lines.Add('                    $resourceCandidates += ($leaf + ''s'').ToLowerInvariant()')
$lines.Add('                }')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $excluded = @(''meta'', ''msg'', ''message'', ''success'', ''errors'')')
$lines.Add('    $candidateProps = @($Response.PSObject.Properties | Where-Object { $excluded -notcontains $_.Name })')
$lines.Add('')
$lines.Add('    if ($resourceCandidates.Count -gt 0) {')
$lines.Add('        foreach ($candidateName in ($resourceCandidates | Select-Object -Unique)) {')
$lines.Add('            $candidateProp = @($candidateProps | Where-Object { $_.Name -ieq $candidateName } | Select-Object -First 1)')
$lines.Add('            if ($candidateProp.Count -eq 0) { continue }')
$lines.Add('')
$lines.Add('            $value = $candidateProp[0].Value')
$lines.Add('            if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string] -and $value -isnot [pscustomobject]) {')
$lines.Add('                return @{ IsCollection = $true; Data = @($value) }')
$lines.Add('            }')
$lines.Add('')
$lines.Add('            return @{ IsCollection = $false; Data = $value }')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $arrayProps = @($candidateProps | Where-Object {')
$lines.Add('            $_.Value -is [System.Collections.IEnumerable] -and $_.Value -isnot [string] -and $_.Value -isnot [pscustomobject]')
$lines.Add('        })')
$lines.Add('')
$lines.Add('    if ($arrayProps.Count -eq 1) {')
$lines.Add('        return @{ IsCollection = $true; Data = @($arrayProps[0].Value) }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($candidateProps.Count -eq 1) {')
$lines.Add('        return @{ IsCollection = $false; Data = $candidateProps[0].Value }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($IsDetailRequest) {')
$lines.Add('        $objectProp = @($candidateProps | Where-Object { $_.Value -is [pscustomobject] } | Select-Object -First 1)')
$lines.Add('        if ($objectProp.Count -eq 1) {')
$lines.Add('            return @{ IsCollection = $false; Data = $objectProp[0].Value }')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return @{ IsCollection = $false; Data = $Response }')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Initialize-MorpheusColumnProfiles {')
$lines.Add('    if ($null -ne $script:MorpheusColumnProfiles) {')
$lines.Add('        return')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $defaults = @{')
$lines.Add('        default = @{')
$lines.Add('            list = @(''id'', ''name'', ''status'', ''type'')')
$lines.Add('            detail = @(''id'', ''name'', ''status'', ''type'', ''description'', ''code'', ''dateCreated'', ''lastUpdated'', ''uuid'')')
$lines.Add('        }')
$lines.Add('        instances = @{')
$lines.Add('            list = @(''id'', ''name'', ''status'', ''powerState'', ''instanceType'', ''plan'')')
$lines.Add('            detail = @(''id'', ''name'', ''displayName'', ''status'', ''powerState'', ''instanceType'', ''plan'', ''createdBy'', ''dateCreated'', ''lastUpdated'', ''uuid'')')
$lines.Add('        }')
$lines.Add('        servers = @{')
$lines.Add('            list = @(''id'', ''name'', ''status'', ''powerState'', ''hostname'', ''internalIp'')')
$lines.Add('            detail = @(''id'', ''name'', ''displayName'', ''status'', ''powerState'', ''hostname'', ''internalIp'', ''externalIp'', ''plan'', ''createdBy'', ''dateCreated'', ''lastUpdated'', ''uuid'')')
$lines.Add('        }')
$lines.Add('        groups = @{')
$lines.Add('            list = @(''id'', ''name'', ''code'', ''location'')')
$lines.Add('            detail = @(''id'', ''name'', ''code'', ''location'', ''zonePools'', ''visibility'', ''active'', ''dateCreated'', ''lastUpdated'', ''uuid'')')
$lines.Add('        }')
$lines.Add('        apps = @{')
$lines.Add('            list = @(''id'', ''name'', ''status'', ''type'')')
$lines.Add('            detail = @(''id'', ''name'', ''description'', ''status'', ''type'', ''dateCreated'', ''lastUpdated'', ''uuid'')')
$lines.Add('        }')
$lines.Add('        activity = @{')
$lines.Add('            list = @(''id'', ''name'', ''success'', ''user'', ''message'', ''dateCreated'')')
$lines.Add('            detail = @(''id'', ''name'', ''success'', ''user'', ''message'', ''description'', ''eventType'', ''dateCreated'', ''lastUpdated'')')
$lines.Add('        }')
$lines.Add('        policies = @{')
$lines.Add('            list = @(''id'', ''name'', ''type'', ''scope'', ''enabled'')')
$lines.Add('            detail = @(''id'', ''name'', ''type'', ''scope'', ''enabled'', ''description'', ''code'', ''dateCreated'', ''lastUpdated'')')
$lines.Add('        }')
$lines.Add('        accounts = @{')
$lines.Add('            list = @(''id'', ''name'', ''role'', ''status'')')
$lines.Add('            detail = @(''id'', ''name'', ''username'', ''email'', ''role'', ''status'', ''dateCreated'', ''lastUpdated'')')
$lines.Add('        }')
$lines.Add('        users = @{')
$lines.Add('            list = @(''id'', ''name'', ''username'', ''email'', ''status'')')
$lines.Add('            detail = @(''id'', ''name'', ''username'', ''email'', ''role'', ''status'', ''dateCreated'', ''lastUpdated'')')
$lines.Add('        }')
$lines.Add('        clouds = @{')
$lines.Add('            list = @(''id'', ''name'', ''type'', ''status'')')
$lines.Add('            detail = @(''id'', ''name'', ''type'', ''status'', ''enabled'', ''dateCreated'', ''lastUpdated'')')
$lines.Add('        }')
$lines.Add('        clusters = @{')
$lines.Add('            list = @(''id'', ''name'', ''type'', ''status'')')
$lines.Add('            detail = @(''id'', ''name'', ''type'', ''status'', ''enabled'', ''dateCreated'', ''lastUpdated'')')
$lines.Add('        }')
$lines.Add('        networks = @{')
$lines.Add('            list = @(''id'', ''name'', ''type'', ''cidr'', ''vlan'', ''active'')')
$lines.Add('            detail = @(''id'', ''name'', ''type'', ''cidr'', ''vlan'', ''active'', ''dhcpServer'', ''dateCreated'', ''lastUpdated'')')
$lines.Add('        }')
$lines.Add('        plans = @{')
$lines.Add('            list = @(''id'', ''name'', ''code'', ''active'')')
$lines.Add('            detail = @(''id'', ''name'', ''code'', ''active'', ''description'', ''dateCreated'', ''lastUpdated'')')
$lines.Add('        }')
$lines.Add('        tasks = @{')
$lines.Add('            list = @(''id'', ''name'', ''type'', ''status'')')
$lines.Add('            detail = @(''id'', ''name'', ''type'', ''status'', ''result'', ''dateCreated'', ''lastUpdated'')')
$lines.Add('        }')
$lines.Add('        applianceSettings = @{')
$lines.Add('            list = @(''id'', ''name'', ''code'', ''status'', ''enabled'', ''dateCreated'', ''lastUpdated'')')
$lines.Add('            detail = @(''id'', ''name'', ''code'', ''status'', ''enabled'', ''description'', ''dateCreated'', ''lastUpdated'', ''uuid'')')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $script:MorpheusColumnProfiles = $defaults')
$lines.Add('')
$lines.Add('    $profilePath = Join-Path $PSScriptRoot ''Morpheus.OpenApi.ColumnProfiles.psd1''')
$lines.Add('    if (-not (Test-Path $profilePath)) {')
$lines.Add('        return')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    try {')
$lines.Add('        $custom = Import-PowerShellDataFile -Path $profilePath')
$lines.Add('        foreach ($profileKey in $custom.Keys) {')
$lines.Add('            if ($custom[$profileKey] -is [System.Collections.IDictionary]) {')
$lines.Add('                $script:MorpheusColumnProfiles[$profileKey] = $custom[$profileKey]')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('    catch {')
$lines.Add('        Write-Warning "Unable to load Morpheus column profile file [$profilePath]. Using built-in defaults."')
$lines.Add('    }')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusProfileKeyForPath {')
$lines.Add('    param([Parameter(Mandatory)][string]$Path)')
$lines.Add('')
$lines.Add('    $p = $Path.ToLowerInvariant()')
$lines.Add('    if ($p -match ''/instances'') { return ''instances'' }')
$lines.Add('    if ($p -match ''/servers'') { return ''servers'' }')
$lines.Add('    if ($p -match ''/groups'') { return ''groups'' }')
$lines.Add('    if ($p -match ''/apps'') { return ''apps'' }')
$lines.Add('    if ($p -match ''/activity'') { return ''activity'' }')
$lines.Add('    if ($p -match ''/policies'') { return ''policies'' }')
$lines.Add('    if ($p -match ''/accounts'') { return ''accounts'' }')
$lines.Add('    if ($p -match ''/users'') { return ''users'' }')
$lines.Add('    if ($p -match ''/clouds'') { return ''clouds'' }')
$lines.Add('    if ($p -match ''/clusters'') { return ''clusters'' }')
$lines.Add('    if ($p -match ''/networks'') { return ''networks'' }')
$lines.Add('    if ($p -match ''/service-plans'') { return ''plans'' }')
$lines.Add('    if ($p -match ''/tasks|/processes|/jobs/executions'') { return ''tasks'' }')
$lines.Add('    if ($p -match ''/appliance-settings'') { return ''applianceSettings'' }')
$lines.Add('    return ''default''')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusDefaultFields {')
$lines.Add('    param(')
$lines.Add('        [Parameter(Mandatory)][string]$MethodValue,')
$lines.Add('        [Parameter(Mandatory)][string]$PathValue,')
$lines.Add('        [Parameter(Mandatory)][bool]$Detail')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($MethodValue -ne ''GET'') { return @() }')
$lines.Add('')
$lines.Add('    Initialize-MorpheusColumnProfiles')
$lines.Add('')
$lines.Add('    $profileKey = Get-MorpheusProfileKeyForPath -Path $PathValue')
$lines.Add('    $profile = $script:MorpheusColumnProfiles[$profileKey]')
$lines.Add('    if ($null -eq $profile) {')
$lines.Add('        $profile = $script:MorpheusColumnProfiles[''default'']')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $mode = if ($Detail) { ''detail'' } else { ''list'' }')
$lines.Add('    if ($profile -is [System.Collections.IDictionary] -and $profile.Contains($mode)) {')
$lines.Add('        return @($profile[$mode])')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $fallback = $script:MorpheusColumnProfiles[''default'']')
$lines.Add('    if ($fallback -is [System.Collections.IDictionary] -and $fallback.Contains($mode)) {')
$lines.Add('        return @($fallback[$mode])')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return @(''id'', ''name'', ''code'', ''status'')')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Set-MorpheusDefaultDisplayProperties {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][AllowNull()][object]$Item,')
$lines.Add('        [Parameter()][string[]]$Properties')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($null -eq $Item) { return $null }')
$lines.Add('    if ($Item -isnot [pscustomobject]) { return $Item }')
$lines.Add('    if (-not $Properties -or $Properties.Count -eq 0) { return $Item }')
$lines.Add('')
$lines.Add('    $resolved = New-Object System.Collections.Generic.List[string]')
$lines.Add('    foreach ($name in @($Properties)) {')
$lines.Add('        if ([string]::IsNullOrWhiteSpace([string]$name)) { continue }')
$lines.Add('        $match = @($Item.PSObject.Properties.Name | Where-Object { $_ -ieq [string]$name } | Select-Object -First 1)')
$lines.Add('        if ($match.Count -gt 0 -and -not $resolved.Contains($match[0])) {')
$lines.Add('            $resolved.Add($match[0])')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($resolved.Count -eq 0) { return $Item }')
$lines.Add('')
$lines.Add('    $propertySet = New-Object System.Management.Automation.PSPropertySet(''DefaultDisplayPropertySet'', [string[]]@($resolved))')
$lines.Add('    $memberSet = New-Object System.Management.Automation.PSMemberSet(''PSStandardMembers'', [System.Management.Automation.PSMemberInfo[]]@($propertySet))')
$lines.Add('')
$lines.Add('    if ($Item.PSObject.Members[''PSStandardMembers'']) {')
$lines.Add('        $Item.PSObject.Members.Remove(''PSStandardMembers'')')
$lines.Add('    }')
$lines.Add('    $Item.PSObject.Members.Add($memberSet)')
$lines.Add('')
$lines.Add('    return $Item')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Select-MorpheusColumns {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][AllowNull()][object]$Item,')
$lines.Add('        [Parameter()][string[]]$Property,')
$lines.Add('        [Parameter(Mandatory)][string]$Method,')
$lines.Add('        [Parameter(Mandatory)][string]$Path,')
$lines.Add('        [Parameter(Mandatory)][bool]$IsDetailRequest,')
$lines.Add('        [Parameter(Mandatory)][bool]$AllProperties')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($null -eq $Item) { return $null }')
$lines.Add('    if ($Item -is [System.Collections.IDictionary]) {')
$lines.Add('        $Item = ConvertTo-MorpheusObject -Value $Item')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($AllProperties) {')
$lines.Add('        return $Item')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Item -isnot [pscustomobject]) {')
$lines.Add('        return $Item')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $allNames = @($Item.PSObject.Properties.Name)')
$lines.Add('    if ($allNames.Count -eq 0) { return $Item }')
$lines.Add('')
$lines.Add('    $desired = @()')
$lines.Add('    if ($Property -and $Property.Count -gt 0) {')
$lines.Add('        $selectedExplicit = New-Object System.Collections.Generic.List[string]')
$lines.Add('        foreach ($want in @($Property)) {')
$lines.Add('            $match = @($allNames | Where-Object { $_ -ieq [string]$want } | Select-Object -First 1)')
$lines.Add('            if ($match.Count -gt 0 -and -not $selectedExplicit.Contains($match[0])) {')
$lines.Add('                $selectedExplicit.Add($match[0])')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        if ($selectedExplicit.Count -eq 0) { return $Item }')
$lines.Add('        return ($Item | Select-Object -Property @($selectedExplicit))')
$lines.Add('    }')
$lines.Add('    elseif ($Method -eq ''GET'') {')
$lines.Add('        $desired = Get-MorpheusDefaultFields -MethodValue $Method -PathValue $Path -Detail:$IsDetailRequest')
$lines.Add('    }')
$lines.Add('    else {')
$lines.Add('        return $Item')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $selected = New-Object System.Collections.Generic.List[string]')
$lines.Add('    foreach ($want in $desired) {')
$lines.Add('        $match = @($allNames | Where-Object { $_ -ieq $want } | Select-Object -First 1)')
$lines.Add('        if ($match.Count -gt 0 -and -not $selected.Contains($match[0])) {')
$lines.Add('            $selected.Add($match[0])')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($selected.Count -eq 0) {')
$lines.Add('        if ($Method -eq ''GET'') {')
$lines.Add('            foreach ($fallback in @(''id'', ''name'', ''uuid'', ''type'', ''status'')) {')
$lines.Add('                $match = @($allNames | Where-Object { $_ -ieq $fallback } | Select-Object -First 1)')
$lines.Add('                if ($match.Count -gt 0 -and -not $selected.Contains($match[0])) {')
$lines.Add('                    $selected.Add($match[0])')
$lines.Add('                }')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Method -eq ''GET'' -and $selected.Count -lt 2) {')
$lines.Add('        foreach ($candidateName in $allNames) {')
$lines.Add('            if ($selected.Contains($candidateName)) { continue }')
$lines.Add('            $candidateValue = $Item.$candidateName')
$lines.Add('            if ($null -eq $candidateValue) { continue }')
$lines.Add('            if ($candidateValue -is [string] -or $candidateValue -is [ValueType]) {')
$lines.Add('                $selected.Add($candidateName)')
$lines.Add('            }')
$lines.Add('            if ($selected.Count -ge 5) { break }')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($selected.Count -eq 0) {')
$lines.Add('        return $Item')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return (Set-MorpheusDefaultDisplayProperties -Item $Item -Properties @($selected))')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Add-MorpheusColumn {')
$lines.Add('    param(')
$lines.Add('        [Parameter(Mandatory)][object]$Item,')
$lines.Add('        [Parameter(Mandatory)][string]$Morpheus')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($Item -is [pscustomobject]) {')
$lines.Add('        $o = [ordered]@{ Morpheus = $Morpheus }')
$lines.Add('        foreach ($p in $Item.PSObject.Properties) { $o[$p.Name] = $p.Value }')
$lines.Add('        return [pscustomobject]$o')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return [pscustomobject]@{ Morpheus = $Morpheus; Value = $Item }')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusTypeName {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][string]$Path,')
$lines.Add('        [Parameter()][bool]$IsCollection')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ([string]::IsNullOrWhiteSpace($Path)) { return ''Morpheus.Resource'' }')
$lines.Add('')
$lines.Add('    $segments = @($Path.Trim(''/'') -split ''/'' | Where-Object {')
$lines.Add('            $_ -and $_ -ne ''api'' -and $_ -notmatch ''^\{.+\}$'' -and $_ -notmatch ''^\d+$''')
$lines.Add('        })')
$lines.Add('')
$lines.Add('    if ($segments.Count -eq 0) { return ''Morpheus.Resource'' }')
$lines.Add('')
$lines.Add('    $leaf = [string]$segments[$segments.Count - 1]')
$lines.Add('    if ($leaf.EndsWith(''ies'')) {')
$lines.Add('        $leaf = $leaf.Substring(0, $leaf.Length - 3) + ''y''')
$lines.Add('    }')
$lines.Add('    elseif ($leaf.EndsWith(''s'') -and -not $leaf.EndsWith(''ss'')) {')
$lines.Add('        $leaf = $leaf.Substring(0, $leaf.Length - 1)')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $resourceName = (($leaf -split ''[^a-zA-Z0-9]+'') | Where-Object { $_ } | ForEach-Object {')
$lines.Add('        if ($_.Length -eq 1) { $_.ToUpperInvariant() } else { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) }')
$lines.Add('    }) -join ''''')
$lines.Add('')
$lines.Add('    if ([string]::IsNullOrWhiteSpace($resourceName)) { return ''Morpheus.Resource'' }')
$lines.Add('    if ($IsCollection) { return "Morpheus.$resourceName.Summary" }')
$lines.Add('    return "Morpheus.$resourceName"')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Add-MorpheusTypeName {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][object]$Item,')
$lines.Add('        [Parameter()][string]$TypeName')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($null -eq $Item -or [string]::IsNullOrWhiteSpace($TypeName)) { return $Item }')
$lines.Add('    if ($Item -isnot [pscustomobject]) { return $Item }')
$lines.Add('')
$lines.Add('    if ($Item.PSObject.TypeNames -notcontains ''Morpheus.Resource'') {')
$lines.Add('        $Item.PSObject.TypeNames.Insert(0, ''Morpheus.Resource'')')
$lines.Add('    }')
$lines.Add('    if ($Item.PSObject.TypeNames -notcontains $TypeName) {')
$lines.Add('        $Item.PSObject.TypeNames.Insert(0, $TypeName)')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return $Item')
$lines.Add('}')
$lines.Add('')
$lines.Add('function ConvertFrom-MorpheusInputValue {')
$lines.Add('    param([Parameter()][string]$InputValue)')
$lines.Add('')
$lines.Add('    if ($null -eq $InputValue) { return $null }')
$lines.Add('    $trimmed = $InputValue.Trim()')
$lines.Add('')
$lines.Add('    if ($trimmed -ieq ''null'') { return $null }')
$lines.Add('')
$lines.Add('    $boolValue = $false')
$lines.Add('    if ([bool]::TryParse($trimmed, [ref]$boolValue)) { return $boolValue }')
$lines.Add('')
$lines.Add('    $longValue = [long]0')
$lines.Add('    if ([long]::TryParse($trimmed, [ref]$longValue)) { return $longValue }')
$lines.Add('')
$lines.Add('    $doubleValue = [double]0')
$lines.Add('    if ([double]::TryParse($trimmed, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$doubleValue)) { return $doubleValue }')
$lines.Add('')
$lines.Add('    return $InputValue')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Set-MorpheusBodyPathValue {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][object]$Body,')
$lines.Add('        [Parameter(Mandatory)][string]$Path,')
$lines.Add('        [Parameter()][object]$Value')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($null -eq $Body) { $Body = @{} }')
$lines.Add('')
$lines.Add('    if ($Body -is [pscustomobject]) {')
$lines.Add('        $tmp = @{}')
$lines.Add('        foreach ($prop in $Body.PSObject.Properties) { $tmp[$prop.Name] = $prop.Value }')
$lines.Add('        $Body = $tmp')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Body -isnot [System.Collections.IDictionary]) {')
$lines.Add('        throw ''Unable to set body field values because -Body is not an object/hashtable.''')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $parts = @($Path -split ''\.'' | Where-Object { $_ })')
$lines.Add('    if ($parts.Count -eq 0) { return $Body }')
$lines.Add('')
$lines.Add('    $cursor = $Body')
$lines.Add('    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {')
$lines.Add('        $part = [string]$parts[$i]')
$lines.Add('        if (-not $cursor.Contains($part) -or $null -eq $cursor[$part]) {')
$lines.Add('            $cursor[$part] = @{}')
$lines.Add('        }')
$lines.Add('        elseif ($cursor[$part] -is [pscustomobject]) {')
$lines.Add('            $tmp = @{}')
$lines.Add('            foreach ($prop in $cursor[$part].PSObject.Properties) { $tmp[$prop.Name] = $prop.Value }')
$lines.Add('            $cursor[$part] = $tmp')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        if ($cursor[$part] -isnot [System.Collections.IDictionary]) {')
$lines.Add('            $cursor[$part] = @{}')
$lines.Add('        }')
$lines.Add('        $cursor = $cursor[$part]')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $leaf = [string]$parts[$parts.Count - 1]')
$lines.Add('    $cursor[$leaf] = $Value')
$lines.Add('    return $Body')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusBodyPathValue {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][object]$Body,')
$lines.Add('        [Parameter(Mandatory)][string]$Path')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($null -eq $Body) { return $null }')
$lines.Add('')
$lines.Add('    if ($Body -is [pscustomobject]) {')
$lines.Add('        $tmp = @{}')
$lines.Add('        foreach ($prop in $Body.PSObject.Properties) { $tmp[$prop.Name] = $prop.Value }')
$lines.Add('        $Body = $tmp')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Body -isnot [System.Collections.IDictionary]) { return $null }')
$lines.Add('')
$lines.Add('    $parts = @($Path -split ''\.'' | Where-Object { $_ })')
$lines.Add('    if ($parts.Count -eq 0) { return $null }')
$lines.Add('')
$lines.Add('    $cursor = $Body')
$lines.Add('    for ($i = 0; $i -lt $parts.Count; $i++) {')
$lines.Add('        $part = [string]$parts[$i]')
$lines.Add('        if ($cursor -is [pscustomobject]) {')
$lines.Add('            $tmp = @{}')
$lines.Add('            foreach ($prop in $cursor.PSObject.Properties) { $tmp[$prop.Name] = $prop.Value }')
$lines.Add('            $cursor = $tmp')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        if ($cursor -isnot [System.Collections.IDictionary]) { return $null }')
$lines.Add('        if (-not $cursor.Contains($part)) { return $null }')
$lines.Add('')
$lines.Add('        $cursor = $cursor[$part]')
$lines.Add('        if ($null -eq $cursor) { return $null }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return $cursor')
$lines.Add('}')
$lines.Add('')
$lines.Add('function ConvertTo-MorpheusPromptLabel {')
$lines.Add('    param([Parameter(Mandatory)][string]$Path)')
$lines.Add('')
$lines.Add('    $parts = @($Path -split ''\.'' | Where-Object { $_ })')
$lines.Add('    if ($parts.Count -eq 0) { return $Path }')
$lines.Add('')
$lines.Add('    $name = (($parts | ForEach-Object {')
$lines.Add('        $token = ([string]$_ -replace ''[^a-zA-Z0-9]'', '' '')')
$lines.Add('        ($token -split ''\s+'' | Where-Object { $_ } | ForEach-Object {')
$lines.Add('            if ($_.Length -eq 1) { $_.ToUpperInvariant() } else { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) }')
$lines.Add('        }) -join ''''')
$lines.Add('    }) -join '''')')
$lines.Add('')
$lines.Add('    if ([string]::IsNullOrWhiteSpace($name)) { return $Path }')
$lines.Add('    if ($name.Length -eq 1) { return $name.ToLowerInvariant() }')
$lines.Add('    return $name.Substring(0,1).ToLowerInvariant() + $name.Substring(1)')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Ensure-MorpheusRequiredArrayBodyFields {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][object]$Body,')
$lines.Add('        [Parameter()][object[]]$ArrayRequirements,')
$lines.Add('        [Parameter()][string[]]$RequiredRootPaths')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if (-not $ArrayRequirements -or $ArrayRequirements.Count -eq 0) { return $Body }')
$lines.Add('    if ($null -eq $Body) { $Body = @{} }')
$lines.Add('')
$lines.Add('    if ($Body -is [pscustomobject]) {')
$lines.Add('        $tmp = @{}')
$lines.Add('        foreach ($prop in $Body.PSObject.Properties) { $tmp[$prop.Name] = $prop.Value }')
$lines.Add('        $Body = $tmp')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($Body -isnot [System.Collections.IDictionary]) {')
$lines.Add('        throw ''Unable to prompt for required array body fields because -Body is not an object/hashtable.''')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    foreach ($arrayReq in $ArrayRequirements) {')
$lines.Add('        if ($null -eq $arrayReq) { continue }')
$lines.Add('        $arrayPath = if ($arrayReq.PSObject.Properties[''Path'']) { [string]$arrayReq.Path } else { '''' }')
$lines.Add('        if ([string]::IsNullOrWhiteSpace($arrayPath)) { continue }')
$lines.Add('')
$lines.Add('        $itemRequiredPaths = @()')
$lines.Add('        if ($arrayReq.PSObject.Properties[''RequiredPaths'']) { $itemRequiredPaths = @($arrayReq.RequiredPaths) }')
$lines.Add('        if ($itemRequiredPaths.Count -eq 0) { continue }')
$lines.Add('')
$lines.Add('        $arrayLabel = ConvertTo-MorpheusPromptLabel -Path $arrayPath')
$lines.Add('        $isRootRequired = ($RequiredRootPaths -and (@($RequiredRootPaths) | Where-Object { $_ -eq $arrayPath }).Count -gt 0)')
$lines.Add('')
$lines.Add('        $arrayValue = Get-MorpheusBodyPathValue -Body $Body -Path $arrayPath')
$lines.Add('        if ($null -eq $arrayValue) { $arrayValue = @() }')
$lines.Add('')
$lines.Add('        if ($arrayValue -isnot [System.Collections.IEnumerable] -or $arrayValue -is [string]) {')
$lines.Add('            throw "Body field [$arrayPath] must be an array of objects."')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        $items = New-Object System.Collections.Generic.List[object]')
$lines.Add('        foreach ($item in @($arrayValue)) {')
$lines.Add('            if ($item -is [System.Collections.IDictionary]) {')
$lines.Add('                $items.Add($item)')
$lines.Add('            }')
$lines.Add('            elseif ($item -is [pscustomobject]) {')
$lines.Add('                $tmpItem = @{}')
$lines.Add('                foreach ($prop in $item.PSObject.Properties) { $tmpItem[$prop.Name] = $prop.Value }')
$lines.Add('                $items.Add($tmpItem)')
$lines.Add('            }')
$lines.Add('            else {')
$lines.Add('                throw "Items in [$arrayPath] must be objects."')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        if ($items.Count -eq 0 -and $isRootRequired) {')
$lines.Add('            do {')
$lines.Add('                $newItem = @{}')
$lines.Add('                foreach ($itemPath in $itemRequiredPaths) {')
$lines.Add('                    $label = ConvertTo-MorpheusPromptLabel -Path $itemPath')
$lines.Add('                    $value = ConvertFrom-MorpheusInputValue -InputValue (Read-Host -Prompt "Enter required value for $arrayLabel item 1 $label")')
$lines.Add('                    $newItem = Set-MorpheusBodyPathValue -Body $newItem -Path ([string]$itemPath) -Value $value')
$lines.Add('                }')
$lines.Add('                $items.Add($newItem)')
$lines.Add('                $more = Read-Host -Prompt "Add another $arrayLabel item? (y/N)"')
$lines.Add('            } while ($more -match ''^(y|yes)$'')')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        for ($i = 0; $i -lt $items.Count; $i++) {')
$lines.Add('            $itemObj = $items[$i]')
$lines.Add('            foreach ($itemPath in $itemRequiredPaths) {')
$lines.Add('                $current = Get-MorpheusBodyPathValue -Body $itemObj -Path ([string]$itemPath)')
$lines.Add('                $hasCurrent = $null -ne $current -and -not [string]::IsNullOrWhiteSpace([string]$current)')
$lines.Add('                if (-not $hasCurrent) {')
$lines.Add('                    $label = ConvertTo-MorpheusPromptLabel -Path ([string]$itemPath)')
$lines.Add('                    $value = ConvertFrom-MorpheusInputValue -InputValue (Read-Host -Prompt "Enter required value for $arrayLabel item $($i + 1) $label")')
$lines.Add('                    $itemObj = Set-MorpheusBodyPathValue -Body $itemObj -Path ([string]$itemPath) -Value $value')
$lines.Add('                }')
$lines.Add('            }')
$lines.Add('            $items[$i] = $itemObj')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        $Body = Set-MorpheusBodyPathValue -Body $Body -Path $arrayPath -Value @($items)')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return $Body')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Ensure-MorpheusRequiredBodyFields {')
$lines.Add('    param(')
$lines.Add('        [Parameter()][object]$Body,')
$lines.Add('        [Parameter()][string[]]$RequiredPaths,')
$lines.Add('        [Parameter()][hashtable]$PromptMap,')
$lines.Add('        [Parameter()][string]$ContentType = ''application/json''')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if (-not $RequiredPaths -or $RequiredPaths.Count -eq 0) {')
$lines.Add('        return $Body')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($ContentType -ne ''application/json'') {')
$lines.Add('        if ($null -eq $Body) { $Body = @{} }')
$lines.Add('        foreach ($path in $RequiredPaths) {')
$lines.Add('            if ([string]::IsNullOrWhiteSpace($path)) { continue }')
$lines.Add('            $promptName = if ($PromptMap -and $PromptMap.ContainsKey($path)) { [string]$PromptMap[$path] } else { [string]$path }')
$lines.Add('            if ($Body -is [System.Collections.IDictionary] -and $Body.Contains($path) -and -not [string]::IsNullOrWhiteSpace([string]$Body[$path])) { continue }')
$lines.Add('            $Body[$path] = ConvertFrom-MorpheusInputValue -InputValue (Read-Host -Prompt "Enter required value for $promptName")')
$lines.Add('        }')
$lines.Add('        return $Body')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $workingBody = Convert-MorpheusBodyInput -Body $Body -ContentType $ContentType')
$lines.Add('    if ($null -eq $workingBody) { $workingBody = @{} }')
$lines.Add('')
$lines.Add('    if ($workingBody -is [pscustomobject]) {')
$lines.Add('        $tmp = @{}')
$lines.Add('        foreach ($prop in $workingBody.PSObject.Properties) { $tmp[$prop.Name] = $prop.Value }')
$lines.Add('        $workingBody = $tmp')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($workingBody -isnot [System.Collections.IDictionary]) {')
$lines.Add('        throw ''Unable to prompt for required body fields because -Body is not an object/hashtable.''')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    foreach ($path in $RequiredPaths) {')
$lines.Add('        if ([string]::IsNullOrWhiteSpace($path)) { continue }')
$lines.Add('        $promptName = if ($PromptMap -and $PromptMap.ContainsKey($path)) { [string]$PromptMap[$path] } else { [string]$path }')
$lines.Add('')
$lines.Add('        $parts = @($path -split ''\.'' | Where-Object { $_ })')
$lines.Add('        if ($parts.Count -eq 0) { continue }')
$lines.Add('')
$lines.Add('        $cursor = $workingBody')
$lines.Add('        for ($i = 0; $i -lt ($parts.Count - 1); $i++) {')
$lines.Add('            $part = [string]$parts[$i]')
$lines.Add('            if (-not $cursor.Contains($part) -or $null -eq $cursor[$part]) {')
$lines.Add('                $cursor[$part] = @{}')
$lines.Add('            }')
$lines.Add('            elseif ($cursor[$part] -is [pscustomobject]) {')
$lines.Add('                $tmp = @{}')
$lines.Add('                foreach ($prop in $cursor[$part].PSObject.Properties) { $tmp[$prop.Name] = $prop.Value }')
$lines.Add('                $cursor[$part] = $tmp')
$lines.Add('            }')
$lines.Add('')
$lines.Add('            if ($cursor[$part] -isnot [System.Collections.IDictionary]) {')
$lines.Add('                $cursor[$part] = @{}')
$lines.Add('            }')
$lines.Add('            $cursor = $cursor[$part]')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        $leaf = [string]$parts[$parts.Count - 1]')
$lines.Add('        $hasValue = ($cursor.Contains($leaf) -and $null -ne $cursor[$leaf] -and -not [string]::IsNullOrWhiteSpace([string]$cursor[$leaf]))')
$lines.Add('        if (-not $hasValue) {')
$lines.Add('            if ($leaf -ieq ''config'') {')
$lines.Add('                $cursor[$leaf] = New-MorpheusKeyValueMap -Interactive')
$lines.Add('            }')
$lines.Add('            else {')
$lines.Add('                $cursor[$leaf] = ConvertFrom-MorpheusInputValue -InputValue (Read-Host -Prompt "Enter required value for $promptName")')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return $workingBody')
$lines.Add('}')
$lines.Add('')
$lines.Add('function ConvertTo-MorpheusCurlLiteral {')
$lines.Add('    param([Parameter()][string]$Text)')
$lines.Add('')
$lines.Add('    if ($null -eq $Text) { return '''' }')
$lines.Add('    return $Text')
$lines.Add('}')
$lines.Add('')
$lines.Add('function New-MorpheusCurlCommand {')
$lines.Add('    param(')
$lines.Add('        [Parameter(Mandatory)][string]$Method,')
$lines.Add('        [Parameter(Mandatory)][string]$Uri,')
$lines.Add('        [Parameter()][hashtable]$Headers,')
$lines.Add('        [Parameter()][object]$Body,')
$lines.Add('        [Parameter()][string]$ContentType,')
$lines.Add('        [Parameter()][switch]$Scrub')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    $parts = New-Object System.Collections.Generic.List[string]')
$lines.Add('    $parts.Add("curl -X $Method ''$(ConvertTo-MorpheusCurlLiteral -Text $Uri)''")')
$lines.Add('')
$lines.Add('    if ($Headers) {')
$lines.Add('        foreach ($key in ($Headers.Keys | Sort-Object)) {')
$lines.Add('            $value = [string]$Headers[$key]')
$lines.Add('            if ($Scrub -and $key -ieq ''Authorization'' -and $value -match ''^Bearer\s+'') {')
$lines.Add('                $value = ''Bearer ********''')
$lines.Add('            }')
$lines.Add('            $parts.Add("-H ''$(ConvertTo-MorpheusCurlLiteral -Text (""{0}: {1}"" -f [string]$key, $value))''")')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($PSBoundParameters.ContainsKey(''Body'') -and $null -ne $Body) {')
$lines.Add('        if ($ContentType -eq ''application/x-www-form-urlencoded'' -and $Body -is [System.Collections.IDictionary]) {')
$lines.Add('            foreach ($k in ($Body.Keys | Sort-Object)) {')
$lines.Add('                $v = [string]$Body[$k]')
$lines.Add('                $parts.Add("--data-urlencode ''$(ConvertTo-MorpheusCurlLiteral -Text (""{0}={1}"" -f [string]$k, $v))''")')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('        else {')
$lines.Add('            $payload = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 100 -Compress }')
$lines.Add('            if ($ContentType) {')
$lines.Add('                $parts.Add("-H ''Content-Type: $(ConvertTo-MorpheusCurlLiteral -Text $ContentType)''")')
$lines.Add('            }')
$lines.Add('            $parts.Add("--data-raw ''$(ConvertTo-MorpheusCurlLiteral -Text $payload)''")')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return ($parts -join (" " + [Environment]::NewLine + "  "))')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Invoke-MorpheusOperation {')
$lines.Add('    [CmdletBinding()]')
$lines.Add('    param(')
$lines.Add('        [Parameter(Mandatory)][string]$Method,')
$lines.Add('        [Parameter(Mandatory)][string]$Path,')
$lines.Add('        [Parameter()][hashtable]$Query,')
$lines.Add('        [Parameter()][hashtable]$Headers,')
$lines.Add('        [Parameter()][object]$Body,')
$lines.Add('        [Parameter()][string]$Morpheus,')
$lines.Add('        [Parameter()][string]$ContentType = ''application/json'',')
$lines.Add('        [Parameter()][string[]]$Property,')
$lines.Add('        [Parameter()][switch]$Detailed,')
$lines.Add('        [Parameter()][switch]$Curl,')
$lines.Add('        [Parameter()][switch]$Scrub,')
$lines.Add('        [Parameter()][bool]$IsDetailRequest = $false,')
$lines.Add('        [Parameter()][bool]$SupportsPaging = $false,')
$lines.Add('        [Parameter()][switch]$NoPaging')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    $targets = Resolve-MorpheusTargets -Morpheus $Morpheus -Method $Method')
$lines.Add('    $results = New-Object System.Collections.Generic.List[object]')
$lines.Add('    $allTargets = $targets.Count -gt 1')
$lines.Add('')
$lines.Add('    foreach ($target in $targets) {')
$lines.Add('        $base = [string]$target.Server')
$lines.Add('        $queryState = @{}')
$lines.Add('        if ($Query) {')
$lines.Add('            foreach ($k in $Query.Keys) {')
$lines.Add('                if ($null -ne $Query[$k]) {')
$lines.Add('                    $queryState[[string]$k] = $Query[$k]')
$lines.Add('                }')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        $userSpecifiedMax = $queryState.ContainsKey(''max'')')
$lines.Add('        $userSpecifiedOffset = $queryState.ContainsKey(''offset'')')
$lines.Add('        $autoPaging = ($Method -eq ''GET'' -and $SupportsPaging -and -not $NoPaging -and -not $IsDetailRequest -and -not $userSpecifiedMax -and -not $userSpecifiedOffset)')
$lines.Add('')
$lines.Add('        if ($autoPaging) {')
$lines.Add('            $queryState[''offset''] = 0')
$lines.Add('            $queryState[''max''] = 25')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        $continuePaging = $true')
$lines.Add('        while ($continuePaging) {')
$lines.Add('            $uriBuilder = [System.UriBuilder]::new([System.Uri]::new([System.Uri]$base, $Path))')
$lines.Add('')
$lines.Add('            if ($queryState.Count -gt 0) {')
$lines.Add('                $pairs = foreach ($k in $queryState.Keys) {')
$lines.Add('                    if ($null -eq $queryState[$k]) { continue }')
$lines.Add('                    "{0}={1}" -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$queryState[$k])')
$lines.Add('                }')
$lines.Add('                $uriBuilder.Query = ($pairs -join ''&'')')
$lines.Add('            }')
$lines.Add('')
$lines.Add('        $invokeHeaders = @{ Authorization = "Bearer $($target.AccessToken)" }')
$lines.Add('        if ($Headers) {')
$lines.Add('            foreach ($headerKey in $Headers.Keys) {')
$lines.Add('                if ($null -ne $Headers[$headerKey]) {')
$lines.Add('                    $invokeHeaders[$headerKey] = [string]$Headers[$headerKey]')
$lines.Add('                }')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        $invokeParams = @{')
$lines.Add('            Method = $Method')
$lines.Add('            Uri = $uriBuilder.Uri.AbsoluteUri')
$lines.Add('            Headers = $invokeHeaders')
$lines.Add('            ErrorAction = ''Stop''')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        if ($PSBoundParameters.ContainsKey(''Body'') -and $null -ne $Body) {')
$lines.Add('            $effectiveBody = Convert-MorpheusBodyInput -Body $Body -ContentType $ContentType')
$lines.Add('            if ($ContentType -eq ''application/x-www-form-urlencoded'') {')
$lines.Add('                $invokeParams[''Body''] = $effectiveBody')
$lines.Add('                $invokeParams[''ContentType''] = ''application/x-www-form-urlencoded''')
$lines.Add('            }')
$lines.Add('            elseif ($ContentType -eq ''application/json'') {')
$lines.Add('                if ($effectiveBody -is [string]) {')
$lines.Add('                    $invokeParams[''Body''] = $effectiveBody')
$lines.Add('                }')
$lines.Add('                else {')
$lines.Add('                    $invokeParams[''Body''] = ($effectiveBody | ConvertTo-Json -Depth 100)')
$lines.Add('                }')
$lines.Add('                $invokeParams[''ContentType''] = ''application/json''')
$lines.Add('            }')
$lines.Add('            else {')
$lines.Add('                $invokeParams[''Body''] = $effectiveBody')
$lines.Add('                $invokeParams[''ContentType''] = $ContentType')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('')
$lines.Add('            if ($Curl) {')
$lines.Add('                $curlCommand = New-MorpheusCurlCommand -Method $Method -Uri $invokeParams.Uri -Headers $invokeHeaders -Body $invokeParams[''Body''] -ContentType $invokeParams[''ContentType''] -Scrub:$Scrub')
$lines.Add('                if ($allTargets) {')
$lines.Add('                    $results.Add([pscustomobject]@{ Morpheus = $target.Name; Curl = $curlCommand })')
$lines.Add('                }')
$lines.Add('                else {')
$lines.Add('                    $results.Add($curlCommand)')
$lines.Add('                }')
$lines.Add('                $continuePaging = $false')
$lines.Add('                continue')
$lines.Add('            }')
$lines.Add('')
$lines.Add('            $response = Invoke-RestMethod @invokeParams')
$lines.Add('            $normalized = ConvertTo-MorpheusObject -Value $response')
$lines.Add('            $payload = Get-MorpheusPayloadData -Response $normalized -Path $Path -IsDetailRequest:$IsDetailRequest')
$lines.Add('')
$lines.Add('            if ($payload.IsCollection) {')
$lines.Add('                $collectionTypeName = Get-MorpheusTypeName -Path $Path -IsCollection:$true')
$lines.Add('                $currentPageItems = @($payload.Data)')
$lines.Add('                foreach ($item in $currentPageItems) {')
$lines.Add('                    $view = Select-MorpheusColumns -Item $item -Property $Property -Method $Method -Path $Path -IsDetailRequest:$IsDetailRequest -AllProperties:$Detailed')
$lines.Add('                    $view = Add-MorpheusTypeName -Item $view -TypeName $collectionTypeName')
$lines.Add('                    if ($allTargets) {')
$lines.Add('                        $view = Add-MorpheusColumn -Item $view -Morpheus $target.Name')
$lines.Add('                        $view = Add-MorpheusTypeName -Item $view -TypeName $collectionTypeName')
$lines.Add('                    }')
$lines.Add('                    $results.Add($view)')
$lines.Add('                }')
$lines.Add('')
$lines.Add('                if (-not $autoPaging) {')
$lines.Add('                    $continuePaging = $false')
$lines.Add('                    continue')
$lines.Add('                }')
$lines.Add('')
$lines.Add('                $pageSize = @($currentPageItems).Count')
$lines.Add('                if ($pageSize -le 0) {')
$lines.Add('                    $continuePaging = $false')
$lines.Add('                    continue')
$lines.Add('                }')
$lines.Add('')
$lines.Add('                $nextOffset = [int]$queryState[''offset''] + $pageSize')
$lines.Add('                $queryState[''offset''] = $nextOffset')
$lines.Add('')
$lines.Add('                $metaTotal = $null')
$lines.Add('                if ($normalized -is [pscustomobject] -and $normalized.PSObject.Properties[''meta'']) {')
$lines.Add('                    $meta = $normalized.meta')
$lines.Add('                    if ($meta -and $meta.PSObject.Properties[''total'']) {')
$lines.Add('                        $metaTotal = [int]$meta.total')
$lines.Add('                    }')
$lines.Add('                }')
$lines.Add('')
$lines.Add('                if ($null -ne $metaTotal) {')
$lines.Add('                    $continuePaging = ($nextOffset -lt $metaTotal)')
$lines.Add('                }')
$lines.Add('                else {')
$lines.Add('                    $continuePaging = ($pageSize -ge [int]$queryState[''max''])')
$lines.Add('                }')
$lines.Add('                continue')
$lines.Add('            }')
$lines.Add('')
$lines.Add('            $singleTypeName = Get-MorpheusTypeName -Path $Path -IsCollection:$false')
$lines.Add('            $single = Select-MorpheusColumns -Item $payload.Data -Property $Property -Method $Method -Path $Path -IsDetailRequest:$IsDetailRequest -AllProperties:$Detailed')
$lines.Add('            $single = Add-MorpheusTypeName -Item $single -TypeName $singleTypeName')
$lines.Add('            if ($allTargets) {')
$lines.Add('                $single = Add-MorpheusColumn -Item $single -Morpheus $target.Name')
$lines.Add('                $single = Add-MorpheusTypeName -Item $single -TypeName $singleTypeName')
$lines.Add('            }')
$lines.Add('            $results.Add($single)')
$lines.Add('            $continuePaging = $false')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($results.Count -eq 1) {')
$lines.Add('        return $results[0]')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return $results')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Connect-Morpheus {')
$lines.Add('    [CmdletBinding(DefaultParameterSetName = ''Token'')]')
$lines.Add('    param(')
$lines.Add('        [Parameter(Mandatory)]')
$lines.Add('        [ValidateNotNullOrEmpty()]')
$lines.Add('        [string]$Name,')
$lines.Add('')
$lines.Add('        [Parameter(Mandatory)]')
$lines.Add('        [ValidateNotNullOrEmpty()]')
$lines.Add('        [string]$Server,')
$lines.Add('')
$lines.Add('        [Parameter(Mandatory, ParameterSetName = ''Token'')]')
$lines.Add('        [ValidateNotNullOrEmpty()]')
$lines.Add('        [string]$ApiToken,')
$lines.Add('')
$lines.Add('        [Parameter(Mandatory, ParameterSetName = ''Credential'')]')
$lines.Add('        [ValidateNotNull()]')
$lines.Add('        [pscredential]$Credential,')
$lines.Add('')
$lines.Add('        [Parameter(Mandatory, ParameterSetName = ''UserPass'')]')
$lines.Add('        [Parameter(Mandatory, ParameterSetName = ''UserPassPlain'')]')
$lines.Add('        [ValidateNotNullOrEmpty()]')
$lines.Add('        [string]$Username,')
$lines.Add('')
$lines.Add('        [Parameter(Mandatory, ParameterSetName = ''UserPass'')]')
$lines.Add('        [ValidateNotNull()]')
$lines.Add('        [securestring]$Password,')
$lines.Add('')
$lines.Add('        [Parameter(Mandatory, ParameterSetName = ''UserPassPlain'')]')
$lines.Add('        [ValidateNotNullOrEmpty()]')
$lines.Add('        [string]$PlainTextPassword,')
$lines.Add('')
$lines.Add('        [Parameter()]')
$lines.Add('        [switch]$Default')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    $normalizedServer = $Server.TrimEnd(''/'' ) + ''/''')
$lines.Add('')
$lines.Add('    $accessToken = $ApiToken')
$lines.Add('    $refreshToken = $null')
$lines.Add('    $expiresIn = $null')
$lines.Add('')
$lines.Add('    if ($PSCmdlet.ParameterSetName -eq ''UserPass'') {')
$lines.Add('        $Credential = [pscredential]::new($Username, $Password)')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($PSCmdlet.ParameterSetName -eq ''UserPassPlain'') {')
$lines.Add('        Write-Warning ''Using -PlainTextPassword can expose credentials in shell history and logs. Prefer -Password (SecureString).''')
$lines.Add('        $securePassword = ConvertTo-SecureString -String $PlainTextPassword -AsPlainText -Force')
$lines.Add('        $Credential = [pscredential]::new($Username, $securePassword)')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($PSCmdlet.ParameterSetName -in @(''Credential'', ''UserPass'', ''UserPassPlain'')) {')
$lines.Add('        $tokenUri = [System.Uri]::new([System.Uri]$normalizedServer, ''oauth/token?client_id=morph-api&grant_type=password&scope=write'')')
$lines.Add('        $body = @{')
$lines.Add('            username = $Credential.UserName')
$lines.Add('            password = $Credential.GetNetworkCredential().Password')
$lines.Add('        }')
$lines.Add('        $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUri.AbsoluteUri -Body $body -ContentType ''application/x-www-form-urlencoded'' -ErrorAction Stop')
$lines.Add('        $accessToken = [string]$tokenResponse.access_token')
$lines.Add('        $refreshToken = [string]$tokenResponse.refresh_token')
$lines.Add('        $expiresIn = [int]$tokenResponse.expires_in')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $connection = [pscustomobject]@{')
$lines.Add('        Name = $Name')
$lines.Add('        Server = $normalizedServer')
$lines.Add('        AccessToken = $accessToken')
$lines.Add('        RefreshToken = $refreshToken')
$lines.Add('        ExpiresIn = $expiresIn')
$lines.Add('        ConnectedAt = Get-Date')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $script:MorpheusConnections[$Name] = $connection')
$lines.Add('')
$lines.Add('    if ($Default -or -not $script:DefaultMorpheus) {')
$lines.Add('        $script:DefaultMorpheus = $Name')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return $connection')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Disconnect-Morpheus {')
$lines.Add('    [CmdletBinding()]')
$lines.Add('    param(')
$lines.Add('        [Parameter()]')
$lines.Add('        [ArgumentCompleter({ param($commandName, $parameterName, $wordToComplete) Get-MorpheusConnectionNameCompletions -WordToComplete $wordToComplete })]')
$lines.Add('        [string]$Name,')
$lines.Add('')
$lines.Add('        [Parameter()]')
$lines.Add('        [switch]$All')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($All) {')
$lines.Add('        $script:MorpheusConnections.Clear()')
$lines.Add('        $script:DefaultMorpheus = $null')
$lines.Add('        return')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if (-not $Name) {')
$lines.Add('        throw ''Specify -Name or -All.''')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($script:MorpheusConnections.ContainsKey($Name)) {')
$lines.Add('        [void]$script:MorpheusConnections.Remove($Name)')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($script:DefaultMorpheus -eq $Name) {')
$lines.Add('        $script:DefaultMorpheus = ($script:MorpheusConnections.Keys | Select-Object -First 1)')
$lines.Add('    }')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusConnection {')
$lines.Add('    [CmdletBinding()]')
$lines.Add('    param(')
$lines.Add('        [Parameter()]')
$lines.Add('        [ArgumentCompleter({ param($commandName, $parameterName, $wordToComplete) Get-MorpheusConnectionNameCompletions -WordToComplete $wordToComplete })]')
$lines.Add('        [string]$Name')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($Name) {')
$lines.Add('        if (-not $script:MorpheusConnections.ContainsKey($Name)) {')
$lines.Add('            throw "Unknown Morpheus connection [$Name]."')
$lines.Add('        }')
$lines.Add('        return $script:MorpheusConnections[$Name]')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return $script:MorpheusConnections.Values')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Set-MorpheusDefault {')
$lines.Add('    [CmdletBinding()]')
$lines.Add('    param(')
$lines.Add('        [Parameter(Mandatory)]')
$lines.Add('        [ArgumentCompleter({ param($commandName, $parameterName, $wordToComplete) Get-MorpheusConnectionNameCompletions -WordToComplete $wordToComplete })]')
$lines.Add('        [string]$Name')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if (-not $script:MorpheusConnections.ContainsKey($Name)) {')
$lines.Add('        throw "Unknown Morpheus connection [$Name]."')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $script:DefaultMorpheus = $Name')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusTaskIdFromObject {')
$lines.Add('    param([Parameter()][object]$InputObject)')
$lines.Add('')
$lines.Add('    if ($null -eq $InputObject) { return $null }')
$lines.Add('')
$lines.Add('    if ($InputObject -is [System.Collections.IDictionary]) {')
$lines.Add('        foreach ($key in @(''taskId'', ''processId'', ''executionId'', ''jobExecutionId'', ''id'')) {')
$lines.Add('            if ($InputObject.Contains($key) -and $InputObject[$key]) { return [string]$InputObject[$key] }')
$lines.Add('        }')
$lines.Add('        foreach ($nested in @(''task'', ''process'', ''execution'', ''jobExecution'', ''job'')) {')
$lines.Add('            if ($InputObject.Contains($nested) -and $InputObject[$nested]) {')
$lines.Add('                $candidate = Get-MorpheusTaskIdFromObject -InputObject $InputObject[$nested]')
$lines.Add('                if ($candidate) { return $candidate }')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('    elseif ($InputObject -is [pscustomobject]) {')
$lines.Add('        foreach ($key in @(''taskId'', ''processId'', ''executionId'', ''jobExecutionId'', ''id'')) {')
$lines.Add('            if ($InputObject.PSObject.Properties[$key] -and $InputObject.$key) { return [string]$InputObject.$key }')
$lines.Add('        }')
$lines.Add('        foreach ($nested in @(''task'', ''process'', ''execution'', ''jobExecution'', ''job'')) {')
$lines.Add('            if ($InputObject.PSObject.Properties[$nested] -and $InputObject.$nested) {')
$lines.Add('                $candidate = Get-MorpheusTaskIdFromObject -InputObject $InputObject.$nested')
$lines.Add('                if ($candidate) { return $candidate }')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return $null')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusTaskStateInfo {')
$lines.Add('    param([Parameter()][object]$TaskObject)')
$lines.Add('')
$lines.Add('    $status = $null')
$lines.Add('    $success = $null')
$lines.Add('    $complete = $null')
$lines.Add('')
$lines.Add('    $stack = New-Object System.Collections.Generic.Queue[object]')
$lines.Add('    if ($null -ne $TaskObject) { $stack.Enqueue($TaskObject) }')
$lines.Add('')
$lines.Add('    while ($stack.Count -gt 0) {')
$lines.Add('        $current = $stack.Dequeue()')
$lines.Add('        if ($null -eq $current) { continue }')
$lines.Add('')
$lines.Add('        if ($current -is [pscustomobject]) {')
$lines.Add('            foreach ($name in @(''status'', ''state'', ''phase'')) {')
$lines.Add('                if (-not $status -and $current.PSObject.Properties[$name] -and $current.$name) { $status = [string]$current.$name }')
$lines.Add('            }')
$lines.Add('            if ($null -eq $complete -and $current.PSObject.Properties[''complete'']) { $complete = [bool]$current.complete }')
$lines.Add('            if ($null -eq $success -and $current.PSObject.Properties[''success'']) { $success = [bool]$current.success }')
$lines.Add('')
$lines.Add('            foreach ($prop in $current.PSObject.Properties) {')
$lines.Add('                if ($prop.Value -is [pscustomobject] -or ($prop.Value -is [System.Collections.IDictionary])) {')
$lines.Add('                    $stack.Enqueue($prop.Value)')
$lines.Add('                }')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('        elseif ($current -is [System.Collections.IDictionary]) {')
$lines.Add('            foreach ($name in @(''status'', ''state'', ''phase'')) {')
$lines.Add('                if (-not $status -and $current.Contains($name) -and $current[$name]) { $status = [string]$current[$name] }')
$lines.Add('            }')
$lines.Add('            if ($null -eq $complete -and $current.Contains(''complete'')) { $complete = [bool]$current[''complete''] }')
$lines.Add('            if ($null -eq $success -and $current.Contains(''success'')) { $success = [bool]$current[''success''] }')
$lines.Add('')
$lines.Add('            foreach ($k in $current.Keys) {')
$lines.Add('                $v = $current[$k]')
$lines.Add('                if ($v -is [pscustomobject] -or ($v -is [System.Collections.IDictionary])) {')
$lines.Add('                    $stack.Enqueue($v)')
$lines.Add('                }')
$lines.Add('            }')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $statusText = if ($status) { $status } else { ''unknown'' }')
$lines.Add('    $normalized = $statusText.ToLowerInvariant()')
$lines.Add('    $successStates = @(''success'', ''succeeded'', ''completed'', ''complete'', ''done'', ''finished'', ''ok'')')
$lines.Add('    $failureStates = @(''failed'', ''failure'', ''error'', ''errored'', ''cancelled'', ''canceled'', ''timedout'', ''timeout'', ''aborted'')')
$lines.Add('')
$lines.Add('    $isTerminal = $false')
$lines.Add('    $isSuccess = $null')
$lines.Add('')
$lines.Add('    if ($successStates -contains $normalized) { $isTerminal = $true; $isSuccess = $true }')
$lines.Add('    elseif ($failureStates -contains $normalized) { $isTerminal = $true; $isSuccess = $false }')
$lines.Add('')
$lines.Add('    if (-not $isTerminal -and $null -ne $complete -and $complete) {')
$lines.Add('        $isTerminal = $true')
$lines.Add('        if ($null -ne $success) { $isSuccess = [bool]$success }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return [pscustomobject]@{ Status = $statusText; IsTerminal = $isTerminal; IsSuccess = $isSuccess }')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Get-MorpheusTask {')
$lines.Add('    [CmdletBinding()]')
$lines.Add('    param(')
$lines.Add('        [Parameter(Mandatory, ValueFromPipelineByPropertyName = $true)]')
$lines.Add('        [Alias(''Id'', ''ProcessId'', ''ExecutionId'', ''JobExecutionId'')]')
$lines.Add('        [string]$TaskId,')
$lines.Add('        [Parameter()]')
$lines.Add('        [ArgumentCompleter({ param($commandName, $parameterName, $wordToComplete) Get-MorpheusConnectionNameCompletions -WordToComplete $wordToComplete })]')
$lines.Add('        [string]$Morpheus')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    $target = @(Resolve-MorpheusTargets -Morpheus $Morpheus -Method ''GET'' | Select-Object -First 1)')
$lines.Add('    if ($target.Count -eq 0) { throw ''No Morpheus target available.'' }')
$lines.Add('')
$lines.Add('    $candidatePaths = @(')
$lines.Add('        "/api/processes/$TaskId",')
$lines.Add('        "/api/jobs/executions/$TaskId",')
$lines.Add('        "/api/tasks/$TaskId",')
$lines.Add('        "/api/executions/$TaskId"')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    $lastError = $null')
$lines.Add('    foreach ($path in $candidatePaths) {')
$lines.Add('        try {')
$lines.Add('            $uri = [System.Uri]::new([System.Uri][string]$target[0].Server, $path).AbsoluteUri')
$lines.Add('            $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $($target[0].AccessToken)" } -ErrorAction Stop')
$lines.Add('            $obj = ConvertTo-MorpheusObject -Value $resp')
$lines.Add('            $state = Get-MorpheusTaskStateInfo -TaskObject $obj')
$lines.Add('            if ($obj -is [pscustomobject]) {')
$lines.Add('                if (-not $obj.PSObject.Properties[''TaskId'']) { $obj | Add-Member -MemberType NoteProperty -Name TaskId -Value $TaskId -Force }')
$lines.Add('                if (-not $obj.PSObject.Properties[''TaskPath'']) { $obj | Add-Member -MemberType NoteProperty -Name TaskPath -Value $path -Force }')
$lines.Add('                if (-not $obj.PSObject.Properties[''TaskStatus'']) { $obj | Add-Member -MemberType NoteProperty -Name TaskStatus -Value $state.Status -Force }')
$lines.Add('                if (-not $obj.PSObject.Properties[''IsTerminal'']) { $obj | Add-Member -MemberType NoteProperty -Name IsTerminal -Value $state.IsTerminal -Force }')
$lines.Add('                if (-not $obj.PSObject.Properties[''IsSuccess'']) { $obj | Add-Member -MemberType NoteProperty -Name IsSuccess -Value $state.IsSuccess -Force }')
$lines.Add('                if ($obj.PSObject.TypeNames -notcontains ''Morpheus.Task'') { $obj.PSObject.TypeNames.Insert(0, ''Morpheus.Task'') }')
$lines.Add('            }')
$lines.Add('            return $obj')
$lines.Add('        }')
$lines.Add('        catch {')
$lines.Add('            $lastError = $_')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($lastError) { throw $lastError }')
$lines.Add('    throw "Unable to locate task [$TaskId] on known Morpheus task endpoints."')
$lines.Add('}')
$lines.Add('')
$lines.Add('function Wait-MorpheusTask {')
$lines.Add('    [CmdletBinding()]')
$lines.Add('    param(')
$lines.Add('        [Parameter(Mandatory, ParameterSetName = ''ById'', ValueFromPipelineByPropertyName = $true)]')
$lines.Add('        [Alias(''Id'', ''ProcessId'', ''ExecutionId'', ''JobExecutionId'')]')
$lines.Add('        [string]$TaskId,')
$lines.Add('        [Parameter(Mandatory, ParameterSetName = ''ByObject'', ValueFromPipeline = $true)]')
$lines.Add('        [object]$InputObject,')
$lines.Add('        [Parameter()]')
$lines.Add('        [ArgumentCompleter({ param($commandName, $parameterName, $wordToComplete) Get-MorpheusConnectionNameCompletions -WordToComplete $wordToComplete })]')
$lines.Add('        [string]$Morpheus,')
$lines.Add('        [Parameter()]')
$lines.Add('        [ValidateRange(1, 300)]')
$lines.Add('        [int]$PollSeconds = 5,')
$lines.Add('        [Parameter()]')
$lines.Add('        [ValidateRange(5, 86400)]')
$lines.Add('        [int]$TimeoutSeconds = 1800,')
$lines.Add('        [Parameter()]')
$lines.Add('        [switch]$PassThru')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    $resolvedTaskId = $TaskId')
$lines.Add('    if ($PSCmdlet.ParameterSetName -eq ''ByObject'') {')
$lines.Add('        $resolvedTaskId = Get-MorpheusTaskIdFromObject -InputObject $InputObject')
$lines.Add('        if (-not $resolvedTaskId) {')
$lines.Add('            throw ''Unable to determine task id from -InputObject. Provide -TaskId explicitly.''')
$lines.Add('        }')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)')
$lines.Add('    $last = $null')
$lines.Add('')
$lines.Add('    while ((Get-Date) -lt $deadline) {')
$lines.Add('        $last = Get-MorpheusTask -TaskId $resolvedTaskId -Morpheus $Morpheus')
$lines.Add('        $state = Get-MorpheusTaskStateInfo -TaskObject $last')
$lines.Add('')
$lines.Add('        if ($state.IsTerminal) {')
$lines.Add('            if ($state.IsSuccess -eq $false) {')
$lines.Add('                throw "Task [$resolvedTaskId] finished in failure state [$($state.Status)]."')
$lines.Add('            }')
$lines.Add('            if ($PassThru) { return $last }')
$lines.Add('            return [pscustomobject]@{ TaskId = $resolvedTaskId; Status = $state.Status; Completed = $true; Success = $true }')
$lines.Add('        }')
$lines.Add('')
$lines.Add('        Start-Sleep -Seconds $PollSeconds')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    if ($PassThru -and $last) { return $last }')
$lines.Add('    throw "Timed out waiting for task [$resolvedTaskId] after $TimeoutSeconds seconds."')
$lines.Add('}')
$lines.Add('')
$lines.Add('function New-MorpheusKeyValueMap {')
$lines.Add('    [CmdletBinding(DefaultParameterSetName = ''Interactive'')]')
$lines.Add('    param(')
$lines.Add('        [Parameter(ParameterSetName = ''Interactive'')]')
$lines.Add('        [switch]$Interactive,')
$lines.Add('        [Parameter(ParameterSetName = ''Map'', Mandatory)]')
$lines.Add('        [hashtable]$Map')
$lines.Add('    )')
$lines.Add('')
$lines.Add('    if ($PSCmdlet.ParameterSetName -eq ''Map'') {')
$lines.Add('        return $Map')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    $result = [ordered]@{}')
$lines.Add('    while ($true) {')
$lines.Add('        $key = Read-Host -Prompt ''Config key (blank to finish)''')
$lines.Add('        if ([string]::IsNullOrWhiteSpace($key)) { break }')
$lines.Add('')
$lines.Add('        $rawValue = Read-Host -Prompt "Value for [$key]"')
$lines.Add('        $parsedValue = ConvertFrom-MorpheusInputValue -InputValue $rawValue')
$lines.Add('')
$lines.Add('        $result[[string]$key] = $parsedValue')
$lines.Add('    }')
$lines.Add('')
$lines.Add('    return $result')
$lines.Add('}')
$lines.Add('')

$exportedCommands = New-Object System.Collections.Generic.List[string]
$exportedCommands.Add('Connect-Morpheus')
$exportedCommands.Add('Disconnect-Morpheus')
$exportedCommands.Add('Get-MorpheusConnection')
$exportedCommands.Add('Set-MorpheusDefault')
$exportedCommands.Add('Get-MorpheusTask')
$exportedCommands.Add('Wait-MorpheusTask')
$exportedCommands.Add('New-MorpheusKeyValueMap')

foreach ($op in $operationsToGenerate) {
    $morpheusMandatory = '$false'
    $isRemoveAction = $op.CmdletName.StartsWith('Remove-')
    $isMutatingNonDelete = @('POST', 'PUT', 'PATCH') -contains [string]$op.Method
    $dynamicCompleterParams = @('ZoneId', 'SiteId', 'GroupId', 'PlanId', 'LayoutId', 'NetworkId', 'ClusterId', 'ServerId', 'InstanceId')

    $functionLines = New-Object System.Collections.Generic.List[string]
    $functionLines.Add("function $($op.CmdletName) {")

    $paramBlocks = New-Object System.Collections.Generic.List[object]
    $paramOrder = New-Object System.Collections.Generic.List[string]
    $paramHelp = @{
        Morpheus = 'Target Morpheus connection name. Required for mutating operations when multiple connections are active.'
        Property = 'Select specific properties in output.'
        Detailed = 'Return full object output instead of default selected columns.'
        NoPaging = 'Disable automatic paging on GET endpoints that support max/offset.'
        Curl = 'Preview the API request as curl and do not execute the call.'
        Scrub = 'With -Curl, obfuscate only the bearer API token in output.'
        Body = 'Request body payload as object/hashtable or JSON string.'
    }
    $paramBlocks.Add(@(
            "        [Parameter(Mandatory = $morpheusMandatory)]",
            '        [ArgumentCompleter({ param($commandName, $parameterName, $wordToComplete) Get-MorpheusConnectionNameCompletions -WordToComplete $wordToComplete })]',
            '        [string]$Morpheus'
        ))
    $paramOrder.Add('Morpheus')
    $paramBlocks.Add(@(
            '        [Parameter(Mandatory = $false)]',
            '        [string[]]$Property'
        ))
    $paramOrder.Add('Property')
    $paramBlocks.Add(@(
            '        [Parameter(Mandatory = $false)]',
            '        [switch]$Detailed'
        ))
    $paramOrder.Add('Detailed')
    $paramBlocks.Add(@(
            '        [Parameter(Mandatory = $false)]',
            '        [switch]$NoPaging'
        ))
    $paramOrder.Add('NoPaging')
    $paramBlocks.Add(@(
            '        [Parameter(Mandatory = $false)]',
            '        [switch]$Curl'
        ))
    $paramOrder.Add('Curl')
    $paramBlocks.Add(@(
            '        [Parameter(Mandatory = $false)]',
            '        [switch]$Scrub'
        ))
    $paramOrder.Add('Scrub')

    $usedParamNames = @{
        Morpheus = 1
        Property = 1
        Detailed = 1
        NoPaging = 1
        Curl = 1
        Scrub = 1
        Body = 1
    }
    $pathBindings = New-Object System.Collections.Generic.List[object]
    $queryBindings = New-Object System.Collections.Generic.List[object]
    $headerBindings = New-Object System.Collections.Generic.List[object]
    $bodyBindings = New-Object System.Collections.Generic.List[object]
    $bodyPromptMap = @{}
    $hasConsolidatedId = $false
    $consolidatedIdParamName = ''
    $nextPathPosition = 0

    foreach ($apiParam in $op.Parameters) {
        $apiName = if (Test-NodeKey -Node $apiParam -Key 'name') { [string](Get-NodeValue -Node $apiParam -Key 'name') } else { '' }
        $apiIn = if (Test-NodeKey -Node $apiParam -Key 'in') { [string](Get-NodeValue -Node $apiParam -Key 'in') } else { '' }
        $required = if (Test-NodeKey -Node $apiParam -Key 'required') { [bool](Get-NodeValue -Node $apiParam -Key 'required') } else { $false }
        $schema = if (Test-NodeKey -Node $apiParam -Key 'schema') { Get-NodeValue -Node $apiParam -Key 'schema' } else { $null }
        $apiDescription = if (Test-NodeKey -Node $apiParam -Key 'description') { [string](Get-NodeValue -Node $apiParam -Key 'description') } else { '' }

        if (-not $apiName -or -not $apiIn) { continue }

        $paramName = Convert-ToParameterName -RawName $apiName
        if ($usedParamNames.ContainsKey($paramName)) {
            $usedParamNames[$paramName] += 1
            $paramName = "$paramName$($usedParamNames[$paramName])"
        }
        else {
            $usedParamNames[$paramName] = 1
        }

        $psType = Convert-ToPSType -Schema $schema

        $requiredLiteral = if ($required) { '$true' } else { '$false' }
        $currentParamBlock = New-Object System.Collections.Generic.List[string]
        if ($apiIn -eq 'path') {
            $currentParamBlock.Add("        [Parameter(Mandatory = $requiredLiteral, Position = $nextPathPosition, ValueFromPipelineByPropertyName = `$true)]")
            $nextPathPosition++
        }
        else {
            $currentParamBlock.Add("        [Parameter(Mandatory = $requiredLiteral)]")
        }

        if ($apiIn -ne 'path' -and $paramName.EndsWith('Id')) {
            $currentParamBlock[0] = $currentParamBlock[0].Replace(')]', ', ValueFromPipelineByPropertyName = $true)]')
        }

        if ($schema -and (Test-NodeKey -Node $schema -Key 'enum')) {
            $enumValues = @(@((Get-NodeValue -Node $schema -Key 'enum')) | ForEach-Object { "'$(Escape-SingleQuote -Text ([string]$_))'" })
            if ($enumValues.Count -gt 0) {
                $currentParamBlock.Add("        [ValidateSet($($enumValues -join ', '))]")
            }
        }

        if ($dynamicCompleterParams -contains $paramName) {
            $currentParamBlock.Add('        [ArgumentCompleter({ param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters) Get-MorpheusDynamicIdCompletions -ParameterName $parameterName -WordToComplete $wordToComplete -BoundParameters $fakeBoundParameters })]')
        }

        $currentParamBlock.Add("        $psType`$$paramName")
        $paramBlocks.Add($currentParamBlock.ToArray())
        $paramOrder.Add($paramName)
        if ([string]::IsNullOrWhiteSpace($apiDescription)) {
            $apiDescription = "OpenAPI parameter '$apiName' in $apiIn."
        }
        $paramHelp[$paramName] = $apiDescription

        $binding = [pscustomobject]@{ ParamName = $paramName; ApiName = $apiName }
        switch ($apiIn) {
            'path' { $pathBindings.Add($binding) }
            'query' { $queryBindings.Add($binding) }
            'header' { $headerBindings.Add($binding) }
        }
    }

    if ((Test-NodeKey -Node $op -Key 'ConsolidatedIdParam') -and $op.ConsolidatedIdParam) {
        $idParamNode = $op.ConsolidatedIdParam
        $idApiName = if (Test-NodeKey -Node $idParamNode -Key 'name') { [string](Get-NodeValue -Node $idParamNode -Key 'name') } else { 'id' }
        $idSchema = if (Test-NodeKey -Node $idParamNode -Key 'schema') { Get-NodeValue -Node $idParamNode -Key 'schema' } else { $null }
        $idParamName = 'Id'

        if (-not $usedParamNames.ContainsKey($idParamName)) {
            $usedParamNames[$idParamName] = 1
            $idType = Convert-ToPSType -Schema $idSchema

            $idParamBlock = New-Object System.Collections.Generic.List[string]
            $idParamBlock.Add(('        [Parameter(Mandatory = $false, Position = {0}, ValueFromPipelineByPropertyName = $true)]' -f $nextPathPosition))
            $nextPathPosition++
            $idParamBlock.Add("        $idType`$$idParamName")
            $paramBlocks.Add($idParamBlock.ToArray())
            $paramOrder.Add($idParamName)

            $idDescription = if (Test-NodeKey -Node $idParamNode -Key 'description') { [string](Get-NodeValue -Node $idParamNode -Key 'description') } else { '' }
            if ([string]::IsNullOrWhiteSpace($idDescription)) { $idDescription = 'Resource identifier.' }
            $paramHelp[$idParamName] = $idDescription

            $pathBindings.Add([pscustomobject]@{ ParamName = $idParamName; ApiName = $idApiName })
            $hasConsolidatedId = $true
            $consolidatedIdParamName = $idParamName
        }
    }

    if ($op.RequestBody) {
        $bodyRequired = '$false'
        $resourceRootName = (Get-PathResourceNoun -Path $op.Path -Singular:$true).ToLowerInvariant()
        $paramBlocks.Add(@(
                "        [Parameter(Mandatory = $bodyRequired)]",
                '        [object]$Body'
            ))

        $leafDefinitions = @()
        if ((Test-NodeKey -Node $op -Key 'BodyLeafDefinitions') -and $op.BodyLeafDefinitions) {
            $leafDefinitions = @($op.BodyLeafDefinitions)
        }

        foreach ($leafDefinition in $leafDefinitions) {
            $bodyPath = if (Test-NodeKey -Node $leafDefinition -Key 'Path') { [string](Get-NodeValue -Node $leafDefinition -Key 'Path') } else { '' }
            if ([string]::IsNullOrWhiteSpace($bodyPath)) { continue }

            $pathParts = @($bodyPath -split '\.' | Where-Object { $_ })
            if ($pathParts.Count -eq 0) { continue }

            $effectiveParts = @($pathParts)
            if ((Test-NodeKey -Node $op -Key 'RootBodyProperty') -and $op.RootBodyProperty) {
                $rootName = [string]$op.RootBodyProperty
                while ($effectiveParts.Count -gt 1 -and $effectiveParts[0] -ieq $rootName) {
                    $effectiveParts = @($effectiveParts[1..($effectiveParts.Count - 1)])
                }
            }
            while ($effectiveParts.Count -gt 1 -and $effectiveParts[0].ToLowerInvariant() -eq $resourceRootName) {
                $effectiveParts = @($effectiveParts[1..($effectiveParts.Count - 1)])
            }

            $rawParamName = if ($effectiveParts.Count -gt 0) { $effectiveParts -join ' ' } else { $pathParts -join ' ' }
            $paramName = Convert-ToParameterName -RawName $rawParamName
            if ($paramName -eq 'Param') {
                $paramName = Convert-ToParameterName -RawName ($pathParts -join ' ')
            }

            if ($usedParamNames.ContainsKey($paramName)) {
                $usedParamNames[$paramName] += 1
                $paramName = "$paramName$($usedParamNames[$paramName])"
            }
            else {
                $usedParamNames[$paramName] = 1
            }

            $leafSchema = if (Test-NodeKey -Node $leafDefinition -Key 'Schema') { Get-NodeValue -Node $leafDefinition -Key 'Schema' } else { $null }
            $leafName = [string]$pathParts[$pathParts.Count - 1]
            $leafType = if ($leafName -ieq 'config') { '[hashtable]' } else { Convert-ToPSType -Schema $leafSchema }

            $bodyParamBlock = New-Object System.Collections.Generic.List[string]
            $bodyParamBlock.Add('        [Parameter(Mandatory = $false)]')
            if ($paramName.EndsWith('Id')) {
                $bodyParamBlock[0] = '        [Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true)]'
            }
            if ($dynamicCompleterParams -contains $paramName) {
                $bodyParamBlock.Add('        [ArgumentCompleter({ param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters) Get-MorpheusDynamicIdCompletions -ParameterName $parameterName -WordToComplete $wordToComplete -BoundParameters $fakeBoundParameters })]')
            }
            $bodyParamBlock.Add("        $leafType`$$paramName")
            $paramBlocks.Add($bodyParamBlock.ToArray())
            $paramOrder.Add($paramName)

            $bodyBindings.Add([pscustomobject]@{ ParamName = $paramName; BodyPath = $bodyPath })
            if (-not $bodyPromptMap.ContainsKey($bodyPath)) {
                $bodyPromptMap[$bodyPath] = Convert-ToLowerCamelCase -Name $paramName
            }

            $leafDescription = ''
            if ($leafSchema -and (Test-NodeKey -Node $leafSchema -Key 'description')) {
                $leafDescription = [string](Get-NodeValue -Node $leafSchema -Key 'description')
            }
            if ([string]::IsNullOrWhiteSpace($leafDescription)) {
                $leafDescription = "Body field '$bodyPath'."
            }
            $paramHelp[$paramName] = $leafDescription
        }
    }

    $synopsisText = if (-not [string]::IsNullOrWhiteSpace([string]$op.Summary)) { [string]$op.Summary } else { "$($op.Method) $($op.Path)" }
    $descriptionText = if (-not [string]::IsNullOrWhiteSpace([string]$op.Description)) { [string]$op.Description } else { $synopsisText }
    $exampleResponseText = if ((Test-NodeKey -Node $op -Key 'ResponseExample') -and $op.ResponseExample) { [string]$op.ResponseExample } else { '' }

    $helpLines = New-Object System.Collections.Generic.List[string]
    $helpLines.Add('    <#')
    $helpLines.Add('    .SYNOPSIS')
    foreach ($line in @($synopsisText -split '\r?\n')) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $helpLines.Add("    $line") }
    }
    $helpLines.Add('')
    $helpLines.Add('    .DESCRIPTION')
    foreach ($line in @($descriptionText -split '\r?\n')) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $helpLines.Add("    $line") }
    }

    $emittedHelpParams = New-Object System.Collections.Generic.HashSet[string]
    foreach ($paramName in $paramOrder) {
        if ($emittedHelpParams.Contains($paramName)) { continue }
        [void]$emittedHelpParams.Add($paramName)
        $paramDescriptionText = if ($paramHelp.ContainsKey($paramName)) { [string]$paramHelp[$paramName] } else { "Parameter $paramName." }
        if ([string]::IsNullOrWhiteSpace($paramDescriptionText)) { $paramDescriptionText = "Parameter $paramName." }
        $helpLines.Add('')
        $helpLines.Add("    .PARAMETER $paramName")
        foreach ($line in @($paramDescriptionText -split '\r?\n')) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $helpLines.Add("    $line") }
        }
    }

    $helpLines.Add('')
    $helpLines.Add('    .EXAMPLE')
    $helpLines.Add("    PS> $($op.CmdletName)")
    $helpLines.Add('    Calls the Morpheus API endpoint for this operation.')

    if (-not [string]::IsNullOrWhiteSpace($exampleResponseText)) {
        $helpLines.Add('')
        $helpLines.Add('    .EXAMPLE')
        $helpLines.Add("    PS> $($op.CmdletName) -Detailed")
        $helpLines.Add('    Example response payload:')
        foreach ($line in @($exampleResponseText -split '\r?\n')) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $helpLines.Add("    $line") }
        }
    }

    $helpLines.Add('')
    $helpLines.Add('    .OUTPUTS')
    $helpLines.Add('    PSCustomObject or Object[]')
    $helpLines.Add('    #>')

    foreach ($helpLine in $helpLines) {
        $functionLines.Add($helpLine)
    }

    if ($isRemoveAction) {
        $functionLines.Add('    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = ''High'')]')
    }
    elseif ($isMutatingNonDelete) {
        $functionLines.Add('    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = ''Medium'')]')
    }
    else {
        $functionLines.Add('    [CmdletBinding()]')
    }

    $functionLines.Add('    param(')

    for ($i = 0; $i -lt $paramBlocks.Count; $i++) {
        $paramBlock = @($paramBlocks[$i])
        for ($j = 0; $j -lt $paramBlock.Count; $j++) {
            $line = [string]$paramBlock[$j]
            if ($j -eq ($paramBlock.Count - 1) -and $i -lt ($paramBlocks.Count - 1)) {
                $line += ','
            }
            $functionLines.Add($line)
        }
    }

    $functionLines.Add('    )')
    $functionLines.Add('')
    if ($op.Summary) {
        $functionLines.Add("    # $([string]$op.Summary)")
    }
    if ($hasConsolidatedId -and (Test-NodeKey -Node $op -Key 'ConsolidatedItemPath')) {
        $collectionPathEscaped = [string](Escape-SingleQuote -Text $op.Path)
        $itemPathEscaped = [string](Escape-SingleQuote -Text $op.ConsolidatedItemPath)
        $functionLines.Add("    `$resolvedPath = if (`$PSBoundParameters.ContainsKey('$consolidatedIdParamName') -and `$null -ne `$$consolidatedIdParamName) { '$itemPathEscaped' } else { '$collectionPathEscaped' }")
        $functionLines.Add("    `$isDetailRequest = (`$PSBoundParameters.ContainsKey('$consolidatedIdParamName') -and `$null -ne `$$consolidatedIdParamName)")
    }
    else {
        $functionLines.Add("    `$resolvedPath = '$([string](Escape-SingleQuote -Text $op.Path))'")
        $isDetailLiteral = if ((Test-NodeKey -Node $op -Key 'IsDetailPath') -and $op.IsDetailPath) { '$true' } else { '$false' }
        $functionLines.Add("    `$isDetailRequest = $isDetailLiteral")
    }

    foreach ($pathBinding in $pathBindings) {
        $escapedToken = [Regex]::Escape("{$($pathBinding.ApiName)}")
        $functionLines.Add("    `$resolvedPath = `$resolvedPath -replace '$escapedToken', [uri]::EscapeDataString([string]`$$($pathBinding.ParamName))")
    }

    if ($isRemoveAction -or $isMutatingNonDelete) {
        $functionLines.Add('')
        $functionLines.Add("    if (-not `$Curl -and -not `$PSCmdlet.ShouldProcess(`$resolvedPath, '$($op.Method)')) { return }")
    }

    $functionLines.Add('')
    $functionLines.Add('    $query = @{}')
    foreach ($queryBinding in $queryBindings) {
        $functionLines.Add("    if (`$PSBoundParameters.ContainsKey('$($queryBinding.ParamName)')) { `$query['$($queryBinding.ApiName)'] = `$$($queryBinding.ParamName) }")
    }

    $functionLines.Add('')
    $functionLines.Add('    $headers = @{}')
    foreach ($headerBinding in $headerBindings) {
        $functionLines.Add("    if (`$PSBoundParameters.ContainsKey('$($headerBinding.ParamName)')) { `$headers['$($headerBinding.ApiName)'] = `$$($headerBinding.ParamName) }")
    }

    $functionLines.Add('')
    if ($op.RequestBody) {
        $arrayReqLiteral = '@()'
        $arrayReqRootPaths = @()
        if ((Test-NodeKey -Node $op -Key 'ArrayObjectRequirements') -and $op.ArrayObjectRequirements) {
            $arrayReqEntries = New-Object System.Collections.Generic.List[string]
            foreach ($arrayReq in @($op.ArrayObjectRequirements)) {
                $arrayPath = if (Test-NodeKey -Node $arrayReq -Key 'Path') { [string](Get-NodeValue -Node $arrayReq -Key 'Path') } else { '' }
                if ([string]::IsNullOrWhiteSpace($arrayPath)) { continue }

                $reqPaths = @()
                if (Test-NodeKey -Node $arrayReq -Key 'RequiredPaths') {
                    $reqPaths = @((Get-NodeValue -Node $arrayReq -Key 'RequiredPaths') | ForEach-Object { [string]$_ } | Where-Object { $_ })
                }
                if ($reqPaths.Count -eq 0) { continue }

                $quotedReqPaths = @($reqPaths | ForEach-Object { "'$(Escape-SingleQuote -Text ([string]$_))'" })
                $entry = "@{ Path = '$(Escape-SingleQuote -Text $arrayPath)'; RequiredPaths = @($($quotedReqPaths -join ', ')) }"
                $arrayReqEntries.Add($entry)
                $arrayReqRootPaths += @($arrayPath)
            }

            if ($arrayReqEntries.Count -gt 0) {
                $arrayReqLiteral = "@($($arrayReqEntries -join ', '))"
            }
        }

        $requiredRootArrayLiteral = '@()'
        if ($arrayReqRootPaths.Count -gt 0) {
            $quotedRoots = @($arrayReqRootPaths | Select-Object -Unique | ForEach-Object { "'$(Escape-SingleQuote -Text ([string]$_))'" })
            $requiredRootArrayLiteral = "@($($quotedRoots -join ', '))"
        }

        if ($bodyBindings.Count -gt 0) {
            $functionLines.Add('    $bodyFieldBound = $false')
            foreach ($bodyBinding in $bodyBindings) {
                $functionLines.Add("    if (`$PSBoundParameters.ContainsKey('$($bodyBinding.ParamName)')) { `$bodyFieldBound = `$true }")
            }
            $functionLines.Add('')
            $functionLines.Add('    if ($bodyFieldBound -and ($Body -is [string])) {')
            $functionLines.Add('        if ([string]::IsNullOrWhiteSpace($Body)) {')
            $functionLines.Add('            $Body = @{}')
            $functionLines.Add('        }')
            $functionLines.Add('        else {')
            $functionLines.Add('            try {')
            $functionLines.Add('                $Body = ConvertFrom-Json -InputObject $Body -AsHashtable -Depth 100 -ErrorAction Stop')
            $functionLines.Add('            }')
            $functionLines.Add('            catch {')
            $functionLines.Add('                throw ''When using body field parameters, -Body must be a JSON object string or hashtable/object.''')
            $functionLines.Add('            }')
            $functionLines.Add('        }')
            $functionLines.Add('    }')
            $functionLines.Add('')
            foreach ($bodyBinding in $bodyBindings) {
                $functionLines.Add("    if (`$PSBoundParameters.ContainsKey('$($bodyBinding.ParamName)')) { `$Body = Set-MorpheusBodyPathValue -Body `$Body -Path '$([string](Escape-SingleQuote -Text $bodyBinding.BodyPath))' -Value `$$($bodyBinding.ParamName) }")
            }
            $functionLines.Add('')
        }

        $functionLines.Add("    `$arrayRequirements = $arrayReqLiteral")
        $functionLines.Add("    `$arrayRequirementRoots = $requiredRootArrayLiteral")
        $functionLines.Add('    $Body = Ensure-MorpheusRequiredArrayBodyFields -Body $Body -ArrayRequirements $arrayRequirements -RequiredRootPaths $arrayRequirementRoots')
        $functionLines.Add('')

        $requiredBodyPathsLiteral = '@()'
        if ($op.RequiredBodyPaths -and @($op.RequiredBodyPaths).Count -gt 0) {
            $filteredRequiredPaths = @($op.RequiredBodyPaths)
            if ($arrayReqRootPaths.Count -gt 0) {
                $filteredRequiredPaths = @($filteredRequiredPaths | Where-Object { $arrayReqRootPaths -notcontains [string]$_ })
            }
            $quotedPaths = @($filteredRequiredPaths | ForEach-Object { "'$(Escape-SingleQuote -Text ([string]$_))'" })
            $requiredBodyPathsLiteral = "@($($quotedPaths -join ', '))"
        }
        $promptMapLiteral = '@{}'
        $promptPairs = @()
        foreach ($requiredPath in @($op.RequiredBodyPaths)) {
            $requiredPathString = [string]$requiredPath
            if ($bodyPromptMap.ContainsKey($requiredPathString)) {
                $promptPairs += "'$(Escape-SingleQuote -Text $requiredPathString)'='$(Escape-SingleQuote -Text ([string]$bodyPromptMap[$requiredPathString]))'"
            }
        }
        if ($promptPairs.Count -gt 0) {
            $promptMapLiteral = "@{ $($promptPairs -join '; ') }"
        }
        $functionLines.Add("    `$requiredBodyPaths = $requiredBodyPathsLiteral")
        $functionLines.Add("    `$requiredPromptMap = $promptMapLiteral")
        $functionLines.Add("    `$Body = Ensure-MorpheusRequiredBodyFields -Body `$Body -RequiredPaths `$requiredBodyPaths -PromptMap `$requiredPromptMap -ContentType '$($op.RequestContentType)'")
        $functionLines.Add('')
    }

    $functionLines.Add('')
    $supportsPaging = (@($queryBindings | Where-Object { $_.ApiName -eq 'max' }).Count -gt 0 -and @($queryBindings | Where-Object { $_.ApiName -eq 'offset' }).Count -gt 0)
    $supportsPagingLiteral = if ($supportsPaging) { '$true' } else { '$false' }

    $callLine = "    Invoke-MorpheusOperation -Method '$($op.Method)' -Path `$resolvedPath -Query `$query -Headers `$headers -Morpheus `$Morpheus -Property `$Property -Detailed:`$Detailed -Curl:`$Curl -Scrub:`$Scrub -NoPaging:`$NoPaging -IsDetailRequest:`$isDetailRequest -SupportsPaging:$supportsPagingLiteral -ContentType '$($op.RequestContentType)'"
    if ($op.RequestBody) {
        $callLine += ' -Body $Body'
    }
    $functionLines.Add($callLine)
    $functionLines.Add('}')
    $functionLines.Add('')

    foreach ($line in $functionLines) {
        $lines.Add($line)
    }

    $exportedCommands.Add($op.CmdletName)
}

$lines.Add("Export-ModuleMember -Function @('$($exportedCommands -join "','")')")

$moduleFile = Join-Path $OutputDir "$ModuleName.psm1"
Set-Content -Path $moduleFile -Value ($lines -join [Environment]::NewLine) -Encoding UTF8

$manifestContent = @"
@{
    RootModule = '$ModuleName.psm1'
    ModuleVersion = '8.0.13'
    GUID = '66e324ef-f692-481d-aeb2-c85baf74f2d5'
    Author = 'Generated from morpheus-openapi'
    CompanyName = 'Morpheus'
    Copyright = '(c) Morpheus'
    Description = 'PowerShell module generated from Morpheus OpenAPI v8.0.13.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('*')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
"@
$manifestFile = Join-Path $OutputDir "$ModuleName.psd1"
Set-Content -Path $manifestFile -Value $manifestContent -Encoding UTF8

Write-Host "Generated module: $moduleFile"
Write-Host "Generated manifest: $manifestFile"
Write-Host "Generated operations: $($operationsToGenerate.Count)"

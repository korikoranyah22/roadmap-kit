[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('plan', 'install', 'upgrade', 'doctor', 'uninstall-runtime')]
    [string]$Command = 'plan',

    [string]$RepoRoot = (Get-Location).Path,

    [ValidateSet('none', 'codex', 'miyuagents')]
    [string]$Adapter = 'none',

    [switch]$DryRun,

    [ValidateSet('text', 'json')]
    [string]$OutputFormat = 'text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PackageRoot = $PSScriptRoot
$ManifestPath = Join-Path $PackageRoot 'manifest.json'
$StateRelativePath = '.roadmap-kit/state.json'
$bundledVersion = ''
$installedVersion = ''

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-OptionalProperty {
    param($Value, [string]$Name, $Default = $null)
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Assert-SafeRelativePath {
    param([string]$Path, [string]$Label)

    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or
        $Path.Contains('\') -or $Path.Contains(':') -or
        @($Path.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw "$Label inválido: '$Path'."
    }
}

function Get-ContainedPath {
    param([string]$Root, [string]$RelativePath)

    Assert-SafeRelativePath $RelativePath 'Path relativo'
    $fullRoot = [IO.Path]::GetFullPath($Root)
    $fullPath = [IO.Path]::GetFullPath((Join-Path $fullRoot $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $prefix = $fullRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, $comparison)) { throw "Path fuera de la raíz permitida: '$RelativePath'." }
    return $fullPath
}

function Assert-NoReparseTraversal {
    param([string]$Root, [string]$RelativePath)

    $current = [IO.Path]::GetFullPath($Root)
    foreach ($segment in $RelativePath.Split('/')) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Se rechazó un symlink/reparse point en '$RelativePath'."
            }
        }
    }
}

function ConvertTo-StableStateText {
    param([string]$Version, [object[]]$Entries)

    $managed = @($Entries | Where-Object policy -eq 'managed' | Sort-Object targetPath | ForEach-Object {
        [ordered]@{
            path = [string]$_.targetPath
            sha256 = [string]$_.sha256
        }
    })
    $state = [ordered]@{
        schemaVersion = 1
        kitVersion = $Version
        managed = $managed
    }
    return (($state | ConvertTo-Json -Depth 6).Replace("`r`n", "`n").Replace("`r", "`n") + "`n")
}

function Read-ExistingState {
    param([string]$Path)

    $result = [ordered]@{
        Exists = (Test-Path -LiteralPath $Path -PathType Leaf)
        Valid = $false
        Version = ''
        Managed = @{}
        Text = ''
    }
    if (-not $result.Exists) { return [pscustomobject]$result }

    $result.Text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    try {
        $state = $result.Text | ConvertFrom-Json
        if ((Get-OptionalProperty $state 'schemaVersion' 0) -ne 1) { return [pscustomobject]$result }
        $result.Version = [string](Get-OptionalProperty $state 'kitVersion' '')
        if ($result.Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { return [pscustomobject]$result }
        $seenManaged = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($item in @(Get-OptionalProperty $state 'managed' @())) {
            $path = [string](Get-OptionalProperty $item 'path' '')
            $sha = [string](Get-OptionalProperty $item 'sha256' '')
            try { Assert-SafeRelativePath $path 'state managed path' }
            catch { return [pscustomobject]$result }
            if (-not $path.StartsWith('scripts/', [StringComparison]::Ordinal) -or
                -not $seenManaged.Add($path) -or $sha -notmatch '^[0-9a-f]{64}$') {
                return [pscustomobject]$result
            }
            $result.Managed[$path] = $sha
        }
        $result.Valid = $true
    }
    catch {
        $result.Valid = $false
    }
    return [pscustomobject]$result
}

function New-PlanItem {
    param(
        [string]$Action,
        [string]$TargetPath,
        [string]$Policy,
        [string]$Component,
        [string]$SourcePath = '',
        [string]$DesiredHash = '',
        [switch]$IsState
    )
    return [pscustomobject]@{
        Action = $Action
        TargetPath = $TargetPath
        Policy = $Policy
        Component = $Component
        SourcePath = $SourcePath
        DesiredHash = $DesiredHash
        IsState = [bool]$IsState
    }
}

function Write-Plan {
    param([object[]]$Plan)
    foreach ($item in @($Plan | Sort-Object TargetPath)) {
        Write-Output ("{0,-10} {1} [{2}/{3}]" -f $item.Action, $item.TargetPath, $item.Policy, $item.Component)
    }
}

function ConvertTo-StableJson {
    param($Value)
    return (($Value | ConvertTo-Json -Depth 10 -Compress).Replace("`r`n", "`n").Replace("`r", "`n"))
}

function Get-PlanFingerprint {
    param(
        [string]$Version,
        [string]$InstalledVersion,
        [string]$AdapterName,
        [object[]]$Plan
    )

    $canonical = [ordered]@{
        bundledVersion = $Version
        installedVersion = if ([string]::IsNullOrWhiteSpace($InstalledVersion)) { $null } else { $InstalledVersion }
        adapter = $AdapterName
        items = @($Plan | Sort-Object TargetPath | ForEach-Object {
            [ordered]@{
                action = [string]$_.Action
                targetPath = [string]$_.TargetPath
                policy = [string]$_.Policy
                component = [string]$_.Component
            }
        })
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-StableJson $canonical))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Resolve-CapabilityState {
    param(
        $ExistingState,
        [string]$Version,
        [object[]]$Plan,
        [string[]]$Problems = @()
    )

    if (@($Plan | Where-Object Action -eq 'CONFLICT').Count -gt 0) { return 'conflict' }
    if (-not $ExistingState.Exists) { return 'absent' }
    if (-not $ExistingState.Valid) { return 'conflict' }
    if ($ExistingState.Version -ne $Version) { return 'upgrade' }
    if (@($Problems | Where-Object { $_ -match '^(config:|managed modificado:|state ausente o inválido)' }).Count -gt 0) {
        return 'conflict'
    }
    if ($Problems.Count -gt 0) { return 'upgrade' }
    if (@($Plan | Where-Object Action -in @('CREATE', 'UPDATE', 'REMOVE-MANAGED')).Count -gt 0) { return 'upgrade' }
    return 'ready'
}

function Write-StructuredResult {
    param(
        [string]$CommandName,
        [string]$State,
        [string]$Version,
        [string]$InstalledVersion,
        [string]$AdapterName,
        [object[]]$Plan = @(),
        [string[]]$Problems = @(),
        [string]$Message = ''
    )

    $items = @($Plan | Sort-Object TargetPath | ForEach-Object {
        [ordered]@{
            action = [string]$_.Action
            targetPath = [string]$_.TargetPath
            policy = [string]$_.Policy
            component = [string]$_.Component
        }
    })
    $conflicts = @($items | Where-Object action -eq 'CONFLICT' | ForEach-Object targetPath)
    if ($State -eq 'conflict') { $conflicts = @($conflicts) + @($Problems) }
    $action = switch ($State) {
        'absent' { 'install' }
        'upgrade' { 'upgrade' }
        'conflict' { 'resolve-conflict' }
        default { 'none' }
    }
    $fingerprint = if ($State -eq 'unsupported') { $null } else {
        Get-PlanFingerprint $Version $InstalledVersion $AdapterName $Plan
    }
    $result = [ordered]@{
        schemaVersion = 1
        command = $CommandName
        state = $State
        bundledVersion = if ([string]::IsNullOrWhiteSpace($Version)) { $null } else { $Version }
        installedVersion = if ([string]::IsNullOrWhiteSpace($InstalledVersion)) { $null } else { $InstalledVersion }
        adapter = $AdapterName
        action = $action
        items = $items
        conflicts = $conflicts
        problems = @($Problems)
        planFingerprint = $fingerprint
        message = if ([string]::IsNullOrWhiteSpace($Message)) { $null } else { $Message }
    }
    Write-Output (ConvertTo-StableJson $result)
}

try {
    if ($OutputFormat -eq 'json' -and $Command -notin @('plan', 'doctor')) {
        throw 'OutputFormat json sólo está disponible para plan y doctor.'
    }
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Roadmap Kit requiere PowerShell 7 o posterior.' }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Falta manifest.json junto al instalador." }

    $RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { throw "RepoRoot inexistente: $RepoRoot" }
    # Docker Desktop puede presentar el bind-mount con un owner distinto del uid 1000.
    # La excepción es efímera y se limita a esta raíz exacta; no escribe config global.
    $gitRootOutput = @(& git -c "safe.directory=$RepoRoot" -C $RepoRoot rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "RepoRoot no es un repositorio Git: $RepoRoot" }
    $gitRoot = [IO.Path]::GetFullPath(($gitRootOutput -join '').Trim())
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $RepoRoot.Equals($gitRoot, $comparison)) { throw "RepoRoot debe señalar la raíz Git exacta: $gitRoot" }

    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1) { throw "manifest schemaVersion no soportado: $($manifest.schemaVersion)." }
    $version = [string]$manifest.kitVersion
    $bundledVersion = $version
    $selectedEntries = [System.Collections.Generic.List[object]]::new()
    $seenTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($manifest.files | Sort-Object targetPath)) {
        foreach ($property in @('bundlePath', 'targetPath', 'component', 'policy', 'sha256')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-OptionalProperty $entry $property ''))) {
                throw "Entrada de manifest sin '$property'."
            }
        }
        Assert-SafeRelativePath ([string]$entry.bundlePath) 'bundlePath'
        Assert-SafeRelativePath ([string]$entry.targetPath) 'targetPath'
        if ([string]$entry.policy -notin @('managed', 'seed', 'fragment')) { throw "Policy desconocida: $($entry.policy)." }
        if ([string]$entry.targetPath -eq 'AGENTS.md' -or [string]$entry.targetPath -eq $StateRelativePath -or
            [string]$entry.targetPath -match '^\.git(?:/|$)') {
            throw "El manifest intenta administrar un path protegido: $($entry.targetPath)."
        }
        if ([string]$entry.policy -eq 'managed' -and -not ([string]$entry.targetPath).StartsWith('scripts/', [StringComparison]::Ordinal)) {
            throw "En schema 1 los managed deben vivir bajo scripts/: $($entry.targetPath)."
        }
        if (-not $seenTargets.Add([string]$entry.targetPath)) { throw "targetPath duplicado: $($entry.targetPath)." }
        $sourcePath = Get-ContainedPath $PackageRoot ([string]$entry.bundlePath)
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Payload ausente: $($entry.bundlePath)." }
        if ((Get-Sha256 $sourcePath) -ne [string]$entry.sha256) { throw "Hash inválido en payload: $($entry.bundlePath)." }
        if ([string]$entry.component -eq 'adapter-agents' -and $Adapter -eq 'none') { continue }
        if ([string]$entry.component -eq 'adapter-codex' -and $Adapter -ne 'codex') { continue }
        $selectedEntries.Add([pscustomobject]@{
            bundlePath = [string]$entry.bundlePath
            targetPath = [string]$entry.targetPath
            component = [string]$entry.component
            policy = [string]$entry.policy
            sha256 = [string]$entry.sha256
            sourcePath = $sourcePath
        })
    }

    $statePath = Get-ContainedPath $RepoRoot $StateRelativePath
    Assert-NoReparseTraversal $RepoRoot $StateRelativePath
    $existingState = Read-ExistingState $statePath
    $installedVersion = $existingState.Version
    $stateText = ConvertTo-StableStateText $version @($selectedEntries)
    $stateBytes = [Text.UTF8Encoding]::new($false).GetBytes($stateText)

    $isUninstall = $Command -eq 'uninstall-runtime'
    if ($Command -eq 'upgrade' -and -not $existingState.Valid) {
        Write-Output 'Abortado: upgrade exige un state válido de una instalación anterior.'
        exit 2
    }

    $plan = [System.Collections.Generic.List[object]]::new()
    if ($isUninstall) {
        if (-not $existingState.Exists) {
            Write-Output 'Uninstall: no-op; no existe state administrado.'
            exit 0
        }
        if (-not $existingState.Valid) {
            Write-Output 'Abortado: state inválido; no se puede determinar ownership para desinstalar.'
            exit 2
        }
        foreach ($managedPath in @($existingState.Managed.Keys | Sort-Object)) {
            Assert-NoReparseTraversal $RepoRoot $managedPath
            $target = Get-ContainedPath $RepoRoot $managedPath
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $action = if ((Get-Sha256 $target) -eq $existingState.Managed[$managedPath]) { 'REMOVE-MANAGED' } else { 'PRESERVE-MODIFIED' }
            }
            elseif (Test-Path -LiteralPath $target) {
                $action = 'PRESERVE-MODIFIED'
            }
            else {
                $action = 'NOOP'
            }
            $plan.Add((New-PlanItem $action $managedPath 'managed' 'runtime'))
        }
        $plan.Add((New-PlanItem 'REMOVE-STATE' $StateRelativePath 'managed' 'state' -IsState))
    }
    else {
        $currentManagedTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $selectedEntries) {
            if ($entry.policy -eq 'managed') { [void]$currentManagedTargets.Add($entry.targetPath) }
            Assert-NoReparseTraversal $RepoRoot $entry.targetPath
            $target = Get-ContainedPath $RepoRoot $entry.targetPath
            $existsAsFile = Test-Path -LiteralPath $target -PathType Leaf
            $existsOther = (Test-Path -LiteralPath $target) -and -not $existsAsFile
            if ($existsOther) {
                $plan.Add((New-PlanItem 'CONFLICT' $entry.targetPath $entry.policy $entry.component $entry.sourcePath $entry.sha256))
                continue
            }
            if (-not $existsAsFile) {
                $plan.Add((New-PlanItem 'CREATE' $entry.targetPath $entry.policy $entry.component $entry.sourcePath $entry.sha256))
                continue
            }

            $currentHash = Get-Sha256 $target
            if ($entry.policy -eq 'managed') {
                if ($currentHash -eq $entry.sha256) {
                    $action = 'NOOP'
                }
                elseif ($existingState.Valid -and $existingState.Managed.ContainsKey($entry.targetPath) -and
                    $existingState.Managed[$entry.targetPath] -eq $currentHash) {
                    $action = 'UPDATE'
                }
                else {
                    $action = 'CONFLICT'
                }
            }
            else {
                $action = 'PRESERVE'
            }
            $plan.Add((New-PlanItem $action $entry.targetPath $entry.policy $entry.component $entry.sourcePath $entry.sha256))
        }

        if ($existingState.Valid) {
            foreach ($managedPath in @($existingState.Managed.Keys | Sort-Object)) {
                if ($currentManagedTargets.Contains($managedPath)) { continue }
                Assert-NoReparseTraversal $RepoRoot $managedPath
                $target = Get-ContainedPath $RepoRoot $managedPath
                if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-Sha256 $target) -eq $existingState.Managed[$managedPath]) {
                    $retiredAction = 'REMOVE-MANAGED'
                }
                else {
                    $retiredAction = 'PRESERVE-RETIRED'
                }
                $plan.Add((New-PlanItem $retiredAction $managedPath 'managed' 'retired'))
            }
        }

        if (-not $existingState.Exists) {
            $stateAction = 'CREATE'
        }
        elseif ($existingState.Text -eq $stateText) {
            $stateAction = 'NOOP'
        }
        elseif ($existingState.Valid -and $existingState.Version -ne $version) {
            $stateAction = 'UPDATE'
        }
        else {
            $stateAction = 'CONFLICT'
        }
        $stateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stateBytes)).ToLowerInvariant()
        $plan.Add((New-PlanItem $stateAction $StateRelativePath 'managed' 'state' -DesiredHash $stateHash -IsState))
    }

    if ($Command -eq 'doctor') {
        $problems = [System.Collections.Generic.List[string]]::new()
        $configLoader = $selectedEntries | Where-Object targetPath -eq 'scripts/roadmap-kit-config.psm1' | Select-Object -First 1
        if ($null -eq $configLoader) {
            $problems.Add('config loader ausente del manifest')
        }
        else {
            try {
                Import-Module $configLoader.sourcePath -Force
                [void](Get-RoadmapKitConfig -RepoRoot $RepoRoot -RequireFile)
            }
            catch { $problems.Add("config: $($_.Exception.Message)") }
        }
        if (-not $existingState.Valid) { $problems.Add('state ausente o inválido') }
        elseif ($existingState.Text -ne $stateText) { $problems.Add('state no coincide con el bundle/adapter seleccionados') }
        foreach ($entry in $selectedEntries) {
            $target = Get-ContainedPath $RepoRoot $entry.targetPath
            if ($entry.policy -eq 'managed') {
                if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $problems.Add("managed ausente: $($entry.targetPath)") }
                elseif ((Get-Sha256 $target) -ne $entry.sha256) { $problems.Add("managed modificado: $($entry.targetPath)") }
            }
            elseif ($entry.policy -eq 'fragment' -and -not (Test-Path -LiteralPath $target -PathType Leaf)) {
                $problems.Add("adapter ausente: $($entry.targetPath)")
            }
        }
        $capabilityState = Resolve-CapabilityState $existingState $version @($plan) @($problems)
        if ($OutputFormat -eq 'json') {
            Write-StructuredResult $Command $capabilityState $version $existingState.Version $Adapter @($plan) @($problems)
            exit $(if ($capabilityState -eq 'ready') { 0 } elseif ($capabilityState -eq 'conflict') { 2 } else { 1 })
        }
        if ($problems.Count -gt 0) {
            foreach ($problem in $problems) { Write-Output "PROBLEM $problem" }
            exit 1
        }
        Write-Output "Doctor: OK ($version, adapter $Adapter)."
        exit 0
    }

    $conflicts = @($plan | Where-Object Action -eq 'CONFLICT')
    if ($Command -eq 'plan' -and $OutputFormat -eq 'json') {
        $capabilityState = Resolve-CapabilityState $existingState $version @($plan)
        Write-StructuredResult $Command $capabilityState $version $existingState.Version $Adapter @($plan)
        exit $(if ($capabilityState -eq 'conflict') { 2 } else { 0 })
    }
    Write-Plan @($plan)
    if ($conflicts.Count -gt 0) {
        Write-Output "Abortado: $($conflicts.Count) conflicto(s); no se escribió ningún archivo."
        exit 2
    }
    if ($Command -eq 'install' -and $existingState.Valid -and $existingState.Version -ne $version) {
        Write-Output "Abortado: la versión instalada es $($existingState.Version); usar upgrade para instalar $version."
        exit 2
    }
    if ($Command -eq 'plan' -or $DryRun) { exit 0 }

    $mutations = @($plan | Where-Object Action -in @('CREATE', 'UPDATE', 'REMOVE-MANAGED', 'REMOVE-STATE') | Sort-Object @{ Expression = { if ($_.IsState) { 1 } else { 0 } } }, TargetPath)
    if ($mutations.Count -eq 0) {
        Write-Output "$Command`: no-op."
        exit 0
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("roadmap-kit-install-" + [guid]::NewGuid().ToString('N'))
    $stageRoot = Join-Path $tempRoot 'stage'
    $backupRoot = Join-Path $tempRoot 'backup'
    $journal = [System.Collections.Generic.List[object]]::new()
    New-Item -ItemType Directory -Force -Path $stageRoot, $backupRoot | Out-Null
    try {
        foreach ($item in $mutations) {
            if ($item.Action -in @('REMOVE-MANAGED', 'REMOVE-STATE')) { continue }
            $staged = Get-ContainedPath $stageRoot $item.TargetPath
            $stagedParent = Split-Path -Parent $staged
            New-Item -ItemType Directory -Force -Path $stagedParent | Out-Null
            if ($item.IsState) { [IO.File]::WriteAllBytes($staged, $stateBytes) }
            else { [IO.File]::WriteAllBytes($staged, [IO.File]::ReadAllBytes($item.SourcePath)) }
            if ((Get-Sha256 $staged) -ne $item.DesiredHash) { throw "Staging inválido para $($item.TargetPath)." }
        }

        $writeCount = 0
        $failAfter = 0
        if ($env:ROADMAP_KIT_TEST_FAIL_AFTER_WRITE) {
            [void][int]::TryParse($env:ROADMAP_KIT_TEST_FAIL_AFTER_WRITE, [ref]$failAfter)
        }

        try {
            foreach ($item in $mutations) {
                Assert-NoReparseTraversal $RepoRoot $item.TargetPath
                $target = Get-ContainedPath $RepoRoot $item.TargetPath
                $exists = Test-Path -LiteralPath $target -PathType Leaf
                if ($item.Action -eq 'CREATE' -and (Test-Path -LiteralPath $target)) {
                    throw "El destino apareció después del plan: $($item.TargetPath)."
                }
                $backup = Join-Path $backupRoot ("$($journal.Count).bak")
                if ($exists) { [IO.File]::WriteAllBytes($backup, [IO.File]::ReadAllBytes($target)) }
                $journal.Add([pscustomobject]@{ Target = $target; Existed = $exists; Backup = $backup })
                if ($item.Action -in @('REMOVE-MANAGED', 'REMOVE-STATE')) {
                    if ($exists) { Remove-Item -LiteralPath $target -Force }
                }
                else {
                    $targetParent = Split-Path -Parent $target
                    New-Item -ItemType Directory -Force -Path $targetParent | Out-Null
                    $staged = Get-ContainedPath $stageRoot $item.TargetPath
                    [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($staged))
                }
                $writeCount++
                if ($failAfter -gt 0 -and $writeCount -eq $failAfter) {
                    throw "Fallo de prueba inyectado después de $writeCount escritura(s)."
                }
            }
        }
        catch {
            for ($i = $journal.Count - 1; $i -ge 0; $i--) {
                $record = $journal[$i]
                if ($record.Existed) { [IO.File]::WriteAllBytes($record.Target, [IO.File]::ReadAllBytes($record.Backup)) }
                elseif (Test-Path -LiteralPath $record.Target -PathType Leaf) { Remove-Item -LiteralPath $record.Target -Force }
            }
            Write-Output "ROLLBACK: $($_.Exception.Message)"
            exit 3
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }

    Write-Output "$Command`: OK ($($mutations.Count) operación(es), versión $version, adapter $Adapter)."
    exit 0
}
catch {
    if ($OutputFormat -eq 'json') {
        Write-StructuredResult $Command 'unsupported' $bundledVersion $installedVersion $Adapter @() @() $_.Exception.Message
    }
    else {
        Write-Output "Roadmap Kit: error interno: $($_.Exception.Message)"
        Write-Output $_.ScriptStackTrace
    }
    exit 3
}

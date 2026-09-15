<#
.SYNOPSIS
Invokes the Desired State Configuration (DSC) based on a provided configuration file.

.DESCRIPTION
The Start-DscRunner function processes a DSC configuration file (YAML or JSON) and executes the tasks defined within it.
It supports both 'Test' and 'Set' modes to either validate the current state or apply changes to achieve the desired state.

Each resource is evaluated through the selected engine (DscV2 / DscV3 / custom), which returns a normalized
[DscMethodResult]. The runner records one structured result per resource, keyed by
(ConfigurationFile, ResourceType, InstanceName), so a resource is never double-counted. The report is written from a
finally block, so it is produced even when the run is stopped early (Stop-TaskProcessing) or aborted by an exception.

All human-readable output is emitted on the information stream (Write-Information, tag 'Dsc.PipelineRunner') rather
than Write-Host, so a caller can capture it with -InformationVariable or redirect it. DSC's native progress UI is
suppressed for the duration of the run so it does not flood the pipeline log.

.PARAMETER FilePath
The path to the configuration file (.yaml/.yml or .json).

.PARAMETER Mode
Specifies the mode of operation. Valid values are 'Test' (default) and 'Set'.
'Test' mode validates the current state, while 'Set' mode applies changes to achieve the desired state.

.PARAMETER ReportPath
Optional directory for saving the report. When provided, a CSV and a JSON report are written for the configuration.

.PARAMETER Engine
Execution engine action (Actions/Engine/<Engine>.ps1). 'Auto' opts in to detection; default is Invoke-DscResource (DscV2).

.PARAMETER EngineVersion
Optional resource version hint that biases 'Auto' engine selection by major version.

.PARAMETER EngineAction
Optional inline engine override; takes precedence over -Engine.

.OUTPUTS
[pscustomobject] describing the run: ConfigurationFile, Status (Completed / StoppedByRequest / AbortedByException),
TotalResources, PassCount, FailCount, SkipCount, DurationSeconds, ErrorMessage, FailedResources and the per-resource Results.

.EXAMPLE
Start-DscRunner -FilePath "C:\Configs\MyConfig.yaml" -Mode "Test"
Invokes the DSC configuration in 'Test' mode using the specified YAML configuration file.

.EXAMPLE
Start-DscRunner -FilePath "C:\Configs\MyConfig.json" -Mode "Set" -ReportPath "C:\Reports"
Invokes the DSC configuration in 'Set' mode using the specified JSON configuration file and saves the report to the specified path.

.NOTES
- The function supports both YAML and JSON configuration files.
- The function processes tasks in the order of their dependencies.
- The function generates a detailed report of the execution, which can be saved to a specified path.

#>
#
# Function to Invoke the DSC Configuration
function Start-DscRunner {
    # Declare parameters for the function with default values and validation where needed
    param (
        [string] $FilePath, # The path to the configuration file (.yaml/.yml or .json)
        [ValidateSet("Test", "Set")] # Ensures that Mode can only be 'Test' or 'Set'
        [string] $Mode = "Test", # Default mode is 'Test', can be set to 'Set' for applying changes,
        [String] $ReportPath = $null, # Optional parameter for specifying a report path
        [string] $Engine = 'DscV2', # Execution engine action (Actions/Engine/<Engine>.ps1). 'Auto' opts in to detection; default is Invoke-DscResource.
        [string] $EngineVersion, # Optional resource version hint that biases 'Auto' engine selection by major version.
        [scriptblock] $EngineAction, # Optional inline engine override; takes precedence over -Engine.

        # Resolved PipelineRunnerSettings (#57 §2/§3/§4), e.g. AllowExecutionScripts, Reboot,
        # Target. Invoke-DscRunner resolves this once from Datum.yml (pre-compile, since it is
        # not present in a compiled per-node YAML file) and passes it through; a direct caller
        # of Start-DscRunner may also supply it. Defaults are applied throughout when absent, so
        # every key stays optional and today's behavior is unchanged when this is not supplied.
        [hashtable] $RunnerSettings = @{}
    )

    # Informational output is the pipeline log's signal channel; make it visible by default
    # for the duration of the run, and keep DSC's native progress UI out of the log. Both are
    # local to this scope, so the caller's preferences are left untouched on return.
    $InformationPreference = 'Continue'
    $previousProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    $infoTag = 'Dsc.PipelineRunner'

    # Resolve the engine once so any dsc.exe probe / auto-selection warning happens a
    # single time per file rather than per resource. An inline EngineAction override
    # bypasses selection entirely (it takes precedence over -Engine); an explicit engine
    # name is honoured verbatim, and only 'Auto' triggers detection.
    $resolvedEngine = $Engine
    if (-not $EngineAction -and $Engine -eq 'Auto') {
        $resolvedEngine = Resolve-DscEngine -Engine $Engine -Version $EngineVersion
        Write-Verbose "Auto-selected DSC engine: $resolvedEngine"
    }

    # Build the engine selector once; every Test/Set/Get for this file runs through it.
    $engineArgs = @{ Engine = $resolvedEngine }
    if ($EngineAction) { $engineArgs.EngineAction = $EngineAction }

    # Reset the run-control flag for this file. $script:StopTaskProcessing is a documented
    # cross-file, module-script-scope contract (#26): Start-DscRunner owns it (resets here,
    # reads it once per resource below), and Stop-TaskProcessing is the only other writer,
    # setting it $true to skip the rest of the file. See Stop-TaskProcessing.ps1 for the guard
    # that keeps the two in lock-step.
    $script:StopTaskProcessing = $false

    # notify/using(): reset the per-run state that ties notify declarations, Get() output and
    # forced-refresh requests to this file. Owned by Start-DscRunner the same way
    # $script:StopTaskProcessing is above.
    $script:notifyDeclarations = @{}
    $script:resourceOutputs = @{}
    $script:pendingNotifyRefresh = @{}
    $script:currentResourceKey = $null

    # #57 §4: sessions opened by a Target action, cached per (TargetAction, ComputerName,
    # CredentialKey) so multiple resources aimed at the same remote target reuse one
    # connection instead of opening a fresh CimSession/PSSession per resource. Closed in the
    # finally block below regardless of how the run ends.
    $sessionCache = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # #57 §3: reboot policy. 'Fail' (default) stops the run when a local Set reports
    # RebootRequired; 'Ignore' continues without restarting. A remote target always restarts
    # and waits (Restart-Computer -Wait) regardless of this setting, since the runner is not
    # itself what needs to come back up.
    $rebootPolicy = if ($RunnerSettings -and -not [string]::IsNullOrWhiteSpace([string]$RunnerSettings['Reboot'])) { [string]$RunnerSettings['Reboot'] } else { 'Fail' }

    # #57 §4: the file-level default Target action; a resource may override it with its own
    # 'target' block. 'Local' (today's only behavior) is the default so an unmodified
    # configuration's execution is unchanged.
    $defaultTargetAction = if ($RunnerSettings -and -not [string]::IsNullOrWhiteSpace([string]$RunnerSettings['Target'])) { [string]$RunnerSettings['Target'] } else { 'Local' }

    # Determine the file extension of the provided FilePath
    $fileExtension = [System.IO.Path]::GetExtension($FilePath)
    Write-Verbose "File extension determined: $fileExtension"

    if ($fileExtension -notin '.yaml', '.yml', '.json') {
        throw "[Start-DscRunner] Unsupported configuration file extension '$fileExtension'. Expected .yaml, .yml or .json."
    }

    # Reject unsupported inputs up front, before any reporting state is set up (#15). A
    # missing file used to make Get-Content emit a *non-terminating* error, leaving $pipeline
    # $null; the run then completed with zero resources and reported 'Completed', so a typo
    # in a path looked exactly like a successful no-op run.
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new(
            "[Start-DscRunner] Configuration file not found: '$FilePath'.", $FilePath)
    }

    # Run-level bookkeeping. Results are structured records, deduplicated by the
    # (ConfigurationFile, ResourceType, InstanceName) tuple so a resource is counted once.
    $nodeName    = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $results     = [System.Collections.Generic.List[pscustomobject]]::new()
    $resultIndex = [System.Collections.Generic.Dictionary[string, pscustomobject]]::new([System.StringComparer]::Ordinal)
    $runStatus   = 'Completed'
    $runError    = $null
    $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Records a single resource outcome, replacing any earlier record for the same tuple so a
    # resource re-observed within a file does not double-count.
    $recordResult = {
        param($ResourceType, $InstanceName, $Status, $DurationMs, $ErrorMessage)

        # #57 §3/§4: Target/ComputerName/RebootRequired are read from the enclosing loop's
        # variables (this scriptblock is invoked with & from inside the loop, same as
        # $FilePath/$nodeName above, so it sees them by the same dynamic-scoping rule) rather
        # than as parameters, so every existing call site keeps working unchanged. They may be
        # unset at call sites that record a result before target resolution runs (e.g. a
        # preCondition failure) - PowerShell reads an unset variable as $null, handled below.
        $recordedTarget       = $targetAction
        $recordedComputerName = if ($session) { $session.ComputerName } else { $null }
        $recordedReboot       = if ($result) { [bool]$result.RebootRequired } else { $false }

        $record = [pscustomobject]@{
            NodeName          = $nodeName
            ResourceType      = $ResourceType
            InstanceName      = $InstanceName
            ConfigurationFile = $FilePath
            Status            = $Status
            DurationMs        = $DurationMs
            ErrorMessage      = $ErrorMessage
            Target            = $recordedTarget
            ComputerName      = $recordedComputerName
            RebootRequired    = $recordedReboot
        }

        $key = '{0}|{1}|{2}' -f $FilePath, $ResourceType, $InstanceName
        if ($resultIndex.ContainsKey($key)) {
            $existing = $resultIndex[$key]
            $results[$results.IndexOf($existing)] = $record
        }
        else {
            $results.Add($record)
        }
        $resultIndex[$key] = $record
    }

    # Load the configuration from the YAML or JSON file into the $pipeline variable.
    # -LiteralPath throughout: a configuration path is data, and a bracket in a directory
    # name would otherwise be read as a wildcard.
    if ($fileExtension -eq ".yaml" -or $fileExtension -eq ".yml") {
        $pipeline = Get-Content -LiteralPath $FilePath | ConvertFrom-Yaml
        Write-Verbose "Loaded YAML configuration from file: $FilePath"
    }
    else {
        # ConvertFrom-Json -AsHashtable returns a case-SENSITIVE OrderedHashtable on
        # PowerShell 7.3+, which breaks the runner's and the rules' mixed-case member access
        # (e.g. Sort-DependsOn's $Resource.Type, Start-DscRunner's $task.Condition) and would
        # silently collapse every resource onto the same empty key. Normalize to case-insensitive
        # hashtables so a JSON configuration behaves exactly like the YAML loader's output.
        $pipeline = ConvertTo-CaseInsensitiveHashtable -InputObject (Get-Content -LiteralPath $FilePath | ConvertFrom-Json -AsHashtable)
        Write-Verbose "Loaded JSON configuration from file: $FilePath"
    }

    # An empty or content-free configuration file must not report a clean 'Completed' run
    # with zero resources - that is indistinguishable from a successful run and hides the
    # real problem (#15).
    if ($null -eq $pipeline) {
        throw "[Start-DscRunner] The configuration file '$FilePath' is empty or contains no readable content."
    }

    $pipelineKeyCount = if ($pipeline -is [System.Collections.IDictionary]) { $pipeline.Keys.Count }
                        else { @($pipeline.PSObject.Properties).Count }

    if ($pipelineKeyCount -eq 0) {
        throw "[Start-DscRunner] The configuration file '$FilePath' parsed to an empty document; expected at least a 'resources' section."
    }

    # Clear any existing data in these hashtables before populating them
    $parameters.Clear()
    $variables.Clear()
    $references.Clear()
    Write-Verbose "Cleared existing data in parameters, variables, and references hashtables"

    # Run preamble — a single legible block at the top of the log (#30).
    Write-Information "---------------------------------------------------------------------" -Tags $infoTag
    Write-Information "Processing configuration file: $FilePath" -Tags $infoTag
    Write-Information "Mode: $Mode" -Tags $infoTag
    Write-Information "Engine: $resolvedEngine" -Tags $infoTag
    Write-Information "Report Path: $ReportPath" -Tags $infoTag
    Write-Information "---------------------------------------------------------------------" -Tags $infoTag
    Write-Information "--> Setting Variables:" -Tags $infoTag

    # Retrieve default values for parameters and set variables based on the pipeline's content.
    # The pipeline's parameter default values must land in $parameters so that later
    # property/variable expansion (Expand-HashTable) and conditions can resolve them; a prior
    # refactor left the result bound to an unused local and fed a $null source to $parameters,
    # so parameter defaults never took effect. Bind the defaults to $parameters directly.
    $defaultValues = GetDefaultValues -Source $pipeline.parameters

    SetVariables -Source $pipeline.variables -Target $variables
    SetVariables -Source $defaultValues -Target $parameters

    Write-Verbose "Retrieved default values for parameters and set variables based on pipeline content"

    Write-Information "--> Expanding notify declarations:" -Tags $infoTag

    # notify/using(): fold each resource's `notify` into its target's DependsOn *before* the
    # dependency sort runs, so the same topological sort (and its cycle detection) also governs
    # notify-induced ordering. Must run before Sort-DependsOn below.
    Invoke-CustomTask -Tasks $pipeline.resources -CustomTaskName "Expand-NotifyDependsOn" | Out-Null

    # Build the source-resource-key -> notify-targets map that using() consults to gate access.
    # Built from the unsorted resources - identity, not order, is what matters here.
    foreach ($notifySource in $pipeline.resources) {
        if (-not $notifySource.Notify) { continue }
        $notifySourceKey = "$($notifySource.type)/$($notifySource.name)"
        $script:notifyDeclarations[$notifySourceKey] = @($notifySource.Notify | ForEach-Object { $_.Trim() })
    }
    Write-Verbose "Built notify declaration map for $($script:notifyDeclarations.Count) resource(s)"

    Write-Information "--> Sorting tasks based on dependencies:" -Tags $infoTag

    # Sort the tasks based on their dependencies to ensure correct execution order
    $tasks = Invoke-CustomTask -Tasks $pipeline.resources -CustomTaskName "Sort-DependsOn"
    Write-Verbose "Sorted tasks based on dependencies"

    # Invoke the PreParse the rules to process the tasks before formatting them
    Write-Information "--> Processing PreParse Rules:" -Tags $infoTag

    # Invoke the PreParse the rules to process the tasks before formatting them
    Invoke-PreParseRules -Tasks $pipeline.resources -Settings $RunnerSettings

    # Invoke the Format Tasks Rules
    Write-Information "--> Processing Formatting Tasks:" -Tags $infoTag

    # Format the tasks based on the configuration rules
    $tasks = Invoke-FormatTasks -Tasks $tasks

    $totalTasks = @($tasks).Count

    # Report Task Counter
    $TaskCounter = 0

    try {
        # Loop through each task/resource and process it according to its configuration
        foreach ($task in $tasks) {

            # Increment the task counter
            $TaskCounter++

            $resourceKey = "$($task.type)/$($task.name)"
            $resourceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            # Reset per-resource state so a value from a previous iteration is never
            # misattributed to this one (#57 §3/§4 - read by $recordResult above).
            $targetAction = $defaultTargetAction
            $session = $null
            $result = $null

            # notify/using(): identify the resource currently being evaluated so using() knows
            # who is calling it once properties are expanded below.
            $script:currentResourceKey = $resourceKey

            Write-Verbose "Processing resource: [$resourceKey]"

            # If the StopTaskProcessing variable is set to true, stop processing the tasks
            if ($Script:StopTaskProcessing) {
                Write-Verbose "Skipping resource due to 'Stop-TaskProcessing' being called:"
                $runStatus = 'StoppedByRequest'
                & $recordResult $task.type $task.name 'SKIP' 0 "Resource skipped due to 'Stop-TaskProcessing' cmdlet."
                Write-Information ("[{0}/{1}] SKIP {2} (stopped by request)" -f $TaskCounter, $totalTasks, $resourceKey) -Tags $infoTag
                continue
            }

            # Evaluate the Condition script block if it exists, and skip the task if the condition returns false.
            # The function-language accessors permitted by Assert-SafeConditionExpression
            # (parameters()/variables()/reference()) are designed to throw on a missing
            # key/reference; wrap evaluation in the same per-resource try/catch used elsewhere in
            # this loop so a throwing condition fails only this resource instead of aborting the
            # rest of the file.
            # #57 §2: 'preCondition' is the current name; 'condition' is kept as a back-compat
            # alias (with a one-line deprecation warning) so an existing configuration keeps
            # working unchanged. preCondition wins when a resource somehow carries both.
            $preConditionExpression = $null
            if ($null -ne $task.preCondition) {
                $preConditionExpression = $task.preCondition
            }
            elseif ($null -ne $task.Condition) {
                Write-Warning "[Start-DscRunner] Resource [$resourceKey] uses the deprecated 'condition' key; rename it to 'preCondition'."
                $preConditionExpression = $task.Condition
            }

            if ($null -ne $preConditionExpression) {

                try {
                    # A preCondition is a predicate, not a program: reject any command, assignment
                    # or method call before it runs, so configuration code cannot use it to mutate
                    # the runner's state or its audit record (#35).
                    Assert-SafeConditionExpression -Expression $preConditionExpression

                    # Create a script block from the preCondition property. Normalized the same
                    # way it was validated (#57 §2 - see ConvertTo-NormalizedConditionExpression);
                    # a no-op for anything that isn't the result()/stopProcessing() syntax, which
                    # is rejected for preCondition anyway.
                    $sbCondition = [scriptblock]::Create((ConvertTo-NormalizedConditionExpression -Expression $preConditionExpression))

                    # Invoke with the call operator (&), not dot-sourcing (.), so the block runs in a
                    # child scope. It can still read the runner's variables through dynamic scoping
                    # (which is all the example configurations need), but any assignment it makes stays
                    # local instead of overwriting Start-DscRunner's own state (#35).
                    $conditionResult = & $sbCondition
                }
                catch {
                    Write-Error "[Start-DscRunner] Could not evaluate the preCondition of resource [$resourceKey]: $($_.Exception.Message)" -ErrorAction Continue
                    & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds $_.Exception.Message
                    Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $resourceKey, $resourceStopwatch.ElapsedMilliseconds, $_.Exception.Message) -Tags $infoTag
                    continue
                }

                if ($conditionResult -eq $false) {

                    Write-Verbose "Skipping resource due to preCondition: [$resourceKey]"
                    & $recordResult $task.type $task.name 'SKIP' $resourceStopwatch.ElapsedMilliseconds "Resource skipped due to preCondition {$preConditionExpression}."
                    Write-Information ("[{0}/{1}] SKIP {2} (preCondition)" -f $TaskCounter, $totalTasks, $resourceKey) -Tags $infoTag
                    continue

                }
            }

            # Extract the module name and resource type from the task's type property
            $module = $task.type.Split("/")[0]
            $resourceType = $task.type.Split("/")[1]
            Write-Verbose "Extracted module name: $module and resource type: $resourceType"

            $resourceStatus = 'OK'
            $resourceError = $null

            # Resolve the properties in two passes. Expand-Parameters runs first and does
            # whole-scalar substitution of `<params=Name>` tokens, so a parameter keeps its
            # type (a number stays a number, a hashtable stays a hashtable). Expand-HashTable
            # then runs string interpolation over the result, so a parameter value that
            # itself contains $(...) or a $variable reference still expands.
            #
            # An unresolvable token is this resource's failure, not the run's: expansion is
            # inside the same guard as the engine call so one bad property does not abort the
            # remaining tasks.
            try {
                $Property = Expand-HashTable -InputHashTable (Expand-Parameters -InputHashTable $task.properties)
                Write-Verbose "Replaced parameters and variables in properties with actual values"

                # #57 §7: a declarative 'resourceCredential' block resolves a credential through
                # the Credential hook and injects it into the resource's own properties (e.g. a
                # SqlServerDsc resource's -Credential), so the credential never needs to appear in
                # the configuration itself. Runs even when AllowExecutionScripts is off - it is
                # declarative, not a script, so the execution-scripts gate does not apply to it.
                if ($null -ne $task.resourceCredential) {
                    $credentialContext = $task.resourceCredential
                    $credentialActionName = if (-not [string]::IsNullOrWhiteSpace([string]$credentialContext.action)) { [string]$credentialContext.action } else { 'Environment' }
                    $resolvedResourceCredential = Invoke-Action -Hook Credential -Name $credentialActionName -Context $credentialContext
                    $targetPropertyName = if (-not [string]::IsNullOrWhiteSpace([string]$credentialContext.propertyName)) { [string]$credentialContext.propertyName } else { 'Credential' }
                    $Property[$targetPropertyName] = $resolvedResourceCredential
                    Write-Verbose "Resolved resourceCredential via Credential action '$credentialActionName' into property '$targetPropertyName' for resource: [$resourceKey]"
                }
            }
            catch {
                Write-Error "[Start-DscRunner] Could not resolve the properties of resource [$resourceKey]: $($_.Exception.Message)" -ErrorAction Continue
                & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds $_.Exception.Message
                Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $resourceKey, $resourceStopwatch.ElapsedMilliseconds, $_.Exception.Message) -Tags $infoTag
                continue
            }

            # #57 §4: resolve this resource's execution target. A per-resource 'target' block
            # overrides the file-level default (PipelineRunnerSettings.Target / 'Local'). Session
            # objects are cached per (action, computer, credential) so resources sharing a target
            # reuse one connection; 'Local' never invokes the Target hook at all, so an
            # unmodified configuration's local-only execution path is untouched.
            $targetAction = if ($task.target -and -not [string]::IsNullOrWhiteSpace([string]$task.target.action)) { [string]$task.target.action } else { $defaultTargetAction }
            $session = $null

            if ($targetAction -ne 'Local') {
                try {
                    $targetCredential = $null
                    $credentialCacheKey = ''
                    if ($task.target.credential) {
                        $tCred = $task.target.credential
                        $tCredAction = if (-not [string]::IsNullOrWhiteSpace([string]$tCred.action)) { [string]$tCred.action } else { 'Environment' }
                        $targetCredential = Invoke-Action -Hook Credential -Name $tCredAction -Context $tCred
                        $credentialCacheKey = "$tCredAction|$($tCred.Name)|$($tCred.UserNameVariable)"
                    }

                    $targetContext = @{
                        ComputerName = [string]$task.target.computerName
                        Engine       = $resolvedEngine
                        Credential   = $targetCredential
                    }

                    $sessionCacheKey = "$targetAction|$($targetContext.ComputerName)|$credentialCacheKey"
                    if (-not $sessionCache.ContainsKey($sessionCacheKey)) {
                        Write-Verbose "Opening new '$targetAction' session for target: [$($targetContext.ComputerName)]"
                        $sessionCache[$sessionCacheKey] = Invoke-Action -Hook Target -Name $targetAction -Context $targetContext
                    }
                    $session = $sessionCache[$sessionCacheKey]
                }
                catch {
                    Write-Error "[Start-DscRunner] Could not establish the '$targetAction' target for resource [$resourceKey]: $($_.Exception.Message)" -ErrorAction Continue
                    & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds $_.Exception.Message
                    Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $resourceKey, $resourceStopwatch.ElapsedMilliseconds, $_.Exception.Message) -Tags $infoTag
                    continue
                }
            }
            if ($session) { $engineArgs.Session = $session } else { $engineArgs.Remove('Session') }

            # #57 §2: preExecutionScript runs immediately before the Test/Set evaluation.
            # Mirrors postExecutionScript's execution model (invoked with &, not dot-sourced, so
            # it cannot rewrite Start-DscRunner's own locals - #35) but runs first, so it can
            # prepare state the resource's Test/Set depends on. Gated by PipelineRunnerSettings.
            # AllowExecutionScripts at PreParse time (Test-ExecutionScriptsAllowed.ps1); if the
            # run got this far with a preExecutionScript present, execution scripts are allowed.
            if ($null -ne $task.preExecutionScript) {
                $sbPreExecutionScript = [scriptblock]::Create($task.preExecutionScript)
                & $sbPreExecutionScript
            }

            # Execute the 'Test' method to determine if the state is as desired.
            # The resource is evaluated through the selected engine (DscV2 / DscV3 / custom),
            # which returns a normalized [DscMethodResult] regardless of the underlying tool.
            # A single resource that throws must not abort the entire run, so trap the
            # error, record it as a failed resource, and move on to the next task.
            try {
                $result = Invoke-EngineAction -Method 'Test' -ModuleName $module -Name $resourceType -Property $Property @engineArgs
                Write-Verbose "Executed 'Test' method for DSC resource: [$resourceKey]"
            }
            catch {
                Write-Error "[Start-DscRunner] 'Test' method failed for resource [$resourceKey]: $($_.Exception.Message)" -ErrorAction Continue
                & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds $_.Exception.Message
                Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $resourceKey, $resourceStopwatch.ElapsedMilliseconds, $_.Exception.Message) -Tags $infoTag
                # Skip Set/Get for this resource and continue with the remaining tasks
                continue
            }

            # notify/using(): a resource that a genuinely-changed notifier notifies is forced to
            # re-run Set() this pass even if its own Test() reports it is already in the desired
            # state (Puppet/Chef notify semantics). $neededChange records the engine's own
            # verdict before any forcing is applied, since that (not the forced re-run) is what
            # determines whether this resource's own notify targets should in turn be forced.
            $neededChange = -not $result.InDesiredState
            $forcedByNotify = ($Mode -eq "Set") -and $script:pendingNotifyRefresh.Contains($resourceKey)
            if ($forcedByNotify -and -not $neededChange) {
                Write-Verbose "Resource forced to re-run Set() by a notify from a changed resource: [$resourceKey]"
            }

            # If not in the desired state and Mode is 'Set', execute the 'Set' method to apply changes
            if ($result.InDesiredState -and -not $forcedByNotify) {
                Write-Verbose "Resource is in the desired state: [$resourceKey]"
                $resourceStatus = 'OK'
            }
            elseif ($Mode -eq "Set") {

                try {
                    $result = Invoke-EngineAction -Method 'Set' -ModuleName $module -Name $resourceType -Property $Property @engineArgs
                    Write-Verbose "Executed 'Set' method to make changes: [$resourceKey]"
                    $resourceStatus = 'OK'

                    # #57 §3: reboot handling. A remote target restarts itself and waits for
                    # PowerShell to come back before the run continues, regardless of the reboot
                    # policy - it is the target, not the runner's own host, that comes back up.
                    # A local target cannot safely do this in-process (restarting the machine the
                    # runner itself is on would kill the run mid-file), so it fails the resource
                    # and stops the rest of the file unless the policy explicitly says to ignore it.
                    if ($result.RebootRequired) {
                        if ($session -and $session.IsRemote) {
                            Write-Information "Reboot required on remote target [$($session.ComputerName)] after resource [$resourceKey]; restarting and waiting..." -Tags $infoTag
                            $restartParams = @{ ComputerName = $session.ComputerName; Wait = $true; Force = $true; ErrorAction = 'Stop' }
                            if ($task.target.credential -and $session.PSSession -and $session.PSSession.Credential) {
                                $restartParams.Credential = $session.PSSession.Credential
                            }
                            Restart-Computer @restartParams
                            Write-Verbose "Remote target [$($session.ComputerName)] is back; continuing."
                        }
                        elseif ($rebootPolicy -eq 'Ignore') {
                            Write-Information "Resource [$resourceKey] requires a reboot; PipelineRunnerSettings.Reboot is 'Ignore', continuing without restarting." -Tags $infoTag
                        }
                        else {
                            $resourceStatus = 'FAIL'
                            $resourceError = "Resource [$resourceKey] requires a reboot to complete, and the local host cannot safely restart itself mid-run. Set PipelineRunnerSettings.Reboot: Ignore to continue without restarting, or target this resource at a remote computer (#57 §4) to have the runner restart it and wait automatically."
                            Write-Error "[Start-DscRunner] $resourceError" -ErrorAction Continue
                            $script:StopTaskProcessing = $true
                        }
                    }
                }
                catch {
                    # -ErrorAction Continue keeps this non-terminating even when a caller
                    # runs under $ErrorActionPreference='Stop' (e.g. an advanced-function
                    # wrapper), so one failed 'Set' does not abort the whole run.
                    Write-Error "[Start-DscRunner] Failed to apply changes with 'Set' method: [$resourceKey]: $($_.Exception.Message)" -ErrorAction Continue
                    $resourceStatus = 'FAIL'
                    $resourceError = $_.Exception.Message
                }
            }
            else {
                # Drift detected in Test mode: the resource is not in the desired state.
                Write-Verbose "Change needed, but mode is not set to 'Set': [$resourceKey]"
                $resourceStatus = 'FAIL'
                $resourceError = $result.Message
            }

            # notify/using(): only a genuine change (this resource's own Test() originally
            # reported drift, not merely a forced-by-notify re-run) that completed successfully
            # propagates a forced refresh onward to whatever this resource itself notifies.
            if ($neededChange -and $resourceStatus -eq 'OK' -and $script:notifyDeclarations.Contains($resourceKey)) {
                foreach ($notifyTarget in $script:notifyDeclarations[$resourceKey]) {
                    Write-Verbose "Resource [$resourceKey] changed; forcing re-run of notified resource [$notifyTarget]"
                    $script:pendingNotifyRefresh[$notifyTarget] = $true
                }
            }

            # #57 §2: postCondition runs after Test/Set (before postExecutionScript). Unlike
            # preCondition it is not a skip - a $false postCondition marks the resource FAIL
            # regardless of what the engine itself reported, since it is meant to assert
            # something about the outcome (e.g. via result()) that the engine's own
            # InDesiredState does not capture. -AllowStopProcessing permits it (and only it) to
            # call stopProcessing() as well as read result().
            if ($null -ne $task.postCondition) {
                $script:currentResourceResult = $result
                try {
                    Assert-SafeConditionExpression -Expression $task.postCondition -AllowStopProcessing
                    # result()/stopProcessing() do not parse as written - normalize the same text
                    # that was just validated (#57 §2 - see ConvertTo-NormalizedConditionExpression).
                    $sbPostCondition = [scriptblock]::Create((ConvertTo-NormalizedConditionExpression -Expression $task.postCondition))
                    $postConditionResult = & $sbPostCondition
                }
                catch {
                    Write-Error "[Start-DscRunner] Could not evaluate the postCondition of resource [$resourceKey]: $($_.Exception.Message)" -ErrorAction Continue
                    $resourceStatus = 'FAIL'
                    $resourceError = $_.Exception.Message
                    $postConditionResult = $null
                }
                finally {
                    $script:currentResourceResult = $null
                }

                if ($postConditionResult -eq $false) {
                    Write-Verbose "Resource failed postCondition: [$resourceKey]"
                    $resourceStatus = 'FAIL'
                    $resourceError = "Resource failed postCondition {$($task.postCondition)}."
                }
            }

            #
            # Test if the postExecutionScript property exists and execute the script block if it does.
            if ($null -ne $task.postExecutionScript) {
                # Create a script block from the postExecutionScript property
                $sbPostExecutionScript = [scriptblock]::Create($task.postExecutionScript)

                # Invoke in a child scope with the call operator (&) rather than dot-sourcing (.).
                # postExecutionScript is imperative by design and may still read runner variables
                # and call control verbs such as Stop-TaskProcessing (which sets module-scope
                # state, so it keeps working across the scope boundary), but it can no longer
                # reach in and rewrite Start-DscRunner's locals or its report (#35).
                & $sbPostExecutionScript
            }

            # Execute the 'Get' method to retrieve the current state of the resource.
            # A failed 'Get' should not abort the run; record $null and continue.
            try {
                $getResult = Invoke-EngineAction -Method 'Get' -ModuleName $module -Name $resourceType -Property $Property @engineArgs
                # Store the engine's raw current-state output so downstream reference
                # expansion sees exactly the same shape it did before the engine seam.
                $output_var = $getResult.Raw
                Write-Verbose "Retrieved current state with 'Get' method for DSC resource: [$resourceKey]"
            }
            catch {
                Write-Error "[Start-DscRunner] 'Get' method failed for resource [$resourceKey]: $($_.Exception.Message)" -ErrorAction Continue
                $output_var = $null
            }

            # Store the output of the 'Get' operation in a reference table for later use
            $references.Add($task.name, $output_var)
            Write-Verbose "Stored output of 'Get' operation in references table for resource: [$resourceKey]"

            # notify/using(): store the same output keyed by the full "Type/Name" identity, so
            # using() can read it from a resource this one notifies.
            $script:resourceOutputs[$resourceKey] = $output_var

            # Record the single, deduplicated outcome for this resource and log one line.
            $resourceStopwatch.Stop()
            & $recordResult $task.type $task.name $resourceStatus $resourceStopwatch.ElapsedMilliseconds $resourceError
            Write-Information ("[{0}/{1}] {2} {3} ({4}ms)" -f $TaskCounter, $totalTasks, $resourceStatus, $resourceKey, $resourceStopwatch.ElapsedMilliseconds) -Tags $infoTag

        }
    }
    catch {
        # An unexpected exception aborted the loop. Record the run status so the report,
        # written from the finally block below, reflects the partial results.
        $runStatus = 'AbortedByException'
        $runError = $_.Exception.Message
        Write-Error "[Start-DscRunner] Run aborted by an unexpected error: $($_.Exception.Message)" -ErrorAction Continue
    }
    finally {

        $runStopwatch.Stop()
        $ProgressPreference = $previousProgressPreference

        # #57 §4: close every session this run opened, regardless of how the run ended.
        foreach ($cachedSession in $sessionCache.Values) {
            if ($cachedSession.CimSession) {
                Remove-CimSession -CimSession $cachedSession.CimSession -ErrorAction SilentlyContinue
            }
            if ($cachedSession.PSSession) {
                Remove-PSSession -Session $cachedSession.PSSession -ErrorAction SilentlyContinue
            }
        }

        # Summarize from the deduplicated records.
        $passCount = @($results | Where-Object { $_.Status -eq 'OK' }).Count
        $failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
        $skipCount = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
        $failedResources = @($results | Where-Object { $_.Status -eq 'FAIL' })

        # Always write the report (even on early stop / abort), when a path is supplied.
        if ($ReportPath) {

            Write-Verbose "[Start-DscRunner] Writing report for $FilePath to $ReportPath"

            # [System.IO.Path]::Combine composes the path without resolving a drive
            # qualifier, so a Windows-style ReportPath (e.g. 'C:\Reports') does not throw
            # DriveNotFoundException on a Linux runner.
            $csvPath  = [System.IO.Path]::Combine($ReportPath, ("{0}.csv" -f $nodeName))
            $jsonPath = [System.IO.Path]::Combine($ReportPath, ("{0}.report.json" -f $nodeName))

            $results | Export-Csv -Path $csvPath -NoTypeInformation

            $reportDocument = [pscustomobject]@{
                ConfigurationFile = $FilePath
                Status            = $runStatus
                TotalResources    = $results.Count
                PassCount         = $passCount
                FailCount         = $failCount
                SkipCount         = $skipCount
                DurationSeconds   = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 3)
                ErrorMessage      = $runError
                Results           = $results
            }
            $reportDocument | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath
        }

        # Print the summary block.
        $outcomeIsClean = ($failCount -eq 0) -and ($runStatus -eq 'Completed')

        Write-Information "DSC Configuration Report: $FilePath" -Tags $infoTag
        Write-Information "Run Status: $runStatus" -Tags $infoTag
        Write-Information "Results Summary:" -Tags $infoTag

        foreach ($record in $results) {
            Write-Information ("[{0}] {1}/{2} - Result: [{3}]" -f $record.NodeName, $record.ResourceType, $record.InstanceName, $record.Status) -Tags $infoTag
        }

        Write-Information "Total Tasks Executed: $($results.Count)" -Tags $infoTag
        Write-Information "Tasks Passed:  $passCount" -Tags $infoTag
        Write-Information "Tasks Failed:  $failCount" -Tags $infoTag
        Write-Information "Tasks Skipped: $skipCount" -Tags $infoTag
        Write-Information "Total Tasks: $($results.Count)" -Tags $infoTag

        # Failure detail block — a deduplicated list of every failed resource (#30).
        if ($failedResources.Count -gt 0) {
            Write-Information "Failed Resources:" -Tags $infoTag
            foreach ($failed in $failedResources) {
                Write-Information ("  {0}/{1} [{2}] - {3}" -f $failed.ResourceType, $failed.InstanceName, $failed.ConfigurationFile, $failed.ErrorMessage) -Tags $infoTag
            }
        }

        if (-not $outcomeIsClean) {
            Write-Verbose "[Start-DscRunner] Run completed with failures or interruption (status: $runStatus)."
        }
    }

    # Emit the structured run result so callers (Invoke-DscRunner / Invoke-DscPipelineRunner)
    # can aggregate outcomes across configuration files, surface a machine-readable report and
    # set a non-zero exit code on failure.
    return [pscustomobject]@{
        ConfigurationFile = $FilePath
        NodeName          = $nodeName
        Status            = $runStatus
        TotalResources    = $results.Count
        PassCount         = $passCount
        FailCount         = $failCount
        SkipCount         = $skipCount
        DurationSeconds   = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 3)
        ErrorMessage      = $runError
        FailedResources   = $failedResources
        Results           = $results
    }

}

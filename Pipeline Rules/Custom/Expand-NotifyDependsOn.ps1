<#
.SYNOPSIS
Expands each resource's `Notify` declarations into implicit DependsOn entries on their targets.

.DESCRIPTION
A resource's `notify` property names one or more other resources (by their "Type/Name"
identity, the same format DependsOn already uses) that it notifies. Notify carries an
ordering guarantee: the notifying resource must run before every resource it notifies. Rather
than teach the ordering/cycle-detection machinery (Sort-DependsOn, Test-CircularReferences)
a second relationship to understand, Expand-NotifyDependsOn folds `notify` into the target's
own `DependsOn` before those rules ever run, so a notify-induced ordering conflict or cycle is
caught by the exact same topological sort that already guards DependsOn.

This mutates each target resource's DependsOn property in place (PowerShell hashtables /
PSCustomObjects both support dot-notation assignment) and returns the same resources, so it
can be inserted immediately before the existing Sort-DependsOn custom task with no other
change to the pipeline.

.PARAMETER PipelineResources
An array of pipeline resources to expand. Each resource is expected to have a Type, a Name,
and optionally Notify and DependsOn properties (each a string or an array of "Type/Name"
strings).

.OUTPUTS
The same resources that were supplied, with DependsOn expanded to include every notifier that
names it as a target.

.EXAMPLE
$resources = @(
    [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @(); Notify = @('Module/Resource/Task2') },
    [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @() }
)
.\Expand-NotifyDependsOn.ps1 -PipelineResources $resources
# Task2.DependsOn now contains 'Module/Resource/Task1'.
#>
[CmdletBinding()]
[OutputType([Object[]])]
param(
    [Object[]]$PipelineResources
)

# Nothing to expand.
if ($null -eq $PipelineResources -or $PipelineResources.Count -eq 0) {
    Write-Verbose "[Expand-NotifyDependsOn] No resources supplied; nothing to expand."
    return $PipelineResources
}

# Identity matches Sort-DependsOn's own Get-ResourceKey: "Type/Name", matched directly with no
# re-parsing.
function Get-ResourceKey {
    param($Resource)
    return ('{0}/{1}' -f $Resource.Type, $Resource.Name)
}

$nodes = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($resource in $PipelineResources) {
    $key = Get-ResourceKey -Resource $resource
    if (-not $nodes.ContainsKey($key)) {
        $nodes[$key] = $resource
    }
}

foreach ($resource in $PipelineResources) {
    if (-not $resource.Notify) { continue }

    $key = Get-ResourceKey -Resource $resource

    foreach ($target in @($resource.Notify)) {
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        $targetKey = $target.Trim()

        if ($targetKey -eq $key) {
            throw "[Expand-NotifyDependsOn] Resource [$key] cannot notify itself."
        }
        if (-not $nodes.ContainsKey($targetKey)) {
            throw "[Expand-NotifyDependsOn] Resource [$key] notifies [$targetKey], which is not present in the configuration."
        }

        $targetResource = $nodes[$targetKey]
        $existingDependsOn = @($targetResource.DependsOn)

        if ($existingDependsOn -notcontains $key) {
            Write-Verbose "[Expand-NotifyDependsOn] Resource [$targetKey] implicitly depends on notifying resource [$key]."
            $targetResource.DependsOn = $existingDependsOn + $key
        }
    }
}

return $PipelineResources

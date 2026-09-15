<#
.SYNOPSIS
Reads another resource's Get() output from within a resource it explicitly notifies.

.DESCRIPTION
The `using` function-language accessor reads the raw Get() output (the same object
`reference()` exposes) of another resource, addressed by that resource's full "Type/Name"
identity rather than reference()'s bare Name. Unlike reference(), using() is gated: it may
only be called from within a resource that the named source resource's own `notify` list
explicitly names as a target - this is a declaration-based visibility rule, not an open lookup,
so a data dependency between two resources is always paired with the ordering guarantee that
`notify` also provides (the source is guaranteed to run, and to have produced output, before
any resource allowed to call using() on it).

Start-DscRunner populates $script:notifyDeclarations (source key -> its notify targets),
$script:resourceOutputs (source key -> its Get() Raw output) and $script:currentResourceKey
(the resource currently being evaluated) before expanding a resource's properties, which is
the only place using() is meant to be called from.

.PARAMETER Name
The full "Type/Name" identity (the same format DependsOn/Notify use) of the resource whose
Get() output should be read.

.EXAMPLE
PS> (using 'AzureDevOpsDscNative/AzDoProject/Project').Id
Returns the Id property of AzDoProject/Project's most recent Get() output, but only when the
calling resource is named in AzDoProject/Project's own `notify` list.
#>
function invoke-using {
    [CmdletBinding()]
    [Alias('using')]
    param ([string] $Name)

    $callerKey = $script:currentResourceKey

    if (-not $script:notifyDeclarations -or -not $script:notifyDeclarations.Contains($Name)) {
        throw "[using] Resource [$Name] has no 'notify' declaration, or does not exist. using() may only read a resource that explicitly notifies the calling resource."
    }

    $notifiedTargets = @($script:notifyDeclarations[$Name])
    if ($notifiedTargets -notcontains $callerKey) {
        throw "[using] Resource [$Name] does not notify [$callerKey]. using() may only be called from a resource that [$Name]'s own 'notify' list names as a target."
    }

    if (-not $script:resourceOutputs -or -not $script:resourceOutputs.Contains($Name)) {
        throw "[using] Resource [$Name] has not produced Get() output yet. Ensure [$Name] runs before [$callerKey] (notify already implies this ordering, so this indicates [$Name] has not been processed)."
    }

    return $script:resourceOutputs[$Name]
}

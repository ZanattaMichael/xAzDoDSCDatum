[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Required for output within the DSC Resource')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'notifyDeclarations', Justification='Read via $script: scope by using.ps1 and Start-DscRunner.ps1 (dynamic scoping) to gate and drive notify()/using() reads.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'resourceOutputs', Justification='Read via $script: scope by using.ps1 (dynamic scoping) to serve a using() read.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'pendingNotifyRefresh', Justification='Read via $script: scope by Start-DscRunner.ps1 (dynamic scoping) to force a notified resource''s Set() to re-run.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'currentResourceKey', Justification='Read via $script: scope by using.ps1 (dynamic scoping) to identify the calling resource.')]

$references = @{}
$variables = @{}
$parameters = @{}

# #57 §2: the DscMethodResult of the most recently evaluated resource, so the result()
# function-language accessor can read it from inside a postCondition expression. Owned by
# Start-DscRunner, which sets it before evaluating each resource's postCondition and never
# reads it back itself.
$currentResourceResult = $null

# notify/using() support: the notify/using() feature links two resources by identity
# ("Type/Name", the same format DependsOn already uses) rather than by bare Name, so these
# are kept separate from $references/$currentResourceResult above. Owned by Start-DscRunner.

# Source resource key -> its notify targets (also "Type/Name"), built once per run from every
# resource's `notify` property. using() consults this to gate access: it may only read a
# resource that names the caller as one of its notify targets.
$notifyDeclarations = @{}

# Source resource key -> its Get() Raw output, populated as each resource is evaluated. This is
# what using() actually returns, once the notify gate above allows the read.
$resourceOutputs = @{}

# The set of resource keys that must re-run Set() this pass even if their own Test() reports
# they are already in the desired state, because a resource that notifies them genuinely
# changed. Only meaningful when Mode -eq 'Set'.
$pendingNotifyRefresh = @{}

# The "Type/Name" key of the resource currently being evaluated, so using() knows who is
# calling it. Set immediately before a resource's properties are expanded.
$currentResourceKey = $null

#REPLACE ME!
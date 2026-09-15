# Dsc.PipelineRunner

## Overview

`Dsc.PipelineRunner` is a platform-agnostic DSC pipeline runner designed to execute DSC configurations within any CI/CD pipeline (GitHub Actions, GitLab, Jenkins, Azure DevOps, and more). It utilizes Datum to merge configuration stubs into larger pieces of configuration, which are then parsed and applied by the runner.

The core module has **no hard dependency on Azure DevOps**. Configuration source
(local directory or git clone), authentication/session setup, and the resource
execution engine (DSC v2's `Invoke-DscResource` or cross-platform DSC v3's `dsc.exe`)
are all pluggable **Actions** — see [Architecture: Actions](#architecture-actions).
Azure DevOps support is one opt-in `Connect` action among several, not a required
module.

> ⚠️ **Security — read this first.** The runner executes your configuration repository as
> **fully-trusted code** (a DSC `Configuration` block is code, not just data). There is no
> sandbox. Protect the configuration repository with the same controls as the runner's own
> source. The runner enforces what it can on the way in — the clone transport must be
> `https`/`ssh`, the revision can be pinned to a verified commit, and clones live in
> owner-only directories that are removed when the run ends (see
> [Configuration source security](#configuration-source-security)) — but none of that
> substitutes for trusting the repository itself. See [SECURITY.md](SECURITY.md) and
> [docs/trust-model.md](docs/trust-model.md).

## Datum

This module utilizes Datum from Gael Colas to streamline configuration. For more information on how to implement and use it, please refer to the [official documentation or Gael Colas' resources.](https://github.com/gaelcolas/Datum)

### Key Functions

1. __Custom Datum Variable Interpolation__: Perform custom datum variable interpolation before runner initialization using the format `[x={ $Node.Project }=]`.
1. __Calculated Properties__: Utilize PowerShell subexpressions for calculated properties, such as `$( (1 -eq 2 )? $true: $false )`, to dynamically determine values.
1. __Custom Variables__: Define and reference custom variables within resource properties.

    __Variable Configuration__

    ```yaml
    variables:
      ProjectName: 'Test_Project'
      GroupName: 'Custom_Group_Name'
    ```

    __Resource Variable Reference__

    ```yaml
    - name: CON Board Administrators
      preCondition: equals (variables 'ProjectWorkBoardsStatus') 'enabled'
      type: AzureDevOpsDscNative/AzDoProjectGroup
      dependsOn:
        - AzureDevOpsDscNative/AzDoProject/Project
      properties:
        ProjectName: $(variables('ProjectName'))
        GroupName: $(variables('GroupName'))
    ```

1. __Modular Pipeline Formatting and Validation Rules__: Incorporate modular scripts stored in the `\Pipeline Rules\` directory into the module build process. These scripts are responsible for validating and formatting configuration resources to meet specific requirements. They can be modified and extended as needed. The current set of scripts includes:

    - `Pipeline Rules\PreParse\Test-CircularReferences.ps1`: Walks the `dependsOn` graph and
      rejects genuine cycles, including a resource that depends on itself. A resource reached
      by more than one branch — a diamond, or any other shared dependency — is not a cycle and
      is allowed. If this script detects an error, the runner will not apply any changes.
    - `Pipeline Rules\PreParse\Test-ResourcesForIncorrectProperties.ps1`: Validates resource properties against documented specifications. Errors prevent the runner from applying changes.
    - `Pipeline Rules\Custom\Sort-DependsOn.ps1`: Orders resources based on their `dependsOn` property. This script is mandatory and cannot be bypassed.
    - `Pipeline Rules\Format\`: Directory reserved for format rules that pre-process task properties before execution.

1. __Versioned Configuration__: Ensure all versions are managed by the pipeline runner to avoid unforeseen issues as new features are introduced.

    __Datum.yml__

    ```yaml
    PipelineRunnerSettings:
      ConfigurationVersion: 0.2
      PipelineRunnerVersion: 1.0.0
      DSCResourceVersion: 2.0
    ```

    `ConfigurationVersion` tracks the configuration's own YAML shape and must be bumped
    whenever the configuration's structure changes; `PipelineRunnerVersion` should reflect
    the `Dsc.PipelineRunner` module version the configuration was authored/tested against
    (`ModuleVersion` in `source/Dsc.PipelineRunner.psd1`).

    The runner enforces the following version constraints (defined in `source\Public\VersionConfiguration.ps1`):

    | Setting | Minimum | Maximum |
    |---|---|---|
    | `ConfigurationVersion` | `0.1` | `0.9` |
    | `PSDesiredStateConfiguration` module | `2.0` | `2.9` |
    | DSC Resource module | `1.0` | `1.9` |

### Enhanced Pipeline Runner Resource Features

The pipeline runner provides a set of features applicable to all Desired State Configuration (DSC) resources, enhancing their flexibility and control. These features include:

- __preCondition__ (formerly `condition`, which is still accepted as a deprecated alias):
  This feature allows conditional execution of resources. The expression is evaluated as a
  PowerShell predicate before the resource runs. If it evaluates to `$true`, the resource
  executes; if it evaluates to `$false`, the resource is skipped. This is useful for
  dynamically controlling resource execution based on specific criteria.

    __Example:__

    ```yaml
    - name: CON Board Administrators
      preCondition: equals (variables 'ProjectWorkBoardsStatus') 'enabled'
      type: AzureDevOpsDscNative/AzDoProjectGroup
    ```

    A preCondition may also call the function-language accessors `parameters()`, `variables()`,
    `reference()`, `equals()` and `not()` — an explicit allow-list; any other command
    invocation, a variable assignment, or a method call is still rejected. Unlike a bare
    comparison, `parameters()`/`reference()` throw on a missing key or reference rather than
    silently resolving to `$null`, so a typo fails just that resource instead of skipping it
    unnoticed. These are ordinary PowerShell commands, so multi-argument calls take
    space-separated arguments — `equals (parameters 'Environment') 'Prod'`, not
    `equals(parameters('Environment'), 'Prod')` — the comma-in-parens form parses as a single
    array argument and silently mis-binds:

    ```yaml
    - name: CON Board Administrators
      preCondition: (parameters('Environment')) -eq 'Prod' -and (variables('ProjectWorkBoardsStatus')) -eq 'enabled'
      type: AzureDevOpsDscNative/AzDoProjectGroup
    ```

- __postCondition__: evaluated after the resource's `Test`/`Set`, before `postExecutionScript`.
  A `$false` result marks the resource `FAIL` regardless of what the engine itself reported —
  it asserts something about the *outcome*, where `preCondition` decides whether the resource
  runs at all. It is parsed by the same predicate allow-list as `preCondition`, plus two
  accessors reserved for `postCondition` only: `result()` (the resource's normalized engine
  result — `InDesiredState` / `RebootRequired` / `Message` / `Raw`) and `stopProcessing()` (see
  below).

    __Example:__

    ```yaml
    - name: Print Spooler
      type: PSDscResources/Service
      postCondition: result().InDesiredState -or (not (equals (parameters 'Environment') 'Prod'))
    ```

- __preExecutionScript__ / __postExecutionScript__: run arbitrary PowerShell immediately
  before, or after, the resource's `Test`/`Set` evaluation. Useful for preparing state a
  resource depends on, or for clean-up/state-change logic afterwards. Unlike a condition,
  these are not restricted to a predicate — see `AllowExecutionScripts` below, which gates
  their use. Unlike `properties`/`preCondition`/`postCondition`, these are not parsed through
  `ExpandString` or `Assert-SafeConditionExpression` — they run as plain PowerShell, with
  direct read access to the script-scope variable `Set-Variables` already created for each
  Datum variable, so there is no need to go through the `variables()` accessor here.

    __Example:__

    ```yaml
    - name: Project
      type: AzureDevOpsDscNative/AzDoProject
      postExecutionScript: if ($Project_Ensure -eq 'Absent') { Stop-TaskProcessing }
    ```

- __AllowExecutionScripts__ (`PipelineRunnerSettings.AllowExecutionScripts`, default `false`):
  a configuration-level gate on `preExecutionScript`/`postExecutionScript`. Because an
  execution script runs unrestricted code in the runner's own process, a configuration must
  opt in explicitly before any resource may carry one; otherwise the run fails at PreParse
  time, naming every offending resource in one pass, before any resource is evaluated.

    ```yaml
    PipelineRunnerSettings:
      AllowExecutionScripts: true
    ```

- __resourceCredential__: a declarative way to inject a resolved credential into a resource's
  own properties (for example a resource's `-Credential` parameter) without the credential
  ever appearing in the configuration file. It resolves through the `Credential` action hook
  (see below) and, unlike `preExecutionScript`/`postExecutionScript`, works even when
  `AllowExecutionScripts` is off — it is declarative, not a script.

    __Example:__

    ```yaml
    - name: SQL Login
      type: SqlServerDsc/SqlLogin
      properties:
        InstanceName: MSSQLSERVER
      resourceCredential:
        action: SecretManagement   # a file in Actions/Credential/ (default: Environment)
        name: sql-service-account  # the secret name
        propertyName: Credential   # the properties key the resolved PSCredential is written to (default: Credential)
    ```

- __dependsOn__: This feature establishes a dependency chain, ensuring that resources are executed in a specific order. By defining dependencies, you can create a structured sequence of resource execution, where a resource will only run after its dependencies have successfully completed. This is particularly useful in complex configurations where the order of operations is critical.

    __Example:__

    ```yaml
    - name: Default Git Configuration Permissions
      type: AzureDevOpsDscNative/AzDoGitPermission
      dependsOn:
        - AzureDevOpsDscNative/AzDoProject/Project
        - AzureDevOpsDscNative/AzDoProjectGroup/CON Readers
        - AzureDevOpsDscNative/AzDoProjectGroup/CON Board Administrators
    ```

- __notify__ / __using()__: a Puppet/Chef-style relationship between two resources, combining an
  ordering guarantee with a data link. `notify` is a string or array of strings on the
  *notifying* resource, each naming a target resource by the same `Type/Name` identity
  `dependsOn` uses. It means two things:

    1. **Ordering** — the notifying resource is guaranteed to run before every resource it
       notifies. This is implemented as an implicit `dependsOn` on the target (folded in before
       the dependency sort runs), so a `notify` cycle is rejected exactly the way a `dependsOn`
       cycle already is.
    2. **Forced re-run** — in `Set` mode, if the notifying resource's own `Test()` reported it
       was *not* in the desired state, and its `Set()` then completed successfully, every
       resource it notifies is forced to re-run its own `Set()` this pass, even if that
       resource's `Test()` reports it is already in the desired state. In `Test` mode there is
       no `Set()` to force, so `notify` only contributes its ordering guarantee.

    A resource named in another resource's `notify` list may read that resource's `Get()`
    output with the `using('Type/Name')` accessor, addressed by the same full `Type/Name`
    identity (not the bare `name` that `reference()` uses). Unlike `reference()`, `using()` is
    gated: it only succeeds when the resource being read has actually declared the calling
    resource as a `notify` target — a data dependency is always paired with the ordering
    guarantee that makes it safe to read. `using()` is callable from anywhere within the
    notified resource's own expressions (typically `properties`), and, like `reference()`,
    ordinary PowerShell property-path chaining works on the result.

    `using` is a reserved PowerShell word (the `using module`/`using namespace` directive) when
    it is the first token of a statement, so `using(...)` must always sit inside an outer
    expression — never as a bare, unwrapped call. A property value's `$(...)` already provides
    that wrapping, so the example below (`$((using '...').Id)`) is the pattern to follow; a
    bare `using 'Type/Name'` with nothing enclosing it fails to parse.

    __Example:__

    ```yaml
    resources:
      - name: Project
        type: AzureDevOpsDscNative/AzDoProject
        properties:
          ProjectName: Magenta
        notify:
          - AzureDevOpsDscNative/AzDoGitRepository/Default Repository

      - name: Default Repository
        type: AzureDevOpsDscNative/AzDoGitRepository
        properties:
          # Only readable here because 'Project' names this resource in its own notify list.
          ProjectId: $((using 'AzureDevOpsDscNative/AzDoProject/Project').Id)
    ```

- __parameter tokens__: A resource property whose value is exactly `<params=Name>` is replaced
  by the value of that pipeline parameter, with its type intact — a number stays a number, a
  hashtable stays a hashtable. Parameters resolve first, before string interpolation, so a
  parameter value that itself contains `$(...)` or a `$variable` reference still expands.
  Referencing a parameter that is not declared fails that resource and records it in the run
  report; it does not silently resolve to `$null`.

    The same substitution works inside a list, and `parameters('Name')` reads a parameter
    from a `condition` or a `postExecutionScript`.

    Values come from the configuration's own `parameters` section and nowhere else — each
    parameter's `defaultValue` is the value, and there is no invocation-time override on
    `Invoke-DscRunner`. A parameter declared *without* a `defaultValue` has no value to
    resolve to, so it is ignored with a warning and referencing it fails exactly as an
    undeclared name does. Give every parameter a `defaultValue`; an empty string is a
    legitimate one, and resolves to `''` rather than failing.

    __Example:__

    ```yaml
    parameters:
      ServiceName:
        defaultValue: Spooler
      RetryCount:
        defaultValue: 3

    resources:
      - name: Print Spooler
        type: PSDscResources/Service
        properties:
          Name: <params=ServiceName>
          RetryCount: <params=RetryCount>
    ```

These features collectively enhance the robustness and adaptability of DSC resources managed by the pipeline runner, allowing for more precise and context-sensitive configuration management.

### Configuration Specific Commands

In the realm of configuration, there are specialized commands designed to modify the pipeline runner execution process. These commands provide greater control over how configurations are applied and managed. The key commands include:

- _Stop-TaskProcessing_: This command halts the processing of tasks. When executed, any resources scheduled to run after this command will be bypassed, effectively skipping their execution. This is useful for scenarios where you need to prevent certain operations from taking place without altering the entire configuration. For Example:

    ```yaml
    - name: Project
      type: AzureDevOpsDscNative/AzDoProject
      postExecutionScript: if ($Project_Ensure -eq 'Absent') { Stop-TaskProcessing }
    ```

    In this scenario, when the project is set for deletion, it will remove the project and subsequently halt any further tasks from executing within the pipeline.

- _stopProcessing()_: the `postCondition`-only counterpart of `Stop-TaskProcessing`. It sets
  the same run-control flag, so the remaining resources in the file are skipped, but it is
  reachable from a `postCondition` expression (which cannot call arbitrary commands) rather
  than only from `preExecutionScript`/`postExecutionScript`:

    ```yaml
    - name: Print Spooler
      type: PSDscResources/Service
      postCondition: result().InDesiredState -or stopProcessing()
    ```

### Deep Dive: Configuration Merging and Executing Process

1. Datum merges the example configuration based on the resolution precedence.
1. Once the YAML file for the project has been generated, Datum will execute any `[x={ $Node.ProjectPresence }=]` script blocks within the `_variables` property.
1. The pipeline runner ingests the configuration, loading and interpolating all variables and parameters into memory.
1. The runner executes the `Pre-Parse` and `Format` rules.
1. Each resource's `notify` property is expanded into an implicit `dependsOn` entry on every
   resource it names, so the notifying resource is guaranteed to run first.
1. The `Resources` are ordered according to the `dependsOn` property (including the implicit
   entries `notify` just added).
1. The runner iterates through each of the Resources and performs the following steps:
    1. Checks if `Stop-TaskProcessing`/`stopProcessing()` has been called; if so, the resource will be skipped.
    1. Checks for the `preCondition` property (the `condition` key still works, as a
       deprecated alias) and evaluates the expression. The resource executes when it is
       `$true`; a `$false` result skips the resource.
    1. Resolves the resource's properties in two passes. The first pass substitutes whole-value
       parameter tokens (`<params=Name>`), which keeps the parameter's type intact; the second
       pass interpolates variables and evaluates any calculated properties. Running them in that
       order means a parameter value that itself contains a subexpression still expands. A property
       may therefore use either form:

       ```yaml
       ServiceName: <params=ServiceName>
       Ensure: $( if ([string]::IsNullOrEmpty((variables 'Project_Ensure'))) { 'Present' } else { variables 'Project_Ensure' } )
       ```

       A token naming an undeclared parameter fails that one resource and is recorded in the run
       report; it is not silently resolved to `$null`, and it does not abort the rest of the file.

    1. Resolves the resource's execution `target` (a per-resource override, falling back to
       `PipelineRunnerSettings.Target`, default `Local`) and its `resourceCredential`, if any,
       through the `Target`/`Credential` action hooks.
    1. If present, runs `preExecutionScript` before the engine call (gated by
       `AllowExecutionScripts`).
    1. Runs the engine's `Test` method. If the resource is already in the desired state **and**
       it was not forced to refresh by a `notify` from a resource that changed on this pass (see
       above), it is marked `OK` and Set is skipped. Otherwise, in `Mode -eq 'Set'`, it runs the
       engine's `Set` method — this covers both genuine drift and a forced-by-notify re-run; in
       `Test` mode, drift with no forcing possible marks the resource `FAIL` instead.
       `Invoke-DscResource` drives `DscV2` (the default), `dsc.exe` drives `DscV3` — passing the
       resolved target session when the resource is not running against `Local`.
    1. If `Set` reports `RebootRequired`: a remote target is restarted (`Restart-Computer
       -Wait`) and the run continues once it is back; a local target fails the resource and
       stops the rest of the file, unless `PipelineRunnerSettings.Reboot: Ignore` is set.
    1. If this resource's own `Test` originally reported it needed a change (not merely a
       forced-by-notify re-run) and it completed successfully, every resource named in its
       `notify` list is marked to be forced through `Set()` on its own turn, once the runner
       reaches it.
    1. Checks for the `postCondition` property and evaluates it; a `$false` result marks the
       resource `FAIL` regardless of the engine's own outcome.
    1. Upon completion (even in case of an error), the runner checks for the `postExecutionScript` property and invokes the code if present.
    1. The runner calls the engine's `Get` method on the resource and stores the result in a references table, making it available to subsequent resources via the `reference` function. It is
       also stored under the resource's full `Type/Name` identity, making it available to any
       resource this one notifies via the `using()` function.

## Architecture: Actions

The runner's lifecycle is split into three pluggable seams, each resolved from a
named file under `Actions/<Hook>/<Name>.ps1` (or overridden inline with a
`[scriptblock]`) — the same loader idiom already used for Pipeline Rules:

| Hook | Purpose | Built-in actions | Config key |
|---|---|---|---|
| `Source` | Resolve the configuration to a local directory | `Local` (default), `Git` | `Source` |
| `Connect` | Establish auth/session before evaluation | `None` (default), `AzureDevOps` | `Connect` |
| `Engine` | Drive resource `Test`/`Set`/`Get` | `DscV2` (default, `Invoke-DscResource`), `DscV3` (`dsc.exe`) | `Engine` |
| `Target` | Resolve the session a resource evaluates against | `Local` (default, no-op), `WinRM` (CimSession + PSSession), `SSH` (PSSession over SSH, DscV3 only) | `PipelineRunnerSettings.Target` / per-resource `target.action` |
| `Credential` | Resolve a `[PSCredential]` for a target connection or a `resourceCredential` | `Environment` (default, from env vars), `Static` (inline, dev/test only), `SecretManagement` (`Get-Secret` from a registered vault) | per-use `action` key (a `target.credential` or `resourceCredential` block) |

Select an action by name in `Datum.yml`:

```yaml
PipelineRunnerSettings:
  Source: Git            # a file in Actions/Source/  (default: Local)
  Connect: AzureDevOps   # a file in Actions/Connect/ (default: None)
  Engine: DscV3          # a file in Actions/Engine/  (default: DscV2)
```

...or per-invocation, or with an inline scriptblock for a bespoke, one-off
solution that doesn't warrant a file:

```powershell
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Engine DscV3 -ConnectAction {
    param($Context)
    Connect-MyPlatform -Token $Context.Token   # any custom auth/session logic
}
```

`Actions/Connect/AzureDevOps.ps1` calls `New-AzDoAuthenticationProvider` only if
`AzureDevOpsDsc.Common` is importable — the core module never loads it and never
lists it in `RequiredModules`. Azure DevOps support is therefore opt-in by naming
the action, not a hard dependency.

The `Engine` hook additionally carries a strict, typed contract: it accepts
`{ Method; ModuleName; Name; Property }` and must return a normalized
`[DscMethodResult]` (`{ InDesiredState; RebootRequired; Message; Raw }`), so
reporting stays engine-independent regardless of which engine ran. See
[docs/dsc-v3.md](docs/dsc-v3.md) for the DSC v3 engine, and
[docs/hosted-agent-dsc-v3.md](docs/hosted-agent-dsc-v3.md) for running it on a
hosted Linux agent (bootstrap, engine selection, pipeline-native auth).
[docs/lifecycle-scripting-and-reboot-handling.md](docs/lifecycle-scripting-and-reboot-handling.md)
covers the design behind `preCondition`/`postCondition`/`preExecutionScript`/
`postExecutionScript`, the `stopProcessing()` function-language extension, and
reboot handling for resources that report `RebootRequired` — implemented here
with a simplified fail-and-stop (or `Reboot: Ignore`) policy for local targets
and an in-process `Restart-Computer -Wait` for remote targets, rather than a
full checkpoint/resume across separate runs.
[docs/remote-target-credential-handling.md](docs/remote-target-credential-handling.md)
covers the `Target` and `Credential` action design used for remote-target
execution and `resourceCredential` resolution.
[docs/notify-and-using.md](docs/notify-and-using.md) covers the `notify`/`using()`
resource relationship: the implicit ordering it adds on top of `dependsOn`, the
forced-refresh semantics in `Set` mode, and the declaration-gated visibility
`using()` enforces.

## Public Commands

| Command | Description |
|---|---|
| `Invoke-DscRunner` | Provider-agnostic entry point. Resolves the configured `Source` and `Connect` actions, compiles the Datum configuration, and invokes the runner for each compiled YAML file with the selected `Engine`. |
| `Invoke-DscPipelineRunner` | Azure DevOps back-compat shim. Maps its AzDO-flavored parameters onto `Invoke-DscRunner -Source Git -Connect AzureDevOps` with no functional change for existing callers. |
| `Build-DatumConfiguration` | Compiles the Datum configuration by resolving all nodes and writing per-project YAML files to the output directory. Runs in a separate runspace. |
| `ConvertTo-DscV3ConfigurationDocument` | Converts compiled, runner-specific resources into a schema-compliant DSC v3 configuration document (`$schema` + `name`/`type`/`properties` only) that `dsc config get\|test\|set` accepts. |
| `Test-DatumConfiguration` | Validates a Datum configuration object: checks for `PipelineRunnerSettings`, enforces version constraints, and warns when the configuration version is near the maximum supported version. |
| `Resolve-DscDatumProject` | Resolves a single Datum project node, evaluating variables and converting the result to YAML. Called internally by `Build-DatumConfiguration`. |
| `Stop-TaskProcessing` | Signals the runner to skip all remaining resources in the current YAML file. Must be called from within `postExecutionScript`. |

### `Invoke-DscRunner` Parameters

| Parameter | Description |
|---|---|
| `ConfigurationSourcePath` | Convenience: a local directory or git URL. Populates the `Source` action's context (`Path` for `Local`, `Url` for `Git`). |
| `Source` / `SourceAction` / `SourceContext` | Name of the `Source` action (default `Local`), an inline scriptblock override, and the hashtable context passed to it. |
| `Connect` / `ConnectAction` / `ConnectContext` | Name of the `Connect` action (default `None`), an inline scriptblock override, and the hashtable context passed to it. |
| `Engine` / `EngineAction` / `EngineVersion` | Name of the execution engine action (default `DscV2`; `DscV3` drives `dsc.exe`; `Auto` detects `dsc` on `PATH`), an inline scriptblock override, and a version hint used to bias `Auto` selection. When `-Engine` is not passed, `PipelineRunnerSettings.Engine` (or the back-compat `DSCResourceVersion` major version) decides. |
| `CacheDirectory` | Directory Datum compiles into. Falls back to `PIPELINERUNNER_CACHE_DIRECTORY` (or the legacy `AZDODSC_CACHE_DIRECTORY` alias), then a fresh temporary directory — no environment variable is required. |
| `ConfigurationRevision` | Branch, tag or commit to check out after cloning a git source. Folded into the `Source` action's context as `Revision`. A full 40-character SHA is verified against the clone's resolved HEAD. |
| `Mode` | `Test` (default, validate only) or `Set` (validate and apply changes). |
| `ReportPath` | Optional directory where a per-project CSV report is written after execution. |
| `FailOnError` | Switch. Sets a non-zero process exit code when the run reports a failure. |
| `KeepTemporaryDirectory` | Switch. Leaves any directory the runner created (a clone, a temporary cache) in place instead of removing it when the run ends. A caller-supplied local path is never removed. |

```powershell
# Local directory, no authentication, DSC v2 engine (all defaults).
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Mode Test

# Git source, Azure DevOps auth, DSC v3 engine.
Invoke-DscRunner -Source Git -SourceContext @{ Url = $repoUrl } `
                 -Connect AzureDevOps -ConnectContext @{ OrganizationName = 'MyOrg'; AuthenticationType = 'PAT'; PATToken = $pat } `
                 -Engine DscV3
```

### `Invoke-DscPipelineRunner` Parameters

> New integrations should prefer `Invoke-DscRunner`. `Invoke-DscPipelineRunner` remains
> as a back-compat shim for existing Azure DevOps pipelines and requires the
> `AzureDevOpsDsc.Common` module to be installed separately (it is no longer a
> `RequiredModules` dependency of the core module).

| Parameter | Required | Description |
|---|---|---|
| `AzureDevopsOrganizationName` | Yes | Name of the Azure DevOps organization. |
| `ExportConfigDir` | Yes | Directory where Datum writes compiled per-project YAML files. Must exist. |
| `ConfigurationSourcePath` | Yes | `https`/`ssh` URL (cloned via git) or local directory path for the Datum configuration. |
| `ConfigurationRevision` | No | Branch, tag or commit to check out after cloning. A full 40-character SHA is verified against the clone's resolved HEAD. |
| `JITToken` | No | Just-In-Time access token used for the clone. A `[SecureString]` or a plain string; falls back to `$env:SYSTEM_ACCESSTOKEN`. |
| `Mode` | No | `Test` (default, validate only) or `Set` (validate and apply changes). |
| `PATToken` | Only for PAT auth | Personal Access Token, 20–120 alphanumeric characters. Supplying it selects the PAT parameter set; omit it to authenticate with a managed identity. |
| `ReportPath` | No | Directory path where a per-project CSV report is written after execution. |
| `FailOnError` | No | Switch. Sets a non-zero process exit code when the run reports a failure. |
| `KeepTemporaryDirectory` | No | Switch. Leaves a cloned configuration in place instead of removing it when the run ends. |

> **Breaking change.** `-exportConfigDir` is now `-ExportConfigDir`, and
> `-AuthenticationType` has been removed: supplying `-PATToken` selects PAT
> authentication and omitting it uses the managed identity. Previously
> `-AuthenticationType` defaulted independently of the token, so a caller who passed
> `-PATToken` still went down the managed-identity path. `-Mode` and `-JITToken` are no
> longer mandatory.

> A cache directory environment variable must be set before calling `Invoke-DscPipelineRunner`. Prefer the generic `PIPELINERUNNER_CACHE_DIRECTORY`; the legacy `AZDODSC_CACHE_DIRECTORY` is still honoured as a back-compat alias. `Invoke-DscRunner` needs neither — pass `-CacheDirectory`, set one of those variables, or let it use a temporary directory.

### Configuration source security

Both entry points harden the path between the configuration repository and the runner. None
of it is optional, and none of it needs configuring:

- **The clone transport is enforced, not recommended.** Only `https`, `ssh` and SCP-style
  `git@host:path` remotes are accepted. A plain `http://` URL is rejected with a terminating
  error naming the scheme — the configuration runs as trusted code in the runner's own
  security context, so fetching it over a transport that can be tampered with is a remote
  code-execution path, not a style preference.
- **Pin the revision.** `-ConfigurationRevision` checks out a branch, tag or commit after the
  clone. Supply a full 40-character commit SHA and the pin is exact: the clone's resolved
  `HEAD` is verified against it and a mismatch fails the run. Whatever you pass, the resolved
  `HEAD` SHA is written to the information stream, so the pipeline log records the commit that
  actually ran.
- **Credentials never reach the command line.** The token is injected as an HTTP
  `Authorization` header through git's environment-based configuration and redacted from error
  text. Pass a `[SecureString]` or a plain string; with neither, `$env:SYSTEM_ACCESSTOKEN` is
  used when it is set.
- **Temporary directories are owner-only and removed.** A clone (or a fallback cache
  directory) is created with owner-only permissions — `0700` on Unix, a single full-control ACE
  on Windows — and deleted when the run ends, including when it ends by throwing. Only a
  directory the runner itself created is ever deleted; a path you supplied is left alone. Pass
  `-KeepTemporaryDirectory` to keep a clone for debugging.

## Getting Started

> **Running on a hosted Linux agent with DSC v3?** See
> [docs/hosted-agent-dsc-v3.md](docs/hosted-agent-dsc-v3.md) for bootstrapping the `dsc`
> engine, pipeline-native authentication, and workload-identity federation (no stored PAT).

### Quick start (provider-agnostic)

No Azure DevOps setup required — point `Invoke-DscRunner` at a local directory built
from the `Example Configuration` structure below:

```powershell
Import-Module Dsc.PipelineRunner
Invoke-DscRunner -ConfigurationSourcePath 'C:\Your-Path\Example Configuration' -Mode Test
```

The steps below walk through building that configuration and, further down, setting up
a self-hosted Azure DevOps agent if that is your target platform. Steps 1–3 apply to any
CI/CD system; the self-hosted agent / Azure DevOps steps are only needed if you use
`Invoke-DscPipelineRunner` or the `AzureDevOps` `Connect` action.

1. Clone the repository: `git clone 'https://github.com/ZanattaMichael/Dsc.PipelineRunner' C:\Your-Path`
1. Using the `Example Configuration` Directory, create a custom datum directory structure following these guidelines:
   1. __Lower-Level Rules__ should be implemented first, such as organizational policies.
   1. __Intermediate-Level Rules__ apply to groups of projects. For example:

      _datum.yml_

      ```yaml
      ResolutionPrecedence:
          # This is a High-Level Policy
          - Projects\$($Node.ProjectPresence)\$($Node.Project)
          # This is an intermediate level policy. Note that $Node.ProjectArea dictates that there potentially are multiple projects that fall under a "Project Area"
          # These can be specified under a higher level policy.
          - ProjectPolicies\$(Node.ProjectArea)\GitPermissions            
          - ProjectPolicies\$(Node.ProjectArea)\GitRepositories
          - ProjectPolicies\$(Node.ProjectArea)\ProjectGroups
          # This is a Low-Level policy.
          - ProjectPolicies\Project
          - OrganizationPolicies\OrganizationGroups
          - OrganizationPolicies\Organization
      ```

      > __Please Note:__ Lower-level configurations take precedence over higher-level configurations. In the event of a conflict, datum will default to the lower-level settings.

      _`($Node.Project).yaml`_

      ```yaml
      # The Project Area can be specified within the end user yaml file.
      ProjectArea: CustomProjectArea

      parameters: {}

      variables: {
          ProjectDescription: 'Custom Magenta Project. Contact Name: John Doe.',
          ProjectRepositoryName: 'CON_Configuration',
          Project_Service_GitRepositories: 'enabled',
          Project_Service_BuildPipelines: 'enabled',
          Project_Service_AzureArtifact: 'enabled'
      }
      ```

   1. __Higher-Level Rules__ describe lower-level areas and project-specific settings.

      > __Note:__ Please keep changes within the project YAML configuration to a minimum. This ensures that the project does not become a 'snowflake' and remains consistent with established standards and practices. By minimizing deviations, we maintain uniformity across projects, facilitating easier maintenance, scalability, and collaboration among team members. This approach also reduces the risk of introducing unique complexities that could complicate future updates or integrations.

   1. Please note that any adjustments should adhere to the established hierarchy and rules.
   1. As a general guideline, __AVOID__ altering `lookup_options` unless you are fully aware of the implications.

1. __Store the Configuration within the Respective Code Environment:__

   - Ensure that all configuration files and settings are securely stored within the appropriate code environment to maintain consistency and security.
   - Use environment-specific directories or repositories to manage configurations, ensuring easy access and version control.

1. __(Azure DevOps only) Setup Dsc.PipelineRunner using a Self-Hosted Agent within the CI/CD Pipeline:__

   - Follow the detailed instructions provided in the [Azure DevOps Agents Documentation](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/agents?view=azure-devops) to configure your self-hosted agent.
   - __If Using Managed Identity within Azure Arc:__
     - Verify that the Agent Pool service is executed under an administrator account to ensure proper permissions and functionality.
   - __Grant Permissions for Identity within Azure DevOps (AZDO):__
     - __Using Managed Identity (Virtual Machine):__  
       Refer to the [Managed Identities Overview](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview) for steps on enabling managed identity on virtual machines.
     - __Using Managed Identity for Azure Arc:__  
       Managed identity is already configured. Add the computer account into the Project Collection Administrators group to grant necessary permissions.
     - __If Using Personal Access Token (PAT):__  
       Add the custom identity to Azure DevOps and generate a PAT to authenticate and authorize actions within the pipeline.

1. __Ensure that the Agent Pools have required dependencies__

    Ensure that the Agent Pool is equipped with all necessary PowerShell module dependencies as specified in the module manifest file [`source\Dsc.PipelineRunner.psd1`](.\source\Dsc.PipelineRunner.psd1). The core module's required modules are:

    | Module | Version Constraint |
    |---|---|
    | `PSDesiredStateConfiguration` | `>= 2.0.0` |
    | `powershell-yaml` | `<= 1.0.0` |
    | `datum` | `<= 1.0.0` |
    | `Datum.InvokeCommand` | `<= 1.0.0` |

    Azure DevOps support is **not** a core dependency — it is an opt-in `Connect` action
    (`Actions/Connect/AzureDevOps.ps1`) that imports the following modules on demand.
    Install them only if you use `Invoke-DscPipelineRunner`, or `Invoke-DscRunner -Connect AzureDevOps`:

    | Module | Version Constraint |
    |---|---|
    | `AzureDevOpsDsc.Common` | `<= 1.0.0` |
    | `AzureDevOpsDscNative` | `<= 1.0.0` |

    To install any of these modules, execute the following command for each module listed above:

    ```powershell
    Install-Module -Name ModuleName
    ```

    __Process:__

    1. __Review the Module Manifest:__
    - Open the `source\Dsc.PipelineRunner.psd1` file to identify all modules listed under the `RequiredModules` section.
    - Take note of each module name and version specified.

    1. __Install Each Module:__
    - For every module identified, run the `Install-Module` command in a PowerShell session with administrative privileges. Replace `ModuleName` with the actual name of the module you wish to install.
    - Example:

        ```powershell
        Install-Module -Name ModuleName
        ```

    1. __Verify Installation:__
    - After installing each module, confirm its presence by running:

        ```powershell
        Get-Module -ListAvailable -Name ModuleName
        ```

    - This command will list the installed modules and their versions, ensuring they match those required by the manifest.

    1. __Update Modules if Necessary:__
    - If any module is outdated, update it using:

        ```powershell
        Update-Module -Name ModuleName
        ```

    1. __Check Compatibility:__
    - Ensure that the installed modules are compatible with your system and other installed software to prevent conflicts or errors during execution.

    By following these steps, you will ensure that your Agent Pool is fully prepared with all necessary PowerShell dependencies, facilitating seamless operation of your Azure DevOps pipelines.

    > Please Note: Maintaining the correct versioning is crucial to prevent pipeline runner compilation errors. Before proceeding with any updates, always verify that the `PipelineRunnerSettings` within `Datum.yml` are within the ranges enforced by the module. The pipeline runner will reject any configuration that does not meet the specified versioning criteria.

1. __Setup the CI/CD Pipeline:__

    Create a pipeline that calls `Invoke-DscPipelineRunner` on your self-hosted agent. A minimal pipeline looks like:

    ```yaml
    trigger:
      - main

    pool:
      name: SelfHosted

    steps:
      - pwsh: |
          $env:PIPELINERUNNER_CACHE_DIRECTORY = "$(Agent.TempDirectory)\PipelineRunnerCache"
          New-Item -Path $env:PIPELINERUNNER_CACHE_DIRECTORY -ItemType Directory -Force | Out-Null

          Import-Module Dsc.PipelineRunner

          Invoke-DscPipelineRunner `
            -AzureDevopsOrganizationName "$(OrganizationName)" `
            -ExportConfigDir "$(Agent.TempDirectory)\ExportedConfig" `
            -ConfigurationSourcePath "$(ConfigurationRepoUrl)" `
            -JITToken "$(System.AccessToken)" `
            -Mode "Set"
        displayName: 'Apply DSC Configuration'
    ```

    The exported config directory must exist before calling `Invoke-DscPipelineRunner`:

    ```powershell
    New-Item -Path "$(Agent.TempDirectory)\ExportedConfig" -ItemType Directory -Force
    ```

    1. __Test to Ensure the Pipeline Runner is Running Correctly:__

    - __Set the Pipeline Runner Mode to Test:__
        - Pass `-Mode Test` to validate configuration changes without applying them immediately.
    - __Look for Runtime Errors:__
        - Monitor pipeline logs for any runtime errors or warnings that could indicate misconfigurations or issues needing resolution.
    - __Verify Expected Outcomes:__
        - Conduct thorough testing to confirm that the pipeline runner behaves as expected, making adjustments as necessary to address any discrepancies or failures.
    - __Review the CSV Report:__
        - If `-ReportPath` is specified, a per-project CSV report is generated containing the pass/fail/skipped status for every resource. Review this output to verify all resources reached their desired state.

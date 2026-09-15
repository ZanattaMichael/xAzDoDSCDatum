Describe "Expand-NotifyDependsOn" -Tag Unit, Runner, Rules, Notify {

    BeforeAll {

        # Load the functions to test
        $customTaskFilePath = (Get-FunctionPath 'Expand-NotifyDependsOn.ps1').FullName

    }

    It "should return nothing when no resources are supplied" {
        $expandedResources = . $customTaskFilePath -PipelineResources @()
        $expandedResources | Should -BeNullOrEmpty
    }

    It "should leave resources without a Notify property unchanged" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @(); Notify = $null },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @(); Notify = $null }
        )

        $expandedResources = . $customTaskFilePath -PipelineResources $resources

        $expandedResources[0].DependsOn | Should -BeNullOrEmpty
        $expandedResources[1].DependsOn | Should -BeNullOrEmpty
    }

    It "should add an implicit DependsOn on the notifying resource to its notify target" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @(); Notify = 'Module/Resource/Task2' },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @() }
        )

        $expandedResources = . $customTaskFilePath -PipelineResources $resources

        ($expandedResources | Where-Object Name -eq 'Task2').DependsOn | Should -Contain 'Module/Resource/Task1'
    }

    It "should support an array of notify targets" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @(); Notify = @('Module/Resource/Task2', 'Module/Resource/Task3') },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @() },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task3'; DependsOn = @() }
        )

        $expandedResources = . $customTaskFilePath -PipelineResources $resources

        ($expandedResources | Where-Object Name -eq 'Task2').DependsOn | Should -Contain 'Module/Resource/Task1'
        ($expandedResources | Where-Object Name -eq 'Task3').DependsOn | Should -Contain 'Module/Resource/Task1'
    }

    It "should not duplicate an existing DependsOn entry already naming the notifier" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @(); Notify = 'Module/Resource/Task2' },
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task1') }
        )

        $expandedResources = . $customTaskFilePath -PipelineResources $resources

        @(($expandedResources | Where-Object Name -eq 'Task2').DependsOn) | Should -Be @('Module/Resource/Task1')
    }

    It "should throw when a resource notifies itself" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @(); Notify = 'Module/Resource/Task1' }
        )

        { . $customTaskFilePath -PipelineResources $resources } | Should -Throw "*cannot notify itself*"
    }

    It "should throw when a resource notifies a target that does not exist" {
        $resources = @(
            [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @(); Notify = 'Module/Resource/Missing' }
        )

        { . $customTaskFilePath -PipelineResources $resources } | Should -Throw "*not present in the configuration*"
    }
}

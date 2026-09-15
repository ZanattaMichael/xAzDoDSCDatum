Describe "using Function Tests" -Tag Unit, Runner {

    BeforeAll {
        . (Get-FunctionPath 'using.ps1').FullName
    }

    BeforeEach {
        $script:notifyDeclarations = @{}
        $script:resourceOutputs = @{}
        $script:currentResourceKey = $null
    }

    # Called via the underlying invoke-using function rather than the 'using' alias:
    # 'using' is a PowerShell reserved word at the start of a statement (the `using
    # module/namespace/assembly` directive), so the alias can only be invoked from inside an
    # outer expression - e.g. $((using 'X').Property) in a property value, exactly as
    # documented in README.md/docs/notify-and-using.md - never as a bare statement, which is
    # what a direct call here would otherwise be.

    It "returns the source resource's Get() output when the caller is a declared notify target" {
        $script:notifyDeclarations['Module/Resource/Source'] = @('Module/Resource/Caller')
        $script:resourceOutputs['Module/Resource/Source'] = [pscustomobject]@{ Property = 'Value' }
        $script:currentResourceKey = 'Module/Resource/Caller'

        $result = invoke-using -Name 'Module/Resource/Source'

        $result.Property | Should -Be 'Value'
    }

    It "throws when the source resource has no notify declaration" {
        $script:currentResourceKey = 'Module/Resource/Caller'

        { invoke-using -Name 'Module/Resource/Source' } | Should -Throw "*has no 'notify' declaration*"
    }

    It "throws when the source resource does not notify the calling resource" {
        $script:notifyDeclarations['Module/Resource/Source'] = @('Module/Resource/SomeoneElse')
        $script:resourceOutputs['Module/Resource/Source'] = [pscustomobject]@{ Property = 'Value' }
        $script:currentResourceKey = 'Module/Resource/Caller'

        { invoke-using -Name 'Module/Resource/Source' } | Should -Throw "*does not notify*"
    }

    It "throws when the source resource has not produced Get() output yet" {
        $script:notifyDeclarations['Module/Resource/Source'] = @('Module/Resource/Caller')
        $script:currentResourceKey = 'Module/Resource/Caller'

        { invoke-using -Name 'Module/Resource/Source' } | Should -Throw "*has not produced Get() output yet*"
    }

    It "is callable via the 'using' alias when wrapped in an outer expression" {
        $script:notifyDeclarations['Module/Resource/Source'] = @('Module/Resource/Caller')
        $script:resourceOutputs['Module/Resource/Source'] = [pscustomobject]@{ Property = 'Value' }
        $script:currentResourceKey = 'Module/Resource/Caller'

        # Mirrors real usage: 'using' is a reserved word at statement-start, so it is always
        # wrapped, e.g. $((using 'Type/Name').Property) inside a property value.
        $result = $((using 'Module/Resource/Source').Property)

        $result | Should -Be 'Value'
    }
}

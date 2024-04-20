using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Initialize PS script
$StatusCode = [HttpStatusCode]::OK
$Resp = ConvertTo-Json @()

# Get query parameters to search non assigned number based on location - OPTIONAL parameter
$Location = $Request.Query.Location

Import-TeamsModule

Try {
    Connect-Teams
}
Catch {
    $Resp = @{ "Error" = $_.Exception.Message }
    $StatusCode =  [HttpStatusCode]::BadGateway
    Write-Error $_
}

# Get unassigned telephone numbers
If ($StatusCode -eq [HttpStatusCode]::OK) {
    Try {
        # $Resp = Get-CsOnlineTelephoneNumber -IsNotAssigned -InventoryType Subscriber -ErrorAction:Stop | Select-Object -Property Id,@{Name='Number';Expression={"+" + [string]$_.Id}},CityCode,@{Name='Country';Expression={If((-not([string]::IsNullOrEmpty($_.CityCode)))){($_.CityCode -Split "-")[1]}Else{$null}}},ActivationState
        $Resp = Get-CsPhoneNumberAssignment -NumberType CallingPlan -CapabilitiesContain UserAssignment -PstnAssignmentStatus Unassigned -ErrorAction:Stop | Select-Object -Property @{Name='Id';Expression={[string]$_.TelephoneNumber}},@{Name='Number';Expression={[string]$_.TelephoneNumber}},CityCode,@{Name='Country';Expression={[string]$_.IsoCountryCode}},ActivationState
        If ([string]::IsNullOrEmpty($Location)){
            $Resp = $Resp |  ConvertTo-Json
        }
        Else {
            $Resp = $Resp | Where-Object {$_.Country -eq $Location} | ConvertTo-Json
        }
    }
    Catch {
        $Resp = @{ "Error" = $_.Exception.Message }
        $StatusCode =  [HttpStatusCode]::BadGateway
        Write-Error $_
    }
}


# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $StatusCode
    ContentType = 'application/json'
    Body = $Resp
})

Disconnect-MicrosoftTeams
Get-PSSession | Remove-PSSession

# Trap all other exceptions that may occur at runtime and EXIT Azure Function
Trap {
    Write-Error $_
    Disconnect-MicrosoftTeams
    break
}

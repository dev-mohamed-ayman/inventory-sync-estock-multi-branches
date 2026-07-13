# Test API: Send branch array directly
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $PSScriptRoot "config.json"
$Config = Get-Content $ConfigFile | ConvertFrom-Json

Write-Host "======================================"
Write-Host "  Testing: Send branch array directly"
Write-Host "======================================"
Write-Host ""

$Headers = @{
    "X-API-KEY" = $Config.apiKey
    "Content-Type" = "application/json"
}

# Test: Send array directly
$Test3Payload = @(
    @{
        branch_code = "1"
        active = "Y"
        branch_name = "الصفتي"
        branch_address = ""
        branch_mobile = ""
        branch_tel = ""
        products = @(
            @{
                code = "1"
                name_en = "ELECTRICIAN"
                name_ar = "قياس ضغط"
                price = 5
                quantity = 869
                international_barcode = ""
            }
        )
    }
)
$Test3Json = $Test3Payload | ConvertTo-Json -Depth 10
Write-Host "Payload: $Test3Json"
try {
    $Test3Response = Invoke-RestMethod -Uri $Config.apiUrl -Method Post -Headers $Headers -Body ([System.Text.Encoding]::UTF8.GetBytes($Test3Json)) -TimeoutSec $Config.requestTimeoutSeconds
    Write-Host "Test 3 SUCCESS! Response:" -ForegroundColor Green
    Write-Host ($Test3Response | ConvertTo-Json -Compress)
} catch {
    Write-Host "Test 3 FAILED" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $ErrorResponse = $Reader.ReadToEnd()
        Write-Host "API Response: $ErrorResponse"
    }
}

Write-Host ""
Read-Host "Press Enter to exit"

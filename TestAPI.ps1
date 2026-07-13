# Test API Payload Structures
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $PSScriptRoot "config.json"
$Config = Get-Content $ConfigFile | ConvertFrom-Json

Write-Host "======================================"
Write-Host "  Testing API Payload Structures"
Write-Host "======================================"
Write-Host ""

$Headers = @{
    "X-API-KEY" = $Config.apiKey
    "Content-Type" = "application/json"
}

# Test 1: The structure we were sending (branches array)
Write-Host "Test 1: Sending payload with 'branches' field"
$Test1Payload = @{
    branches = @(
        @{
            branch_id = 1
            branch_code = "1"
            branch_name = "Test Branch"
            active = "Y"
            products = @(
                @{
                    code = "1"
                    name_en = "Test Product"
                    price = 5
                    quantity = 10
                    international_barcode = ""
                }
            )
        }
    )
}
$Test1Json = $Test1Payload | ConvertTo-Json -Depth 10
Write-Host "Payload: $Test1Json"
try {
    $Test1Response = Invoke-RestMethod -Uri $Config.apiUrl -Method Post -Headers $Headers -Body ([System.Text.Encoding]::UTF8.GetBytes($Test1Json)) -TimeoutSec $Config.requestTimeoutSeconds
    Write-Host "Test 1 SUCCESS! Response:" -ForegroundColor Green
    Write-Host ($Test1Response | ConvertTo-Json -Compress)
} catch {
    Write-Host "Test 1 FAILED" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $ErrorResponse = $Reader.ReadToEnd()
        Write-Host "API Response: $ErrorResponse"
    }
}
Write-Host ""

# Test 2: Sending payload with just 'products' field
Write-Host "Test 2: Sending payload with 'products' field only"
$Test2Payload = @{
    products = @(
        @{
            code = "1"
            name_en = "Test Product"
            price = 5
            quantity = 10
            international_barcode = ""
        }
    )
}
$Test2Json = $Test2Payload | ConvertTo-Json -Depth 10
Write-Host "Payload: $Test2Json"
try {
    $Test2Response = Invoke-RestMethod -Uri $Config.apiUrl -Method Post -Headers $Headers -Body ([System.Text.Encoding]::UTF8.GetBytes($Test2Json)) -TimeoutSec $Config.requestTimeoutSeconds
    Write-Host "Test 2 SUCCESS! Response:" -ForegroundColor Green
    Write-Host ($Test2Response | ConvertTo-Json -Compress)
} catch {
    Write-Host "Test 2 FAILED" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $ErrorResponse = $Reader.ReadToEnd()
        Write-Host "API Response: $ErrorResponse"
    }
}

Write-Host ""
Read-Host "Press Enter to exit"

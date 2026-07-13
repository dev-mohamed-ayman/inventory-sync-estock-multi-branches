# Check Branches Table Script
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $PSScriptRoot "config.json"
$Config = Get-Content $ConfigFile | ConvertFrom-Json

Write-Host "======================================"
Write-Host "  Checking Branches Table"
Write-Host "======================================"
Write-Host ""

Write-Host "Connecting to SQL Server..."
if ([string]::IsNullOrWhiteSpace($Config.username)) {
    $ConnectionString = "Server=$($Config.sqlServer);Database=$($Config.database);Integrated Security=True;Connect Timeout=30;"
} else {
    $ConnectionString = "Server=$($Config.sqlServer);Database=$($Config.database);User ID=$($Config.username);Password=$($Config.password);Connect Timeout=30;"
}

$Connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)

try {
    $Connection.Open()
    Write-Host "✅ Connected successfully!"
    Write-Host ""
    
    Write-Host "--- Querying Branches table ---"
    $Query = @"
SELECT 
    branch_id,
    branch_code,
    branch_name,
    active,
    is_server
FROM Branches
"@
    
    $Cmd = $Connection.CreateCommand()
    $Cmd.CommandText = $Query
    $Adapter = New-Object System.Data.SqlClient.SqlDataAdapter($Cmd)
    $Table = New-Object System.Data.DataTable
    [void]$Adapter.Fill($Table)
    
    Write-Host "Total rows in Branches: $($Table.Rows.Count)"
    Write-Host ""
    
    if ($Table.Rows.Count -eq 0) {
        Write-Host "❌ No rows found in Branches table!" -ForegroundColor Red
    } else {
        Write-Host "Branches found:" -ForegroundColor Green
        Write-Host "----------------------------------------"
        foreach ($Row in $Table.Rows) {
            Write-Host "Branch ID: $($Row.branch_id)"
            Write-Host "  Code: $($Row.branch_code)"
            Write-Host "  Name: $($Row.branch_name)"
            Write-Host "  Active: $($Row.active)"
            Write-Host "  Is Server: $($Row.is_server)"
            Write-Host "----------------------------------------"
        }
    }
    
    Write-Host ""
    Write-Host "--- Also checking distinct branch_id from Branches_Product_Amount ---"
    $BPQuery = "SELECT DISTINCT branch_id FROM Branches_Product_Amount ORDER BY branch_id"
    $BPCmd = $Connection.CreateCommand()
    $BPCmd.CommandText = $BPQuery
    $BPAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($BPCmd)
    $BPTable = New-Object System.Data.DataTable
    [void]$BPAdapter.Fill($BPTable)
    
    Write-Host "Distinct branch_id in Branches_Product_Amount: $($BPTable.Rows.Count)"
    if ($BPTable.Rows.Count -gt 0) {
        Write-Host "Branch IDs: $($BPTable.Rows.branch_id -join ', ')"
    }
    
} catch {
    Write-Host "❌ Error: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    $Connection.Close()
}

Write-Host ""
Read-Host "Press Enter to exit"

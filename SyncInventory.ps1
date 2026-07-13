# Pharmacy Inventory Sync Agent
# Created for: Max Pharmacy
# Version: 2.0.0 - Sums quantities from all branches

# Force TLS 1.2+ for SSL/TLS connections
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $PSScriptRoot "config.json"
$LogFile = Join-Path $PSScriptRoot "logs\sync.log"

# --- Logging Functions ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    $LogEntry | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

function Clear-Log {
    if (Test-Path $LogFile) {
        Remove-Item $LogFile -Force
    }
    $LogDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
}

# --- Initialization ---
try {
    Clear-Log
    Write-Log "Starting Pharmacy Inventory Sync Agent..."
    $StartTime = Get-Date

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file not found: $ConfigFile"
    }

    $Config = Get-Content $ConfigFile | ConvertFrom-Json
    Write-Log "Configuration loaded successfully."

    if ($Config.password -eq "your_password") {
        Write-Log "WARNING: You are using the default password in config.json. Please update it." -Level "WARNING"
    }

    # --- SQL Connection ---
    Write-Log "Connecting to SQL Server: $($Config.sqlServer)..."
    
    if ([string]::IsNullOrWhiteSpace($Config.username)) {
        Write-Log "Using Windows Authentication (Integrated Security)."
        $ConnectionString = "Server=$($Config.sqlServer);Database=$($Config.database);Integrated Security=True;Connect Timeout=30;"
    } else {
        Write-Log "Using SQL Server Authentication (User: $($Config.username))."
        $ConnectionString = "Server=$($Config.sqlServer);Database=$($Config.database);User ID=$($Config.username);Password=$($Config.password);Connect Timeout=30;"
    }
    $Connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    
    try {
        $Connection.Open()
        Write-Log "SQL Connection Status: SUCCESS"
    } catch {
        Write-Log "SQL Connection Status: FAILED" -Level "ERROR"
        throw "Failed to connect to SQL Server: $($_.Exception.Message)"
    }

    # --- Load all products from all branches and sum quantities ---
    Write-Log "Loading products from all branches..."
    
    $ProductsHash = @{}
    
    # First: Get products from Branches_Product_Amount
    $BranchProductsQuery = @"
SELECT 
    p.product_id,
    p.product_code AS code,
    p.product_name_ar AS name_ar,
    p.product_name_en AS name_en,
    CAST(p.sell_price AS FLOAT) AS price,
    SUM(CAST(bpa.amount AS FLOAT)) AS quantity,
    p.product_int_code AS international_barcode
FROM Products p
INNER JOIN Branches_Product_Amount bpa ON p.product_id = bpa.product_id
WHERE ISNULL(p.deleted, 'N') != 'Y'
GROUP BY p.product_id, p.product_code, p.product_name_ar, 
         p.product_name_en, p.sell_price, p.product_int_code
"@
    $BranchProductsCmd = $Connection.CreateCommand()
    $BranchProductsCmd.CommandText = $BranchProductsQuery
    $BranchProductsAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($BranchProductsCmd)
    $BranchProductsTable = New-Object System.Data.DataTable
    [void]$BranchProductsAdapter.Fill($BranchProductsTable)
    
    Write-Log "Loaded $($BranchProductsTable.Rows.Count) product entries from branches"

    foreach ($Row in $BranchProductsTable.Rows) {
        $ProductCode = if ($Row.code -ne [DBNull]::Value) { $Row.code.ToString().Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($ProductCode)) { continue }
        
        $Quantity = [int][Math]::Floor([double]$Row.quantity)
        
        if (-not $ProductsHash.ContainsKey($ProductCode)) {
            $ProductNameAr = if ($Row.name_ar -ne [DBNull]::Value) { $Row.name_ar.ToString().Trim() } else { "" }
            $ProductNameEn = if ($Row.name_en -ne [DBNull]::Value) { $Row.name_en.ToString().Trim() } else { "" }
            if ([string]::IsNullOrWhiteSpace($ProductNameEn) -and [string]::IsNullOrWhiteSpace($ProductNameAr)) {
                $ProductNameEn = "Product $ProductCode"
            }
            
            $ProductsHash[$ProductCode] = @{
                code = $ProductCode
                price = [double]$Row.price
                quantity = $Quantity
                international_barcode = if ($Row.international_barcode -ne [DBNull]::Value) { $Row.international_barcode.ToString().Trim() } else { "" }
            }
            
            if (-not [string]::IsNullOrWhiteSpace($ProductNameAr)) {
                $ProductsHash[$ProductCode]["name_ar"] = $ProductNameAr
            }
            if (-not [string]::IsNullOrWhiteSpace($ProductNameEn)) {
                $ProductsHash[$ProductCode]["name_en"] = $ProductNameEn
            }
        } else {
            $ProductsHash[$ProductCode].quantity += $Quantity
        }
    }

    # Second: Get products from Product_Amount (server branch) and add them
    $ServerProductsQuery = @"
SELECT 
    p.product_id,
    p.product_code AS code,
    p.product_name_ar AS name_ar,
    p.product_name_en AS name_en,
    CAST(p.sell_price AS FLOAT) AS price,
    SUM(CAST(pa.amount AS FLOAT)) AS quantity,
    p.product_int_code AS international_barcode
FROM Products p
INNER JOIN Product_Amount pa ON p.product_id = pa.product_id
WHERE ISNULL(p.deleted, 'N') != 'Y'
GROUP BY p.product_id, p.product_code, p.product_name_ar, 
         p.product_name_en, p.sell_price, p.product_int_code
"@
    $ServerProductsCmd = $Connection.CreateCommand()
    $ServerProductsCmd.CommandText = $ServerProductsQuery
    $ServerProductsAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($ServerProductsCmd)
    $ServerProductsTable = New-Object System.Data.DataTable
    [void]$ServerProductsAdapter.Fill($ServerProductsTable)
    
    Write-Log "Loaded $($ServerProductsTable.Rows.Count) product entries from server branch"

    foreach ($Row in $ServerProductsTable.Rows) {
        $ProductCode = if ($Row.code -ne [DBNull]::Value) { $Row.code.ToString().Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($ProductCode)) { continue }
        
        $Quantity = [int][Math]::Floor([double]$Row.quantity)
        
        if (-not $ProductsHash.ContainsKey($ProductCode)) {
            $ProductNameAr = if ($Row.name_ar -ne [DBNull]::Value) { $Row.name_ar.ToString().Trim() } else { "" }
            $ProductNameEn = if ($Row.name_en -ne [DBNull]::Value) { $Row.name_en.ToString().Trim() } else { "" }
            if ([string]::IsNullOrWhiteSpace($ProductNameEn) -and [string]::IsNullOrWhiteSpace($ProductNameAr)) {
                $ProductNameEn = "Product $ProductCode"
            }
            
            $ProductsHash[$ProductCode] = @{
                code = $ProductCode
                price = [double]$Row.price
                quantity = $Quantity
                international_barcode = if ($Row.international_barcode -ne [DBNull]::Value) { $Row.international_barcode.ToString().Trim() } else { "" }
            }
            
            if (-not [string]::IsNullOrWhiteSpace($ProductNameAr)) {
                $ProductsHash[$ProductCode]["name_ar"] = $ProductNameAr
            }
            if (-not [string]::IsNullOrWhiteSpace($ProductNameEn)) {
                $ProductsHash[$ProductCode]["name_en"] = $ProductNameEn
            }
        } else {
            $ProductsHash[$ProductCode].quantity += $Quantity
        }
    }

    $ProductsList = $ProductsHash.Values | Where-Object { $_.quantity -gt 0 }
    Write-Log "Total products with stock > 0: $($ProductsList.Count)"

    # --- Prepare and send to API ---
    if ($ProductsList.Count -eq 0) {
        Write-Log "No products with stock to sync."
    } else {
        Write-Log "Preparing data for API..."
        
        $Headers = @{
            "X-API-KEY" = $Config.apiKey
            "Content-Type" = "application/json"
        }
        
        $PayloadObject = @{
            products = $ProductsList
        }
        $Payload = $PayloadObject | ConvertTo-Json -Depth 10
        $BodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
        
        try {
            Write-Log "Sending data to API..."
            $Response = Invoke-RestMethod -Uri $Config.apiUrl -Method Post -Headers $Headers -Body $BodyBytes -TimeoutSec $Config.requestTimeoutSeconds
            
            Write-Log "SUCCESS: Data sent to API"
            Write-Log "API Response: $($Response | ConvertTo-Json -Compress)"
        } catch {
            $StatusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            Write-Log "FAILED - HTTP Status Code: $StatusCode" -Level "ERROR"
            Write-Log "API Error: $($_.Exception.Message)" -Level "ERROR"
            
            if ($_.Exception.Response) {
                $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $ErrorResponse = $Reader.ReadToEnd()
                Write-Log "API Error Response: $ErrorResponse" -Level "ERROR"
            }
        }
    }

    $Connection.Close()
    
    $EndTime = Get-Date
    $Duration = $EndTime - $StartTime
    Write-Log "End Time: $($EndTime.ToString("yyyy-MM-dd HH:mm:ss"))"
    Write-Log "Duration: $($Duration.TotalSeconds) seconds"
    Write-Log "Sync completed successfully."

} catch {
    Write-Log "CRITICAL ERROR: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Full Exception Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    Write-Host "`n--------------------------------------------------" -ForegroundColor Red
    Write-Host "ERROR DETECTED!" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host "--------------------------------------------------`n" -ForegroundColor Red
    
    Read-Host "Press Enter To Exit"
    exit 1
} finally {
    if ($Connection -and $Connection.State -eq "Open") {
        $Connection.Close()
    }
}

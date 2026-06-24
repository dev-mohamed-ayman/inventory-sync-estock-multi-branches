# Pharmacy Inventory Sync Agent
# Created for: Max Pharmacy
# Version: 1.0.0

# Force TLS 1.2+ for SSL/TLS connections (fix for "Could not create SSL/TLS secure channel" error)
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
    # Create directory if not exists
    $LogDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force
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

    # --- Step 1: Identify Server Branch ---
    Write-Log "Identifying server (main) branch..."
    
    $ServerBranchQuery = @"
SELECT TOP 1 branch_id FROM co_inf WHERE branch_id IS NOT NULL
"@
    $ServerBranchCmd = $Connection.CreateCommand()
    $ServerBranchCmd.CommandText = $ServerBranchQuery
    $ServerBranchId = $ServerBranchCmd.ExecuteScalar()
    
    if ($ServerBranchId -ne $null) {
        Write-Log "Server Branch ID: $ServerBranchId"
    } else {
        Write-Log "Could not identify server branch from co_inf, will try Branches.is_server" -Level "WARNING"
        $ServerBranchFallbackQuery = "SELECT TOP 1 branch_id FROM Branches WHERE is_server = 'Y'"
        $ServerBranchFallbackCmd = $Connection.CreateCommand()
        $ServerBranchFallbackCmd.CommandText = $ServerBranchFallbackQuery
        $ServerBranchId = $ServerBranchFallbackCmd.ExecuteScalar()
        if ($ServerBranchId -ne $null) {
            Write-Log "Server Branch ID (from Branches.is_server): $ServerBranchId"
        } else {
            Write-Log "Could not identify server branch. Server branch stock will be skipped." -Level "WARNING"
        }
    }

    # --- Step 2: Load All Active Branches ---
    Write-Log "Loading active branches..."
    
    $BranchesQuery = @"
SELECT 
    b.branch_id,
    b.branch_code,
    b.branch_name,
    b.branch_address,
    b.branch_tel,
    b.branch_mobile,
    b.active,
    b.is_server,
    b.barcode_name,
    b.barcode_tel
FROM Branches b
WHERE ISNULL(b.active, 'Y') = 'Y'
"@
    $BranchesCmd = $Connection.CreateCommand()
    $BranchesCmd.CommandText = $BranchesQuery
    $BranchesAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($BranchesCmd)
    $BranchesTable = New-Object System.Data.DataTable
    [void]$BranchesAdapter.Fill($BranchesTable)
    
    Write-Log "Number Of Active Branches: $($BranchesTable.Rows.Count)"

    # --- Step 3: Load Products Stock Per Branch (Branches_Product_Amount) ---
    Write-Log "Loading branch products stock (Branches_Product_Amount)..."
    
    $BranchProductsQuery = @"
SELECT 
    bpa.branch_id,
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
GROUP BY bpa.branch_id, p.product_id, p.product_code, p.product_name_ar, 
         p.product_name_en, p.sell_price, p.product_int_code
HAVING SUM(CAST(bpa.amount AS FLOAT)) > 0
"@
    $BranchProductsCmd = $Connection.CreateCommand()
    $BranchProductsCmd.CommandText = $BranchProductsQuery
    $BranchProductsAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($BranchProductsCmd)
    $BranchProductsTable = New-Object System.Data.DataTable
    [void]$BranchProductsAdapter.Fill($BranchProductsTable)
    
    Write-Log "Branch product stock rows loaded: $($BranchProductsTable.Rows.Count)"

    # --- Step 4: Load Server Branch Products Stock (Product_Amount) ---
    $ServerProductsTable = New-Object System.Data.DataTable
    if ($ServerBranchId -ne $null) {
        Write-Log "Loading server branch products stock (Product_Amount)..."
        
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
HAVING SUM(CAST(pa.amount AS FLOAT)) > 0
"@
        $ServerProductsCmd = $Connection.CreateCommand()
        $ServerProductsCmd.CommandText = $ServerProductsQuery
        $ServerProductsAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($ServerProductsCmd)
        [void]$ServerProductsAdapter.Fill($ServerProductsTable)
        
        Write-Log "Server branch products with stock > 0: $($ServerProductsTable.Rows.Count)"
    }

    # --- Step 5: Build Branch-Based Data Structure ---
    Write-Log "Building branch-based data structure..."
    
    # Helper function to build a product object
    function Build-ProductObject {
        param($Row)
        
        $ProductCode = if ($Row.code -ne [DBNull]::Value) { $Row.code.ToString().Trim() } else { "" }
        $ProductNameAr = if ($Row.name_ar -ne [DBNull]::Value) { $Row.name_ar.ToString().Trim() } else { "" }
        $ProductNameEn = if ($Row.name_en -ne [DBNull]::Value) { $Row.name_en.ToString().Trim() } else { "" }
        
        # Skip product if it has no code
        if ([string]::IsNullOrWhiteSpace($ProductCode)) {
            return $null
        }

        $Product = @{
            code = $ProductCode
            price = [double]$Row.price
            quantity = [int][Math]::Floor([double]$Row.quantity)
            international_barcode = if ($Row.international_barcode -ne [DBNull]::Value) { $Row.international_barcode.ToString().Trim() } else { "" }
            image = ""
        }
        
        # Add name_ar if it's not empty
        if (-not [string]::IsNullOrWhiteSpace($ProductNameAr)) {
            $Product["name_ar"] = $ProductNameAr
        }
        
        # Add name_en if it's not empty
        if (-not [string]::IsNullOrWhiteSpace($ProductNameEn)) {
            $Product["name_en"] = $ProductNameEn
        }
        
        # If both names are empty, use code as fallback
        if ([string]::IsNullOrWhiteSpace($ProductNameAr) -and [string]::IsNullOrWhiteSpace($ProductNameEn)) {
            $Product["name_en"] = "Product " + $ProductCode
        }
        
        return $Product
    }

    # Index branch products by branch_id for fast lookup
    $BranchProductsIndex = @{}
    foreach ($Row in $BranchProductsTable.Rows) {
        $BrId = [int]$Row.branch_id
        $ProductObj = Build-ProductObject -Row $Row
        if ($ProductObj -ne $null) {
            if (-not $BranchProductsIndex.ContainsKey($BrId)) {
                $BranchProductsIndex[$BrId] = New-Object System.Collections.Generic.List[Object]
            }
            $BranchProductsIndex[$BrId].Add($ProductObj)
        }
    }

    # Build branches list
    $BranchesList = New-Object System.Collections.Generic.List[Object]
    $TotalProductsCount = 0

    foreach ($BranchRow in $BranchesTable.Rows) {
        $BranchId = [int]$BranchRow.branch_id
        $IsServerBranch = ($ServerBranchId -ne $null -and $BranchId -eq [int]$ServerBranchId)
        
        # Get products for this branch
        $Products = New-Object System.Collections.Generic.List[Object]
        
        if ($IsServerBranch) {
            # Server branch: use Product_Amount data
            foreach ($Row in $ServerProductsTable.Rows) {
                $ProductObj = Build-ProductObject -Row $Row
                if ($ProductObj -ne $null) {
                    $Products.Add($ProductObj)
                }
            }
        }
        
        # Also add products from Branches_Product_Amount (if any exist for this branch)
        if ($BranchProductsIndex.ContainsKey($BranchId)) {
            foreach ($ProductObj in $BranchProductsIndex[$BranchId]) {
                $Products.Add($ProductObj)
            }
        }
        
        # Skip branches with no products
        if ($Products.Count -eq 0) {
            Write-Log "Skipping branch '$($BranchRow.branch_name)' (ID: $BranchId) - no products with stock > 0"
            continue
        }
        
        $TotalProductsCount += $Products.Count
        
        $BranchObject = @{
            branch_id    = $BranchId
            branch_code  = if ($BranchRow.branch_code -ne [DBNull]::Value) { $BranchRow.branch_code.ToString().Trim() } else { "" }
            branch_name  = if ($BranchRow.branch_name -ne [DBNull]::Value) { $BranchRow.branch_name.ToString().Trim() } else { "" }
            branch_address = if ($BranchRow.branch_address -ne [DBNull]::Value) { $BranchRow.branch_address.ToString().Trim() } else { "" }
            branch_tel   = if ($BranchRow.branch_tel -ne [DBNull]::Value) { $BranchRow.branch_tel.ToString().Trim() } else { "" }
            branch_mobile = if ($BranchRow.branch_mobile -ne [DBNull]::Value) { $BranchRow.branch_mobile.ToString().Trim() } else { "" }
            active       = if ($BranchRow.active -ne [DBNull]::Value) { $BranchRow.active.ToString().Trim() } else { "Y" }
            products     = $Products
        }
        
        $BranchesList.Add($BranchObject)
        Write-Log "Branch '$($BranchObject.branch_name)' (ID: $BranchId): $($Products.Count) products"
    }

    Write-Log "Total branches with products: $($BranchesList.Count)"
    Write-Log "Total products across all branches: $TotalProductsCount"

    if ($BranchesList.Count -eq 0) {
        Write-Log "No branches with products found to sync."
    } else {
        # --- API Sync ---
        Write-Log "Preparing data for API..."
        
        $BatchSize = 10  # Number of branches per batch
        $TotalBatches = [Math]::Ceiling($BranchesList.Count / $BatchSize)
        Write-Log "Splitting into $TotalBatches batches of $BatchSize branches each..."
        
        $Headers = @{
            "X-API-KEY" = $Config.apiKey
            "Content-Type" = "application/json"
        }
        
        $SuccessBranches = 0
        $FailedBranches = 0
        
        for ($i = 0; $i -lt $TotalBatches; $i++) {
            $Start = $i * $BatchSize
            $End = [Math]::Min(($i + 1) * $BatchSize - 1, $BranchesList.Count - 1)
            $Batch = $BranchesList[$Start..$End]
            
            $BatchProductsCount = ($Batch | ForEach-Object { $_.products.Count } | Measure-Object -Sum).Sum
            Write-Log "Processing Batch $($i + 1)/$TotalBatches ($($Batch.Count) branches, $BatchProductsCount products)..."
            
            $PayloadObject = @{
                branches = $Batch
            }
            $Payload = $PayloadObject | ConvertTo-Json -Depth 10
            $BodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
            
            try {
                Write-Log "Sending Batch $($i + 1) to API..."
                $Response = Invoke-RestMethod -Uri $Config.apiUrl -Method Post -Headers $Headers -Body $BodyBytes -TimeoutSec $Config.requestTimeoutSeconds
                
                Write-Log "Batch $($i + 1) SUCCESS"
                Write-Log "API Response: $($Response | ConvertTo-Json -Compress)"
                $SuccessBranches += $Batch.Count
            } catch {
                $StatusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                Write-Log "Batch $($i + 1) FAILED - HTTP Status Code: $StatusCode" -Level "ERROR"
                Write-Log "API Error: $($_.Exception.Message)" -Level "ERROR"
                
                if ($_.Exception.Response) {
                    $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $ErrorResponse = $Reader.ReadToEnd()
                    Write-Log "API Error Response: $ErrorResponse" -Level "ERROR"
                }
                $FailedBranches += $Batch.Count
            }
            
            # Small delay between batches to avoid overwhelming the server
            Start-Sleep -Milliseconds 500
        }
        
        Write-Log "Sync Summary: Successfully sent $SuccessBranches branches, Failed: $FailedBranches"
        if ($FailedBranches -gt 0) {
            Write-Log "Some batches failed. Check logs above for details." -Level "WARNING"
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

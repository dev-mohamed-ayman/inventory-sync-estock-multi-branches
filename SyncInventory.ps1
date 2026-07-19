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

    # --- Load all branches and their products ---
    Write-Log "Loading branches and products..."
    
    # --- Step 1: Identify Server Branch ---
    Write-Log "Identifying server (main) branch..."
    $ServerBranchQuery = @"
SELECT TOP 1 branch_id FROM co_inf WHERE branch_id IS NOT NULL
"@
    $ServerBranchCmd = $Connection.CreateCommand()
    $ServerBranchCmd.CommandText = $ServerBranchQuery
    $ServerBranchId = $ServerBranchCmd.ExecuteScalar()
    
    Write-Log "Server Branch ID: $ServerBranchId"

    # --- Step 2: Load All Branches ---
    Write-Log "Loading branches..."
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
"@
    $BranchesCmd = $Connection.CreateCommand()
    $BranchesCmd.CommandText = $BranchesQuery
    $BranchesAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($BranchesCmd)
    $BranchesTable = New-Object System.Data.DataTable
    [void]$BranchesAdapter.Fill($BranchesTable)
    
    Write-Log "Number Of Branches: $($BranchesTable.Rows.Count)"

    # --- Step 3: Load Products Stock Per Branch ---
    Write-Log "Loading branch products stock..."
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

    # --- Step 4: Load Server Branch Products Stock ---
    $ServerProductsTable = New-Object System.Data.DataTable
    if ($ServerBranchId -ne $null) {
        Write-Log "Loading server branch products stock..."
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
    function Build-ProductObject {
        param($Row)
        $ProductCode = if ($Row.code -ne [DBNull]::Value) { $Row.code.ToString().Trim() } else { "" }
        $ProductNameAr = if ($Row.name_ar -ne [DBNull]::Value) { $Row.name_ar.ToString().Trim() } else { "" }
        $ProductNameEn = if ($Row.name_en -ne [DBNull]::Value) { $Row.name_en.ToString().Trim() } else { "" }
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
        if (-not [string]::IsNullOrWhiteSpace($ProductNameAr)) {
            $Product["name_ar"] = $ProductNameAr
        }
        if (-not [string]::IsNullOrWhiteSpace($ProductNameEn)) {
            $Product["name_en"] = $ProductNameEn
        }
        if ([string]::IsNullOrWhiteSpace($ProductNameAr) -and [string]::IsNullOrWhiteSpace($ProductNameEn)) {
            $Product["name_en"] = "Product " + $ProductCode
        }
        return $Product
    }
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
    $BranchesList = New-Object System.Collections.Generic.List[Object]
    $TotalProductsCount = 0
    foreach ($BranchRow in $BranchesTable.Rows) {
        $BranchId = [int]$BranchRow.branch_id
        $IsServerBranch = ($ServerBranchId -ne $null -and $BranchId -eq [int]$ServerBranchId)
        $Products = New-Object System.Collections.Generic.List[Object]
        if ($IsServerBranch) {
            foreach ($Row in $ServerProductsTable.Rows) {
                $ProductObj = Build-ProductObject -Row $Row
                if ($ProductObj -ne $null) {
                    $Products.Add($ProductObj)
                }
            }
        }
        if ($BranchProductsIndex.ContainsKey($BranchId)) {
            foreach ($ProductObj in $BranchProductsIndex[$BranchId]) {
                $Products.Add($ProductObj)
            }
        }
        if ($Products.Count -eq 0) {
            continue
        }
        $TotalProductsCount += $Products.Count
        
        # Get and normalize active field
        $RawActive = if ($BranchRow.active -ne [DBNull]::Value) { $BranchRow.active.ToString().Trim() } else { "" }
        Write-Log "Branch '$($BranchRow.branch_name)' raw active value: '$RawActive'"
        
        $NormalizedActive = "Y"
        if ($RawActive -eq "0" -or $RawActive -eq "N" -or $RawActive -eq "n" -or $RawActive -eq "False" -or $RawActive -eq "false") {
            $NormalizedActive = "N"
        } elseif ($RawActive -eq "1" -or $RawActive -eq "Y" -or $RawActive -eq "y" -or $RawActive -eq "True" -or $RawActive -eq "true" -or $RawActive -eq "") {
            $NormalizedActive = "Y"
        }
        
        $BranchObject = @{
            code  = if ($BranchRow.branch_code -ne [DBNull]::Value) { $BranchRow.branch_code.ToString().Trim() } else { "" }
            name  = if ($BranchRow.branch_name -ne [DBNull]::Value) { $BranchRow.branch_name.ToString().Trim() } else { "" }
            address = if ($BranchRow.branch_address -ne [DBNull]::Value) { $BranchRow.branch_address.ToString().Trim() } else { "" }
            phone   = if ($BranchRow.branch_tel -ne [DBNull]::Value) { $BranchRow.branch_tel.ToString().Trim() } else { if ($BranchRow.branch_mobile -ne [DBNull]::Value) { $BranchRow.branch_mobile.ToString().Trim() } else { "" } }
            products     = $Products
        }
        $BranchesList.Add($BranchObject)
        Write-Log "Branch '$($BranchObject.name)' (Code: $($BranchObject.code)): $($Products.Count) products"
    }
    Write-Log "Total branches with products: $($BranchesList.Count)"
    Write-Log "Total products across all branches: $TotalProductsCount"

    # --- Prepare and send to API (split into product chunks) ---
    if ($BranchesList.Count -eq 0) {
        Write-Log "No branches with products to sync."
    } else {
        $Headers = @{
            "X-API-KEY" = $Config.apiKey
            "Content-Type" = "application/json"
        }
        
        $chunkSize = 1000
        $totalSuccessfulChunks = 0
        $totalFailedChunks = 0
        
        foreach ($Branch in $BranchesList) {
            $BranchName = $Branch.name
            Write-Log "Processing branch: $BranchName (total products: $($Branch.products.Count))"
            
            # Split products into chunks
            $productChunks = @()
            $currentChunk = @()
            foreach ($product in $Branch.products) {
                $currentChunk += $product
                if ($currentChunk.Count -ge $chunkSize) {
                    $productChunks += ,$currentChunk
                    $currentChunk = @()
                }
            }
            if ($currentChunk.Count -gt 0) {
                $productChunks += ,$currentChunk
            }
            
            Write-Log "Branch '$BranchName' split into $($productChunks.Count) chunks"
            
            $branchSuccessfulChunks = 0
            $branchFailedChunks = 0
            
            for ($i = 0; $i -lt $productChunks.Count; $i++) {
                $chunkIndex = $i + 1
                try {
                    Write-Log "Preparing and sending chunk $chunkIndex/$($productChunks.Count) for branch: $BranchName"
                    
                    # Create branch copy with current chunk products
                    $BranchChunk = @{
                        code = $Branch.code
                        name = $Branch.name
                        address = $Branch.address
                        phone = $Branch.phone
                        products = $productChunks[$i]
                    }
                    
                    $PayloadObject = @{
                        branches = @($BranchChunk)
                    }
                    $Payload = $PayloadObject | ConvertTo-Json -Depth 10
                    Write-Log "Payload for $BranchName (chunk $chunkIndex) - first 500 chars: $($Payload.Substring(0, [Math]::Min(500, $Payload.Length)))"
                    $BodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
                    
                    Write-Log "Sending chunk $chunkIndex for branch '$BranchName' to API..."
                    $Response = Invoke-RestMethod -Uri $Config.apiUrl -Method Post -Headers $Headers -Body $BodyBytes -TimeoutSec $Config.requestTimeoutSeconds
                    
                    Write-Log "SUCCESS: Chunk $chunkIndex for branch '$BranchName' sent to API"
                    Write-Log "API Response: $($Response | ConvertTo-Json -Compress)"
                    $branchSuccessfulChunks++
                    $totalSuccessfulChunks++
                } catch {
                    $StatusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    Write-Log "FAILED - Chunk $chunkIndex for branch '$BranchName' - HTTP Status Code: $StatusCode" -Level "ERROR"
                    Write-Log "API Error: $($_.Exception.Message)" -Level "ERROR"
                    
                    if ($_.Exception.Response) {
                        $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                        $ErrorResponse = $Reader.ReadToEnd()
                        Write-Log "API Error Response: $ErrorResponse" -Level "ERROR"
                    }
                    $branchFailedChunks++
                    $totalFailedChunks++
                }
            }
            
            Write-Log "Branch '$BranchName' complete: $branchSuccessfulChunks chunks succeeded, $branchFailedChunks chunks failed."
        }
        
        Write-Log "Sync complete: $totalSuccessfulChunks chunks succeeded, $totalFailedChunks chunks failed."
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

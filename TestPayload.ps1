# Test Payload Generation
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $PSScriptRoot "config.json"
$Config = Get-Content $ConfigFile | ConvertFrom-Json

Write-Host "======================================"
Write-Host "  Testing Payload Generation"
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
    
    # --- Step 1: Identify Server Branch ---
    Write-Host "Identifying server (main) branch..."
    $ServerBranchQuery = @"
SELECT TOP 1 branch_id FROM co_inf WHERE branch_id IS NOT NULL
"@
    $ServerBranchCmd = $Connection.CreateCommand()
    $ServerBranchCmd.CommandText = $ServerBranchQuery
    $ServerBranchId = $ServerBranchCmd.ExecuteScalar()
    
    Write-Host "Server Branch ID: $ServerBranchId"
    Write-Host ""

    # --- Step 2: Load All Branches ---
    Write-Host "Loading branches..."
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
    
    Write-Host "Number Of Branches: $($BranchesTable.Rows.Count)"
    Write-Host ""

    # --- Step 3: Load Products Stock Per Branch ---
    Write-Host "Loading branch products stock..."
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
    
    Write-Host "Branch product stock rows loaded: $($BranchProductsTable.Rows.Count)"
    Write-Host ""

    # --- Step 4: Load Server Branch Products Stock ---
    $ServerProductsTable = New-Object System.Data.DataTable
    if ($ServerBranchId -ne $null) {
        Write-Host "Loading server branch products stock..."
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
        
        Write-Host "Server branch products with stock > 0: $($ServerProductsTable.Rows.Count)"
        Write-Host ""
    }

    # --- Step 5: Build Branch-Based Data Structure ---
    Write-Host "Building branch-based data structure..."
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
        Write-Host "Branch '$($BranchObject.branch_name)' (ID: $BranchId): $($Products.Count) products"
    }
    Write-Host ""
    Write-Host "Total branches with products: $($BranchesList.Count)"
    Write-Host "Total products across all branches: $TotalProductsCount"
    Write-Host ""

    # --- Save Sample Payload ---
    Write-Host "Saving sample payload..."
    $PayloadObject = @{
        branches = $BranchesList
    }
    $SamplePayloadPath = Join-Path $PSScriptRoot "sample-payload.json"
    $PayloadObject | ConvertTo-Json -Depth 10 | Out-File -FilePath $SamplePayloadPath -Encoding UTF8
    Write-Host "Sample payload saved to: $SamplePayloadPath"

} catch {
    Write-Host "❌ Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
} finally {
    $Connection.Close()
}

Write-Host ""
Read-Host "Press Enter to exit"

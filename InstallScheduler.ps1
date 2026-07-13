# Install Scheduler for Pharmacy Inventory Sync
# This script creates a Windows Scheduled Task to run the sync script automatically.

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $PSScriptRoot "config.json"
$SyncScript = Join-Path $PSScriptRoot "SyncInventory.ps1"

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration file not found: $ConfigFile"
    Read-Host "Press Enter To Exit"
    exit 1
}

$Config = Get-Content $ConfigFile | ConvertFrom-Json
$Interval = $Config.syncIntervalMinutes

if (-not $Interval) {
    $Interval = 120 # Default to 120 minutes if not specified
}

$TaskName = "PharmacyInventorySync"

Write-Host "=================================================="
Write-Host "  Pharmacy Inventory Sync - Scheduler Installer"
Write-Host "=================================================="
Write-Host ""
Write-Host "Task Name: $TaskName"
Write-Host "Interval: Every $Interval minutes"
Write-Host "Script: $SyncScript"
Write-Host ""

try {
    # Check if ScheduledTasks module is available (Windows 8.1/Server 2012 R2 and later)
    if (Get-Module -ListAvailable -Name ScheduledTasks) {
        Import-Module ScheduledTasks

        # Check if task already exists
        $ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($ExistingTask) {
            Write-Host "Found existing scheduled task: $TaskName" -ForegroundColor Yellow
            Write-Host "Deleting existing task..." -ForegroundColor Yellow
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Existing task deleted successfully!" -ForegroundColor Green
            Write-Host ""
        }

        # Create the action
        $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SyncScript`""

        # Create the trigger
        $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $Interval)

        # Create principal to run as SYSTEM
        $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

        # Register the task
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Force | Out-Null

        Write-Host "`nScheduled Task created successfully!" -ForegroundColor Green
        Write-Host "The sync will run automatically every $Interval minutes."
    } else {
        # Fallback to schtasks.exe with proper quoting
        Write-Host "Using schtasks.exe for compatibility..."
        
        # Check if task already exists using schtasks
        $CheckTask = schtasks /Query /TN $TaskName 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Found existing scheduled task: $TaskName" -ForegroundColor Yellow
            Write-Host "Deleting existing task..." -ForegroundColor Yellow
            schtasks /Delete /TN $TaskName /F | Out-Null
            Write-Host "Existing task deleted successfully!" -ForegroundColor Green
            Write-Host ""
        }

        # For schtasks.exe, we need to escape quotes properly:
        # - Escape internal quotes with backslashes
        # - Enclose the entire command in quotes
        $EscapedScriptPath = $SyncScript -replace '"', '\"'
        $FullCommand = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$EscapedScriptPath`""
        
        # Use schtasks with /F to overwrite if exists (but we already deleted it, just to be safe)
        schtasks /Create /TN $TaskName /TR "`"$FullCommand`"" /SC MINUTE /MO $Interval /RU SYSTEM /F

        if ($LASTEXITCODE -eq 0) {
            Write-Host "`nScheduled Task created successfully!" -ForegroundColor Green
            Write-Host "The sync will run automatically every $Interval minutes."
        } else {
            Write-Host "`nFailed to create Scheduled Task. Ensure you are running as Administrator." -ForegroundColor Red
        }
    }
} catch {
    Write-Host "`nAn error occurred: $($_.Exception.Message)" -ForegroundColor Red
}

Read-Host "`nPress Enter To Exit"

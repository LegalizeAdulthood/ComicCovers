# sync-comics-to-phone.ps1
# Synchronizes a local directory to the DCIM\Comics folder on an Android phone via MTP

param(
    [Parameter(Mandatory=$false)]
    [string]$LocalPath,
    
    [Parameter(Mandatory=$true)]
    [string]$PhoneName,
    
    [Parameter(Mandatory=$false)]
    [string[]]$ExcludeFolders = @("Purchased"),

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [switch]$MoveOrphans,

    [Parameter(Mandatory=$false)]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$Count = 0
)

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($LocalPath)) {
    $LocalPath = Join-Path $scriptRoot "pictures"
}

# Validate local path exists
if (-not (Test-Path -LiteralPath $LocalPath)) {
    Write-Host "Error: Local path '$LocalPath' does not exist"
    exit 1
}

Write-Host "Synchronizing '$LocalPath' to phone DCIM\Comics folder..."
if ($DryRun) {
    Write-Host "Dry run: no files or folders will be changed on the phone."
    if ($Count -gt 0) {
        Write-Host "Dry run stops after first $Count planned change(s)."
    }
}
elseif ($Count -gt 0) {
    Write-Host "Real sync stops after first $Count phone filesystem operation(s)."
}
if ($MoveOrphans) {
    Write-Host "Orphan handling enabled: phone-only .jpg files may be moved to Purchased."
}
else {
    Write-Host "Orphan handling disabled: phone-only files will be left in place."
}
if ($ExcludeFolders.Count -gt 0) {
    Write-Host "Excluding folders: $($ExcludeFolders -join ', ')"
}
Write-Host ""

$script:plannedChanges = 0

function Write-DryRunChange {
    param(
        [string]$Message
    )

    $script:plannedChanges++
    Write-Host "[DRY-RUN] $Message"

    if ($DryRun -and $Count -gt 0 -and $script:plannedChanges -ge $Count) {
        throw "COUNT_LIMIT_REACHED"
    }
}

function Test-DryRunLimitException {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    return $Count -gt 0 -and $ErrorRecord.Exception.Message -eq "COUNT_LIMIT_REACHED"
}

function Assert-PhoneChangeCapacity {
    param([int]$RequiredOperations = 1)

    if ($Count -gt 0 -and ($script:plannedChanges + $RequiredOperations) -gt $Count) {
        throw "COUNT_LIMIT_REACHED"
    }
}

function Invoke-PhoneChange {
    param([scriptblock]$Action)

    Assert-PhoneChangeCapacity
    $script:plannedChanges++
    & $Action
}

function Join-DisplayPath {
    param(
        [string]$Parent,
        [string]$Child
    )

    if ($Parent) {
        return "$Parent\$Child"
    }
    return $Child
}

function Test-ExcludedPath {
    param(
        [string]$RelativePath,
        [string]$Name
    )

    $normalizedPath = Normalize-ItemName $RelativePath
    $normalizedName = Normalize-ItemName $Name

    foreach ($excludePattern in $ExcludeFolders) {
        $normalizedPattern = Normalize-ItemName $excludePattern
        if ($normalizedPath -like "*$normalizedPattern*" -or $normalizedName -eq $normalizedPattern) {
            return $true
        }
    }
    return $false
}

function Normalize-ItemName {
    param([string]$Name)

    if ($null -eq $Name) {
        return ""
    }

    return $Name.Trim().Normalize([Text.NormalizationForm]::FormC).ToUpperInvariant()
}

function Normalize-CoverFileIdentity {
    param([string]$Name)

    $baseName = [IO.Path]::GetFileNameWithoutExtension($Name)
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        return ""
    }

    $match = [regex]::Match($baseName, '^(?<title>.+?)\([0-9]+\)#(?<issue>.+)$')
    if ($match.Success) {
        return Normalize-ItemName "$($match.Groups['title'].Value)#$($match.Groups['issue'].Value)"
    }

    return Normalize-ItemName $baseName
}

function Test-ShellItemIsFolder {
    param([object]$Item)

    try {
        return [bool]$Item.IsFolder
    }
    catch {
    }

    try {
        $null = $Item.GetFolder
        return $true
    }
    catch {
        return $false
    }
}

function Find-ShellItemByName {
    param(
        [object]$Folder,
        [string]$Name,
        [switch]$FoldersOnly,
        [switch]$FilesOnly
    )

    $targetNames = @(Normalize-ItemName $Name)
    $targetCoverIdentity = if ($FilesOnly) { Normalize-CoverFileIdentity $Name } else { "" }
    $parseNames = @($Name, $Name.ToLowerInvariant(), $Name.ToUpperInvariant())
    if ($FilesOnly) {
        $nameWithoutExtension = [IO.Path]::GetFileNameWithoutExtension($Name)
        if ($nameWithoutExtension) {
            $targetNames += Normalize-ItemName $nameWithoutExtension
            $parseNames += @($nameWithoutExtension, $nameWithoutExtension.ToLowerInvariant(), $nameWithoutExtension.ToUpperInvariant())
        }
    }
    $targetNames = $targetNames | Select-Object -Unique
    $parseNames = $parseNames | Select-Object -Unique

    foreach ($parseName in $parseNames) {
        try {
            $parsed = $Folder.ParseName($parseName)
            if ($parsed) {
                $parsedIsFolder = Test-ShellItemIsFolder $parsed
                if ($FoldersOnly -and -not $parsedIsFolder) {
                    continue
                }
                if ($FilesOnly -and $parsedIsFolder) {
                    continue
                }
                if (($targetNames -contains (Normalize-ItemName $parsed.Name)) -or
                    ($FilesOnly -and $targetCoverIdentity -and (Normalize-CoverFileIdentity $parsed.Name) -eq $targetCoverIdentity)) {
                    return $parsed
                }
            }
        }
        catch {
        }
    }

    $matches = @()

    foreach ($item in $Folder.Items()) {
        $itemIsFolder = Test-ShellItemIsFolder $item
        if ($FoldersOnly -and -not $itemIsFolder) {
            continue
        }
        if ($FilesOnly -and $itemIsFolder) {
            continue
        }
        if (($targetNames -contains (Normalize-ItemName $item.Name)) -or
            ($FilesOnly -and $targetCoverIdentity -and (Normalize-CoverFileIdentity $item.Name) -eq $targetCoverIdentity)) {
            $matches += $item
        }
    }

    if ($matches.Count -gt 1) {
        Write-Host "Warning: Found multiple phone items matching '$Name'; using '$($matches[0].Name)'."
    }

    return $matches | Select-Object -First 1
}

function Find-LocalChildByName {
    param(
        [string]$SourcePath,
        [string]$Name,
        [ValidateSet("Directory", "File")]
        [string]$Type
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return $null
    }

    $targetName = Normalize-ItemName $Name
    $items = if ($Type -eq "Directory") {
        Get-ChildItem -LiteralPath $SourcePath -Directory -ErrorAction SilentlyContinue
    }
    else {
        Get-ChildItem -LiteralPath $SourcePath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq ".jpg" }
    }

    $matches = @($items | Where-Object { (Normalize-ItemName $_.Name) -eq $targetName })
    if ($matches.Count -gt 1) {
        Write-Host "Warning: Found multiple local $Type items matching '$Name' in '$SourcePath'; using '$($matches[0].Name)'."
    }

    return $matches | Select-Object -First 1
}

function Add-IgnoredTopLevelFolder {
    param([string]$Name)

    $key = Normalize-ItemName $Name
    if ($key -and -not $script:ignoredTopLevelFolders.ContainsKey($key)) {
        $script:ignoredTopLevelFolders[$key] = $Name
    }
}

# Create Shell.Application COM object
$shell = New-Object -ComObject Shell.Application

# Get "This PC" folder
$computer = $shell.Namespace(17)

# Find the phone
$phone = $computer.Items() | Where-Object { 
    $_.Name -match $PhoneName -or $_.Type -eq "Portable Device" 
} | Select-Object -First 1

if (-not $phone) {
    Write-Host "Error: Phone '$PhoneName' not found. Available devices:"
    $computer.Items() | ForEach-Object { 
        Write-Host "  - $($_.Name) (Type: $($_.Type))"
    }
 exit 1
}

# Navigate to Internal Storage
$phoneFolder = $phone.GetFolder
$storage = $phoneFolder.Items() | Where-Object { 
    $_.Name -match "Internal" -or $_.Name -match "Phone" -or $_.Name -match "Card"
} | Select-Object -First 1

if (-not $storage) {
    Write-Host "Error: Could not find internal storage on $($phone.Name)"
    Write-Host "Available storage locations:"
 $phoneFolder.Items() | ForEach-Object { 
    Write-Host "  - $($_.Name)"
    }
    exit 1
}

# Find DCIM folder
$storageFolder = $storage.GetFolder
$dcim = Find-ShellItemByName -Folder $storageFolder -Name "DCIM" -FoldersOnly

if (-not $dcim) {
    Write-Host "Error: DCIM folder not found on $($phone.Name)"
    Write-Host "Available folders:"
    $storageFolder.Items() | ForEach-Object { 
        Write-Host "  - $($_.Name)"
  }
    exit 1
}

# Find Comics folder inside DCIM
$dcimFolder = $dcim.GetFolder
$comics = Find-ShellItemByName -Folder $dcimFolder -Name "Comics" -FoldersOnly

if (-not $comics) {
    Write-Host "Error: Comics folder not found in DCIM on $($phone.Name)"
    Write-Host "Please create the 'Comics' folder in DCIM manually on your phone, then run this script again."
    exit 1
}

# Get the Comics folder namespace
$comicsFolder = $comics.GetFolder

# Global variable to track Purchased folder (created once if needed)
$script:purchasedFolder = $null
$script:purchasedFolderName = "Purchased"

# Global list to track empty directories on the phone
$script:emptyDirectories = @()

# Same-named folders directly under DCIM are stale/incorrect locations. They
# are reported for cleanup, but never used as sync destinations or file matches.
$script:ignoredTopLevelFolders = @{}

# Function to ensure Purchased folder exists
function Get-PurchasedFolder {
    param([object]$ComicsFolder)
    
    if ($null -eq $script:purchasedFolder) {
        $purchased = Find-ShellItemByName -Folder $ComicsFolder -Name "Purchased" -FoldersOnly
        
        if (-not $purchased) {
            Write-Host "Warning: Purchased folder not found in the phone's DCIM\Comics filesystem view."
            Write-Host "         Orphaned files will be left in place; create the folder manually if needed."
            return $null
        }
        
        $script:purchasedFolder = $purchased.GetFolder
        $script:purchasedFolderName = $purchased.Name
    }
    
    return $script:purchasedFolder
}

# Function to move all files from a folder to Purchased
function Move-FolderContents {
    param(
        [object]$SourceFolder,
        [string]$FolderName,
        [object]$ComicsFolder,
        [int]$Level = 0
    )
    
 $indent = "  " * $Level
    $purchasedFolder = Get-PurchasedFolder -ComicsFolder $ComicsFolder
    
    if (-not $purchasedFolder) {
        Write-Host "$indent  Cannot move files - Purchased folder unavailable"
        return $false
  }
  
    $items = $SourceFolder.Items()
    $fileCount = 0
    
    foreach ($item in $items) {
        if (-not (Test-ShellItemIsFolder $item)) {
         # Only process .jpg files
            if ($item.Name -notlike "*.jpg") {
 continue
      }
         
     $fileCount++
        try {
      # Check if file already exists in Purchased
     $existingInPurchased = Find-ShellItemByName -Folder $purchasedFolder -Name $item.Name -FilesOnly

        if ($DryRun) {
            if ($existingInPurchased) {
                Write-DryRunChange "Would delete existing $script:purchasedFolderName\$($existingInPurchased.Name) before overwrite"
            }
            Write-DryRunChange "Would move orphaned file '$FolderName\$($item.Name)' to $script:purchasedFolderName"
            continue
        }
      
        if ($existingInPurchased) {
            Assert-PhoneChangeCapacity -RequiredOperations 2
                # Delete existing file to allow overwrite
try {
         Invoke-PhoneChange { $existingInPurchased.InvokeVerb("delete") }
               Start-Sleep -Milliseconds 200
     }
     catch {
         if (Test-DryRunLimitException $_) { throw }
         Write-Host "$indent  Warning: Could not delete existing file, attempting overwrite..."
                    }
                }
                
                # Move file (0x10 = Yes to All, 0x4 = No UI, 0x400 = No progress)
        Invoke-PhoneChange { $purchasedFolder.MoveHere($item, 0x414) }
       Start-Sleep -Milliseconds 300
    }
            catch {
    if (Test-DryRunLimitException $_) { throw }
    Write-Host "$indent  Failed to move $($item.Name): $($_.Exception.Message)"
            }
   }
    }
    
    if ($fileCount -gt 0 -and -not $DryRun) {
        Write-Host "$indent  Moved $fileCount file(s) to Purchased"
    }
    
    return $true
}

# Function to check for orphaned directories and files
function Process-OrphanedItems {
    param(
        [string]$SourcePath,
        [object]$DestFolder,
        [object]$ComicsFolder,
        [int]$Level = 0,
[string]$RelativePath = ""
    )
    
    $indent = "  " * $Level
    
    # Get all items on the phone in this folder
    $phoneItems = $DestFolder.Items()
    
    foreach ($phoneItem in $phoneItems) {
        if (Test-ShellItemIsFolder $phoneItem) {
            # Check if this is an excluded folder
            $currentRelPath = if ($RelativePath) { "$RelativePath\$($phoneItem.Name)" } else { $phoneItem.Name }
            
   if (Test-ExcludedPath -RelativePath $currentRelPath -Name $phoneItem.Name) {
   continue  # Skip excluded folders
   }

# Check if this folder exists locally
       $localFolder = Find-LocalChildByName -SourcePath $SourcePath -Name $phoneItem.Name -Type Directory
 if ($localFolder) {
   # Recurse into matching folders
  $phoneSubFolder = $phoneItem.GetFolder
     Process-OrphanedItems -SourcePath $localFolder.FullName -DestFolder $phoneSubFolder -ComicsFolder $ComicsFolder -Level ($Level + 1) -RelativePath $currentRelPath
         }
   else {
 # Directory exists on phone but not locally - move contents
          if (-not $DryRun) {
          Write-Host "$indent[DIR] $($phoneItem.Name) - Not in local directory"
          }
        $phoneSubFolder = $phoneItem.GetFolder
 
    if (Move-FolderContents -SourceFolder $phoneSubFolder -FolderName $currentRelPath -ComicsFolder $ComicsFolder -Level ($Level + 1)) {
  # Track this empty directory
           if (-not $DryRun) {
           $emptyDirPath = if ($currentRelPath) { $currentRelPath } else { $phoneItem.Name }
     $script:emptyDirectories += $emptyDirPath
    Write-Host "$indent  (Empty directory - listed for manual cleanup)"
    }
      }
    }
   }
        else {
    # It's a file - only process .jpg files
    if ($phoneItem.Name -notlike "*.jpg") {
  continue
        }
 
     # Check if it exists locally
     $localFile = Find-LocalChildByName -SourcePath $SourcePath -Name $phoneItem.Name -Type File
            
     if (-not $localFile) {
         # File exists on phone but not locally - move to Purchased
         if (-not $DryRun) {
         Write-Host "$indent[FILE] $($phoneItem.Name) - Orphaned, moving to Purchased..."
         }
     
     $purchasedFolder = Get-PurchasedFolder -ComicsFolder $ComicsFolder
                
if ($purchasedFolder) {
          try {
   # Check if file already exists in Purchased
    $existingInPurchased = Find-ShellItemByName -Folder $purchasedFolder -Name $phoneItem.Name -FilesOnly

            if ($DryRun) {
                $displayPath = Join-DisplayPath -Parent $RelativePath -Child $phoneItem.Name
                if ($existingInPurchased) {
                    Write-DryRunChange "Would delete existing $script:purchasedFolderName\$($existingInPurchased.Name) before overwrite"
                }
                Write-DryRunChange "Would move orphaned file '$displayPath' to $script:purchasedFolderName"
                continue
            }
           
            if ($existingInPurchased) {
       Assert-PhoneChangeCapacity -RequiredOperations 2
       # Delete existing file to allow overwrite
      try {
   Invoke-PhoneChange { $existingInPurchased.InvokeVerb("delete") }
           Start-Sleep -Milliseconds 200
                 }
            catch {
               if (Test-DryRunLimitException $_) { throw }
               Write-Host "$indent  Warning: Could not delete existing file, attempting overwrite..."
        }
                  }
            
           # Move file
          Invoke-PhoneChange { $purchasedFolder.MoveHere($phoneItem, 0x414) }
   Start-Sleep -Milliseconds 300
         Write-Host "$indent  ? Moved to $script:purchasedFolderName"
              }
    catch {
    if (Test-DryRunLimitException $_) { throw }
    Write-Host "$indent  ? Failed to move: $($_.Exception.Message)"
       }
       }
   }
  }
    }
}

# Function to report a local subtree that would be copied when the phone folder is missing
function Report-WouldCopyTree {
    param(
        [string]$SourcePath,
        [int]$Level = 0,
        [string]$RelativePath = ""
    )

    $items = Get-ChildItem -LiteralPath $SourcePath

    foreach ($item in $items) {
        if ($item.PSIsContainer) {
            $currentRelPath = Join-DisplayPath -Parent $RelativePath -Child $item.Name
            if (Test-ExcludedPath -RelativePath $currentRelPath -Name $item.Name) {
                continue
            }

            Write-DryRunChange "Would create folder '$currentRelPath'"
            Report-WouldCopyTree -SourcePath $item.FullName -Level ($Level + 1) -RelativePath $currentRelPath
        }
        elseif ($item.Extension -eq ".jpg") {
            $filePath = Join-DisplayPath -Parent $RelativePath -Child $item.Name
            Write-DryRunChange "Would copy file '$filePath' ($([math]::Round($item.Length/1KB, 2)) KB)"
        }
    }
}

# Function to copy items recursively
function Copy-ToPhone {
    param(
        [string]$SourcePath,
        [object]$DestFolder,
        [object]$TopLevelDcimFolder = $null,
        [int]$Level = 0,
   [string]$RelativePath = ""
    )
    
    $indent = "  " * $Level
    $items = Get-ChildItem -LiteralPath $SourcePath

    foreach ($item in $items) {
        if ($item.PSIsContainer) {
        # It's a directory
 
          # Calculate relative path for exclusion check
  $currentRelPath = if ($RelativePath) { "$RelativePath\$($item.Name)" } else { $item.Name }
        
            # Check if this folder should be excluded
            if (Test-ExcludedPath -RelativePath $currentRelPath -Name $item.Name) {
          continue
  }
            
 # Check if folder exists on phone
            $existingFolder = Find-ShellItemByName -Folder $DestFolder -Name $item.Name -FoldersOnly

            if (-not $RelativePath -and $null -ne $TopLevelDcimFolder) {
                $topLevelFolder = Find-ShellItemByName -Folder $TopLevelDcimFolder -Name $item.Name -FoldersOnly
                if ($topLevelFolder -and ((Normalize-ItemName $topLevelFolder.Name) -ne (Normalize-ItemName "Comics"))) {
                    Add-IgnoredTopLevelFolder -Name $topLevelFolder.Name
                }
            }
   
         if (-not $existingFolder) {
    # Folder doesn't exist on phone - create it
   if ($DryRun) {
            Write-DryRunChange "Would create folder '$currentRelPath'"
            Report-WouldCopyTree -SourcePath $item.FullName -Level ($Level + 1) -RelativePath $currentRelPath
            continue
   }

   Write-Host "$indent[DIR] $($item.Name) - Creating..."
         try {
            Invoke-PhoneChange { $DestFolder.NewFolder($item.Name) }
         Start-Sleep -Milliseconds 500
  $existingFolder = Find-ShellItemByName -Folder $DestFolder -Name $item.Name -FoldersOnly
            Write-Host "$indent  ? Created"
           }
    catch {
   if (Test-DryRunLimitException $_) { throw }
   Write-Host "$indent  ? Failed to create: $($_.Exception.Message)"
     }
    }
          else {
     # Folder exists - just show status
            if (-not $DryRun) {
                Write-Host "$indent[DIR] $($item.Name)"
            }
       }
 
     if ($existingFolder) {
     # Recurse into subfolder
        $subFolder = $existingFolder.GetFolder
  Copy-ToPhone -SourcePath $item.FullName -DestFolder $subFolder -Level ($Level + 1) -RelativePath $currentRelPath
       }
  }
        else {
         # It's a file - only process .jpg files
          if ($item.Extension -ne ".jpg") {
             continue
     }
      
     # Check if file exists on phone
            $existingFile = Find-ShellItemByName -Folder $DestFolder -Name $item.Name -FilesOnly
          
     if ($existingFile) {
         # File already exists on phone - skip silently
        continue
            }
        else {
       # File doesn't exist - copy it
          if ($DryRun) {
            $displayPath = Join-DisplayPath -Parent $RelativePath -Child $item.Name
            Write-DryRunChange "Would copy file '$displayPath' ($([math]::Round($item.Length/1KB, 2)) KB)"
            continue
          }

          Write-Host "$indent[FILE] $($item.Name) ($([math]::Round($item.Length/1KB, 2)) KB) - Copying..."
   
                try {
    Invoke-PhoneChange { $DestFolder.CopyHere($item.FullName, 0x414) }
     Start-Sleep -Milliseconds 200
         Write-Host "$indent  ? Done"
       }
    catch {
         if (Test-DryRunLimitException $_) { throw }
         Write-Host "$indent  ? Failed: $($_.Exception.Message)"
       }
  }
        }
    }
}

# Start the sync
try {
    if ($MoveOrphans) {
        Write-Host ""
        Write-Host "Step 1: Processing orphaned items on phone..."
        Write-Host ""
        if (Get-PurchasedFolder -ComicsFolder $comicsFolder) {
            Process-OrphanedItems -SourcePath $LocalPath -DestFolder $comicsFolder -ComicsFolder $comicsFolder
        }
        else {
            Write-Host "Step 1 skipped because Purchased was not found in the MTP filesystem view."
        }
    }
    else {
        Write-Host ""
        Write-Host "Step 1: Skipping orphan handling."
    }

    Write-Host ""
    Write-Host "Step 2: Synchronizing local files to phone..."
    Write-Host ""
    Copy-ToPhone -SourcePath $LocalPath -DestFolder $comicsFolder -TopLevelDcimFolder $dcimFolder
    Write-Host ""
    if ($DryRun) {
        Write-Host "Dry run complete: $script:plannedChanges planned change(s) found."
        if ($Count -gt 0 -and $script:plannedChanges -gt $Count) {
            Write-Host "Displayed first $Count planned change(s)."
        }
    }
    else {
        Write-Host "Synchronization complete: $script:plannedChanges phone filesystem operation(s) attempted."
    }
}
catch {
    if (Test-DryRunLimitException $_) {
        Write-Host ""
        if ($DryRun) {
            Write-Host "Dry run stopped after first $Count planned change(s)."
        }
        else {
            Write-Host "Sync stopped after first $script:plannedChanges phone filesystem operation(s)."
        }
        exit 0
    }

    Write-Host ""
    Write-Host "Error during synchronization: $($_.Exception.Message)"
    exit 1
}

# List empty directories found on the phone
if ($script:emptyDirectories.Count -gt 0) {
    Write-Host ""
    Write-Host "Empty directories found on the phone:"
    foreach ($emptyDir in $script:emptyDirectories) {
        Write-Host "  - $emptyDir"
    }
    Write-Host "Note: Empty directories have been tracked but not deleted. You can remove them manually if desired."
}

if ($script:ignoredTopLevelFolders.Count -gt 0) {
    Write-Host ""
    Write-Host "Ignored same-named folders outside DCIM\Comics:"
    foreach ($folderName in ($script:ignoredTopLevelFolders.Values | Sort-Object)) {
        Write-Host "  - DCIM\$folderName"
    }
    Write-Host "These folders do not count as synced. Verify DCIM\Comics copies before deleting them."
}

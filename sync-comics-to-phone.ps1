# sync-comics-to-phone.ps1
# Synchronizes a local directory to the DCIM\Comics folder on an Android phone via MTP

param(
    [Parameter(Mandatory=$true)]
    [string]$LocalPath,
    
    [Parameter(Mandatory=$true)]
    [string]$PhoneName,
    
    [Parameter(Mandatory=$false)]
    [string[]]$ExcludeFolders = @("Purchased")
)

# Validate local path exists
if (-not (Test-Path $LocalPath)) {
    Write-Host "Error: Local path '$LocalPath' does not exist" -ForegroundColor Red
    exit 1
}

Write-Host "Synchronizing '$LocalPath' to phone DCIM\Comics folder..." -ForegroundColor Cyan
if ($ExcludeFolders.Count -gt 0) {
    Write-Host "Excluding folders: $($ExcludeFolders -join ', ')" -ForegroundColor Yellow
}
Write-Host ""

# Create Shell.Application COM object
$shell = New-Object -ComObject Shell.Application

# Get "This PC" folder
$computer = $shell.Namespace(17)

# Find the phone
$phone = $computer.Items() | Where-Object { 
    $_.Name -match $PhoneName -or $_.Type -eq "Portable Device" 
} | Select-Object -First 1

if (-not $phone) {
    Write-Host "Error: Phone '$PhoneName' not found. Available devices:" -ForegroundColor Red
    $computer.Items() | ForEach-Object { 
        Write-Host "  - $($_.Name) (Type: $($_.Type))" -ForegroundColor Gray
    }
 exit 1
}

# Navigate to Internal Storage
$phoneFolder = $phone.GetFolder
$storage = $phoneFolder.Items() | Where-Object { 
    $_.Name -match "Internal" -or $_.Name -match "Phone" -or $_.Name -match "Card"
} | Select-Object -First 1

if (-not $storage) {
    Write-Host "Error: Could not find internal storage on $($phone.Name)" -ForegroundColor Red
    Write-Host "Available storage locations:" -ForegroundColor Gray
 $phoneFolder.Items() | ForEach-Object { 
    Write-Host "  - $($_.Name)" -ForegroundColor Gray
    }
    exit 1
}

# Find DCIM folder
$storageFolder = $storage.GetFolder
$dcim = $storageFolder.Items() | Where-Object { $_.Name -eq "DCIM" }

if (-not $dcim) {
    Write-Host "Error: DCIM folder not found on $($phone.Name)" -ForegroundColor Red
    Write-Host "Available folders:" -ForegroundColor Gray
    $storageFolder.Items() | ForEach-Object { 
        Write-Host "  - $($_.Name)" -ForegroundColor Gray
  }
    exit 1
}

# Find Comics folder inside DCIM
$dcimFolder = $dcim.GetFolder
$comics = $dcimFolder.Items() | Where-Object { $_.Name -eq "Comics" }

if (-not $comics) {
    Write-Host "Error: Comics folder not found in DCIM on $($phone.Name)" -ForegroundColor Red
    Write-Host "Please create the 'Comics' folder in DCIM manually on your phone, then run this script again." -ForegroundColor Red
    exit 1
}

# Get the Comics folder namespace
$comicsFolder = $comics.GetFolder

# Global variable to track Purchased folder (created once if needed)
$script:purchasedFolder = $null

# Global list to track empty directories on the phone
$script:emptyDirectories = @()

# Function to ensure Purchased folder exists
function Get-PurchasedFolder {
    param([object]$ComicsFolder)
    
    if ($null -eq $script:purchasedFolder) {
        $purchased = $ComicsFolder.Items() | Where-Object { $_.Name -eq "Purchased" }
        
        if (-not $purchased) {
    Write-Host "Creating 'Purchased' folder..." -ForegroundColor Yellow
 try {
       $ComicsFolder.NewFolder("Purchased")
 Start-Sleep -Milliseconds 500
    $purchased = $ComicsFolder.Items() | Where-Object { $_.Name -eq "Purchased" }
          }
  catch {
          Write-Host "Warning: Could not create 'Purchased' folder: $($_.Exception.Message)" -ForegroundColor Red
                return $null
 }
        }
        
        if ($purchased) {
            $script:purchasedFolder = $purchased.GetFolder
        }
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
        Write-Host "$indent  Cannot move files - Purchased folder unavailable" -ForegroundColor Red
        return $false
  }
  
    $items = $SourceFolder.Items()
    $fileCount = 0
    
    foreach ($item in $items) {
        if (-not $item.IsFolder) {
         # Only process .jpg files
            if ($item.Name -notlike "*.jpg") {
 continue
      }
         
     $fileCount++
        try {
      # Check if file already exists in Purchased
     $existingInPurchased = $purchasedFolder.Items() | Where-Object { $_.Name -eq $item.Name }
      
        if ($existingInPurchased) {
                # Delete existing file to allow overwrite
try {
         $existingInPurchased.InvokeVerb("delete")
               Start-Sleep -Milliseconds 200
      }
     catch {
         Write-Host "$indent  Warning: Could not delete existing file, attempting overwrite..." -ForegroundColor Yellow
                    }
                }
                
                # Move file (0x10 = Yes to All, 0x4 = No UI, 0x400 = No progress)
        $purchasedFolder.MoveHere($item, 0x414)
       Start-Sleep -Milliseconds 300
    }
            catch {
    Write-Host "$indent  Failed to move $($item.Name): $($_.Exception.Message)" -ForegroundColor Red
            }
   }
    }
    
    if ($fileCount -gt 0) {
        Write-Host "$indent  Moved $fileCount file(s) to Purchased" -ForegroundColor Green
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
        if ($phoneItem.IsFolder) {
            # Check if this is an excluded folder
            $currentRelPath = if ($RelativePath) { "$RelativePath\$($phoneItem.Name)" } else { $phoneItem.Name }
            
   $shouldExclude = $false
       foreach ($excludePattern in $ExcludeFolders) {
             if ($currentRelPath -like "*$excludePattern*" -or $phoneItem.Name -eq $excludePattern) {
       $shouldExclude = $true
          break
         }
     }
        
   if ($shouldExclude) {
   continue  # Skip excluded folders
   }

# Check if this folder exists locally
       $localFolder = Join-Path $SourcePath $phoneItem.Name
 if (Test-Path $localFolder -PathType Container) {
   # Recurse into matching folders
  $phoneSubFolder = $phoneItem.GetFolder
     Process-OrphanedItems -SourcePath $localFolder -DestFolder $phoneSubFolder -ComicsFolder $ComicsFolder -Level ($Level + 1) -RelativePath $currentRelPath
         }
   else {
 # Directory exists on phone but not locally - move contents
          Write-Host "$indent[DIR] $($phoneItem.Name) - Not in local directory" -ForegroundColor Magenta
        $phoneSubFolder = $phoneItem.GetFolder
 
    if (Move-FolderContents -SourceFolder $phoneSubFolder -FolderName $phoneItem.Name -ComicsFolder $ComicsFolder -Level ($Level + 1)) {
  # Track this empty directory
           $emptyDirPath = if ($currentRelPath) { $currentRelPath } else { $phoneItem.Name }
     $script:emptyDirectories += $emptyDirPath
    Write-Host "$indent  (Empty directory - listed for manual cleanup)" -ForegroundColor Yellow
      }
    }
   }
        else {
    # It's a file - only process .jpg files
    if ($phoneItem.Name -notlike "*.jpg") {
  continue
        }
 
     # Check if it exists locally
     $localFile = Join-Path $SourcePath $phoneItem.Name
            
     if (-not (Test-Path $localFile -PathType Leaf)) {
         # File exists on phone but not locally - move to Purchased
         Write-Host "$indent[FILE] $($phoneItem.Name) - Orphaned, moving to Purchased..." -ForegroundColor Magenta
     
     $purchasedFolder = Get-PurchasedFolder -ComicsFolder $ComicsFolder
                
if ($purchasedFolder) {
          try {
   # Check if file already exists in Purchased
    $existingInPurchased = $purchasedFolder.Items() | Where-Object { $_.Name -eq $phoneItem.Name }
           
            if ($existingInPurchased) {
       # Delete existing file to allow overwrite
      try {
   $existingInPurchased.InvokeVerb("delete")
           Start-Sleep -Milliseconds 200
                 }
            catch {
               Write-Host "$indent  Warning: Could not delete existing file, attempting overwrite..." -ForegroundColor Yellow
        }
                  }
            
           # Move file
          $purchasedFolder.MoveHere($phoneItem, 0x414)
   Start-Sleep -Milliseconds 300
         Write-Host "$indent  ? Moved to Purchased" -ForegroundColor Green
              }
    catch {
    Write-Host "$indent  ? Failed to move: $($_.Exception.Message)" -ForegroundColor Red
       }
       }
   }
  }
    }
}

# Function to copy items recursively
function Copy-ToPhone {
    param(
        [string]$SourcePath,
        [object]$DestFolder,
        [int]$Level = 0,
   [string]$RelativePath = ""
    )
    
    $indent = "  " * $Level
    $items = Get-ChildItem -Path $SourcePath

    foreach ($item in $items) {
        if ($item.PSIsContainer) {
        # It's a directory
 
          # Calculate relative path for exclusion check
  $currentRelPath = if ($RelativePath) { "$RelativePath\$($item.Name)" } else { $item.Name }
        
            # Check if this folder should be excluded
        $shouldExclude = $false
            foreach ($excludePattern in $ExcludeFolders) {
          if ($currentRelPath -like "*$excludePattern*" -or $item.Name -eq $excludePattern) {
        $shouldExclude = $true
   break
        }
            }
  
            if ($shouldExclude) {
          continue
  }
            
 # Check if folder exists on phone
            $existingFolder = $DestFolder.Items() | Where-Object { $_.Name -eq $item.Name }
   
         if (-not $existingFolder) {
    # Folder doesn't exist on phone - create it
   Write-Host "$indent[DIR] $($item.Name) - Creating..." -ForegroundColor Cyan
         try {
            $DestFolder.NewFolder($item.Name)
         Start-Sleep -Milliseconds 500
  $existingFolder = $DestFolder.Items() | Where-Object { $_.Name -eq $item.Name }
            Write-Host "$indent  ? Created" -ForegroundColor Green
           }
    catch {
   Write-Host "$indent  ? Failed to create: $($_.Exception.Message)" -ForegroundColor Red
     }
    }
          else {
     # Folder exists - just show status
                Write-Host "$indent[DIR] $($item.Name)" -ForegroundColor Cyan
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
            $existingFile = $DestFolder.Items() | Where-Object { $_.Name -eq $item.Name }
          
     if ($existingFile) {
         # File already exists on phone - skip silently
        continue
            }
        else {
       # File doesn't exist - copy it
          Write-Host "$indent[FILE] $($item.Name) ($([math]::Round($item.Length/1KB, 2)) KB) - Copying..." -ForegroundColor White
   
                try {
    $DestFolder.CopyHere($item.FullName, 0x414)
     Start-Sleep -Milliseconds 200
         Write-Host "$indent  ? Done" -ForegroundColor Green
       }
    catch {
         Write-Host "$indent  ? Failed: $($_.Exception.Message)" -ForegroundColor Red
       }
  }
        }
    }
}

# Start the sync
Write-Host ""
Write-Host "Step 1: Processing orphaned items on phone..." -ForegroundColor Cyan
Write-Host ""

try {
    Process-OrphanedItems -SourcePath $LocalPath -DestFolder $comicsFolder -ComicsFolder $comicsFolder
    Write-Host ""
    Write-Host "Step 2: Synchronizing local files to phone..." -ForegroundColor Cyan
    Write-Host ""
    Copy-ToPhone -SourcePath $LocalPath -DestFolder $comicsFolder
    Write-Host ""
    Write-Host "Synchronization complete!" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "Error during synchronization: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# List empty directories found on the phone
if ($script:emptyDirectories.Count -gt 0) {
    Write-Host ""
    Write-Host "Empty directories found on the phone:" -ForegroundColor Cyan
    foreach ($emptyDir in $script:emptyDirectories) {
        Write-Host "  - $emptyDir" -ForegroundColor Yellow
    }
    Write-Host "Note: Empty directories have been tracked but not deleted. You can remove them manually if desired." -ForegroundColor White
}

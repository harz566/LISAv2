# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation

# Description: This script Cleans the old files generated by LISAv2.
#   The default cleanup directory DriveLetter:\LISAv2
#   This script will iterate through all the available drives.
# How to Use?
#   1. Estimate the cleanup
#   .\Utilities\Remove-LISAv2OrphanFiles.ps1 -FileAgeInDays 15 -DryRun
#   2. Run the cleanup
#   .\Utilities\Remove-LISAv2OrphanFiles.ps1 -FileAgeInDays 15

param
(
    [int] $FileAgeInDays = 7,
    [string] $LogFileName = "Remove-LISAv2OrphanFiles.log",
    # Dryrun will not delete any files. It will show, how many files can be deleted.
    [switch] $DryRun
)

#Load libraries
if (!$global:LogFileName) {
    Set-Variable -Name LogFileName -Value $LogFileName -Scope Global -Force
}

try {
    Set-Variable -Name LogDir -Value $PWD -Scope Global -Force
    Get-ChildItem (Join-Path $PWD "Libraries") -Recurse | Where-Object { $_.FullName.EndsWith(".psm1") } | `
	ForEach-Object { Import-Module $_.FullName -Force -Global -DisableNameChecking }

    Set-Content -Path $LogFileName -Value "" -Force
    $CurrentTime = Get-Date
    $RemovedSize = 0
    $UnremovedSize = 0
    $RemovedFilesCount = 0
    $AllFilesCount = 0
    $Drives = (Get-PSDrive | Where-Object {$_.Provider -imatch "FileSystem" }).Root
    $DrivesCount = $Drives.Count
    $CurrentDriveCount = 0
    if ( $DryRun ) {
        $RemovalString = "could be removed"
        $SuccessfulClanupString = "Estimated Cleanup"
        $FailedClanupString = "Estimated failures"
        $RemovedFilesString = "Estimated Removable Files"
    } else {
        $RemovalString = "removed"
        $SuccessfulClanupString = "Cleanup successful"
        $FailedClanupString = "Cleanup unsuccessful"
        $RemovedFilesString = "Total Removed Files"
    }
    foreach ($Drive in $Drives) {
        $CurrentFolder = 0
        $CurrentDriveCount += 1
        $CleanupFolder = Join-Path $Drive "LISAv2"
        Write-LogInfo "Getting file list from $CleanupFolder"
        if (Test-Path $CleanupFolder) {
            $CleanupFiles = Get-ChildItem -Path $CleanupFolder
            foreach ($CleanupFile in $CleanupFiles) {
                $SkipCurrentFolder = $false
                if ($CleanupFile.Mode.StartsWith("d---") ) {
                    $CurrentFolder += 1

                    # We are calculating age by using property "LastAccessTime"
                    $LastAccessTime = $CleanupFile.LastAccessTime
                    $CurrentCleanupDirectoryAge = ($CurrentTime - $LastAccessTime)

                    if ($CurrentCleanupDirectoryAge.TotalDays -gt $FileAgeInDays) {
                        $CurrentCleanupFiles = Get-ChildItem -Path $CleanupFile.FullName -Recurse | `
                            Where-Object {$_.Mode.StartsWith("-a")}
                        $TotalFiles = $CurrentCleanupFiles.Count
                        $Size = $CurrentCleanupFiles | Measure-Object -Sum -Property Length
                        Write-LogWarn "Cleaning $([int]$CurrentCleanupDirectoryAge.TotalDays) days old $($CleanupFile.FullName) [Size:$([math]::Round(($Size.Sum/1024/1024),2))MB]..."
                        $CurrentFiles = 0
                        foreach ($File in $CurrentCleanupFiles) {
                            $FileLastAccessTime = $File.LastAccessTime
                            $FileAge = ($CurrentTime - $FileLastAccessTime)
                            if ($FileAge.TotalDays -gt $FileAgeInDays) {
                                $CurrentFiles += 1
                                $AllFilesCount += 1
                                try {
                                    if ( -not $DryRun ) {
                                        [void](Remove-Item -Force -Path $File.FullName)
                                    }
                                    Write-LogInfo "[File: $CurrentFiles/$TotalFiles; Folder:$CurrentFolder/$($CleanupFiles.Count); Drive:$CurrentDriveCount/$DrivesCount] $($File.Name) $RemovalString."
                                    $RemovedFilesCount += 1
                                    $RemovedSize += $File.Length
                                } catch {
                                    Write-LogErr "Unable to remove $($File.Name)"
                                    $UnremovedSize += $File.Length
                                }
                            } else {
                                Write-LogInfo "[File: $CurrentFiles/$TotalFiles; Folder:$CurrentFolder/$($CleanupFiles.Count); Drive:$CurrentDriveCount/$DrivesCount] $($File.Name) Skipped. (Last Accessed $($File.LastAccessTime.ToString()))."
                                $SkipCurrentFolder = $true
                            }
                        }
                        if ( -not $SkipCurrentFolder ) {
                            try {
                                if ( -not $DryRun ) {
                                    [void](Remove-Item -Force -Path $CleanupFile.FullName -Recurse)
                                }
                                Write-LogInfo "Parent directory : $($CleanupFile.FullName) $RemovalString."
                            } catch {
                                Write-LogErr "Unable to remove parent directory $($CleanupFile.FullName)"
                            }
                        }
                    }
                }
            }
        } else {
            Write-LogInfo "$CleanupFolder does not exists."
        }
    }
} catch {
    Raise-Exception ($_)
} finally {
    Write-LogInfo "------------------Cleanup Report--------------------------"
    Write-LogInfo "$SuccessfulClanupString : $([math]::Round(($RemovedSize/1024/1024),2))MB [$([math]::Round(($RemovedSize/1024/1024/1024),2))GB]"
    Write-LogInfo "$FailedClanupString : $([math]::Round(($UnremovedSize/1024/1024),2))MB [$([math]::Round(($UnremovedSize/1024/1024/1024),2))GB]"
    Write-LogInfo "$RemovedFilesString : $RemovedFilesCount/$AllFilesCount"
    Write-LogInfo "----------------------------------------------------------"
    exit 0
}
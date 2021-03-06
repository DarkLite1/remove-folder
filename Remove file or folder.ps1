#Requires -Version 5.1
#Requires -Modules ImportExcel

<#
.SYNOPSIS
    Remove files or folders on remote machine.

.DESCRIPTION
    The script reads an Excel file containing a computer name and a local folder
    or file path in each row. It then tries to remove the files or folders 
    defined on the requested computers.

.PARAMETER Path
    Path to the Excel file containing the rows with the computer names and local
    folder/file paths.
#>

[CmdLetBinding()]
Param (
    [Parameter(Mandatory)]
    [String]$ScriptName,
    [Parameter(Mandatory)]
    [String]$Path,
    [Parameter(Mandatory)]
    [String[]]$MailTo,
    [String]$LogFolder = "$env:POWERSHELL_LOG_FOLDER\Home drives removal\$ScriptName",
    [String]$ScriptAdmin = $env:POWERSHELL_SCRIPT_ADMIN
)

Begin {
    $scriptBlock = {
        Param (
            [Parameter(Mandatory)]
            [String[]]$Paths
        )

        foreach ($path in $Paths) {
            Try {
                $result = [PSCustomObject]@{
                    ComputerName = $env:COMPUTERNAME
                    Path         = $path
                    Date         = Get-Date
                    Exist        = $true
                    Action       = $null
                    Error        = $null
                }

                if (-not (Test-Path -LiteralPath $path)) {
                    $result.Exist = $false
                    $result.Error = 'Path not found'
                    Continue
                }

                $result.Action = 'Remove'
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop

                if (-not (Test-Path -LiteralPath $path)) {
                    $result.Exist = $false
                }
            }
            Catch {
                $result.Error = $_
                $Error.RemoveAt(0)
            }
            finally {
                $result
            }
        }
    }

    Try {
        Import-EventLogParamsHC -Source $ScriptName
        Write-EventLog @EventStartParams
        Get-ScriptRuntimeHC -Start
        $Error.Clear()

        #region Logging
        try {
            $LogParams = @{
                LogFolder    = New-Item -Path $LogFolder -ItemType 'Directory' -Force -ErrorAction 'Stop'
                Name         = $ScriptName
                Date         = 'ScriptStartTime'
                NoFormatting = $true
            }
            $LogFile = New-LogFileNameHC @LogParams
        }
        Catch {
            throw "Failed creating the log folder '$LogFolder': $_"
        }
        #endregion

        $mailParams = @{ }
    }
    Catch {
        Write-Warning $_
        Send-MailHC -To $ScriptAdmin -Subject 'FAILURE' -Priority 'High' -Message $_ -Header $ScriptName
        Write-EventLog @EventErrorParams -Message "FAILURE:`n`n- $_"
        Write-EventLog @EventEndParams; Exit 1
    }
}

Process {
    Try {
        $M = "Import Excel file '$Path'"
        Write-Verbose $M; Write-EventLog @EventOutParams -Message $M

        $importExcelFile = Import-Excel -Path $Path
        
        #region Test Excel column headers ComputerName and Path
        $M = "Test Excel column headers 'ComputerName' and 'Path'"
        Write-Verbose $M; Write-EventLog @EventOutParams -Message $M

        $properties = $importExcelFile | Get-Member -MemberType NoteProperty

        if (
            ($properties.Name -notContains 'ComputerName') -or 
            ($properties.Name -notContains 'Path')
        ) {
            throw "Column headers 'ComputerName' and 'Path' are not found in the Excel sheet."
        }
        #endregion
        
        #region Remove files/folders on remote machines
        $jobs = foreach (
            $computer in 
            ($importExcelFile | Group-Object ComputerName)
        ) {
            if (-not $computer.Group.Path) { Continue }

            $invokeParams = @{
                ComputerName = $computer.Name 
                ScriptBlock  = $scriptBlock
                ArgumentList = , $computer.Group.Path
                asJob        = $true
            }

            $M = "Start job on '$($invokeParams.ComputerName)' for $($invokeParams.ArgumentList[0].Count) paths"
            Write-Verbose $M; Write-EventLog @EventOutParams -Message $M

            Invoke-Command @invokeParams
        }

        $M = "Wait for all $($jobs.count) jobs to be finished"
        Write-Verbose $M; Write-EventLog @EventOutParams -Message $M

        $jobResults = if ($jobs) { $jobs | Wait-Job | Receive-Job }
        #endregion

        #region Export results to Excel log file
        if ($jobResults) {
            $M = "Export $($jobResults.Count) rows to Excel"
            Write-Verbose $M; Write-EventLog @EventOutParams -Message $M
            
            $excelParams = @{
                Path               = $LogFile + '- Log.xlsx'
                AutoSize           = $true
                WorksheetName      = 'Overview'
                TableName          = 'Overview'
                FreezeTopRow       = $true
                NoNumberConversion = '*'
            }
            $jobResults | 
            Select-Object -Property 'ComputerName', 'Path', 'Date', 
            'Exist', 'Action', 'Error' | 
            Export-Excel @excelParams

            $mailParams.Attachments = $excelParams.Path
        }
        #endregion

        #region Send mail to user
        $removedFolders = $jobResults.Where( {
                ($_.Action -eq 'Remove') -and
                ($_.Exist -eq $false)
            })
        $folderRemovalErrors = $jobResults.Where( { $_.Error })
        $notExistingFolders = $jobResults.Where( { $_.Exist -eq $false })
           
        $mailParams.Subject = "Removed $($removedFolders.Count)/$($importExcelFile.count) items"

        $ErrorTable = $null
   
        if ($Error) {
            $mailParams.Priority = 'High'
            $mailParams.Subject = "$($Error.Count) errors, $($mailParams.Subject)"
            $ErrorTable = "<p>During removal <b>$($Error.Count) non terminating errors</b> were detected:$($Error.Exception | Select-Object -ExpandProperty Message | ConvertTo-HtmlListHC)</p>"
        }

        if ($folderRemovalErrors) {
            $mailParams.Priority = 'High'
            $mailParams.Subject += ", $($folderRemovalErrors.Count) removal errors"
        }
   
        $table = "
           <table>
               <tr>
                   <th>Successfully removed items</th>
                   <td>$($removedFolders.Count)</td>
               </tr>
               <tr>
                   <th>Errors while removing items</th>
                   <td>$($folderRemovalErrors.Count)</td>
               </tr>
               <tr>
                   <th>Imported Excel file rows</th>
                   <td>$($importExcelFile.Count)</td>
               </tr>
               <tr>
                   <th>Not existing items after running the script</th>
                   <td>$($notExistingFolders.Count)</td>
               </tr>
           </table>
           "
   
        $mailParams += @{
            To        = $MailTo
            Bcc       = $ScriptAdmin
            Message   = "<p>Summary of removed items (files or folders):</p>
                $table
                $ErrorTable
                <p><i>* Check the attachment for details</i></p>"
            LogFolder = $LogParams.LogFolder
            Header    = $ScriptName
            Save      = $LogFile + ' - Mail.html'
        }
   
        Get-ScriptRuntimeHC -Stop
        Send-MailHC @mailParams
        #endregion
    }
    Catch {
        Write-Warning $_
        Send-MailHC -To $ScriptAdmin -Subject 'FAILURE' -Priority 'High' -Message $_ -Header $ScriptName
        Write-EventLog @EventErrorParams -Message "FAILURE:`n`n- $_"
        Exit 1
    }
    Finally {
        Get-Job | Remove-Job
        Write-EventLog @EventEndParams
    }
}
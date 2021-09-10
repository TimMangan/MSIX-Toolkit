function CreateMPTTemplate($conversionParam, $refId,  $virtualMachine, $workingDirectory)
{
    # create template file for this conversion
    $templateFilePath = [System.IO.Path]::Combine($workingDirectory, "MPT_Templates", "MsixPackagingToolTemplate_Job$($refId).xml")
    $conversionMachine = "<mptv2:RemoteMachine ComputerName=""$($virtualMachine.Name)"" Username=""$($virtualMachine.Credential.UserName)"" />"

    $saveFolder = [System.IO.Path]::Combine($workingDirectory, "MSIX")
    $xmlContent = @"
<MsixPackagingToolTemplate
    xmlns="http://schemas.microsoft.com/appx/msixpackagingtool/template/2018"
    xmlns:mptv2="http://schemas.microsoft.com/msix/msixpackagingtool/template/1904">
<Installer Path="$($conversionParam.InstallerPath)" Arguments="$($conversionParam.InstallerArguments)" />
$conversionMachine
<SaveLocation PackagePath="$saveFolder" />
<PackageInformation
    PackageName="$($conversionParam.PackageName)"
    PackageDisplayName="$($conversionParam.PackageDisplayName)"
    PublisherName="$($conversionParam.PublisherName)"
    PublisherDisplayName="$($conversionParam.PublisherDisplayName)"
    Version="$($conversionParam.PackageVersion)">
</PackageInformation>
</MsixPackagingToolTemplate>
"@
    Set-Content -Value $xmlContent -Path $templateFilePath
    $templateFilePath
}

function RunConversionJobs($conversionsParameters, $virtualMachines, $workingDirectory, $retryBad)
{
    #Cleanup previous run
    get-job | Stop-Job |Remove-Job
    if (Test-Path  ([System.IO.Path]::Combine($workingDirectory, "MPT_Templates")))
    {
        Remove-item ([System.IO.Path]::Combine($workingDirectory, "MPT_Templates")) -recurse
    }
    if (Test-Path  ([System.IO.Path]::Combine($workingDirectory, "MSIX")))
    {
        Remove-item ([System.IO.Path]::Combine($workingDirectory, "MSIX")) -recurse
    }
    if (Test-Path  ([System.IO.Path]::Combine($workingDirectory, "LOGS")))
    {
        Remove-item ([System.IO.Path]::Combine($workingDirectory, "Logs")) -recurse
    }

    #Set up this run
    New-Item -Force -Type Directory ([System.IO.Path]::Combine($workingDirectory, "MPT_Templates"))
    New-Item -Force -Type Directory ([System.IO.Path]::Combine($workingDirectory, "MSIX"))
    New-Item -Force -Type Directory ([System.IO.Path]::Combine($workingDirectory, "LOGS"))

    $logfolder  = ([System.IO.Path]::Combine($workingDirectory, "LOGS"))

  

    # create list of the indices of $conversionsParameters that haven't started running yet
    $remainingConversionIndexes = @()
    $conversionsParameters | Foreach-Object { $i = 0 } { $remainingConversionIndexes += ($i++) }

    $failedConversionIndexes = @()
    
    # Next schedule jobs on virtual machines which can be checkpointed/re-used
    # keep a mapping of VMs and the current job they're running, initialized ot null
    $virtMachinesArray = New-Object -TypeName "System.Collections.ArrayList"
    foreach ($vm in $virtualmachines)
    {
        $virtMachine = New-Object -TypeName PSObject
        $virtMachine | Add-Member -NotePropertyName npVmCfgObj -NotePropertyValue $vm
        $virtMachine | Add-Member -NotePropertyName npVmGetObj -NotePropertyValue (get-vm -ComputerName $vm.Host -Name $vm.Name)
        $virtMachine | Add-Member -NotePropertyName npRefId -NotePropertyValue -1
        $virtMachine | Add-Member -NotePropertyName npInUse -NotePropertyValue $false
        $virtMachine | Add-Member -NotePropertyName npJobObj -NotePropertyValue $nul
        $virtMachine | Add-Member -NotePropertyName npAppName -NotePropertyValue ""    
        $virtMachine | Add-Member -NotePropertyName npErrorCount -NotePropertyValue 0    
        $virtMachine | Add-Member -NotePropertyName npDisabled -NotePropertyValue $false    
        $virtMachinesArray.Add($virtMachine)    > $xxx ## $xxx is just to avoid unwated console output
    }

    # Use a semaphore to signal when a machine is available. Note we need a global semaphore as the jobs are each started in a different powershell process
    # Make sure prior runs are cleared out first
    $semaphore = New-Object -TypeName System.Threading.Semaphore -ArgumentList @($virtMachinesArray.Count, $virtMachinesArray.Count, "Global\MPTBatchConversion")
    $semaphore.Close()
    $semaphore.Dispose()

    $semaphore = New-Object -TypeName System.Threading.Semaphore -ArgumentList @($virtMachinesArray.Count, $virtMachinesArray.Count, "Global\MPTBatchConversion")
    Write-Host ""

    while ($semaphore.WaitOne(-1))
    {
        if ($remainingConversionIndexes.Count -gt 0)
        {
            # select a job to run 
            Write-Host "Determining next job to run..."
            $conversionParam = $conversionsParameters[$remainingConversionIndexes[0]]
            if ( $conversionParam.Enabled)
            {
                # select a VM to run it on. Retry a few times due to race between semaphore signaling and process completion status
                $vm = $nul
                while (-not $vm) { $vm = $virtMachinesArray | where { $_.npInUse -eq $false -and $_.npDisabled -eq $false } | Select-Object -First 1 }
               

                # Capture the ref index and update list of remaining conversions to run
                $refId = $remainingConversionIndexes[0]
                $remainingConversionIndexes = $remainingConversionIndexes | where { $_ -ne $remainingConversionIndexes[0] }
                Write-Host "Dequeue for conversion Ref $($refId) for app $($conversionParam.PackageName) on VM $($vm.npVmGetObj.Name)." -Foreground Cyan
                
                $vm.npRefId = $refId
                $vm.npAppName = $conversionParam.PackageName
                $vm.npInUse = $true

                $templateFilePath = CreateMPTTemplate $conversionParam $refId $vm.npVmCfgObj $workingDirectory 
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($vm.npVmCfgObj.Credential.Password)
                $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

                
                $jobObject = start-job -ScriptBlock {  
                    param($refId, $vMachine,  $machinePassword, $templateFilePath, $initialSnapshotName,$logFile)
                    
                    Write-Output "Starting with params:  $($refId), $($vMachine.npVmGetObj.ComputerName)/$($vMachine.npVmGetObj.Name), $($vmsCount), $($machinePassword), $($templateFilePath), $($initialSnapshotName), $($logFile)" > $logFile

                    try
                    {
                        Write-Output "debug: be4 get snapshot" >> $logFile
                        $snap = Get-VMSnapshot -Name $initialSnapshotName -VMName $vMachine.npVmCfgObj.Name -ComputerName $vMachine.npVmCfgObj.Host -ErrorAction Continue
                        Write-Output "debug: after get snapshot" >> $logFile
                        if ( $snap)
                        {
                            Write-Output "Reverting VM snapshot for  $($vMachine.npVmCfgObj.Host) / $($vMachine.npVmCfgObj.Name): $($initialSnapshotName)" >> $logFile
                            Restore-VMSnapshot -ComputerName $vMachine.npVmCfgObj.Host -VMName $vMachine.npVmCfgObj.Name -Name $initialSnapshotName -Confirm:$false
                            Write-Output "debug: after revert" >> $logFile
                            ####probably don't need to replace this, but once had an issue...
                            Start-Sleep 2
                            $vMachine.npVmGetObj = (get-vm -ComputerName $vMachine.npVmCfgObj.Host -Name $vMachine.npVmCfgObj.Name)
                            Set-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name -Notes "Preparing $($vMachine.npAppName)"
                            
                            if ( $vMachine.npVmGetObj.state -eq 'Off' -or $vMachine.npVmGetObj.state -eq 'Saved' )
                            {
                                Write-Output "Starting VM" >> $logFile
                                Start-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name 
                                #Write-Output "after Starting VM" >> $logFile
                                $limit = 60
                                while ($vMachine.npVmGetObj.state -ne 'Running')
                                {
                                    Start-Sleep 5
                                    $limit = $limit - 1
                                    if ($limit -eq 0)
                                    {
                                        Write-Output "TIMEOUT while starting restored checkpoint' state=$($vMachine.npVmGetObj.state)." >> $logFile
                                        $vMachine.npErrorCount = $vMachine.npErrorCount + 1
                                        if ($vMachine.npVmGetObj.state -ne 'Off')
                                        {
                                            Write-Host "Debug: Stop VM $( $vMachine.npVmGetObj.Name)" >> $logFile
                                            Stop-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name -TurnOff -Force -ErrorAction SilentlyContinue
                                        }
                                        break;
                                    }
                               }
                            }
                            else
                            {
                                Write-Output "Debug: state is $($vMachine.npVmGetObj.state)" >> $logFile
                            }
                        }
                        else
                        {
                            Write-Output "Get-VMSnapshot error" >> $logFile
                        }

                        $waiting = $true
                        $waitcount = 0
                        ## Let VM Settle a little.  At times the VMs get a little busy thanks to MS and more time seems to work better.
                        while ($waiting)
                        {
                            if ( $vMachine.npVmGetObj.state -eq 'Running' -and $vMachine.npVmGetObj.upTime.TotalSeconds -gt 120  )
                            {
                                $waiting = $false

                                if ($vMachine.npVmCfgObj.PreInstallerArguments -ne $nul)
                                {
                                    Write-Output "---------------- Starting PreInstaller..." >> $logFile
                                    Invoke-Command -ComputerName $vMachine.npVmGetObj.Name { "$($vMachine.npVmCfgObj.InstallerPath) $($vMachine.npVmCfgObj.PreInstallerArguments)" } >> $logFile
                                    Write-Output "---------------- PreInstaller done." >> $logFile
                                }


                                Set-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name -Notes "Packaging $($vMachine.npAppName)"
                                Write-Output "" >> $logFile
                                Write-Output "==========================Starting package..." >> $logFile
                                MsixPackagingTool.exe create-package --template $templateFilePath --machinePassword $machinePassword -v >> $logFile
                                Write-Output "==========================Packaging tool done." >> $logFile
                                Write-Output "" >> $logFile
                            }
                            $waitcount += 1
                            if ($waitcount -gt 360)
                            {
                                $waiting = $false
                                Write-Output "Timeout waiting for OS to start" >> $logFile
                                $vMachine.npErrorCount = $vMachine.npErrorCount + 1
                                if ($vMachine.npVmGetObj.state -ne 'Off')
                                {
                                    Write-Host "Debug: Stop VM $( $vMachine.npVmGetObj.Name)" >> $logFile
                                    Stop-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name -TurnOff -Force -ErrorAction SilentlyContinue
                                }
                            }
                            start-sleep 1
                        }
                        Write-Output "Debug: job ready for finalizing." >> $logFile
                    }
                    finally
                    {
                        Write-Output "Finalizing." >> $logFile
                        Stop-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name -TurnOff -Force -ErrorAction SilentlyContinue

                        #Read-Host -Prompt 'Press any key to exit this window '
                        Write-Output "Complete." >> $logFile
                    }

                }  -ArgumentList $refId,  $vm,  $password, $templateFilePath, $vm.npVmCfgObj.initialSnapshotName, "$($logfolder)\$($conversionParam.PackageName)_$(Get-Date -format FileDateTime).txt"
                $vm.npJobObj = $jobObject
                write-host "Ref$($refId): job is named $($jobObject.Name)"
            }
            else {
                $refId = $remainingConversionIndexes[0]
                $remainingConversionIndexes = $remainingConversionIndexes | where { $_ -ne $remainingConversionIndexes[0] }
                Write-Host "Ref $($refId): $($conversionParam.PackageName) skipped by request." -ForegroundColor Yellow
                $semaphore.Release()
            }
        }
        else
        {
            $semaphore.Release()
            break;
        }


        WaitForFreeVM $virtMachinesArray $workingDirectory $failedConversionIndexes
        Write-host "One or more VMs are available for scheduling..."        
    }

    Write-Host "Finished scheduling all jobs, wait for final jobs to complete."
    #$virtualMachines | foreach-object { if ($vmsCurrentJobNameMap[$_.Name]) { $vmsCurrentJobNameMap[$_.Name].WaitForExit() } }
    $countInUse = $virtMachinesArray.Count
    $firstposttime = $true
    while ($countInUse -gt 0)
    {
        $tempFailedConversions = WaitForFreeVM $virtMachinesArray $workingDirectory 
        foreach ($tempFail in $tempFiledConversions)
        {
            $failedConversionIndexes += ($tempFail)
        }
        $countInUse = CountEnabledInuseVMs $virtMachinesArray
        if ($firstposttime -eq $true)
        {
            $firstposttime = $false
            Write-Host "There are $($countInUse) jobs still running" 
        }
        Sleep(5)
    }

    $semaphore.Dispose()
    Write-Host "Finished running all packaging jobs."

    if ($retryBad)
    {
        #Get the best VM today
        $redoVirtMachinesArray = New-Object -TypeName "System.Collections.ArrayList"
        $bestvmachine = $nul
        foreach ($vmachine in $virtMachinesArray)
        {
            if ($vmachine.npDisabled -eq $false)
            {
                if ($bestvmachine -eq $nul -or $vmachine.npErrorCount -lt $bestvmachine.npErrorCount)
                {
                    $bestvmachine = $vmachine
                }
            }
        }
        $redoVirtMachinesArray.Add($bestmachine)

        Write-host "There are $($failedConversionIndexes.Count) packages for redo" -ForegroundColor Cyan
        foreach ($failedConversionIndex in $failedConversionIndexes)
        {
            $failedConversionParameter = $conversionsParameters[$failedConversionIndex]
            Write-Host "Redo for $($failedConversionParameter.PackageName) on $($bestvmachine.npCfgObj.Name)"  -ForegroundColor Cyan
            $bestvmachine.npRefId = $failedConversionIndex
            $bestvmachine.npAppName = $failedConversionParameter.PackageName
            $bestvmachine.npInUse = $true

            $templateFilePath = CreateMPTTemplate $failedConversionParameter $conversionsParameters.Count+$failedConversionIndex $bestvmachine.npVmCfgObj $workingDirectory 
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($bestvmachine.npVmCfgObj.Credential.Password)
            $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    
    
            PackageThis $bestvmachine $password $templateFilePath $bestvmachine.npVmCfgObj.initialSnapshotName "$($logfolder)\$($conversionParam.PackageName)_Redo_$(Get-Date -format FileDateTime).txt"
        
            WaitForFreeVM $redoVirtMachinesArray $workingDirectory 
        }    
    }

}

function WaitForFreeVM($virtMachinesArray, $workingDirectory)
{
    $thisPassFailedConversionIndexes = @()
    $CountEnabled = 0
    foreach ($vm in $virtMachinesArray)
    {
        if (-not $vm.npDisabled)
        {
            $CountEnabled = $CountEnabled + 1
        }
    }
    $numAvailable = 0
        
    while ($numAvailable -eq 0)
    {
        Sleep(5)
        foreach ($vm in $virtMachinesArray)
        {
            if ($vm.npDisabled -eq $false)
            { 
                if ($vm.npInUse -eq $true)
                { 
                    if ($vm.npJobObj.State -eq 'Running') 
                    { 
                        if ($vm.npVmGetObj.upTime.TotalHours -gt 3.0)
                        {
                            Write-Host "Timeout on $($vm.npVmGetObj.Name) processing $($vm.npAppName)." -ForegroundColor Red
                            Stop-Job -Job $vm.npJobObj
                            Remove-Job -Job $vm.npJobObj -Force
                            $vm.npJobObj = $nul
                            Checkpoint-VM -ComputerName $vm.npVmGetObj.ComputerName -Name $vm.npVmGetObj.Name -SnapshotName "$($vm.npAppName)_$(get-date)"
                            Stop-VM -ComputerName $vm.npVmGetObj.ComputerName -Name $vm.npVmGetObj.Name -TurnOff -ErrorAction SilentlyContinue
                            Set-VM -ComputerName $vm.npVmGetObj.ComputerName -Name $vm.npVmGetObj.Name -Notes 'none'
                            $thisPassFailedConversionIndexes.Add($vm.npRefId)
                            $vm.npRefId = -1
                            $vm.npAppName = ''
                            $vm.npInUse = $false
                            $vm.npErrorCount = $vm.npErrorCount + 1
                            if ($vm.npErrorCount -gt 5 -and $CountEnabled -gt 1)
                            {
                                $vm.npDisabled = $true
                                $CountEnabled -= 1
                                Write-Host "Disabling $($vm.npVmGetObj.Name) due to exess errors" -BackgroundColor DarkRed -ForegroundColor White
                            }
                            else    
                            {
                                $semaphore.Release()
                                $numAvailable += 1
                            }
                        }
                        else
                        {
                            #$countInUse += 0
                        } 
                    }
                    else
                    {
                        write-host "debug: job $($vm.npJobObj.Name) state $($vm.npJobObj.State) "
                        if (Test-Path -Path "$($workingDirectory)\MSIX\$($vm.npAppName)_*.msix")
                        {
                            Write-Host "Completion of  $($vm.npAppName) on $($vm.npVmGetObj.Name)." -ForegroundColor Green
                        }
                        else
                        {
                            Write-Host "Completion without package of  $($vm.npAppName) on $($vm.npVmGetObj.Name)." -ForegroundColor Red
                            Checkpoint-VM -ComputerName $vm.npVmGetObj.ComputerName -Name $vm.npVmGetObj.Name -SnapshotName "$($vm.npAppName)_$(get-date)"
                            $thisPassFailedConversionIndexes += ($vm.npRefId)
                            $vm.npErrorCount = $vm.npErrorCount + 1
                        }
                        Stop-Job -Job $vm.npJobObj
                        Remove-Job -Job $vm.npJobObj -Force
                        $vm.npJobObj = $nul
                        if ($vm.npVmGetObj.State -eq 'Running')
                        {
                            Stop-VM -ComputerName $vm.npVmGetObj.ComputerName -Name $vm.npVmGetObj.Name -TurnOff -ErrorAction SilentlyContinue
                        }
                        Set-VM -ComputerName $vm.npVmGetObj.ComputerName -Name $vm.npVmGetObj.Name -Notes 'none'
                        $vm.npRefId = -1
                        $vm.npAppName = ''
                        $vm.npInUse = $false
                        if ($vm.npErrorCount -gt 5 -and $CountEnabled -gt 1)
                        {
                            $vm.npDisabled = $true
                            $CountEnabled -= 1
                            Write-Host "Disabling $($vm.npVmGetObj.Name) due to exess errors" -BackgroundColor DarkRed -ForegroundColor White
                        }
                        else
                        {
                            $semaphore.Release()
                            $numAvailable += 1
                        }
                    }
                }
                else
                {
                    ## VM already not in use
                    $numAvailable += 1
                }
            }
            else
            {
                # VM already Disabled
            }
        }
    }
    return $thisPassFailedConversionIndexes 
}

function CountEnabledInuseVMs($virtMachinesArray)
{
    $Count = 0
    foreach ($vm in $virtMachinesArray)
    {
        if ($vm.npDisabled -eq $false -and $vm.npInuse -eq $true)
        {
            $Count = $CountEnabled + 1
        }
    }
    return $Count
}

function PackageThis( $vMachine, $machinePassword, $templateFilePath, $initialSnapshotName, $logFile)
{
    Write-Output "Starting with params:   $($vMachine.npVmGetObj.ComputerName)/$($vMachine.npVmGetObj.Name),  $($machinePassword), $($templateFilePath), $($initialSnapshotName), $($logFile)" > $logFile

    try
    {
        Write-Output "debug: be4 get snapshot" >> $logFile
        $snap = Get-VMSnapshot -Name $initialSnapshotName -VMName $vMachine.npVmCfgObj.Name -ComputerName $vMachine.npVmCfgObj.Host -ErrorAction Continue
        Write-Output "debug: after get snapshot" >> $logFile
        if ( $snap)
        {
            Write-Output "Reverting VM snapshot for  $($vMachine.npVmCfgObj.Host) / $($vMachine.npVmCfgObj.Name): $($initialSnapshotName)" >> $logFile
            Restore-VMSnapshot -ComputerName $vMachine.npVmCfgObj.Host -VMName $vMachine.npVmCfgObj.Name -Name $initialSnapshotName -Confirm:$false
            Write-Output "debug: after revert" >> $logFile
            ####probably don't need to replace this, but once had an issue...
            Start-Sleep 5
            $vMachine.npVmGetObj = (get-vm -ComputerName $vMachine.npVmCfgObj.Host -Name $vMachine.npVmCfgObj.Name)
            Set-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name -Notes "Preparing $($vMachine.npAppName)"
            
            if ( $vMachine.npVmGetObj.state -eq 'Off' )
            {
                Write-Output "Starting VM" >> $logFile
                Start-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name 
                #Write-Output "after Starting VM" >> $logFile
                $limit = 60
                while ($vMachine.npVmGetObj.state -ne 'Running')
                {
                    Start-Sleep 5
                    $limit = $limit - 1
                    if ($limit -eq 0)
                    {
                        Write-Output "TIMEOUT while starting restored checkpoint' state=$($vMachine.npVmGetObj.state)." >> $logFile
                        $vMachine.npErrorCount = $vMachine.npErrorCount + 1
                        if ($vMachine.npVmGetObj.state -ne 'Off')
                        {
                            Write-Host "Debug: Stop VM $( $vMachine.npVmGetObj.Name)" >> $logFile
                            Stop-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name -TurnOff -Force -ErrorAction SilentlyContinue
                        }
                        break;
                    }
                }
            }
            elseif ( $vMachine.npVmGetObj.state -eq 'Saved' )
            {
                Write-Output "Resuming VM" >> $logFile
                Resume-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name 
                #Write-Output "debug: after Resuming VM" >> $logFile
                $limit = 60
                while ($vMachine.npVmGetObj.state -ne 'Running')
                {
                    Start-Sleep 5
                    $limit = $limit - 1
                    if ($limit -eq 0)
                    {
                        Write-Output "TIMEOUT while starting restored checkpoint' state=$($vMachine.npVmGetObj.state)." >> $logFile
                        $vMachine.npErrorCount = $vMachine.npErrorCount + 1
                        if ($vMachine.npVmGetObj.state -ne 'Off')
                        {
                            Write-Host "Debug: Stop VM $( $vMachine.npVmGetObj.Name)" >> $logFile
                            Stop-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name -TurnOff -Force -ErrorAction SilentlyContinue
                        }
                        break;
                    }
                }
            }
            else
            {
                Write-Output "debug state is $($vMachine.npVmGetObj.state)" >> $logFile
            }

        }
        else
        {
            Write-Output "Get-VMSnapshot error" >> $logFile
        }

        $waiting = $true
        $waitcount = 0
        ## Let VM Settle a little.  At times the VMs get a little busy thanks to MS and more time seems to work better.
        while ($waiting)
        {
            if ( $vMachine.npVmGetObj.state -eq 'Running' -and $vMachine.npVmGetObj.upTime.TotalSeconds -gt 120  )
            {
                $waiting = $false
                Set-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name -Notes "Packaging $($vMachine.npAppName)"
                Write-Output "" >> $logFile
                Write-Output "==========================Starting package..." >> $logFile
                MsixPackagingTool.exe create-package --template $templateFilePath --machinePassword $machinePassword -v >> $logFile
                Write-Output "==========================Packaging tool done." >> $logFile
                Write-Output "" >> $logFile
            }
            $waitcount += 1
            if ($waitcount -gt 360)
            {
                $waiting = $false
                Write-Output "Timeout waiting for OS to start" >> $logFile
                $vMachine.npErrorCount = $vMachine.npErrorCount + 1
                if ($vMachine.npVmGetObj.state -ne 'Off')
                {
                    Write-Host "Debug: Stop VM $( $vMachine.npVmGetObj.Name)" >> $logFile
                    Stop-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name -TurnOff -Force -ErrorAction SilentlyContinue
                }
            }
            start-sleep 1
        }
        Write-Output "Debug: job ready for finalizing." >> $logFile
    }
    finally
    {
        Write-Output "Finalizing." >> $logFile
        Stop-VM -ComputerName $vMachine.npVmGetObj.ComputerName -Name $vMachine.npVmGetObj.Name -TurnOff -Force -ErrorAction SilentlyContinue

        #Read-Host -Prompt 'Press any key to exit this window '
        Write-Output "Complete." >> $logFile
    }
}


function FindUndoneJobs($conversionsParameters,$workingDirectory)
{
    # NO longer used
    $undoneConversionArray = @() 
    foreach ($conversionParam in $conversionParameters)
    {
        if ( $conversionParam.Enabled)
        {
            if (-not (Test-Path -Path "$($workingDirectory)\MSIX\$($conversionParam.PackageName)_*.msix"))
            {
                $undoneConversionArray.Add($conversionParam)
            }
        }
    }
    return $undoneConversionArray
}

function SignPackages($msixFolder, $signtoolPath, $certfile, $certpassword, $timestamper)
{

    Get-ChildItem $msixFolder | foreach-object {
        $msixPath = $_.FullName
        Write-Host "Running: $signtoolPath sign /f $certfile /p "*redacted*" /fd SHA256 /t $timestamper $msixPath"
        & $signtoolPath sign /f $certfile  /p $certpassword /fd SHA256 /t $timestamper $msixPath
    }
}

function AutoFixPackages($inputfolder, $outputFolder)
{
    $Toolpath = 'TMEditX.exe'

    Get-ChildItem $inputfolder | foreach-object {
        $msixPath = $_.FullName
        Write-Host "Running: $($Toolpath) /ApplyAllFixes /AutoSaveAsMsix $($msixPath)" -ForegroundColor Cyan
        & $Toolpath /ApplyAllFixes /AutoSaveAsMsix $msixPath
        Start-Sleep 15
    }
}

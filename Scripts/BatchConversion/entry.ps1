. $PSScriptRoot\batch_convert.ps1

## Setup:
##      You need a "controller" machine plus one or more "worker" machines that will perform capture operations, plus a hypervisor:  
##            The worker machines should be Hyper-V VMs. (you can edit batch_convert.ps1 if you need a different hypervisor but you are on your own on that).
##            If multiple workers are utilized, you will be packaging in paralell.  These workers may be present on different hypervisors.
##            These instructions assume all machines are domain joined for simplicity.  It should be possible to do with non-domain joined worker machines.
##      The MMPT on the controller simply remotes the work to the worker.  
##            It does this by copying necessary files over to a temp folder on the worker, including MMPT executables and dependencies.
##            It seems to run the copy MMPT, but still needs the driver to be installed, hence you take care of that (see instructions below) manually
##            Since you probably want Windows Update disabled on the worker (and that must be enabled to perform driver install).
##            It also appears that the package is created on the worker, so if you want to change configuration (including allowing non-store version numbers and/or changeing the default exclusion list) you'd have to do it on the worker setup, although I'm not sure the copy MMPT runs in the container to get those configurations!
##      On the Controller: 
##            Place the two files, entry.ps1 and batch_convert.ps1 in a folder.
##            enable-psremoting
##            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Tools-All  
##            Import-Module Hyper-V
##            Install the Microsoft MSIX Packaging Tool (MMPT)
##            Start the MMPT and configure telemetry and any settings needed. (This script doesn't use the MMPT to sign the packages, it will be done by the script directly).
##      Create one or more worker VMs on Hyper-V hypervisors :
##             Install the Microsoft MSIX Packaging tool
##             enable-psremoting
##             Start the packaging tool, choose  telemetry option, then start an app and get to the point that the MMPT driver is installed, then close tool.
##             Disable Windows Updates, etc.
##             Nueter Antivius like defender (turn off features and add C:\ as exclusion folder)
##             Take a snapshot/checkpoint and give it a name.  This should preferably be done with VM running, but may be while shut down.
##      On the hypervisor (Windows 10):
##             It is likely that you already have the full Hyper-V platform installed.  If not, do so, reboot, and configure: 
##                 Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Tools-All
##      On the hypervisor (Server):
##              It is likely that you already have the full Hyper-V platform installed.  If not, do so, reboot, and configure: 
##                 Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
##      On hypervisor (all):
##             --> not needed <-- Import-Module Hyper-V
##             Enable ps-remoting
##             You may need to enable WinRM, often via GPO Administrative Templates
## Testing Setup:
##     From the controller, with a worker VM running:
##             Start a PowerShell/ISE window as administrator
##             Use "get-VM -ComputerName hypervisorName -Name vmname" to ensure you can talk to the hypervisor.  
##             run "enter-PsSession -ComputerName vmname" to ensure you can run remote powershell commands to the worker.
##
## Usage:
##     Edit this script up to and including the conversionsParameters variable for your particulars.
##     Run this script (preferably from an administrative powershell/ise window).
##     When prompted, enter the username/credentials needed on the remote worker VM.
##     When packages are created, but before signing, there will be a prompt to continue.
##     When signing is completed, look in the "out" folder under the folder containing this script.  Packages and logs may be found there.

### Configuration
#   $retryBad tells the script to take a second shot of packaging any application package that obviously fails on the first attempt.
#   $AutoFixPackages tells the script to run TMEDITx on the packages to automatically inject the PSF with the default set of fixups and configuration.
#   $SignPackages tells the script to sign the packages.  Note that if you use AutoFixPackages the TMEditX tool can be configured to sign the packages instead.
$retryBad = $true
$AutoFixPackages = $true
$SignPackages = $false

# This is the only prompt you'll get.  You must enter your password that is needed to work with the remote VMs.
$credential = Get-Credential

# Hyper-V can get a little touchy if you try to do too much in parallel.  In particular, the controller VM needs lots of resources when parallel packaging on more VMs, so don't bog down the Hypervisor it is on.
# Just rebooting all of the hypervisors before starting seems to help quite a bit.
## Configuration
#    Name is the both the worker VM name in Hyper-V and the Windows Machine Name for DNS.
#    host is the hypervisor hosting the VM.
#    initialSnapshotName is the name of the snapshot/checkpoint with your account logged on.
$virtualMachines = @(
  ##   @{ Name = "n1WorkerA"; Credential = $credential; host='nuc1'; initialSnapshotName='Snap' }
     @{ Name = "n1WorkerB"; Credential = $credential; host='nuc1'; initialSnapshotName='Snap' }
  #  @{ Name = "n1WorkerC"; Credential = $credential; host='nuc1'; initialSnapshotName='Snap' }
     @{ Name = "n3WorkerB"; Credential = $credential; host='nuc3'; initialSnapshotName='Snap' }
  #  @{ Name = "n3WorkerC"; Credential = $credential; host='nuc3'; initialSnapshotName='Snap' }
     @{ Name = "n5WorkerA"; Credential = $credential; host='nuc5'; initialSnapshotName='Snap' }
     @{ Name = "n5WorkerB"; Credential = $credential; host='nuc5'; initialSnapshotName='Snap' }
  #  @{ Name = "n5WorkerC"; Credential = $credential; host='nuc5'; initialSnapshotName='Snap' }
  ##   @{ Name = "n6WorkerA"; Credential = $credential; host='nuc6'; initialSnapshotName='Snap' }
     @{ Name = "n6WorkerB"; Credential = $credential; host='nuc6'; initialSnapshotName='Snap' }
  #  @{ Name = "n6WorkerC"; Credential = $credential; host='nuc6'; initialSnapshotName='Snap' }
)

## Configuration
#   $PublisherName is the subject name of your certificate.
#   $signtoolPath is for the controller, only needed if $SignPackages was enabled.
#   $certfile/password/timestamper only needed for controller is $SignPackages was enabled.
#   $DefaultInstallerPath is the executable on the remote machine that will be used to run your installer script.  PowerShell is a good choice!  
#   $InstallerArgStart is the start of command line parameters for this executable.
#      These last two variables are just a convenence to make the $conversionsParameters array a bit simpler to look at.
$PublisherName = "CN=TMurgent Technologies LLP, O=TMurgent Technologies LLP, L=Canton, S=Massachusetts, C=US";
$PublisherDisplayName = "Packaged by TMurgent Technologies, LLP";
$signtoolPath = "\\nuc2\Installers\Tim\Cert\signtool.exe"
$certfile = "\\nuc2\Installers\Cert\SigningCert.pfx"
$certpassword = "Deprecated" 
$timestamper = 'http://timestamp.digicert.com'
$DefaultInstallerPath = "C:\Windows\system32\WindowsPowerShell\v1.0\powershell.exe";
$InstallerArgStart = "-ExecutionPolicy Bypass -File \\nuc2\installers\Automation\Apps"

## Configuration
# This is an array of things to be packaged.
#   InstallerPath is used on the remote worker as the command exe to run for both the
#   PreInstallerArgumtnes and InstallerArguments scripts (when present).
#   PackageName will be the name in the package as well as the package filename.
#   Enabled is used to turn off array elements rather than have to delete them.
$conversionsParameters = @(
    @{
        InstallerPath = $DefaultInstallerPath;
        PreInstallerArguments = $nul
        InstallerArguments = "$($InstallerArgStart)\7Zip\PassiveInstall.ps1";
        PackageName = "7Zip";
        PackageDisplayName = "7-Zip";
        PublisherName = $PublisherName;
        PublisherDisplayName = $PublisherDisplayName;
        PackageVersion = "19.0.0.0";
        Enabled = $true
    },
    @{
       InstallerPath = $DefaultInstallerPath;
       PreInstallerArguments = $nul
       InstallerArguments = "$($InstallerArgStart)\NotepadPlusPlus\PassiveInstall.ps1";
       PackageName = "NotepadPlusPlus";
       PackageDisplayName = "NotepadPlusPlus";
       PublisherName = $PublisherName;
       PublisherDisplayName = $PublisherDisplayName;
       PackageVersion = "8.1.2.0";
       Enabled = $true
    },
    @{
       InstallerPath = $DefaultInstallerPath;
       PreInstallerArguments = "$($InstallerArgStart)\NotepadPlusPlus_Plugins\PassiveInstall.ps1";
       InstallerArguments = "$($InstallerArgStart)\NotepadPlusPlus_Plugins\PassiveInstall.ps1";
       PackageName = "NotepadPlusPlus_Plugins";
       PackageDisplayName = "NotepadPlusPlus Plugins";
       PublisherName = $PublisherName;
       PublisherDisplayName = $PublisherDisplayName;
       PackageVersion = "8.1.2.0";
       Enabled = $true
    },
    @{
       InstallerPath = $DefaultInstallerPath;
       PreInstallerArguments = $nul
       InstallerArguments = "$($InstallerArgStart)\ObsStudio\PassiveInstall.ps1";
       PackageName = "ObsStudio";
       PackageDisplayName = "Obs Studio";
       PublisherName = $PublisherName;
       PublisherDisplayName = $PublisherDisplayName;
       PackageVersion = "27.0.1.0";
       Enabled = $false
    }
)


#############################################################################################
##############################  All Edits above this line ###################################
#############################################################################################

$workingDirectory = [System.IO.Path]::Combine($PSScriptRoot, "out")



Write-Host "Converting $($conversionsParameters.Count) packages using $($virtualMachines.Count) VMs." -ForegroundColor Cyan
RunConversionJobs -conversionsParameters $conversionsParameters -virtualMachines $virtualMachines $workingDirectory -RetryBad $RetryBad

$countPackages = (get-item "$($workingDirectory)\MSIX\*.msix").Count
Write-Host "$($countPackages) packages created." -ForegroundColor Green

#####Read-Host -Prompt "Press Enter key to continue to package signing $($countPackages) packages."
if ($AutoFixPackages)
{
    Write-Host "AutoFix $($countPackages) packages..." -ForegroundColor Cyan
    AutoFixPackages "$workingDirectory\MSIX" "$workingDirectory\MSIXPsf"
}

if ($signPackages)
{
    Write-Host "Sign $($countPackages) packages..." -ForegroundColor Cyan
    if ($countPackages -gt 0)
    {
        SignPackages "$workingDirectory\MSIX" $signtoolPath $certfile $certpassword $timestamper
    }
}

Write-Host "Done." -ForegroundColor Green
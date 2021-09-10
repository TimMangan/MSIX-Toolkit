# Batch Conversion scripts
A set of basic scripts that allow converting a batch of installers on a set of machines using MSIX Packaging Tool:

## Supporting scripts
1. batch_convert.ps1 - Dispatch work to target machines
2. entry.ps1 - Provides application, virtual machine, and /or remote machine information then executes scripts based on information provided.

## Requirements
1.  The Microsoft MSIX Packaging Tool
2.  Signtool
3.  Optionally TMEditX to inject the PSF and sign.
4.  Hyper-V to host VMs for packaging.

## Usage
Edit the file entry.ps1 with:
1.  The parameters of your virtual/remote machines 
2.  Configuration for installers you would like to convert.
3.  CodeSigning file and Password.
See entry1.ps1 for more details on setting up.
Run: entry.ps1

<#
.SYNOPSIS
    Automation script

.DESCRIPTION
    Automation script to downloading files from remote server (GitHub), preprocess *proj files,
    produce binaries, compute hash codes, archive and publish archives and symbols into output
    path.

.PARAMETER MsBuildPath
    [Optional] This program by default trying to find Visual Studio MsBuild, if you don't have Visual
    Studio installed or using other operation system you could manually pass path
    to your build tool.

.PARAMETER Configuration
    [Optional] Configuration for MSBuild (Release, Debug). Default value: Release.

.PARAMETER Platform
    [Optional] Platform for MSBuild. Default value: x64

.PARAMETER SourcesDirectory
    [Optional] Path to downloading projects.

.PARAMETER Owner
    [Optional] Your name in GitHub. Default value: Radmir95

.PARAMETER Repository
    [Optional] Your repository in GitHub. Default value: MsBuildTest
#>

param(
    [string]$MsBuildPath = "",
    [string]$Configuration = "Release",
    [string]$Platform = "x64",
    [string]$SourcesDirectory = "",
    [string]$Owner = "Radmir95",
    [string]$Repository = "MsBuildTest",
    [string]$OAthToken = ""
)

if ([System.String]::IsNullOrEmpty($SourcesDirectory)){
    $SourcesDirectory = Get-Location
}

$destinationPath = Join-Path -Path $SourcesDirectory -ChildPath "$($Owner)_$($repository)"

function GetMsBuildPathFromVswhere {
    $path = $null;

    try{
        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        $path = & $vswhere -latest -prerelease -products * -requires Microsoft.Component.MSBuild -property installationPath
        if ($path) {
            $tool = join-path $path 'MSBuild\Current\Bin\MSBuild.exe'
            if (test-path $tool) {
                $path = $tool
            }
            else {
                $tool = join-path $path 'MSBuild\15.0\Bin\MSBuild.exe'
                if (test-path $tool) {
                    $path = $tool
                }
            }
        }
        
        if ($null -ne $path){
            return $path
        }
        else{
            throw
        }
    }
    catch{
        throw "Couldn't find path to MsBuild. Please install MsBuild and pass path to MsBuild through argument."
    }
}

function InitializeWebClient{
    Param(
        [string]$OAthToken = ""
    )
    $webClient = New-Object -TypeName System.Net.WebClient
    if (![System.String]::IsNullOrEmpty($OAthToken)){
        $webClient.Headers.Add('Authorization', "token $($OAthToken)")
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    return $webClient
}

function GetFilesFromRepo {
    Param(
        [System.Net.WebClient]$WebClient,
        [string]$Owner,
        [string]$Repository,
        [string]$Path,
        [string]$DestinationPath
        )
    
        $baseUri = "https://api.github.com/"
        $otherPath = "repos/$Owner/$Repository/contents/$Path"
        $webClient.Headers.Add("user-agent", "Anything");
        $content = $WebClient.DownloadString($baseuri+$otherPath)
        $objects = $content | ConvertFrom-Json
        $files = $objects | Where-Object {$_.type -eq "file"} | Select-Object -exp download_url
        $directories = $objects | Where-Object {$_.type -eq "dir"}
    
        $directories | ForEach-Object { 
            $dest = Join-Path -Path $DestinationPath -ChildPath $_.name
            GetFilesFromRepo -WebClient $WebClient -Owner $Owner -Repository $Repository -Path $_.path -DestinationPath $dest
        }

        if (-not (Test-Path $DestinationPath)) {
            # Destination path does not exist, let's create it
            try {
                New-Item -Path $DestinationPath -ItemType Directory -ErrorAction Stop
            } catch {
                throw "Could not create path '$DestinationPath'!"
            }
        }

        foreach ($file in $files) {
            $fileDestination = Join-Path $DestinationPath (Split-Path $file -Leaf)
            try {
                $webClient.Headers.Add("user-agent", "Anything");
                $WebClient.DownloadFile($file, $fileDestination)
                "Placed '$($file)' to '$fileDestination'"
            } catch {
                throw "Unable to download '$($file.path)'"
            }
        }
}

function EnableSymbolsInConfiguration {
    param (
        [string]$SourcesDirectory,
        [string]$Configuration
    )
    
    $csprojFiles = Get-ChildItem -Path $SourcesDirectory -Recurse | Where-Object {$_.Extension -eq ".csproj"}
    $vcxprojFiles = Get-ChildItem -Path $SourcesDirectory -Recurse | Where-Object {$_.Extension -eq ".vcxproj"}

    foreach ($projFile in $csprojFiles){
        $path = $projFile.FullName
        $xml = [xml](Get-Content $path)
        $xmlns = $xml.Project.xmlns
        $nodes = $xml.Project.PropertyGroup | Where-Object {$_.Condition -Match $Configuration}
        
        foreach ($node in $nodes){
            $val = $node.DebugSymbols

            if ($null -eq $val){
                $newElem = $xml.CreateElement("DebugSymbols", $xmlns)
                $newElem.InnerText = "true"
                $node.AppendChild($newElem)
            }
            elseif ($val -ne "true"){
                $node.DebugSymbols = "true"
            }
        }
        $xml.Save($path)
    }

    foreach ($projFile in $vcxprojFiles){
        $path = $projFile.FullName
        $xml = [xml](Get-Content $path)
        $xmlns = $xml.Project.xmlns
        $nodes = $xml.Project.ItemDefinitionGroup | Where-Object {$_.Condition -Match $Configuration}
        
        foreach ($node in $nodes){
            $val = $node.Link.GenerateDebugInformation

            if ($null -eq $val){
                $newElem = $xml.CreateElement("GenerateDebugInformation", $xmlns)
                $newElem.InnerText = "true"
                $node.Link.AppendChild($newElem)
            }
            elseif ("false" -eq $val.InnerText){
                $node.Link.GenerateDebugInformation = "true"
            }
        }
        $xml.Save($path)
    }
} 

function BuildProjects {
    param (
        [string]$MsBuildPath,
        [string]$SourcesDirectory,
        [string[]]$MsBuildArgs
    )
    
    $slnFilePath = Get-ChildItem -Path $SourcesDirectory | Where-Object {$_.Extension -eq ".sln"}
    $fullPath = $slnFilePath.FullName

    $MsBuildArgs = $MsBuildArgs + $fullPath
    
    & $MsBuildPath $MsBuildArgs
}

function GenerateHashManifestFiles{
    param(
        [string]$SourcesDirectory,
        [string]$Configuration,
        [string]$Platform
    )

    $projFolders = Get-ChildItem -Path $SourcesDirectory | Where-Object {$true -eq $_.PSIsContainer }
    
    $pathToBinaries = "bin/$($Configuration)_$($Platform)/"

    foreach ($projFolder in $projFolders){
        if ($projFolder.Name -eq "out"){
            continue
        }

        $path = Join-Path -Path $projFolder.FullName -ChildPath $pathToBinaries
        $files = Get-ChildItem -Path $path -Recurse | Where-Object {$_.Extension -eq ".dll" -or $_.Extension -eq ".exe"}
        
        $manifestPath = Join-Path -Path $path -ChildPath "manifest.xml"

        if (Test-Path $manifestPath){
            Remove-Item $manifestPath
        }

        New-Item $manifestPath -ItemType File
        Set-Content $manifestPath '<Files></Files>'
        $xml = [xml](Get-Content $manifestPath)

        foreach ($file in $files){
            $hash = Get-FileHash $file.FullName
            $fileElem = $xml.CreateElement("File")

            $fileNameElem = $xml.CreateElement("FileName")
            $fileNameElem.InnerText = $hash.Path

            $hashElem = $xml.CreateElement("Hash")
            $hashElem.InnerText = $hash.Hash
            $fileElem.AppendChild($fileNameElem)
            $fileElem.AppendChild($hashElem)

            $xml.FirstChild.AppendChild($fileElem)
        }
        $xml.Save($manifestPath)
    }
}

function CompressArchiveAndCopyIntoConfigurationFolder{
    param (
        [string]$SourcesDirectory,
        [string]$Configuration,
        [string]$Platform
    )

    $projFolders = Get-ChildItem -Path $SourcesDirectory | Where-Object {$true -eq $_.PSIsContainer }

    $pathToBinaries = "bin/$($Configuration)_$($Platform)/"

    $outputPath = Join-Path -Path $SourcesDirectory -ChildPath "out/$($Configuration)"

    if ($false -eq (Test-Path -Path $outputPath)){
        New-Item -Path $outputPath -ItemType Directory -ErrorAction Stop
    }

    foreach ($projFolder in $projFolders){
        if ($projFolder.Name -eq "out"){
            continue
        }

        $path = Join-Path -Path $projFolder.FullName -ChildPath $pathToBinaries
        $destZipPath = Join-Path -Path $path -ChildPath "$($projFolder).zip"

        $compress = @{
            Path = "$($path)manifest.xml", "$($path)*.dll", "$($path)*.exe" 
            CompressionLevel = "Fastest"
            DestinationPath = $destZipPath
        }

        Compress-Archive @compress -Force
        Copy-Item $destZipPath -Destination $outputPath
    }
}

function CopySymbols{
    param (
        [string]$SourcesDirectory,
        [string]$Configuration,
        [string]$Patform
    )

    $pathToBinaries = "bin/$($Configuration)_$($Platform)/"
    $projFolders = Get-ChildItem -Path $SourcesDirectory | Where-Object {$true -eq $_.PSIsContainer }
    $outputPath = Join-Path -Path $SourcesDirectory -ChildPath "out/$($configuration)/Symbols"   

    foreach ($projFolder in $projFolders){
        if ($projFolder.Name -eq "out"){
            continue
        }

        $path = Join-Path -Path $projFolder.FullName -ChildPath $pathToBinaries
        $pdbs = Get-ChildItem -Path $path -Recurse | Where-Object {$_.Extension -eq ".pdb"}

        $outPdbPath = Join-Path -Path $outputPath -ChildPath $projFolder.Name

        if ($false -eq (Test-Path -Path $outPdbPath)){
            New-Item -Path $outPdbPath -ItemType Directory -ErrorAction Stop
        }

        foreach ($pdb in $pdbs){
            Copy-Item $pdb.FullName -Destination $outPdbPath
        }
    }
}

if ([System.String]::IsNullOrEmpty($OAthToken)){
    $OAthToken = ""
}

# Init WebClient
$webClient = InitializeWebClient -OAthToken $OAthToken

# Download recursivly files
GetFilesFromRepo -WebClient $webClient -Owner $Owner -Repository $Repository -DestinationPath $DestinationPath

# Enable debug symbols in Release configuration
EnableSymbolsInConfiguration -SourcesDirectory $DestinationPath -Configuration $Configuration

if ([System.String]::IsNullOrEmpty($MsBuildPath)){
    # Trying to find MsBuild otherwise will raise exception
    $MsBuildPath = GetMsBuildPathFromVswhere
}
# Build configurations
$paramConfiguration = "/p:Configuration=$($Configuration)"
$paramPlatform = "/p:Platform=$($Platform)"
$msBuildArgs = @($paramConfiguration, $paramPlatform)

# Start build
BuildProjects -MsBuildPath $MsBuildPath -MsBuildArgs $msBuildArgs -SourcesDirectory $DestinationPath

# Get SHA256 Hash, create manifest file
GenerateHashManifestFiles -SourcesDirectory $DestinationPath -Configuration $Configuration -Platform $Platform

# Compress and copy archives into destination folder
CompressArchiveAndCopyIntoConfigurationFolder -SourcesDirectory $DestinationPath -Configuration $Configuration -Platform $Platform

# Copy symbols into Symbols directory ({solution_foler}/out/{Configuration_Platform})
CopySymbols -SourcesDirectory $DestinationPath -Configuration $Configuration -Patform $Platform

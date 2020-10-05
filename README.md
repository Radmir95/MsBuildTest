# MsBuildTest

## Description

This solution contains three simple projects and automation script for processing these projects.

## Solution structure
This solution conains following projects:
* CppProj
* FirstCSProj
* SecondCSProj

CppProj - simple cpp project which writes in console "Hello World" message.  
FirstCSProj - call static method from SecondCSProj and writes in console result message.  
SecondCSProj - contain static method which returns "Hello" message.  

## AutomationScript working process
1) GetFilesFromRepo function. Downloads files from specified repository (by default selected this repository). 
If you want to change repository to other one you should pass in script additional parameters `AutomationScript.ps1 -Owner {you_name} -Repository {you_repository}`, 
also change authorization token in InitializeWebClient function.
2) EnableSymbolsInConfiguration function. Add DebugSymbols node if doesn't exist or change it to true in csproj files. Add GenerateDebugInformation if doesn't exist 
or change it to true in vcxproj files.
3) GetMsBuildPathFromVswhere function. Trying to get information about installed Visual Studio and find path to MSBuild tools. If function cannot find path it throws exception.
 Also you could specify path to MSBuild in parameters `AutomationScript.ps1 -MsBuildPath {you_path}`.
4) BuildProjects function. Build projects.
5) GenerateHashManifestFiles function. Generates manifest.xml output files with following structure:
```
<Files>
  <File>
    <FileName>{Name of file}</FileName>
    <Hash>{Sha256 hash}</Hash>
  </File>
  ...
</Files>
```
6) CompressArchiveAndCopyIntoConfigurationFolder function. Compress archives and place them into {solution_foler}/out/{Configuration} folder.
7) CopySymbols function. Copies symbols into Symboles directory in {solution_foler}/out/{Configuration}/Symbols folder.

## Notes
* If you have OAth token for your repository, you could pass it as parameter: `AutomationScript.ps1 -OAuthToken {your_token}`
* This repository contains also AutomationScript.ps1 file. You don't need to download other files.
* It don't work under 'Any Cpy' configuration. For this needs to add this configuration in *proj files.
* This project by default trying to find all outputs of projects in bin/{Configuration}_{Platform} folder. It won't work if OutputDir configured in another way.

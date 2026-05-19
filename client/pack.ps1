param (
    [string]$sourceDir = "$PSScriptRoot\build\windows\x64\runner\Release"
)

$zipPath = Join-Path $PSScriptRoot "extfrtc_payload.zip"
$csPath = Join-Path $PSScriptRoot "Wrapper.cs"
$exePath = Join-Path $PSScriptRoot "ExtFRTC_Single.exe"

Write-Host "Creating zip archive..."
if (Test-Path $zipPath) { Remove-Item $zipPath }
Compress-Archive -Path "$sourceDir\*" -DestinationPath $zipPath

Write-Host "Writing C# wrapper..."
$csCode = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.IO.Compression;

class Program
{
    static void Main()
    {
        string tempFolder = Path.Combine(Path.GetTempPath(), "ExtFrtcApp_" + Guid.NewGuid().ToString().Substring(0, 8));
        try
        {
            Directory.CreateDirectory(tempFolder);

            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream resFilestream = assembly.GetManifestResourceStream("payload.zip"))
            {
                if (resFilestream == null) throw new Exception("Payload not found");
                using (var zipArchive = new ZipArchive(resFilestream, ZipArchiveMode.Read))
                {
                    zipArchive.ExtractToDirectory(tempFolder);
                }
            }

            string exePath = Path.Combine(tempFolder, "sharemyself.exe");
            Process p = Process.Start(new ProcessStartInfo(exePath) { UseShellExecute = false });
            p.WaitForExit();
        }
        catch (Exception ex)
        {
            Console.WriteLine("Error: " + ex.Message);
        }
        finally 
        {
            try { Directory.Delete(tempFolder, true); } catch { }
        }
    }
}
"@
Set-Content -Path $csPath -Value $csCode -Encoding UTF8

Write-Host "Compiling standalone executable..."
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /target:winexe /out:$exePath /reference:System.IO.Compression.FileSystem.dll /reference:System.IO.Compression.dll /resource:$zipPath,payload.zip $csPath

Write-Host "Done! Executable created at $exePath"

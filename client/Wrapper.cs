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

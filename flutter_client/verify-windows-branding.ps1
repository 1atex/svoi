param(
    [Parameter(Mandatory)][string]$Executable,
    [string]$Icon = "$PSScriptRoot/../assets/svoi.ico"
)
$ErrorActionPreference = 'Stop'
if (-not ('SvoiIconResources' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
public static class SvoiIconResources {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr LoadLibraryEx(string name, IntPtr file, uint flags);
    [DllImport("kernel32.dll", EntryPoint="FindResourceW", SetLastError=true)]
    static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll")] static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32.dll")] static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
    static byte[] Read(IntPtr module, int id, int type) {
        var resource = FindResource(module, (IntPtr)id, (IntPtr)type);
        if (resource == IntPtr.Zero) throw new Exception("Missing icon resource " + id);
        var pointer = LockResource(LoadResource(module, resource));
        var bytes = new byte[SizeofResource(module, resource)];
        if (pointer == IntPtr.Zero || bytes.Length == 0) throw new Exception("Empty icon resource");
        Marshal.Copy(pointer, bytes, 0, bytes.Length);
        return bytes;
    }
    public static void Verify(string executable, string icon) {
        var source = File.ReadAllBytes(icon);
        var module = LoadLibraryEx(executable, IntPtr.Zero, 0x22);
        if (module == IntPtr.Zero) throw new Exception("Cannot open EXE resources");
        try {
            foreach (int groupId in new[] {101, 102}) {
                var group = Read(module, groupId, 14);
                int count = BitConverter.ToUInt16(source, 4);
                if (BitConverter.ToUInt16(group, 4) != count) throw new Exception("Icon frame count differs");
                for (int i = 0; i < count; ++i) {
                    int icoEntry = 6 + i * 16, resourceEntry = 6 + i * 14;
                    int length = BitConverter.ToInt32(source, icoEntry + 8);
                    int offset = BitConverter.ToInt32(source, icoEntry + 12);
                    var expected = source.Skip(offset).Take(length).ToArray();
                    var actual = Read(module, BitConverter.ToUInt16(group, resourceEntry + 12), 3);
                    if (!source.Skip(icoEntry).Take(4).SequenceEqual(group.Skip(resourceEntry).Take(4)) ||
                        !source.Skip(icoEntry + 6).Take(6).SequenceEqual(group.Skip(resourceEntry + 6).Take(6)) ||
                        !expected.SequenceEqual(actual)) throw new Exception("Stale icon in EXE, group " + groupId + ", frame " + i);
                }
            }
        } finally { FreeLibrary(module); }
    }
}
'@
}
$exePath = (Resolve-Path -LiteralPath $Executable).Path
[SvoiIconResources]::Verify($exePath, (Resolve-Path -LiteralPath $Icon).Path)
$info = [Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
if ($info.ProductName -ne 'SVOI' -or $info.FileDescription -ne 'SVOI') {
    throw 'Windows application name must be SVOI'
}
Write-Output 'Verified SVOI name and all application/tray icon frames in the compiled EXE.'

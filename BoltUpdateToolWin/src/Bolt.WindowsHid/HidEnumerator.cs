using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Bolt.WindowsHid;

public static class HidEnumerator
{
    public static IReadOnlyList<HidDeviceInfo> Enumerate()
    {
        NativeMethods.HidD_GetHidGuid(out var hidGuid);
        var set = NativeMethods.SetupDiGetClassDevsW(
            in hidGuid,
            0,
            0,
            NativeMethods.DigcfPresent | NativeMethods.DigcfDeviceInterface);
        if (set == new nint(-1))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiGetClassDevs failed.");
        }

        try
        {
            var results = new List<HidDeviceInfo>();
            for (uint index = 0; ; index++)
            {
                var interfaceData = new NativeMethods.SpDeviceInterfaceData
                {
                    Size = Marshal.SizeOf<NativeMethods.SpDeviceInterfaceData>()
                };
                if (!NativeMethods.SetupDiEnumDeviceInterfaces(
                        set, 0, in hidGuid, index, ref interfaceData))
                {
                    var error = Marshal.GetLastWin32Error();
                    if (error == NativeMethods.ErrorNoMoreItems)
                    {
                        break;
                    }

                    throw new Win32Exception(error, "SetupDiEnumDeviceInterfaces failed.");
                }

                _ = NativeMethods.SetupDiGetDeviceInterfaceDetailW(
                    set, ref interfaceData, 0, 0, out var required, 0);
                var detail = Marshal.AllocHGlobal(checked((int)required));
                try
                {
                    Marshal.WriteInt32(detail, Environment.Is64BitProcess ? 8 : 6);
                    if (!NativeMethods.SetupDiGetDeviceInterfaceDetailW(
                            set, ref interfaceData, detail, required, out _, 0))
                    {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "SetupDiGetDeviceInterfaceDetail failed.");
                    }

                    var path = Marshal.PtrToStringUni(detail + 4)
                        ?? throw new InvalidOperationException("HID interface has no device path.");
                    var info = ReadInfo(path);
                    if (info is not null)
                    {
                        results.Add(info);
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(detail);
                }
            }

            return results;
        }
        finally
        {
            _ = NativeMethods.SetupDiDestroyDeviceInfoList(set);
        }
    }

    private static HidDeviceInfo? ReadInfo(string path)
    {
        using var handle = NativeMethods.CreateFile(
            path,
            0,
            NativeMethods.FileShareRead | NativeMethods.FileShareWrite,
            0,
            NativeMethods.OpenExisting,
            0,
            0);
        if (handle.IsInvalid)
        {
            return null;
        }

        var attributes = new NativeMethods.HiddAttributes
        {
            Size = Marshal.SizeOf<NativeMethods.HiddAttributes>()
        };
        if (!NativeMethods.HidD_GetAttributes(handle, ref attributes) ||
            !NativeMethods.HidD_GetPreparsedData(handle, out var preparsed))
        {
            return null;
        }

        try
        {
            var status = NativeMethods.HidP_GetCaps(preparsed, out var caps);
            if (status < 0)
            {
                return null;
            }

            return new(
                attributes.VendorId,
                attributes.ProductId,
                caps.UsagePage,
                caps.Usage,
                caps.InputReportByteLength,
                caps.OutputReportByteLength,
                caps.FeatureReportByteLength,
                NativeMethods.GetProductString(handle),
                path);
        }
        finally
        {
            _ = NativeMethods.HidD_FreePreparsedData(preparsed);
        }
    }
}

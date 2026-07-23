namespace Bolt.WindowsHid;

public static class BoltDeviceLocator
{
    public const ushort LogitechVendorId = 0x046D;
    public const ushort RuntimeProductId = 0xC548;
    public const ushort BootloaderProductId = 0xAB07;
    public const ushort RuntimeUsagePage = 0xFF00;
    public const ushort RuntimeUsage = 0x0001;
    public const ushort RuntimeLongReportUsage = 0x0002;

    public static IReadOnlyList<HidDeviceInfo> ListRuntimeInterfaces() =>
        HidEnumerator.Enumerate()
            .Where(device =>
                device.VendorId == LogitechVendorId &&
                device.ProductId == RuntimeProductId)
            .ToArray();

    public static IReadOnlyList<HidDeviceInfo> ListBootloaderInterfaces() =>
        HidEnumerator.Enumerate()
            .Where(device =>
                device.VendorId == LogitechVendorId &&
                device.ProductId == BootloaderProductId)
            .ToArray();

    public static (HidDeviceInfo ShortReports, HidDeviceInfo LongReports)
        FindRuntimeHidppInterfaces()
    {
        var interfaces = ListRuntimeInterfaces();
        var shortReports = interfaces.FirstOrDefault(device => device.IsBoltRuntimeHidpp);
        var longReports = interfaces.FirstOrDefault(
            device => device.IsBoltRuntimeHidppLongReports);
        if (shortReports is null)
        {
            throw new InvalidOperationException(
                "No Bolt runtime interface 046D:C548 FF00:0001 was found.");
        }

        if (longReports is null)
        {
            throw new InvalidOperationException(
                "No Bolt long-report interface 046D:C548 FF00:0002 was found.");
        }

        return (shortReports, longReports);
    }

    public static (HidDeviceInfo ShortReports, HidDeviceInfo LongReports)
        FindBootloaderHidppInterfaces()
    {
        var interfaces = ListBootloaderInterfaces();
        var shortReports = interfaces.FirstOrDefault(device =>
            device.InputReportLength >= 7 &&
            device.OutputReportLength >= 7 &&
            device.InputReportLength < 20);
        var longReports = interfaces.FirstOrDefault(device =>
            device.InputReportLength >= 20 &&
            device.OutputReportLength >= 20);
        if (shortReports is null || longReports is null)
        {
            throw new InvalidOperationException(
                "AB07 was detected, but its HID++ short-/long-report interfaces " +
                "could not be identified unambiguously.");
        }

        return (shortReports, longReports);
    }
}

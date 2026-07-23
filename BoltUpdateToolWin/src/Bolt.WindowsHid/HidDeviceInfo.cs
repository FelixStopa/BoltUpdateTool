namespace Bolt.WindowsHid;

public sealed record HidDeviceInfo(
    ushort VendorId,
    ushort ProductId,
    ushort UsagePage,
    ushort Usage,
    ushort InputReportLength,
    ushort OutputReportLength,
    ushort FeatureReportLength,
    string Product,
    string DevicePath)
{
    public bool IsBoltRuntime =>
        VendorId == BoltDeviceLocator.LogitechVendorId &&
        ProductId == BoltDeviceLocator.RuntimeProductId;

    public bool IsBoltRuntimeHidpp =>
        IsBoltRuntime &&
        UsagePage == BoltDeviceLocator.RuntimeUsagePage &&
        Usage == BoltDeviceLocator.RuntimeUsage;

    public bool IsBoltRuntimeHidppLongReports =>
        IsBoltRuntime &&
        UsagePage == BoltDeviceLocator.RuntimeUsagePage &&
        Usage == BoltDeviceLocator.RuntimeLongReportUsage;
}

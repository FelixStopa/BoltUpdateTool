namespace Bolt.Protocol;

public enum HidppReportId : byte
{
    Short = 0x10,
    Long = 0x11
}

public readonly record struct HidppMessage(
    HidppReportId ReportId,
    byte DeviceId,
    byte SubId,
    byte FunctionId,
    ReadOnlyMemory<byte> Data)
{
    public const byte ReceiverDeviceId = 0xFF;
    public const byte SoftwareId = 0x0A;

    public int WireLength => ReportId == HidppReportId.Short ? 7 : 20;

    public byte[] Pack()
    {
        var result = new byte[WireLength];
        result[0] = (byte)ReportId;
        result[1] = DeviceId;
        result[2] = SubId;
        result[3] = FunctionId;
        Data.Span[..Math.Min(Data.Length, result.Length - 4)].CopyTo(result.AsSpan(4));
        return result;
    }

    public static HidppMessage Unpack(ReadOnlySpan<byte> report)
    {
        if (report.Length < 4 ||
            report[0] is not ((byte)HidppReportId.Short) and not ((byte)HidppReportId.Long))
        {
            throw new HidppProtocolException($"Malformed HID++ report ({report.Length} bytes).");
        }

        var expected = report[0] == (byte)HidppReportId.Short ? 7 : 20;
        if (report.Length < expected)
        {
            throw new HidppProtocolException(
                $"Truncated HID++ report 0x{report[0]:X2}: expected {expected}, got {report.Length}.");
        }

        return new(
            (HidppReportId)report[0],
            report[1],
            report[2],
            report[3],
            report[4..expected].ToArray());
    }
}

public sealed class HidppProtocolException(string message) : Exception(message);

public sealed class HidppRemoteException(
    bool isHidpp10,
    byte code,
    byte requestSubId,
    byte requestFunctionId)
    : Exception(
        $"HID++{(isHidpp10 ? "1.0" : "2.0")} error 0x{code:X2} for " +
        $"sub-ID 0x{requestSubId:X2}, function 0x{requestFunctionId:X2}.")
{
    public bool IsHidpp10 { get; } = isHidpp10;
    public byte Code { get; } = code;
}

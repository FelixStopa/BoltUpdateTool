namespace Bolt.Protocol;

public static class HidppFeatures
{
    public const ushort Root = 0x0000;
    public const ushort FirmwareInfo = 0x0003;
    public const ushort Dfu = 0x00D0;
}

public sealed class Hidpp20Session(IHidppTransport transport, byte deviceId = 0xFF)
{
    private readonly Dictionary<ushort, byte> featureCache = [];

    public byte DeviceId { get; } = deviceId;

    public async Task<byte> PingAsync(CancellationToken cancellationToken = default)
    {
        var request = ShortMessage(0x00, 0x01, new byte[] { 0x00, 0x00, 0xAA });
        var response = await transport.TransferAsync(
            request, 2, ignoreFunctionId: true, cancellationToken);
        return response.Data.Span[0];
    }

    public async Task<byte> GetFeatureIndexAsync(
        ushort featureId,
        CancellationToken cancellationToken = default)
    {
        if (featureCache.TryGetValue(featureId, out var cached))
        {
            return cached;
        }

        var request = ShortMessage(
            0x00,
            0x00,
            new byte[] { (byte)(featureId >> 8), (byte)featureId, 0x00 });
        var response = await transport.TransferAsync(
            request, 2, cancellationToken: cancellationToken);
        var index = response.Data.Span[0];
        featureCache[featureId] = index;
        return index;
    }

    public async Task<IReadOnlyList<FirmwareEntity>> GetFirmwareEntitiesAsync(
        CancellationToken cancellationToken = default)
    {
        var feature = await GetFeatureIndexAsync(
            HidppFeatures.FirmwareInfo, cancellationToken);
        if (feature == 0)
        {
            throw new NotSupportedException(
                "Device does not expose HID++ feature 0x0003 (FirmwareInfo).");
        }

        var countResponse = await transport.TransferAsync(
            ShortMessage(feature, 0x00),
            2,
            cancellationToken: cancellationToken);
        var count = countResponse.Data.Span[0];
        var entities = new List<FirmwareEntity>(count);
        for (byte index = 0; index < count; index++)
        {
            var response = await transport.TransferAsync(
                ShortMessage(feature, 0x01, new byte[] { index }),
                2,
                ignoreFunctionId: true,
                cancellationToken);
            var data = response.Data.Span;
            if (data.Length < 8)
            {
                continue;
            }

            var name = new string(
                data.Slice(1, 3)
                    .ToArray()
                    .Where(value => value is >= 32 and < 127)
                    .Select(value => (char)value)
                    .ToArray());
            entities.Add(new(
                index,
                data[0],
                name,
                data[4],
                data[5],
                (ushort)((data[6] << 8) | data[7]),
                data.Length <= 8 || (data[8] & 1) != 0));
        }

        return entities;
    }

    public HidppMessage LongMessage(byte feature, byte function, ReadOnlyMemory<byte> data) =>
        new(HidppReportId.Long, DeviceId, feature, (byte)(function << 4), data);

    private HidppMessage ShortMessage(
        byte feature,
        byte function,
        ReadOnlyMemory<byte> data = default) =>
        new(HidppReportId.Short, DeviceId, feature, (byte)(function << 4), data);
}
